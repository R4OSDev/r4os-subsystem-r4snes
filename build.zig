const std = @import("std");

pub fn build(b: *std.Build) void {
    const sdk_build = b.lazyImport(@This(), "r4os_sdk") orelse return;
    const sdk_dep = b.dependencyFromBuildZig(sdk_build, .{});
    const sdk = sdk_build.sdk(b, sdk_dep, .{});
    _ = sdk.addR4MF(b.path("module.R4MF"));

    const host_r4os = sdk.createR4osModule(b.graph.host, .Debug);
    const core = b.createModule(.{
        .root_source_file = b.path("src/core.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    core.addImport("r4os", host_r4os);

    const unit_root = b.createModule(.{
        .root_source_file = b.path("Tests/unit_test.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    unit_root.addImport("core", core);
    unit_root.addImport("r4os", host_r4os);
    const unit_tests = b.addTest(.{ .root_module = unit_root });
    const run_unit_tests = b.addRunArtifact(unit_tests);

    const reference_root = b.createModule(.{
        .root_source_file = b.path("Tests/reference_harness.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
    });
    reference_root.addImport("core", core);
    const reference_harness = b.addExecutable(.{
        .name = "r4snes-reference-harness",
        .root_module = reference_root,
    });
    const run_references = b.addRunArtifact(reference_harness);
    run_references.setCwd(b.path("."));
    run_references.addArg(b.option([]const u8, "snes-reference-root", "SNES reference root; absent material is skipped") orelse "../../../ExFiles/Reference/SNES");
    run_references.addArg(b.option([]const u8, "snes-qualification-matrix", "SNES qualification matrix") orelse "../../../Docs/Subsystems/SNESQualificationMatrix.json");

    const test_step = b.step("test", "Build R4SNES and run deterministic owner tests");
    test_step.dependOn(b.getInstallStep());
    test_step.dependOn(&run_unit_tests.step);

    const reference_step = b.step("reference-test", "Validate pinned SNES reference inventories and corpus counts");
    reference_step.dependOn(&run_references.step);
}
