//! `zig build pico-lib`: libPicoTensorFold.dylib, the Metal engines and a tokenizer behind a C interface.
const std = @import("std");

/// The C side keeps its safety checks, as the server's HTTP side does; the engines below it run at their own mode.
pub fn add(b: *std.Build, target: std.Build.ResolvedTarget, api: *std.Build.Module, engines: *std.Build.Module) void {
    const hub = b.createModule(.{ .root_source_file = b.path("zig/src/cli/hub.zig"), .target = target, .optimize = .ReleaseSafe, .link_libc = true, .imports = &.{.{ .name = "native_engines", .module = engines }} });
    const lib = b.addLibrary(.{ .name = "PicoTensorFold", .linkage = .dynamic, .root_module = b.createModule(.{
        .root_source_file = b.path("zig/src/capi/pico.zig"),
        .target = target,
        .optimize = .ReleaseSafe,
        .link_libc = true,
        .imports = &.{ .{ .name = "engine_api", .module = api }, .{ .name = "native_engines", .module = engines }, .{ .name = "tokenizer", .module = engines.import_table.get("tokenizer").? }, .{ .name = "hub", .module = hub } },
    }) });
    const install = b.addInstallArtifact(lib, .{ .dest_dir = .{ .override = .{ .custom = "native/lib" } } });
    b.step("pico-lib", "libPicoTensorFold.dylib with the Metal engines into zig-out/native/lib (bundles: -Dcpu=apple_m1)").dependOn(&install.step);
}
