const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const exe = b.addExecutable(.{ .name = "ziglean", .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize });
    exe.stack_size = 128 * 1024 * 1024;
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Check a lean4export NDJSON file").dependOn(&run.step);
    const tests = b.addTest(.{ .root_source_file = b.path("test.zig"), .target = target, .optimize = optimize });
    b.step("test", "Run kernel regression tests").dependOn(&b.addRunArtifact(tests).step);
}
