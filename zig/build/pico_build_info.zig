//! The Pico library records its own checkout, rather than the host application's revision.
const std = @import("std");

const Info = struct { revision: []const u8, tag: ?[]const u8, dirty: ?bool };

pub fn options(b: *std.Build) *std.Build.Step.Options {
    b.graph.poisonCache(); // Git's revision and worktree state are inputs outside Zig's file graph.
    const result = b.addOptions();
    const prefix = git(b, &.{ "rev-parse", "--show-prefix" });
    // A source archive inside another checkout must not borrow that checkout's identity.
    const info = if (prefix != null and trim(prefix.?).len == 0)
        identity(git(b, &.{ "rev-parse", "--verify", "HEAD" }), git(b, &.{ "describe", "--tags", "--exact-match", "HEAD" }), git(b, &.{ "status", "--porcelain", "--untracked-files=all" }))
    else
        null;
    const json = if (info) |value| std.json.Stringify.valueAlloc(b.allocator, value, .{}) catch @panic("OOM") else null;
    result.addOption(?[]const u8, "json", json);
    return result;
}

fn git(b: *std.Build, args: []const []const u8) ?[]const u8 {
    const argv = std.mem.concat(b.allocator, []const u8, &.{
        &.{ "git", "-C", b.root.root_dir.path orelse "." }, args,
    }) catch @panic("OOM");
    var code: u8 = 0;
    const output = b.runAllowFail(argv, &code, .ignore) catch return null;
    return if (code == 0) output else null;
}

fn trim(text: []const u8) []const u8 {
    return std.mem.trim(u8, text, "\r\n");
}

fn identity(revision_output: ?[]const u8, tag_output: ?[]const u8, status_output: ?[]const u8) ?Info {
    const revision = trim(revision_output orelse return null);
    if (revision.len != 40 and revision.len != 64) return null;
    for (revision) |byte| if (!std.ascii.isHex(byte)) return null;
    const tag = if (tag_output) |text| trim(text) else "";
    return .{
        .revision = revision,
        .tag = if (tag.len == 0) null else tag,
        .dirty = if (status_output) |text| trim(text).len != 0 else null,
    };
}

pub fn tests(b: *std.Build) void {
    const module = b.createModule(.{ .root_source_file = b.path("zig/build/pico_build_info.zig"), .target = b.graph.host });
    const run = b.addRunArtifact(b.addTest(.{ .root_module = module }));
    b.step("test-pico-build-info-host", "Pico source identity, exact tags and unknown archive metadata").dependOn(&run.step);
}

test "Pico source identity requires a full Git revision and never invents one" {
    try std.testing.expect(identity(null, null, null) == null);
    try std.testing.expect(identity("7aadce5\n", null, null) == null);
    const invalid: [40]u8 = @splat('x');
    try std.testing.expect(identity(&invalid, null, null) == null);
    const revision: [64]u8 = @splat('a');
    const sha256 = identity(&revision, null, null).?;
    try std.testing.expectEqualStrings(&revision, sha256.revision);
    try std.testing.expect(sha256.tag == null);
    try std.testing.expect(sha256.dirty == null);
}

test "Pico source identity keeps exact tags and distinguishes clean from unknown" {
    const revision = "7aadce5e255e024af6e989c61d95c6650c016a29";
    const clean = identity(revision ++ "\n", "v1.3.4\n", "").?;
    try std.testing.expectEqualStrings(revision, clean.revision);
    try std.testing.expectEqualStrings("v1.3.4", clean.tag.?);
    try std.testing.expectEqual(false, clean.dirty.?);
    const changed = identity(revision, null, " M zig/src/capi/pico.zig\n?? new-file\n").?;
    try std.testing.expect(changed.tag == null);
    try std.testing.expectEqual(true, changed.dirty.?);
    const unknown = identity(revision, "", null).?;
    try std.testing.expect(unknown.tag == null);
    try std.testing.expect(unknown.dirty == null);
}

test "Pico source metadata is valid JSON even when an exact tag needs escaping" {
    const revision: [40]u8 = @splat('b');
    const info = identity(&revision, "release-\"quoted\"", "").?;
    const json = try std.json.Stringify.valueAlloc(std.testing.allocator, info, .{});
    defer std.testing.allocator.free(json);
    const parsed = try std.json.parseFromSlice(Info, std.testing.allocator, json, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings(info.revision, parsed.value.revision);
    try std.testing.expectEqualStrings(info.tag.?, parsed.value.tag.?);
    try std.testing.expectEqual(false, parsed.value.dirty.?);
}
