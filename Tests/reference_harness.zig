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
    repositories: usize,
    downloads: usize,
    trees: usize,
    test_roms: usize,
    dma_reference_roms: usize,
    ppu_reference_roms: usize,
    hdrv_geometry_cases: usize,
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
    commercial_roms: usize,
    proprietary_firmware_images: usize,
};

const MatrixSuite = struct {
    rom_count: ?usize = null,
};

const Matrix = struct {
    schema: u32,
    release: []const u8,
    corpus: Corpus,
    suites: []const MatrixSuite,
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
    if (matrix.schema != 1 or !std.mem.eql(u8, matrix.release, "0.73.9")) return error.UnsupportedQualificationMatrix;
    if (matrix.suites.len != 9 or matrix.corpus.test_roms != expected.test_roms or
        matrix.corpus.spc700_single_step_files != expected.spc700_files or
        matrix.corpus.spc700_single_step_records != expected.spc700_records or
        matrix.corpus.commercial_roms != 0 or matrix.corpus.proprietary_firmware_images != 0)
    {
        return error.QualificationMatrixMismatch;
    }
    var matrix_roms: usize = 0;
    for (matrix.suites) |suite| matrix_roms += suite.rom_count orelse 0;
    if (matrix_roms != expected.test_roms) return error.QualificationSuiteCountMismatch;

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
        "R4SNES reference harness OK: repositories={d} downloads={d} trees={d} ROMs={d} DMA-diagnostics={d} PPU-diagnostics={d} HDRV-geometries={d} Gilyon-basic={d} Gilyon-full={d} Gilyon-spc={d} IPL-speed-bytes={d} IPL-speed-first-divergence=none IPL-speed-steps={d} SPC700-files={d} vectors={d}\n",
        .{ expected.repositories, expected.downloads, expected.trees, roms, dma_cases.foreign_roms.len, ppu_cases.foreign_roms.len, hdrv_cases.cases.len, basic_steps, full_steps, spc_steps, ipl_speed.bytes, ipl_speed.steps, vectors.files, vectors.records },
    );
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
