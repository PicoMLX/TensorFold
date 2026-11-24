//! `zig build pico-lib`: libPicoTensorFold.dylib, the Metal engines and a tokenizer behind a C interface.
const std = @import("std");

/// The C side keeps its safety checks, as the server's HTTP side does; the engines below it run at their own mode.
pub fn add(b: *std.Build, target: std.Build.ResolvedTarget, api: *std.Build.Module, engines: *std.Build.Module, no_compiler: ?*std.Build.Step) void {
    // Kimi's release tokenizer as the server loads it, on the engines' tokenizer module
    const tok = engines.import_table.get("tokenizer").?;
    const kimi_text = b.createModule(.{ .root_source_file = b.path("zig/src/server/kimi_text.zig"), .target = target, .optimize = .ReleaseSafe, .imports = &.{ .{ .name = "tokenizer", .module = tok }, .{ .name = "json", .module = @import("server.zig").json(b, target, .ReleaseSafe) } } });
    const hub = b.createModule(.{ .root_source_file = b.path("zig/src/cli/hub.zig"), .target = target, .optimize = .ReleaseSafe, .link_libc = true, .imports = &.{.{ .name = "native_engines", .module = engines }} });
    const lib = b.addLibrary(.{ .name = "PicoTensorFold", .linkage = .dynamic, .root_module = b.createModule(.{
        .root_source_file = b.path("zig/src/capi/pico.zig"),
        .target = target,
        .optimize = .ReleaseSafe,
        .link_libc = true,
        .imports = &.{ .{ .name = "engine_api", .module = api }, .{ .name = "native_engines", .module = engines }, .{ .name = "tokenizer", .module = tok }, .{ .name = "hub", .module = hub }, .{ .name = "kimi_text", .module = kimi_text } },
    }) });
    lib.root_module.addOptions("pico_build_info", @import("pico_build_info.zig").options(b));
    const install = b.addInstallArtifact(lib, .{ .dest_dir = .{ .override = .{ .custom = "native/lib" } } });
    b.step("test-pico-lib", "libPicoTensorFold's tokenizer checks without a GPU or weights").dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = lib.root_module })).step);
    const step = b.step("pico-lib", "libPicoTensorFold.dylib with the Metal engines into zig-out/native/lib (bundles: -Dcpu=apple_m1)");
    step.dependOn(&install.step);
    if (no_compiler) |fail| step.dependOn(fail);
}
