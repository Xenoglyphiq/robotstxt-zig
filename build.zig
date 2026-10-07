const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Core: `@import("robotstxt")`. parse, isAllowed, matchingRule, crawlDelay, statusPolicy.
    _ = b.addModule("robotstxt", .{
        .root_source_file = b.path("src/robotstxt.zig"),
        .target = target,
    });
    // zig build test: unit tests and the fuzz target (`zig build test --fuzz`).
    const core_test_mod = b.createModule(.{
        .root_source_file = b.path("src/robotstxt.zig"),
        .target = target,
        .optimize = optimize,
    });
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = core_test_mod })).step);
}
