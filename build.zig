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
    const run_wav_analyzer = b.addSystemCommand(&.{ "pwsh", "-NoLogo", "-NoProfile", "-File" });
    run_wav_analyzer.addFileArg(b.path("Tests/Analyze-SdspWav.ps1"));
    run_wav_analyzer.addArg("-SelfTest");

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
    const snes_reference_root = b.option([]const u8, "snes-reference-root", "SNES reference root; absent material is skipped") orelse "../../../ExFiles/Reference/SNES";
    run_references.addArg(snes_reference_root);
    run_references.addArg(b.option([]const u8, "snes-qualification-matrix", "SNES qualification matrix") orelse "../../../Docs/Subsystems/SNESQualificationMatrix.json");

    const superfx_output = b.option([]const u8, "superfx-program-output", "Generated Super FX program directory") orelse "../../../Temp/R4SNES-SuperFX";
    const assemble_superfx = b.addSystemCommand(&.{ "pwsh", "-NoLogo", "-NoProfile", "-File" });
    assemble_superfx.addFileArg(b.path("Tests/Build-SuperFxPrograms.ps1"));
    assemble_superfx.addArg("-ReferenceRoot");
    assemble_superfx.addArg(snes_reference_root);
    assemble_superfx.addArg("-OutputDirectory");
    assemble_superfx.addArg(superfx_output);
    const superfx_program_root = b.createModule(.{
        .root_source_file = b.path("Tests/superfx_program_harness.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
    });
    superfx_program_root.addImport("core", core);
    const superfx_program_harness = b.addExecutable(.{
        .name = "r4snes-superfx-program-harness",
        .root_module = superfx_program_root,
    });
    const run_superfx_programs = b.addRunArtifact(superfx_program_harness);
    run_superfx_programs.setCwd(b.path("."));
    run_superfx_programs.addArg(superfx_output);
    run_superfx_programs.step.dependOn(&assemble_superfx.step);

    const coverage_root = b.createModule(.{
        .root_source_file = b.path("Tests/cpu_coverage.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
    });
    coverage_root.addImport("core", core);
    const coverage_generator = b.addExecutable(.{
        .name = "r4snes-cpu-coverage",
        .root_module = coverage_root,
    });
    const run_coverage = b.addRunArtifact(coverage_generator);
    const coverage_output = run_coverage.addOutputFileArg("CPU_OPCODE_COVERAGE.json");
    const install_coverage = b.addInstallFile(coverage_output, "share/r4snes/CPU_OPCODE_COVERAGE.json");
    b.getInstallStep().dependOn(&install_coverage.step);

    const test_step = b.step("test", "Build R4SNES and run deterministic owner tests");
    test_step.dependOn(b.getInstallStep());
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&run_wav_analyzer.step);

    const reference_step = b.step("reference-test", "Execute pinned SNES qualification ROMs, models and all SPC700 vectors");
    reference_step.dependOn(&run_references.step);
    reference_step.dependOn(&run_superfx_programs.step);
    const superfx_reference_step = b.step("superfx-reference-test", "Rebuild and execute pinned OpenSNES and owner GSU programs");
    superfx_reference_step.dependOn(&run_superfx_programs.step);
}
