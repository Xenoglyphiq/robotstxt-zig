const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Core: `@import("robotstxt")`. parse, isAllowed, matchingRule, crawlDelay, statusPolicy.
    const core = b.addModule("robotstxt", .{
        .root_source_file = b.path("src/robotstxt.zig"),
        .target = target,
    });
    // io: `@import("robotstxt_io")`. fetch over a Transport; HttpTransport on std.http.Client.
    const io = b.addModule("robotstxt_io", .{
        .root_source_file = b.path("src/io.zig"),
        .target = target,
        .imports = &.{.{ .name = "robotstxt", .module = core }},
    });

    // zig build test: unit tests and the fuzz target (`zig build test --fuzz`).
    const core_test_mod = b.createModule(.{
        .root_source_file = b.path("src/robotstxt.zig"),
        .target = target,
        .optimize = optimize,
    });
    const io_test_mod = b.createModule(.{
        .root_source_file = b.path("src/io.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "robotstxt", .module = core }},
    });
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = core_test_mod })).step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = io_test_mod })).step);

    const imports: []const std.Build.Module.Import = &.{
        .{ .name = "robotstxt", .module = core },
        .{ .name = "robotstxt_io", .module = io },
    };

    // zig build conformance: every case in the vendored spec's manifest.
    const runner = b.addExecutable(.{
        .name = "conformance",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/conformance.zig"),
            .target = target,
            .optimize = optimize,
            .imports = imports,
        }),
    });
    const run_conformance = b.addRunArtifact(runner);
    run_conformance.addFileArg(b.path(".spec/conformance/manifest.json"));
    // `zig build conformance -- <manifest.json>` runs another manifest instead
    // (a spec release candidate, say): the runner uses its last argument.
    run_conformance.addPassthruArgs();
    const conformance_step = b.step("conformance", "Run the spec's conformance cases");
    conformance_step.dependOn(&run_conformance.step);
}
