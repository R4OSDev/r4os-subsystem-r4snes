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
    repositories: usize,
    downloads: usize,
    trees: usize,
    test_roms: usize,
    dma_reference_roms: usize,
    ppu_reference_roms: usize,
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
    if (matrix.schema != 1 or !std.mem.eql(u8, matrix.release, "0.73.7")) return error.UnsupportedQualificationMatrix;
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
    const ppu_digests = [_][]const u8{
        "84eefc2777a6e325",
        "a71592d0a1312325",
        "f24128f9b0f3e325",
        "488f665ded0f2325",
        "9ef804ce64d52325",
    };
    if (ppu_cases.schema != 1 or !std.mem.eql(u8, ppu_cases.release, "0.73.7") or
        ppu_cases.model_oracles.len != ppu_digests.len or ppu_cases.foreign_roms.len != expected.ppu_reference_roms)
    {
        return error.PpuReferenceManifestMismatch;
    }
    for (ppu_cases.model_oracles, 0..) |model, index| {
        if (model.mode != index or !std.mem.eql(u8, model.geometry, "256x224") or model.xrgb32.len == 0 or
            !std.mem.eql(u8, model.digest_fnv1a64, ppu_digests[index]))
        {
            return error.PpuModelOracleMismatch;
        }
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

    const vector_root = try std.fs.path.join(allocator, &.{ root, "Tests", "SPC700-SingleStep", "v1" });
    defer allocator.free(vector_root);
    const vectors = try scanVectors(allocator, io, cwd, vector_root);
    if (vectors.files != expected.spc700_files or vectors.records != expected.spc700_records) {
        return error.VectorCountMismatch;
    }

    std.debug.print(
        "R4SNES reference harness OK: repositories={d} downloads={d} trees={d} ROMs={d} DMA-diagnostics={d} PPU-diagnostics={d} Gilyon-basic={d} Gilyon-full={d} SPC700-files={d} vectors={d}\n",
        .{ expected.repositories, expected.downloads, expected.trees, roms, dma_cases.foreign_roms.len, ppu_cases.foreign_roms.len, basic_steps, full_steps, vectors.files, vectors.records },
    );
}

const CpuTestMmio = struct {
    vram: [64 * 1024]u8 = [_]u8{0} ** (64 * 1024),
    vram_word_address: u16 = 0,
    vblank_high: bool = false,
    dma: [8]u8 = [_]u8{0} ** 8,

    pub fn read(self: *CpuTestMmio, address: u32, _: u8, _: u8) core.bus.MmioRead {
        const offset: u16 = @truncate(address);
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
    const bytes = try cwd.readFileAlloc(io, path, allocator, .limited(max_rom_bytes));
    defer allocator.free(bytes);
    var cartridge = try core.cartridge.Cartridge.parse(allocator, bytes);
    defer cartridge.deinit();

    var system_bus = core.bus.Bus{};
    var mmio = CpuTestMmio{};
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

    const step_limit: u64 = 100_000_000;
    var steps: u64 = 0;
    while (steps < step_limit) : (steps += 1) {
        const outcome = try cpu.step(&port);
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
        result.files += 1;
        result.records += records;
    }
    return result;
}
