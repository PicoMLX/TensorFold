//! libPicoTensorFold: one checkpoint's Metal engine and tokenizer behind a C interface, for a host that links no Zig.
const std = @import("std");
const api = @import("engine_api");
const native = @import("native_engines");
const tokenizer = @import("tokenizer");
const hub = @import("hub");
const Allocator = std.mem.Allocator;

/// A host's stderr hears what an engine warns of, not its load and close lines.
pub const std_options: std.Options = .{ .log_level = .warn };

const gpa = std.heap.c_allocator;
// No workers and no signal handlers in the host's process: the engines start their own threads.
var threaded: std.Io.Threaded = .init_single_threaded;

/// status -1: `n` reply tokens, valid during the call; status 0 and up: the request's last call, with its usage.
const Callback = *const fn (ctx: ?*anyopaque, tokens: ?[*]const i32, n: i32, status: i32, usage: ?*const [5]i64) callconv(.c) void;

/// One loaded checkpoint; requests in flight are in `jobs` until their last callback has returned.
const Handle = struct {
    arena: std.heap.ArenaAllocator, // what the open read and the engine was handed: the folder, its type, the end tokens
    opened: api.Opened = undefined,
    info: api.Info = .{},
    tok: tokenizer.Tokenizer = undefined,
    eos: []const u32 = &.{},
    mutex: std.Io.Mutex = .init,
    idle: std.Io.Condition = .init,
    jobs: std.ArrayList(*Job) = .empty,
    next: api.Id = 1, // the engine's names are never reused, so a late cancel cannot reach a newer request
    closing: bool = false,

    fn load(h: *Handle, model_dir: []const u8, problem: *[]const u8) !void {
        const io = threaded.io();
        const a = h.arena.allocator();
        const dir = try a.dupe(u8, model_dir);
        const text = try @import("checkpoint_config").read(a, io, dir, problem) orelse {
            problem.* = try std.fmt.allocPrint(a, "{s} has no config.json", .{dir});
            return error.Refused;
        };
        const config: std.json.Value = std.json.parseFromSliceLeaky(std.json.Value, a, text, .{}) catch .null;
        const model_type = try a.dupe(u8, hub.modelType(a, io, dir));
        h.tok = tokenizer.loadTokenizer(io, gpa, dir) catch |e| {
            problem.* = try std.fmt.allocPrint(a, "cannot read {s}/tokenizer.json ({s})", .{ dir, @errorName(e) });
            return e;
        };
        errdefer h.tok.deinit();
        h.tok.memo = try tokenizer.Memo.create(gpa, 64 << 20); // a chat's earlier turns come back in every prompt
        h.eos = eosIds(a, io, dir, config, &h.tok) catch |e| {
            if (e == error.OutOfMemory) return e;
            problem.* = try std.fmt.allocPrint(a, "invalid checkpoint EOS ({s})", .{@errorName(e)});
            return e;
        };
        h.opened = try native.open(a, gpa, io, .{ .dir = dir, .model_type = model_type }, problem) orelse return error.Refused;
        errdefer h.opened.close(h.opened.ctx);
        h.info = h.opened.engine.info();
        if (!h.info.text_generation) {
            problem.* = try std.fmt.allocPrint(a, "{s} checkpoints write no text", .{model_type});
            return error.Refused;
        }
    }

    fn lock(h: *Handle) void {
        h.mutex.lockUncancelable(threaded.io());
    }

    fn unlock(h: *Handle) void {
        h.mutex.unlock(threaded.io());
    }

    /// The live request the caller named `id`; the caller holds the lock.
    fn find(h: *Handle, id: u64) ?*Job {
        for (h.jobs.items) |job| if (job.id == id) return job;
        return null;
    }

    /// A request the engine is done with (or never took) leaves the handle; a close waiting for the last one wakes.
    fn forget(h: *Handle, job: *Job) void {
        h.lock();
        for (h.jobs.items, 0..) |j, i| if (j == job) {
            _ = h.jobs.swapRemove(i);
            break;
        };
        if (h.jobs.items.len == 0) h.idle.broadcast(threaded.io());
        h.unlock();
        gpa.free(job.request.prompt);
        gpa.destroy(job);
    }
};

/// One request: the engine reads `request` until its `finished` event, which is the caller's last callback.
const Job = struct {
    handle: *Handle,
    id: u64, // the caller's name for it
    engine_id: api.Id = 0,
    request: api.Request,
    cb: Callback,
    ctx: ?*anyopaque,
    submitted: i96,
    prefilled: ?i96 = null,
    cached: u32 = 0,
    sent: i64 = 0,
    ended: bool = false, // an end token came: nothing after it is the reply's
    cancelled: bool = false, // asked to stop, perhaps before the engine knew its name (under the handle's lock)

    /// The engine's sink, on its thread.
    fn event(ctx: *anyopaque, _: api.Id, e: *const api.Event) void {
        const job: *Job = @ptrCast(@alignCast(ctx));
        switch (e.*) {
            .prefilled => |cached| {
                job.cached = cached;
                job.prefilled = now();
            },
            .tokens => |tokens| {
                if (job.ended) return;
                // the engine delivers the end token; the caller's reply stops before it
                const n = for (tokens, 0..) |t, i| {
                    if (std.mem.indexOfScalar(u32, job.request.eos, t) != null) break i;
                } else tokens.len;
                job.ended = n < tokens.len;
                if (n == 0) return;
                job.sent += @intCast(n);
                job.cb(job.ctx, @ptrCast(tokens.ptr), @intCast(n), -1, null);
            },
            .finished => |f| {
                const end = now();
                const filled = job.prefilled orelse end;
                const prompt: i64 = @intCast(job.request.prompt.len);
                const cached: i64 = @min(job.cached, prompt);
                const prefill: i64 = if (f.stats.prefill_seconds) |s| std.math.lossyCast(i64, s * 1e6) else micros(filled - job.submitted);
                const usage = [5]i64{ prompt - cached, cached, job.sent, prefill, micros(end - filled) };
                if (f.reason == .failed) std.log.err("pico_tf: request {d} failed: {s}", .{ job.id, f.message });
                job.cb(job.ctx, null, 0, switch (f.reason) {
                    .stop => 0,
                    .cancelled => 1,
                    .failed, .silence => 2,
                    .length => 3,
                }, &usage);
                job.handle.forget(job);
            },
            else => {},
        }
    }
};

fn now() i96 {
    return std.Io.Clock.awake.now(threaded.io()).toNanoseconds();
}

fn micros(ns: i96) i64 {
    return @intCast(@divTrunc(@max(ns, 0), 1000));
}

/// The checkpoint's end tokens as the server reads them: config.json, generation_config.json, the tokenizer's eos_token.
fn eosIds(a: Allocator, io: std.Io, dir: []const u8, config: std.json.Value, tok: *const tokenizer.Tokenizer) ![]const u32 {
    const vocab = try tokenizer.eos.vocabulary(config, tok.id_to_token.tokens.items.len);
    var out: std.ArrayList(u32) = .empty;
    try out.appendSlice(a, try tokenizer.eos.resolve(a, config, readJson(a, io, dir, "generation_config.json"), vocab));
    const named = readJson(a, io, dir, "tokenizer_config.json");
    if (named == .object) if (named.object.get("eos_token")) |e| {
        const piece = switch (e) {
            .string => |value| value,
            .object => |o| if (o.get("content")) |c| (if (c == .string) c.string else "") else "",
            else => "",
        };
        if (tok.specialTokenId(piece)) |id| try tokenizer.eos.appendId(a, &out, id, vocab);
    };
    return out.items;
}

fn readJson(a: Allocator, io: std.Io, dir: []const u8, name: []const u8) std.json.Value {
    const path = std.fs.path.join(a, &.{ dir, name }) catch return .null;
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(64 << 20)) catch return .null;
    return std.json.parseFromSliceLeaky(std.json.Value, a, bytes, .{}) catch .null;
}

/// A registered family reads the folder's format (MLX affine bits and group, or bf16) and it holds a weights file.
fn servable(a: Allocator, io: std.Io, dir: []const u8) bool {
    const family = hub.family(hub.modelType(a, io, dir)) orelse return false;
    var name: [32]u8 = undefined;
    const format = if (hub.quantization(a, io, dir)) |q| std.fmt.bufPrint(&name, "mlx-q{d}g{d}", .{ q.bits, q.group }) catch return false else "bf16";
    for (family.formats) |f| {
        if (std.mem.eql(u8, f, format)) break;
    } else return false;
    var d = std.Io.Dir.cwd().openDir(io, dir, .{ .iterate = true }) catch return false;
    defer d.close(io);
    var it = d.iterate();
    while (it.next(io) catch null) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".safetensors")) continue;
        const st = d.statFile(io, entry.name, .{}) catch continue; // a cache snapshot's entries are links into blobs
        if (st.size > 0) return true;
    }
    return false;
}

/// `text` into a C buffer of `cap` bytes, cut to fit and NUL-terminated when there is room for one.
fn write(out: ?[*]u8, cap: i32, text: []const u8) void {
    const buf = (out orelse return)[0..@intCast(@max(cap, 0))];
    if (buf.len == 0) return;
    const n = @min(text.len, buf.len - 1);
    @memcpy(buf[0..n], text[0..n]);
    buf[n] = 0;
}

/// 2: `pico_tf_tokenize` takes the text's byte length, so a text may hold NUL characters.
export fn pico_tf_abi_version() i32 {
    return 2;
}

export fn pico_tf_can_serve(model_dir: ?[*:0]const u8) i32 {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    return @intFromBool(servable(arena.allocator(), threaded.io(), std.mem.span(model_dir orelse return 0)));
}

/// `tensorfold info`'s memory floor: the folder's bytes plus the runtime margin.
export fn pico_tf_load_bytes(model_dir: ?[*:0]const u8) i64 {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const weights = hub.sizeOf(arena.allocator(), threaded.io(), std.mem.span(model_dir orelse return -1)) catch return -1;
    if (weights == 0) return -1;
    return std.math.cast(i64, weights + @import("sys").memory_policy.margin) orelse -1;
}

export fn pico_tf_open(model_dir: ?[*:0]const u8, err: ?[*]u8, err_len: i32) ?*Handle {
    const h = gpa.create(Handle) catch {
        write(err, err_len, "OutOfMemory");
        return null;
    };
    h.* = .{ .arena = .init(gpa) };
    var problem: []const u8 = "";
    h.load(std.mem.span(model_dir orelse ""), &problem) catch |e| {
        write(err, err_len, if (problem.len > 0) problem else @errorName(e));
        h.arena.deinit();
        gpa.destroy(h);
        return null;
    };
    return h;
}

export fn pico_tf_close(handle: ?*Handle) void {
    const h = handle orelse return;
    const io = threaded.io();
    h.lock();
    h.closing = true;
    var ids: std.ArrayList(api.Id) = .empty;
    defer ids.deinit(gpa);
    for (h.jobs.items) |job| {
        job.cancelled = true;
        ids.append(gpa, job.engine_id) catch {}; // without memory it runs out on its own
    }
    h.unlock();
    for (ids.items) |id| h.opened.engine.cancel(id);
    h.lock();
    while (h.jobs.items.len > 0) h.idle.waitUncancelable(io, &h.mutex);
    h.unlock();
    h.opened.close(h.opened.ctx);
    h.jobs.deinit(gpa);
    h.tok.deinit();
    h.arena.deinit();
    gpa.destroy(h);
}

export fn pico_tf_tokenize(handle: ?*Handle, text: ?[*]const u8, len: i32, out: ?[*]i32, cap: i32) i32 {
    const h = handle orelse return -1;
    if (len < 0 or (text == null and len > 0)) return -1;
    const bytes: []const u8 = if (text) |t| t[0..@intCast(len)] else &.{};
    if (!std.unicode.utf8ValidateSlice(bytes)) return -1;
    const ids = h.tok.encode(gpa, bytes) catch return -1;
    defer gpa.free(ids);
    const n = @min(ids.len, @as(usize, @intCast(@max(cap, 0))));
    if (out) |o| @memcpy(o[0..n], @as([]const i32, @ptrCast(ids[0..n])));
    return std.math.cast(i32, ids.len) orelse -1;
}

export fn pico_tf_detokenize(handle: ?*Handle, tokens: ?[*]const i32, n: i32, out: ?[*]u8, cap: i32) i32 {
    const h = handle orelse return -1;
    if (n < 0 or (tokens == null and n > 0)) return -1;
    const ids: []const i32 = if (tokens) |t| t[0..@intCast(n)] else &.{};
    for (ids) |id| if (id < 0) return -1;
    const text = h.tok.decode(gpa, @ptrCast(ids), false) catch return -1;
    defer gpa.free(text);
    write(out, cap, text);
    return std.math.cast(i32, text.len) orelse -1;
}

export fn pico_tf_submit(handle: ?*Handle, id: u64, prompt: ?[*]const i32, n: i32, max_tokens: i32, temperature: f32, top_p: f32, cb: ?Callback, ctx: ?*anyopaque) i32 {
    const h = handle orelse return 1;
    if (prompt == null or cb == null or n <= 0) return 1;
    const ids: []const i32 = prompt.?[0..@intCast(n)];
    for (ids) |t| if (t < 0) return 1;
    // the server's preflight: the prompt leaves room for a reply, and the reply ends where the window does
    const window = h.info.context_window;
    if (window > 0 and ids.len >= window) return 1;
    const room: u32 = if (window > 0) window - @as(u32, @intCast(ids.len)) else std.math.maxInt(u32);
    if (temperature > 0 and h.info.capability(.greedy_only)) return 1;
    const job = gpa.create(Job) catch return 1;
    const tokens = gpa.dupe(u32, @ptrCast(ids)) catch {
        gpa.destroy(job);
        return 1;
    };
    job.* = .{
        .handle = h,
        .id = id,
        .request = .{
            .prompt = tokens,
            .max_tokens = if (max_tokens > 0) @min(@as(u32, @intCast(max_tokens)), room) else room,
            // a request that names no seed draws from its prompt's (the server's --prompt-seed)
            .sampling = if (temperature > 0) .{ .seed = api.seedFor(tokens, 0), .temperature = temperature, .top_k = 0, .top_p = if (top_p > 0 and top_p <= 1) top_p else 1.0 } else null,
            .eos = h.eos,
        },
        .cb = cb.?,
        .ctx = ctx,
        .submitted = now(),
    };
    var why: [api.refusal_bytes]u8 = undefined;
    const refused = h.opened.engine.refusal(&job.request, &why) != null;
    h.lock();
    job.engine_id = h.next;
    h.next += 1;
    const taken = !refused and !h.closing and h.find(id) == null and if (h.jobs.append(gpa, job)) |_| true else |_| false;
    h.unlock();
    if (!taken) {
        gpa.free(tokens);
        gpa.destroy(job);
        return 1;
    }
    const engine_id = job.engine_id; // the job may be gone once the engine has it
    h.opened.engine.submit(engine_id, &job.request, .{ .ctx = job, .event = Job.event }) catch {
        h.forget(job);
        return 1;
    };
    // a cancel or close that came before the engine knew the request named it too early: the engine drops unknown names
    h.lock();
    const stop = if (h.find(id)) |live| live.engine_id == engine_id and live.cancelled else false;
    h.unlock();
    if (stop) h.opened.engine.cancel(engine_id);
    return 0;
}

export fn pico_tf_cancel(handle: ?*Handle, id: u64) void {
    const h = handle orelse return;
    h.lock();
    const job = h.find(id);
    if (job) |j| j.cancelled = true;
    const engine_id = if (job) |j| j.engine_id else null;
    h.unlock();
    if (engine_id) |e| h.opened.engine.cancel(e);
}

export fn pico_tf_memory(handle: ?*Handle, out: ?*[3]i64) i32 {
    const h = handle orelse return 1;
    const m = h.opened.engine.memory(false) orelse return 1;
    const counts = out orelse return 1;
    for (counts, [_]u64{ m.active, m.cache, m.peak }) |*slot, bytes| slot.* = std.math.cast(i64, bytes) orelse return 1;
    return 0;
}
