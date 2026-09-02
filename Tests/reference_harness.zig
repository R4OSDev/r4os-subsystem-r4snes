const std = @import("std");
const core = @import("core");

const max_manifest_bytes: usize = 512 * 1024;
const max_vector_bytes: usize = 2 * 1024 * 1024;
const max_rom_bytes: usize = core.cartridge.maximum_rom_size + core.cartridge.copier_header_size + 1;

const Expected = struct {
    schema: u32,
    references_sha256: []const u8,
    qualification_matrix_sha256: []const u8,
    dma_cases_sha256: []const u8,
    ppu_cases_sha256: []const u8,
    hdrv_cases_sha256: []const u8,
    sdsp_cases_sha256: []const u8,
    enhancement_cases_sha256: []const u8,
    repositories: usize,
    downloads: usize,
    trees: usize,
    test_roms: usize,
    dma_reference_roms: usize,
    ppu_reference_roms: usize,
    hdrv_geometry_cases: usize,
    sdsp_oracle_cases: usize,
    enhancement_oracles: usize,
    enhancement_oracle_cases: usize,
    sa1_hardware_roms: usize,
    cx4_programs: usize,
    cx4_independent_implementations: usize,
    cx4_data_rom_sha256: []const u8,
    cx4_aggregate_fnv1a64: []const u8,
    nec_dsp_open_firmware_variants: usize,
    nec_dsp_matrix_words: usize,
    nec_dsp_independent_implementations: usize,
    nec_dsp_aggregate_fnv1a64: []const u8,
    st018_open_firmware_variants: usize,
    st018_independent_implementations: usize,
    st018_open_state_fnv1a64: []const u8,
    spc700_files: usize,
    spc700_records: usize,
};

const References = struct {
    schema: u32,
    repositories: []const std.json.Value,
    files: []const std.json.Value,
    trees: []const std.json.Value,
};

const Corpus = struct {
    test_roms: usize,
    spc700_single_step_files: usize,
    spc700_single_step_records: usize,
    sa1_hardware_roms: usize,
    cx4_programs: usize,
    cx4_independent_implementations: usize,
    nec_dsp_open_firmware_variants: usize,
    nec_dsp_matrix_words: usize,
    nec_dsp_independent_implementations: usize,
    st01x_open_synthetic_profiles: usize,
    st01x_private_firmware_boots: usize,
    st018_open_firmware_variants: usize,
    st018_independent_implementations: usize,
    st018_private_firmware_boots: usize,
    commercial_roms: usize,
    proprietary_firmware_images: usize,
};

const MatrixSuite = struct {
    rom_count: ?usize = null,
};

const MatrixEnhancement = struct {
    id: []const u8,
    status: []const u8,
    version: ?[]const u8 = null,
    firmware: ?[]const u8 = null,
};

const Cx4ReferenceCases = struct {
    release: []const u8,
    programs: usize,
    opcode_encodings_classified: usize,
    defined_encodings: usize,
    reserved_nop_encodings: usize,
    data_rom_words: usize,
    data_rom_sha256: []const u8,
    pixel_oracles: usize,
    aggregate_state_fnv1a64: []const u8,
    independent_sources: []const std.json.Value,
};

const NecDspReferenceCases = struct {
    release: []const u8,
    core: []const u8,
    frequency_hz: u32,
    program_words: usize,
    data_words: usize,
    data_ram_words: usize,
    stack_words: usize,
    open_firmware_variants: usize,
    emitted_matrix_words: usize,
    instruction_classes: usize,
    alu_modes: usize,
    source_selectors: usize,
    destination_selectors: usize,
    defined_branch_modes: usize,
    reserved_branch_modes: usize,
    aggregate_state_fnv1a64: []const u8,
    independent_sources: []const std.json.Value,
    firmware_paths: []const []const u8,
    firmware_bytes_each: usize,
};

const St01xReferenceCases = struct {
    release: []const u8,
    core: []const u8,
    revisions: []const []const u8,
    frequency_hz: []const u32,
    program_words: usize,
    data_words: usize,
    data_ram_words: usize,
    stack_words: usize,
    firmware_paths: []const []const u8,
    firmware_bytes_each: usize,
};

const St018ReferenceCases = struct {
    release: []const u8,
    core: []const u8,
    frequency_hz: u32,
    program_rom_bytes: usize,
    data_rom_bytes: usize,
    work_ram_bytes: usize,
    decoder_keys: usize,
    instruction_classes: usize,
    reset_delay_cycles: usize,
    firmware_path: []const u8,
    firmware_bytes: usize,
    open_firmware_sha256: []const u8,
    open_state_fnv1a64: []const u8,
    independent_sources: []const std.json.Value,
};

const Matrix = struct {
    schema: u32,
    release: []const u8,
    corpus: Corpus,
    cx4_reference_cases: Cx4ReferenceCases,
    nec_dsp_reference_cases: NecDspReferenceCases,
    st01x_reference_cases: St01xReferenceCases,
    st018_reference_cases: St018ReferenceCases,
    suites: []const MatrixSuite,
    enhancement_chips: []const MatrixEnhancement,
};

const DmaReferenceRom = struct {
    path: []const u8,
    sha256: []const u8,
    bytes: usize,
    enabled_as_gate: bool,
    oracle_status: []const u8,
    timeout_master_clocks: u64,
    first_bus_divergence: []const u8,
};

const DmaReferenceCases = struct {
    schema: u32,
    release: []const u8,
    model_oracles: []const []const u8,
    foreign_roms: []const DmaReferenceRom,
};

const PpuModelOracle = struct {
    mode: u3,
    geometry: []const u8,
    xrgb32: []const u8,
    digest_fnv1a64: []const u8,
};

const PpuReferenceCases = struct {
    schema: u32,
    release: []const u8,
    model_oracles: []const PpuModelOracle,
    foreign_roms: []const DmaReferenceRom,
};

const HdrvGeometryCase = struct {
    id: []const u8,
    bgmode: u3,
    setini: u8,
    width: u16,
    height: u16,
};

const HdrvGeometryCases = struct {
    schema: u32,
    release: []const u8,
    source_rom_sha256: []const u8,
    cases: []const HdrvGeometryCase,
};

const SdspReferenceCases = struct {
    schema: u32,
    oracle: Oracle,
    digest: Digest,
    cases: []const Case,

    const Oracle = struct {
        name: []const u8,
        revision: []const u8,
        license: []const u8,
    };
    const Digest = struct {
        algorithm: []const u8,
        sample_encoding: []const u8,
    };
    const Case = struct {
        name: []const u8,
        native_frames: u64,
        pcm_digest: []const u8,
        echo_ram_digest: []const u8,
    };
};

const EnhancementReferenceCases = struct {
    schema: u32,
    generator: struct {
        algorithm: []const u8,
        seed: u32,
        multiplier: u32,
        increment: u32,
        input_bytes: usize,
    },
    trace: struct {
        format: []const u8,
        sha256: []const u8,
        verified_oracles: []const []const u8,
        result: []const u8,
        cases: usize,
    },
    oracles: []const struct {
        name: []const u8,
        verification: []const u8,
        sdd1: []const u8,
        spc7110: []const u8,
    },
    cases: []const struct {
        id: []const u8,
        chip: []const u8,
        mode: u8,
        first_byte: ?u8,
        output_bytes: usize,
        expected_hex: []const u8,
    },
};

pub fn main(init: std.process.Init) void {
    run(init) catch |fault| {
        std.debug.print("R4SNES reference harness FAILED: {s}\n", .{@errorName(fault)});
        std.process.exit(1);
    };
}

fn run(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const cwd = std.Io.Dir.cwd();
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const root = if (args.len >= 2) args[1] else "../../../ExFiles/Reference/SNES";
    const matrix_path = if (args.len >= 3) args[2] else "../../../Docs/Subsystems/SNESQualificationMatrix.json";

    const expected_bytes = try cwd.readFileAlloc(io, "Tests/reference_manifest.json", allocator, .limited(max_manifest_bytes));
    defer allocator.free(expected_bytes);
    var parsed_expected = try std.json.parseFromSlice(Expected, allocator, expected_bytes, .{});
    defer parsed_expected.deinit();
    const expected = parsed_expected.value;
    if (expected.schema != 1) return error.UnsupportedExpectedSchema;

    const matrix_bytes = try cwd.readFileAlloc(io, matrix_path, allocator, .limited(max_manifest_bytes));
    defer allocator.free(matrix_bytes);
    try expectSha256(matrix_bytes, expected.qualification_matrix_sha256);
    var parsed_matrix = try std.json.parseFromSlice(Matrix, allocator, matrix_bytes, .{ .ignore_unknown_fields = true });
    defer parsed_matrix.deinit();
    const matrix = parsed_matrix.value;
    if (matrix.schema != 1 or !std.mem.eql(u8, matrix.release, "0.73.22")) return error.UnsupportedQualificationMatrix;
    if (matrix.suites.len != 9 or matrix.corpus.test_roms != expected.test_roms or
        matrix.corpus.spc700_single_step_files != expected.spc700_files or
        matrix.corpus.spc700_single_step_records != expected.spc700_records or
        matrix.corpus.sa1_hardware_roms != expected.sa1_hardware_roms or
        matrix.corpus.cx4_programs != expected.cx4_programs or
        matrix.corpus.cx4_independent_implementations != expected.cx4_independent_implementations or
        matrix.corpus.nec_dsp_open_firmware_variants != expected.nec_dsp_open_firmware_variants or
        matrix.corpus.nec_dsp_matrix_words != expected.nec_dsp_matrix_words or
        matrix.corpus.nec_dsp_independent_implementations != expected.nec_dsp_independent_implementations or
        matrix.corpus.st01x_open_synthetic_profiles != 2 or matrix.corpus.st01x_private_firmware_boots != 2 or
        matrix.corpus.st018_open_firmware_variants != expected.st018_open_firmware_variants or
        matrix.corpus.st018_independent_implementations != expected.st018_independent_implementations or
        matrix.corpus.st018_private_firmware_boots != 1 or
        matrix.corpus.commercial_roms != 0 or matrix.corpus.proprietary_firmware_images != 0)
    {
        return error.QualificationMatrixMismatch;
    }
    var matrix_roms: usize = 0;
    for (matrix.suites) |suite| matrix_roms += suite.rom_count orelse 0;
    if (matrix_roms != expected.test_roms) return error.QualificationSuiteCountMismatch;
    if (matrix.enhancement_chips.len != 12) return error.QualificationEnhancementCountMismatch;
    try expectImplementedEnhancement(matrix.enhancement_chips, "obc1", "0.73.12");
    try expectImplementedEnhancement(matrix.enhancement_chips, "srtc", "0.73.12");
    try expectImplementedEnhancement(matrix.enhancement_chips, "sdd1", "0.73.13");
    try expectImplementedEnhancement(matrix.enhancement_chips, "spc7110-epson-rtc", "0.73.13");
    try expectImplementedEnhancement(matrix.enhancement_chips, "superfx-gsu1-gsu2", "0.73.14");
    try expectImplementedEnhancement(matrix.enhancement_chips, "sa1", "0.73.15");
    try expectImplementedEnhancement(matrix.enhancement_chips, "cx4", "0.73.16");
    try expectImplementedFirmwareEnhancement(
        matrix.enhancement_chips,
        "dsp1-dsp1a-dsp1b-dsp2-dsp3-dsp4",
        "0.73.17",
        "exact 8192-byte user image required and never distributed",
    );
    try expectImplementedFirmwareEnhancement(
        matrix.enhancement_chips,
        "st010-st011",
        "0.73.18",
        "exact 53248-byte ST010.ROM or ST011.ROM required and never distributed",
    );
    try expectImplementedFirmwareEnhancement(
        matrix.enhancement_chips,
        "st018",
        "0.73.19",
        "exact 163840-byte ST018.ROM required and never distributed",
    );
    const cx4_cases = matrix.cx4_reference_cases;
    if (!std.mem.eql(u8, cx4_cases.release, "0.73.16") or
        cx4_cases.programs != expected.cx4_programs or
        cx4_cases.opcode_encodings_classified != 65_536 or cx4_cases.defined_encodings != 55_808 or
        cx4_cases.reserved_nop_encodings != 9_728 or cx4_cases.data_rom_words != 1_024 or
        !std.mem.eql(u8, cx4_cases.data_rom_sha256, expected.cx4_data_rom_sha256) or
        cx4_cases.pixel_oracles != 64 or
        !std.mem.eql(u8, cx4_cases.aggregate_state_fnv1a64, expected.cx4_aggregate_fnv1a64) or
        cx4_cases.independent_sources.len != expected.cx4_independent_implementations)
    {
        return error.Cx4QualificationMismatch;
    }
    const nec_dsp_cases = matrix.nec_dsp_reference_cases;
    if (!std.mem.eql(u8, nec_dsp_cases.release, "0.73.17") or
        !std.mem.eql(u8, nec_dsp_cases.core, "NEC uPD7725/uPD77C25") or
        nec_dsp_cases.frequency_hz != 7_600_000 or
        nec_dsp_cases.program_words != 2_048 or nec_dsp_cases.data_words != 1_024 or
        nec_dsp_cases.data_ram_words != 256 or nec_dsp_cases.stack_words != 4 or
        nec_dsp_cases.open_firmware_variants != expected.nec_dsp_open_firmware_variants or
        nec_dsp_cases.emitted_matrix_words != expected.nec_dsp_matrix_words or
        nec_dsp_cases.instruction_classes != 4 or nec_dsp_cases.alu_modes != 16 or
        nec_dsp_cases.source_selectors != 16 or nec_dsp_cases.destination_selectors != 16 or
        nec_dsp_cases.defined_branch_modes != 39 or nec_dsp_cases.reserved_branch_modes != 1 or
        !std.mem.eql(u8, nec_dsp_cases.aggregate_state_fnv1a64, expected.nec_dsp_aggregate_fnv1a64) or
        nec_dsp_cases.independent_sources.len != expected.nec_dsp_independent_implementations or
        nec_dsp_cases.firmware_paths.len != expected.nec_dsp_open_firmware_variants or
        nec_dsp_cases.firmware_bytes_each != 8_192)
    {
        return error.NecDspQualificationMismatch;
    }
    const st01x_cases = matrix.st01x_reference_cases;
    if (!std.mem.eql(u8, st01x_cases.release, "0.73.18") or
        !std.mem.eql(u8, st01x_cases.core, "NEC uPD96050 shared with the uPD7725/uPD77C25 decoder") or
        st01x_cases.revisions.len != 2 or st01x_cases.frequency_hz.len != 2 or
        st01x_cases.frequency_hz[0] != 11_000_000 or st01x_cases.frequency_hz[1] != 15_000_000 or
        st01x_cases.program_words != 16_384 or st01x_cases.data_words != 2_048 or
        st01x_cases.data_ram_words != 2_048 or st01x_cases.stack_words != 16 or
        st01x_cases.firmware_paths.len != 2 or st01x_cases.firmware_bytes_each != 53_248)
    {
        return error.St01xQualificationMismatch;
    }
    const st018_cases = matrix.st018_reference_cases;
    if (!std.mem.eql(u8, st018_cases.release, "0.73.19") or
        !std.mem.eql(u8, st018_cases.core, "ARMv3 ARM60") or
        st018_cases.frequency_hz != 21_440_000 or
        st018_cases.program_rom_bytes != 131_072 or st018_cases.data_rom_bytes != 32_768 or
        st018_cases.work_ram_bytes != 16_384 or st018_cases.decoder_keys != 4_096 or
        st018_cases.instruction_classes != 10 or st018_cases.reset_delay_cycles != 65_536 or
        !std.mem.eql(u8, st018_cases.firmware_path, "ST018.ROM") or
        st018_cases.firmware_bytes != 163_840 or
        !std.mem.eql(u8, st018_cases.open_firmware_sha256, "2621d3e067cd23a94c74712eb1aa1d8e5035fca6ecae8ec5f765611966317ad1") or
        !std.mem.eql(u8, st018_cases.open_state_fnv1a64, expected.st018_open_state_fnv1a64) or
        st018_cases.independent_sources.len != expected.st018_independent_implementations)
    {
        return error.St018QualificationMismatch;
    }

    const dma_cases_bytes = try cwd.readFileAlloc(io, "Tests/dma_reference_cases.json", allocator, .limited(max_manifest_bytes));
    defer allocator.free(dma_cases_bytes);
    try expectSha256(dma_cases_bytes, expected.dma_cases_sha256);
    var parsed_dma_cases = try std.json.parseFromSlice(DmaReferenceCases, allocator, dma_cases_bytes, .{ .ignore_unknown_fields = true });
    defer parsed_dma_cases.deinit();
    const dma_cases = parsed_dma_cases.value;
    if (dma_cases.schema != 1 or !std.mem.eql(u8, dma_cases.release, "0.73.6") or
        dma_cases.foreign_roms.len != expected.dma_reference_roms or dma_cases.model_oracles.len != 4)
    {
        return error.DmaReferenceManifestMismatch;
    }
    for (dma_cases.foreign_roms) |rom| {
        if (rom.enabled_as_gate or !std.mem.eql(u8, rom.oracle_status, "diagnostic_only") or
            rom.timeout_master_clocks == 0 or rom.first_bus_divergence.len == 0)
        {
            return error.UnqualifiedDmaReferenceGate;
        }
    }

    const ppu_cases_bytes = try cwd.readFileAlloc(io, "Tests/ppu_reference_cases.json", allocator, .limited(max_manifest_bytes));
    defer allocator.free(ppu_cases_bytes);
    try expectSha256(ppu_cases_bytes, expected.ppu_cases_sha256);
    var parsed_ppu_cases = try std.json.parseFromSlice(PpuReferenceCases, allocator, ppu_cases_bytes, .{ .ignore_unknown_fields = true });
    defer parsed_ppu_cases.deinit();
    const ppu_cases = parsed_ppu_cases.value;
    const ExpectedPpu = struct { mode: u3, geometry: []const u8, digest: []const u8 };
    const ppu_expected = [_]ExpectedPpu{
        .{ .mode = 0, .geometry = "256x224", .digest = "84eefc2777a6e325" },
        .{ .mode = 1, .geometry = "256x224", .digest = "a71592d0a1312325" },
        .{ .mode = 2, .geometry = "256x224", .digest = "f24128f9b0f3e325" },
        .{ .mode = 3, .geometry = "256x224", .digest = "488f665ded0f2325" },
        .{ .mode = 4, .geometry = "256x224", .digest = "9ef804ce64d52325" },
        .{ .mode = 5, .geometry = "512x224", .digest = "0e1cf24d55fc2325" },
        .{ .mode = 6, .geometry = "512x224", .digest = "4d176b91742c2325" },
        .{ .mode = 7, .geometry = "256x224", .digest = "84eefc2777a6e325" },
        .{ .mode = 7, .geometry = "256x224", .digest = "a71592d0a1312325" },
        .{ .mode = 1, .geometry = "256x224", .digest = "18e3f9c9ab60f325" },
        .{ .mode = 1, .geometry = "256x224", .digest = "6b59fc2d52c67325" },
        .{ .mode = 0, .geometry = "256x224", .digest = "fc18121383760325" },
    };
    if (ppu_cases.schema != 1 or !std.mem.eql(u8, ppu_cases.release, "0.73.8") or
        ppu_cases.model_oracles.len != ppu_expected.len or ppu_cases.foreign_roms.len != expected.ppu_reference_roms)
    {
        return error.PpuReferenceManifestMismatch;
    }
    for (ppu_cases.model_oracles, 0..) |model, index| {
        const oracle = ppu_expected[index];
        if (model.mode != oracle.mode or !std.mem.eql(u8, model.geometry, oracle.geometry) or model.xrgb32.len == 0 or
            !std.mem.eql(u8, model.digest_fnv1a64, oracle.digest))
        {
            return error.PpuModelOracleMismatch;
        }
    }

    const hdrv_cases_bytes = try cwd.readFileAlloc(io, "Tests/hdrv_geometry_cases.json", allocator, .limited(max_manifest_bytes));
    defer allocator.free(hdrv_cases_bytes);
    try expectSha256(hdrv_cases_bytes, expected.hdrv_cases_sha256);
    var parsed_hdrv_cases = try std.json.parseFromSlice(HdrvGeometryCases, allocator, hdrv_cases_bytes, .{ .ignore_unknown_fields = true });
    defer parsed_hdrv_cases.deinit();
    const hdrv_cases = parsed_hdrv_cases.value;
    if (hdrv_cases.schema != 1 or !std.mem.eql(u8, hdrv_cases.release, "0.73.8") or
        hdrv_cases.source_rom_sha256.len != 64 or hdrv_cases.cases.len != expected.hdrv_geometry_cases)
    {
        return error.HdrvGeometryManifestMismatch;
    }
    for (hdrv_cases.cases) |case| {
        if (case.id.len == 0) return error.HdrvGeometryManifestMismatch;
        var display = core.ppu.Ppu{};
        if (!display.write(0x2105, case.bgmode, 0, 0) or !display.write(0x2133, case.setini, 0, 0)) {
            return error.HdrvGeometryRegisterRejected;
        }
        const frame = display.renderCompleteFrame();
        if (frame.width != case.width or frame.height != case.height) return error.HdrvGeometryMismatch;
    }
    for (ppu_cases.foreign_roms) |rom| {
        if (rom.enabled_as_gate or !std.mem.eql(u8, rom.oracle_status, "diagnostic_only") or
            rom.timeout_master_clocks == 0 or rom.first_bus_divergence.len == 0)
        {
            return error.UnqualifiedPpuReferenceGate;
        }
    }

    const sdsp_cases_bytes = try cwd.readFileAlloc(io, "Tests/sdsp_reference_cases.json", allocator, .limited(max_manifest_bytes));
    defer allocator.free(sdsp_cases_bytes);
    try expectSha256(sdsp_cases_bytes, expected.sdsp_cases_sha256);
    var parsed_sdsp_cases = try std.json.parseFromSlice(SdspReferenceCases, allocator, sdsp_cases_bytes, .{ .ignore_unknown_fields = true });
    defer parsed_sdsp_cases.deinit();
    const sdsp_cases = parsed_sdsp_cases.value;
    if (sdsp_cases.schema != 1 or sdsp_cases.cases.len != expected.sdsp_oracle_cases or
        !std.mem.eql(u8, sdsp_cases.oracle.name, "SNES-SPC") or
        !std.mem.eql(u8, sdsp_cases.oracle.revision, "ec8ee2bbe30451614c1d02a83f7af1c97d497d45") or
        !std.mem.eql(u8, sdsp_cases.oracle.license, "LGPL-2.1") or
        !std.mem.eql(u8, sdsp_cases.digest.algorithm, "FNV-1a-64") or
        !std.mem.eql(u8, sdsp_cases.digest.sample_encoding, "stereo signed 16-bit little-endian"))
    {
        return error.SdspReferenceManifestMismatch;
    }
    for (sdsp_cases.cases, 0..) |case, index| {
        if (case.name.len == 0 or case.native_frames == 0 or case.pcm_digest.len != 16 or case.echo_ram_digest.len != 16) {
            return error.SdspReferenceManifestMismatch;
        }
        for (sdsp_cases.cases[0..index]) |prior| {
            if (std.mem.eql(u8, prior.name, case.name)) return error.DuplicateSdspReferenceCase;
        }
    }

    const enhancement_cases_bytes = try cwd.readFileAlloc(io, "Tests/enhancement_reference_cases.json", allocator, .limited(max_manifest_bytes));
    defer allocator.free(enhancement_cases_bytes);
    try expectSha256(enhancement_cases_bytes, expected.enhancement_cases_sha256);
    var parsed_enhancement_cases = try std.json.parseFromSlice(EnhancementReferenceCases, allocator, enhancement_cases_bytes, .{});
    defer parsed_enhancement_cases.deinit();
    const enhancement_cases = parsed_enhancement_cases.value;
    if (enhancement_cases.schema != 1 or enhancement_cases.oracles.len != expected.enhancement_oracles or
        enhancement_cases.cases.len != expected.enhancement_oracle_cases)
    {
        return error.EnhancementReferenceManifestMismatch;
    }
    try verifyEnhancementVectors(enhancement_cases);

    cwd.access(io, root, .{}) catch {
        std.debug.print("R4SNES reference harness SKIP: optional root missing: {s}\n", .{root});
        return;
    };

    const references_path = try std.fs.path.join(allocator, &.{ root, "References.json" });
    defer allocator.free(references_path);
    const references_bytes = try cwd.readFileAlloc(io, references_path, allocator, .limited(max_manifest_bytes));
    defer allocator.free(references_bytes);
    try expectSha256(references_bytes, expected.references_sha256);
    var parsed_references = try std.json.parseFromSlice(References, allocator, references_bytes, .{ .ignore_unknown_fields = true });
    defer parsed_references.deinit();
    const references = parsed_references.value;
    if (references.schema != 1 or references.repositories.len != expected.repositories or
        references.files.len != expected.downloads or references.trees.len != expected.trees)
    {
        return error.ReferenceManifestMismatch;
    }
    var executed_oracles: usize = 0;
    for (enhancement_cases.oracles) |oracle| {
        if (std.mem.startsWith(u8, oracle.verification, "executed-")) executed_oracles += 1;
        const sdd1_path = try std.fs.path.join(allocator, &.{ root, oracle.sdd1 });
        defer allocator.free(sdd1_path);
        const spc_path = try std.fs.path.join(allocator, &.{ root, oracle.spc7110 });
        defer allocator.free(spc_path);
        try cwd.access(io, sdd1_path, .{});
        try cwd.access(io, spc_path, .{});
    }
    if (executed_oracles < 2) return error.InsufficientExecutedEnhancementOracles;

    for (dma_cases.foreign_roms) |rom| {
        const path = try std.fs.path.join(allocator, &.{ root, rom.path });
        defer allocator.free(path);
        const bytes = try cwd.readFileAlloc(io, path, allocator, .limited(max_rom_bytes));
        defer allocator.free(bytes);
        if (bytes.len != rom.bytes) return error.DmaReferenceSizeMismatch;
        try expectSha256(bytes, rom.sha256);
        _ = try core.cartridge.inspectCandidateSize(bytes.len);
        var parsed = try core.cartridge.Cartridge.parse(allocator, bytes);
        parsed.deinit();
    }
    for (ppu_cases.foreign_roms) |rom| {
        const path = try std.fs.path.join(allocator, &.{ root, rom.path });
        defer allocator.free(path);
        const bytes = try cwd.readFileAlloc(io, path, allocator, .limited(max_rom_bytes));
        defer allocator.free(bytes);
        if (bytes.len != rom.bytes) return error.PpuReferenceSizeMismatch;
        try expectSha256(bytes, rom.sha256);
        _ = try core.cartridge.inspectCandidateSize(bytes.len);
        var parsed = try core.cartridge.Cartridge.parse(allocator, bytes);
        parsed.deinit();
    }

    const rom_root = try std.fs.path.join(allocator, &.{ root, "Tests", "Binaries" });
    defer allocator.free(rom_root);
    const roms = try scanRoms(allocator, io, cwd, rom_root);
    if (roms != expected.test_roms) return error.RomCountMismatch;

    const cpu_basic_path = try std.fs.path.join(allocator, &.{ root, "Tests", "Binaries", "Gilyon-v1.4", "cputest", "cputest-basic.sfc" });
    defer allocator.free(cpu_basic_path);
    const cpu_full_path = try std.fs.path.join(allocator, &.{ root, "Tests", "Binaries", "Gilyon-v1.4", "cputest", "cputest-full.sfc" });
    defer allocator.free(cpu_full_path);
    const basic_steps = try runGilyon(allocator, io, cwd, cpu_basic_path);
    const full_steps = try runGilyon(allocator, io, cwd, cpu_full_path);
    const spc_path = try std.fs.path.join(allocator, &.{ root, "Tests", "Binaries", "Gilyon-v1.4", "spctest", "spctest.sfc" });
    defer allocator.free(spc_path);
    const spc_steps = try runGilyonSpc(allocator, io, cwd, spc_path);
    const ipl_speed_path = try std.fs.path.join(allocator, &.{ root, "Tests", "Binaries", "Generated", "Undisbeliever-ac6ef800", "hardware-tests", "audio", "ipl-speed-test.sfc" });
    defer allocator.free(ipl_speed_path);
    const ipl_speed = try runIplSpeed(allocator, io, cwd, ipl_speed_path);

    const vector_root = try std.fs.path.join(allocator, &.{ root, "Tests", "SPC700-SingleStep", "v1" });
    defer allocator.free(vector_root);
    const vectors = try scanVectors(allocator, io, cwd, vector_root);
    if (vectors.files != expected.spc700_files or vectors.records != expected.spc700_records) {
        return error.VectorCountMismatch;
    }

    std.debug.print(
        "R4SNES reference harness OK: repositories={d} downloads={d} trees={d} ROMs={d} DMA-diagnostics={d} PPU-diagnostics={d} HDRV-geometries={d} S-DSP-oracles={d} enhancement-oracles={d} enhancement-cases={d} Gilyon-basic={d} Gilyon-full={d} Gilyon-spc={d} IPL-speed-bytes={d} IPL-speed-first-divergence=none IPL-speed-steps={d} SPC700-files={d} vectors={d}\n",
        .{ expected.repositories, expected.downloads, expected.trees, roms, dma_cases.foreign_roms.len, ppu_cases.foreign_roms.len, hdrv_cases.cases.len, sdsp_cases.cases.len, executed_oracles, enhancement_cases.cases.len, basic_steps, full_steps, spc_steps, ipl_speed.bytes, ipl_speed.steps, vectors.files, vectors.records },
    );
}

fn verifyEnhancementVectors(reference: EnhancementReferenceCases) !void {
    if (!std.mem.eql(u8, reference.generator.algorithm, "lcg32-high-byte") or
        reference.generator.seed != 0x12345678 or reference.generator.multiplier != 1664525 or
        reference.generator.increment != 1013904223 or reference.generator.input_bytes != 65536 or
        reference.trace.cases != reference.cases.len or
        !std.mem.eql(u8, reference.trace.result, "byte-identical") or
        reference.trace.verified_oracles.len < 2)
    {
        return error.EnhancementReferenceManifestMismatch;
    }
    for (reference.oracles, 0..) |oracle, index| {
        if (oracle.name.len == 0 or oracle.verification.len == 0 or oracle.sdd1.len == 0 or oracle.spc7110.len == 0) {
            return error.EnhancementReferenceManifestMismatch;
        }
        for (reference.oracles[0..index]) |prior| {
            if (std.mem.eql(u8, prior.name, oracle.name)) return error.DuplicateEnhancementOracle;
        }
    }
    for (reference.trace.verified_oracles) |verified| {
        var matched = false;
        for (reference.oracles) |oracle| {
            if (std.mem.eql(u8, verified, oracle.name) and std.mem.startsWith(u8, oracle.verification, "executed-")) matched = true;
        }
        if (!matched) return error.UnverifiedEnhancementOracle;
    }

    var source: [65536]u8 = undefined;
    fillEnhancementInput(&source);
    var trace_hash = std.crypto.hash.sha2.Sha256.init(.{});
    for (reference.cases, 0..) |case, index| {
        if (case.id.len == 0 or case.output_bytes != 64 or case.expected_hex.len != 128) {
            return error.EnhancementReferenceManifestMismatch;
        }
        var name_buffer: [32]u8 = undefined;
        const name = if (std.mem.eql(u8, case.chip, "sdd1"))
            try std.fmt.bufPrint(name_buffer[0..], "sdd1_{d}", .{case.mode})
        else if (std.mem.eql(u8, case.chip, "spc7110"))
            try std.fmt.bufPrint(name_buffer[0..], "spc7110_{d}", .{case.mode})
        else
            return error.UnknownEnhancementReferenceChip;
        trace_hash.update(name);
        trace_hash.update("=");
        trace_hash.update(case.expected_hex);
        trace_hash.update("\n");

        var expected: [64]u8 = undefined;
        _ = try std.fmt.hexToBytes(expected[0..], case.expected_hex);
        var actual: [64]u8 = undefined;
        if (std.mem.eql(u8, case.chip, "sdd1")) {
            if (case.mode != index or case.mode > 3 or case.first_byte == null) return error.EnhancementReferenceManifestMismatch;
            fillEnhancementInput(&source);
            source[0] = case.first_byte.?;
            var decoder = core.sdd1.Decompressor{};
            decoder.init(source[0..], .{ 0, 1, 2, 3 }, 0xC00000);
            for (&actual) |*byte| byte.* = decoder.read(source[0..], .{ 0, 1, 2, 3 });
        } else {
            if (index < 4 or case.mode != index - 4 or case.mode > 2 or case.first_byte != null) return error.EnhancementReferenceManifestMismatch;
            fillEnhancementInput(&source);
            try decodeSpcEnhancement(source[0..], case.mode, actual[0..]);
        }
        if (!std.mem.eql(u8, expected[0..], actual[0..])) return error.EnhancementOracleMismatch;
    }
    var actual_trace_hash: [32]u8 = undefined;
    trace_hash.final(&actual_trace_hash);
    var expected_trace_hash: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(expected_trace_hash[0..], reference.trace.sha256);
    if (!std.mem.eql(u8, expected_trace_hash[0..], actual_trace_hash[0..])) return error.EnhancementTraceDigestMismatch;
}

fn fillEnhancementInput(bytes: *[65536]u8) void {
    var state: u32 = 0x12345678;
    for (bytes) |*byte| {
        state = state *% 1664525 +% 1013904223;
        byte.* = @truncate(state >> 24);
    }
}

fn decodeSpcEnhancement(data: []const u8, mode: u8, output: []u8) !void {
    var decoder = core.spc7110.Decompressor{};
    try decoder.init(data, mode, 0);
    _ = decoder.decode(data);
    var at: usize = 0;
    while (at < output.len) {
        var tile: [32]u8 = .{0} ** 32;
        for (0..8) |row| {
            const result = decoder.result;
            switch (decoder.bpp) {
                1 => tile[row] = @truncate(result),
                2 => {
                    tile[row * 2] = @truncate(result);
                    tile[row * 2 + 1] = @truncate(result >> 8);
                },
                4 => {
                    tile[row * 2] = @truncate(result);
                    tile[row * 2 + 1] = @truncate(result >> 8);
                    tile[row * 2 + 16] = @truncate(result >> 16);
                    tile[row * 2 + 17] = @truncate(result >> 24);
                },
                else => return error.InvalidSpcEnhancementBpp,
            }
            _ = decoder.decode(data);
        }
        const tile_bytes = @as(usize, decoder.bpp) * 8;
        const count = @min(tile_bytes, output.len - at);
        @memcpy(output[at .. at + count], tile[0..count]);
        at += count;
    }
}

fn expectImplementedEnhancement(chips: []const MatrixEnhancement, id: []const u8, version: []const u8) !void {
    for (chips) |chip| {
        if (!std.mem.eql(u8, chip.id, id)) continue;
        if (!std.mem.eql(u8, chip.status, "implemented") or
            chip.version == null or !std.mem.eql(u8, chip.version.?, version) or
            chip.firmware == null or !std.mem.eql(u8, chip.firmware.?, "none"))
        {
            return error.QualificationEnhancementMismatch;
        }
        return;
    }
    return error.QualificationEnhancementMissing;
}

fn expectImplementedFirmwareEnhancement(
    chips: []const MatrixEnhancement,
    id: []const u8,
    version: []const u8,
    firmware: []const u8,
) !void {
    for (chips) |chip| {
        if (!std.mem.eql(u8, chip.id, id)) continue;
        if (!std.mem.eql(u8, chip.status, "implemented") or
            chip.version == null or !std.mem.eql(u8, chip.version.?, version) or
            chip.firmware == null or !std.mem.eql(u8, chip.firmware.?, firmware))
        {
            return error.QualificationEnhancementMismatch;
        }
        return;
    }
    return error.QualificationEnhancementMissing;
}

const CpuTestMmio = struct {
    vram: [64 * 1024]u8 = [_]u8{0} ** (64 * 1024),
    vram_word_address: u16 = 0,
    vblank_high: bool = false,
    dma: [8]u8 = [_]u8{0} ** 8,
    smp: ?*core.smp.Smp = null,
    apu_fault: bool = false,

    pub fn read(self: *CpuTestMmio, address: u32, _: u8, _: u8) core.bus.MmioRead {
        const offset: u16 = @truncate(address);
        if (offset >= 0x2140 and offset <= 0x2143) {
            const apu = self.smp orelse return .{};
            if (apu.semantic_ipl_state == .running) {
                _ = apu.runSemanticInstructions(1_024) catch {
                    self.apu_fault = true;
                    return .{ .handled = true, .value = 0xff };
                };
            }
            return .{ .handled = true, .value = apu.cpuReadPort(@intCast(offset - 0x2140)) };
        }
        return switch (offset) {
            0x4210 => value: {
                self.vblank_high = !self.vblank_high;
                break :value .{ .handled = true, .value = if (self.vblank_high) 0x80 else 0x00 };
            },
            0x4212, 0x4218, 0x4219 => .{ .handled = true, .value = 0 },
            else => .{},
        };
    }

    pub fn write(self: *CpuTestMmio, address: u32, value: u8, _: u8, _: u8) bool {
        const offset: u16 = @truncate(address);
        if (offset >= 0x2140 and offset <= 0x2143) {
            const apu = self.smp orelse return false;
            apu.cpuWritePort(@intCast(offset - 0x2140), value);
            return true;
        }
        switch (offset) {
            0x2116 => self.vram_word_address = (self.vram_word_address & 0xff00) | value,
            0x2117 => self.vram_word_address = (self.vram_word_address & 0x00ff) | (@as(u16, value) << 8),
            0x2118 => self.vram[@as(usize, self.vram_word_address) * 2] = value,
            0x2119 => {
                self.vram[@as(usize, self.vram_word_address) * 2 + 1] = value;
                self.vram_word_address +%= 1;
            },
            0x4300...0x4307 => self.dma[offset - 0x4300] = value,
            // The ROM's two startup DMAs only clear VRAM and upload the font.
            // Neither affects CPU-visible state or the direct tilemap writes
            // used for the machine-readable result below.
            0x420b => {},
            else => {},
        }
        return true;
    }

    fn contains(self: *const CpuTestMmio, needle: []const u8) bool {
        if (needle.len == 0) return true;
        var word: usize = 0;
        while (word + needle.len <= self.vram.len / 2) : (word += 1) {
            var index: usize = 0;
            while (index < needle.len and self.vram[(word + index) * 2] == needle[index]) : (index += 1) {}
            if (index == needle.len) return true;
        }
        return false;
    }
};

fn runGilyon(allocator: std.mem.Allocator, io: std.Io, cwd: std.Io.Dir, path: []const u8) !u64 {
    return runGilyonCore(allocator, io, cwd, path, false);
}

fn runGilyonSpc(allocator: std.mem.Allocator, io: std.Io, cwd: std.Io.Dir, path: []const u8) !u64 {
    return runGilyonCore(allocator, io, cwd, path, true);
}

fn runGilyonCore(allocator: std.mem.Allocator, io: std.Io, cwd: std.Io.Dir, path: []const u8, with_smp: bool) !u64 {
    const bytes = try cwd.readFileAlloc(io, path, allocator, .limited(max_rom_bytes));
    defer allocator.free(bytes);
    var cartridge = try core.cartridge.Cartridge.parse(allocator, bytes);
    defer cartridge.deinit();

    var system_bus = core.bus.Bus{};
    var mmio = CpuTestMmio{};
    var smp = core.smp.Smp{};
    if (with_smp) {
        smp.powerSemanticIpl();
        mmio.smp = &smp;
    }
    var scpu = core.scpu.Scpu{};
    var clock = core.timing.Clock.init(if (cartridge.board.region == .pal) .pal else .ntsc);
    var controllers = core.controller.Ports{};
    var cpu = core.cpu.Cpu{};
    var port = core.scpu.TimedPortWithDevice(*CpuTestMmio){
        .bus = &system_bus,
        .cartridge = &cartridge,
        .scpu = &scpu,
        .clock = &clock,
        .controllers = &controllers,
        .cpu = &cpu,
        .device = &mmio,
    };

    const step_limit: u64 = if (with_smp) 400_000_000 else 100_000_000;
    var steps: u64 = 0;
    while (steps < step_limit) : (steps += 1) {
        const outcome = try cpu.step(&port);
        if (mmio.apu_fault) return error.GilyonApuFault;
        if (outcome.state == .stopped) {
            std.debug.print("R4SNES Gilyon stopped: {s} PC={x:0>2}:{x:0>4} test={x:0>4}\n", .{ path, cpu.pb, cpu.pc, @as(u16, system_bus.wram[0x10]) | (@as(u16, system_bus.wram[0x11]) << 8) });
            return error.GilyonStopped;
        }
        if ((steps & 0x3ff) == 0) {
            if (mmio.contains("Failed") or mmio.contains("Invalid test order")) {
                std.debug.print("R4SNES Gilyon failure: {s} PC={x:0>2}:{x:0>4} test={x:0>4}\n", .{ path, cpu.pb, cpu.pc, @as(u16, system_bus.wram[0x10]) | (@as(u16, system_bus.wram[0x11]) << 8) });
                return error.GilyonFunctionalFailure;
            }
            if (mmio.contains("Success")) return steps + 1;
        }
    }
    std.debug.print("R4SNES Gilyon timeout: {s} PC={x:0>2}:{x:0>4} test={x:0>4}\n", .{ path, cpu.pb, cpu.pc, @as(u16, system_bus.wram[0x10]) | (@as(u16, system_bus.wram[0x11]) << 8) });
    return error.GilyonTimeout;
}

const IplSpeedResult = struct { bytes: usize, steps: u64 };

fn runIplSpeed(allocator: std.mem.Allocator, io: std.Io, cwd: std.Io.Dir, path: []const u8) !IplSpeedResult {
    const bytes = try cwd.readFileAlloc(io, path, allocator, .limited(max_rom_bytes));
    defer allocator.free(bytes);
    var cartridge = try core.cartridge.Cartridge.parse(allocator, bytes);
    defer cartridge.deinit();

    var system_bus = core.bus.Bus{};
    var smp = core.smp.Smp{};
    smp.powerSemanticIpl();
    var mmio = CpuTestMmio{ .smp = &smp };
    var scpu = core.scpu.Scpu{};
    var clock = core.timing.Clock.init(if (cartridge.board.region == .pal) .pal else .ntsc);
    var controllers = core.controller.Ports{};
    var cpu = core.cpu.Cpu{};
    var port = core.scpu.TimedPortWithDevice(*CpuTestMmio){
        .bus = &system_bus,
        .cartridge = &cartridge,
        .scpu = &scpu,
        .clock = &clock,
        .controllers = &controllers,
        .cpu = &cpu,
        .device = &mmio,
    };

    const transfer_size: usize = 32 * 1024;
    const step_limit: u64 = 100_000_000;
    var steps: u64 = 0;
    while (steps < step_limit) : (steps += 1) {
        const outcome = try cpu.step(&port);
        if (outcome.state == .stopped) return error.IplSpeedStopped;
        if (mmio.apu_fault) return error.IplSpeedApuFault;
        if (smp.semantic_ipl_state == .receiving and smp.semantic_received == transfer_size) {
            for (0..transfer_size) |index| {
                const expected: u8 = @truncate(index / 128);
                const actual = smp.aram[0x0200 + index];
                if (actual != expected) {
                    std.debug.print("R4SNES IPL speed first divergence: byte={d} ARAM={x:0>4} actual={x:0>2} expected={x:0>2}\n", .{ index, 0x0200 + index, actual, expected });
                    return error.IplSpeedDataMismatch;
                }
            }
            return .{ .bytes = transfer_size, .steps = steps + 1 };
        }
    }
    std.debug.print("R4SNES IPL speed timeout: PC={x:0>2}:{x:0>4} received={d} state={s}\n", .{ cpu.pb, cpu.pc, smp.semantic_received, @tagName(smp.semantic_ipl_state) });
    return error.IplSpeedTimeout;
}

fn expectSha256(bytes: []const u8, expected: []const u8) !void {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    var actual: [64]u8 = undefined;
    _ = std.fmt.bufPrint(actual[0..], "{x}", .{digest}) catch unreachable;
    if (!std.mem.eql(u8, expected, actual[0..])) return error.DigestMismatch;
}

fn scanRoms(allocator: std.mem.Allocator, io: std.Io, cwd: std.Io.Dir, root: []const u8) !usize {
    var dir = try cwd.openDir(io, root, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    var count: usize = 0;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or
            (!std.ascii.endsWithIgnoreCase(entry.path, ".sfc") and !std.ascii.endsWithIgnoreCase(entry.path, ".smc"))) continue;
        const path = try std.fs.path.join(allocator, &.{ root, entry.path });
        defer allocator.free(path);
        const bytes = try cwd.readFileAlloc(io, path, allocator, .limited(max_rom_bytes));
        defer allocator.free(bytes);
        _ = try core.cartridge.inspectCandidateSize(bytes.len);
        var parsed = core.cartridge.Cartridge.parse(allocator, bytes) catch |fault| {
            std.debug.print("R4SNES cartridge parse failed: {s} fault={s}\n", .{ entry.path, @errorName(fault) });
            return fault;
        };
        parsed.deinit();
        count += 1;
    }
    return count;
}

const VectorCounts = struct { files: usize = 0, records: usize = 0 };

fn scanVectors(allocator: std.mem.Allocator, io: std.Io, cwd: std.Io.Dir, root: []const u8) !VectorCounts {
    var dir = try cwd.openDir(io, root, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    var result = VectorCounts{};
    var smp = core.smp.Smp{};
    smp.bus_mode = .vector_ram;
    smp.trace_enabled = true;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.ascii.endsWithIgnoreCase(entry.path, ".json")) continue;
        const path = try std.fs.path.join(allocator, &.{ root, entry.path });
        defer allocator.free(path);
        const bytes = try cwd.readFileAlloc(io, path, allocator, .limited(max_vector_bytes));
        defer allocator.free(bytes);
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
        defer parsed.deinit();
        const records = switch (parsed.value) {
            .array => |array| array.items.len,
            else => return error.InvalidVectorFile,
        };
        if (records != 1000) return error.InvalidVectorRecordCount;
        const array = parsed.value.array;
        for (array.items) |record| try runSpc700Vector(&smp, record);
        result.files += 1;
        result.records += records;
    }
    return result;
}

fn runSpc700Vector(smp: *core.smp.Smp, record: std.json.Value) !void {
    const object = switch (record) {
        .object => |value| value,
        else => return error.InvalidVectorRecord,
    };
    const name = try jsonString(object.get("name"));
    const initial = try jsonObject(object.get("initial"));
    const final = try jsonObject(object.get("final"));
    const expected_cycles = try jsonArray(object.get("cycles"));

    @memset(smp.aram[0..], 0);
    smp.a = try jsonU8(initial.get("a"));
    smp.x = try jsonU8(initial.get("x"));
    smp.y = try jsonU8(initial.get("y"));
    smp.sp = try jsonU8(initial.get("sp"));
    smp.pc = try jsonU16(initial.get("pc"));
    smp.psw = try jsonU8(initial.get("psw"));
    smp.cycles = 0;
    smp.stopped = false;
    smp.waiting = false;
    smp.fault = null;
    try loadVectorRam(smp, try jsonArray(initial.get("ram")));

    smp.beginTrace();
    smp.step() catch |fault| {
        std.debug.print("SPC700 vector {s}: execution fault={s}\n", .{ name, @errorName(fault) });
        return fault;
    };
    const actual_cycles = smp.endTrace();

    const expected_a = try jsonU8(final.get("a"));
    const expected_x = try jsonU8(final.get("x"));
    const expected_y = try jsonU8(final.get("y"));
    const expected_sp = try jsonU8(final.get("sp"));
    const expected_pc = try jsonU16(final.get("pc"));
    const expected_psw = try jsonU8(final.get("psw"));
    if (smp.a != expected_a or smp.x != expected_x or smp.y != expected_y or smp.sp != expected_sp or
        smp.pc != expected_pc or smp.psw != expected_psw)
    {
        std.debug.print(
            "SPC700 vector {s}: state actual A={x:0>2} X={x:0>2} Y={x:0>2} SP={x:0>2} PC={x:0>4} PSW={x:0>2}; expected A={x:0>2} X={x:0>2} Y={x:0>2} SP={x:0>2} PC={x:0>4} PSW={x:0>2}\n",
            .{ name, smp.a, smp.x, smp.y, smp.sp, smp.pc, smp.psw, expected_a, expected_x, expected_y, expected_sp, expected_pc, expected_psw },
        );
        return error.Spc700StateMismatch;
    }

    const final_ram = try jsonArray(final.get("ram"));
    for (final_ram.items) |entry| {
        const pair = try jsonArray(entry);
        if (pair.items.len != 2) return error.InvalidVectorRamEntry;
        const address = try jsonU16(pair.items[0]);
        const expected = try jsonU8(pair.items[1]);
        if (smp.aram[address] != expected) {
            std.debug.print("SPC700 vector {s}: RAM[{x:0>4}] actual={x:0>2} expected={x:0>2}\n", .{ name, address, smp.aram[address], expected });
            return error.Spc700RamMismatch;
        }
    }

    if (actual_cycles.len != expected_cycles.items.len) {
        std.debug.print("SPC700 vector {s}: cycle count actual={d} expected={d}\n", .{ name, actual_cycles.len, expected_cycles.items.len });
        return error.Spc700CycleCountMismatch;
    }
    for (expected_cycles.items, actual_cycles, 0..) |expected_value, actual, index| {
        const expected = try jsonArray(expected_value);
        if (expected.items.len != 3) return error.InvalidVectorCycle;
        const expected_kind = try jsonString(expected.items[2]);
        const expected_cycle_kind: core.smp.BusCycleKind = if (std.mem.eql(u8, expected_kind, "read"))
            .read
        else if (std.mem.eql(u8, expected_kind, "write"))
            .write
        else if (std.mem.eql(u8, expected_kind, "wait"))
            .wait
        else
            return error.InvalidVectorCycleKind;
        const address_matches = switch (expected.items[0]) {
            .null => actual.address == null,
            else => actual.address != null and actual.address.? == try jsonU16(expected.items[0]),
        };
        const value_matches = switch (expected.items[1]) {
            .null => true,
            else => actual.value != null and actual.value.? == try jsonU8(expected.items[1]),
        };
        if (actual.kind != expected_cycle_kind or !address_matches or !value_matches) {
            std.debug.print(
                "SPC700 vector {s}: cycle {d} actual={s} address={?x} value={?x}; expected={s} address={any} value={any}\n",
                .{ name, index, @tagName(actual.kind), actual.address, actual.value, expected_kind, expected.items[0], expected.items[1] },
            );
            return error.Spc700CycleMismatch;
        }
    }
}

fn loadVectorRam(smp: *core.smp.Smp, entries: std.json.Array) !void {
    for (entries.items) |entry| {
        const pair = try jsonArray(entry);
        if (pair.items.len != 2) return error.InvalidVectorRamEntry;
        smp.aram[try jsonU16(pair.items[0])] = try jsonU8(pair.items[1]);
    }
}

fn jsonObject(value: ?std.json.Value) !std.json.ObjectMap {
    return switch (value orelse return error.MissingVectorField) {
        .object => |object| object,
        else => error.InvalidVectorField,
    };
}

fn jsonArray(value: anytype) !std.json.Array {
    const resolved = switch (@TypeOf(value)) {
        ?std.json.Value => value orelse return error.MissingVectorField,
        std.json.Value => value,
        else => @compileError("unsupported JSON value wrapper"),
    };
    return switch (resolved) {
        .array => |array| array,
        else => error.InvalidVectorField,
    };
}

fn jsonString(value: anytype) ![]const u8 {
    const resolved = switch (@TypeOf(value)) {
        ?std.json.Value => value orelse return error.MissingVectorField,
        std.json.Value => value,
        else => @compileError("unsupported JSON value wrapper"),
    };
    return switch (resolved) {
        .string => |string| string,
        else => error.InvalidVectorField,
    };
}

fn jsonU8(value: anytype) !u8 {
    const integer = try jsonInteger(value);
    if (integer < 0 or integer > std.math.maxInt(u8)) return error.InvalidVectorInteger;
    return @intCast(integer);
}

fn jsonU16(value: anytype) !u16 {
    const integer = try jsonInteger(value);
    if (integer < 0 or integer > std.math.maxInt(u16)) return error.InvalidVectorInteger;
    return @intCast(integer);
}

fn jsonInteger(value: anytype) !i64 {
    const resolved = switch (@TypeOf(value)) {
        ?std.json.Value => value orelse return error.MissingVectorField,
        std.json.Value => value,
        else => @compileError("unsupported JSON value wrapper"),
    };
    return switch (resolved) {
        .integer => |integer| integer,
        else => error.InvalidVectorField,
    };
}
