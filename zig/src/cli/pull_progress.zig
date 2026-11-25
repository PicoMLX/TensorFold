//! Machine-readable activity from actual cached-file verification reads, without paths or credentials.
const std = @import("std");

pub const Verification = struct {
    out: ?*std.Io.Writer,
    total: u64,
    reported: u64 = 0,

    pub fn begin(out: ?*std.Io.Writer, total: u64) Verification {
        var progress: Verification = .{ .out = out, .total = total };
        progress.report(0);
        return progress;
    }

    pub fn advance(progress: *Verification, completed: u64) void {
        if (completed == progress.total or completed - progress.reported >= 4 << 20)
            progress.report(completed);
    }

    fn report(progress: *Verification, completed: u64) void {
        const out = progress.out orelse return;
        out.print("[tensorfold-pull] {{\"phase\":\"verify\",\"completed\":{d},\"total\":{d}}}\n", .{ completed, progress.total }) catch {
            progress.out = null;
            return;
        };
        out.flush() catch {
            progress.out = null;
            return;
        };
        progress.reported = completed;
    }

    pub fn finish(progress: *Verification) void {
        const out = progress.out orelse return;
        out.writeAll("[tensorfold-pull] {\"phase\":\"download\"}\n") catch return;
        out.flush() catch {};
    }
};

test "verification reports advancing read bytes and restores the network phase" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    var progress = Verification.begin(&out.writer, 5 << 20);
    progress.advance(1 << 20);
    progress.advance(4 << 20);
    progress.advance(5 << 20);
    progress.finish();
    try std.testing.expectEqualStrings(
        "[tensorfold-pull] {\"phase\":\"verify\",\"completed\":0,\"total\":5242880}\n" ++
            "[tensorfold-pull] {\"phase\":\"verify\",\"completed\":4194304,\"total\":5242880}\n" ++
            "[tensorfold-pull] {\"phase\":\"verify\",\"completed\":5242880,\"total\":5242880}\n" ++
            "[tensorfold-pull] {\"phase\":\"download\"}\n",
        out.written(),
    );
}

test "diagnostic writer failure cannot become a checksum failure" {
    var buffer: [0]u8 = .{};
    var out: std.Io.Writer = .fixed(&buffer);
    var progress = Verification.begin(&out, 5 << 20);
    progress.advance(5 << 20);
    progress.finish();
    try std.testing.expect(progress.out == null);
}
