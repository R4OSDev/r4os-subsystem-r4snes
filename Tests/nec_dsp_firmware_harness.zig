const std = @import("std");
const core = @import("core");

const ndsp = core.nec_dsp;
const maximum_manifest_bytes: usize = 256 * 1024;
const expected_aggregate: u64 = 0xb281_ee2e_aaa5_f878;

const Manifest = struct {
    schema: u32,
    tool: []const u8,
    source: []const u8,
    source_sha256: []const u8,
    program_words: usize,
    data_words: usize,
    emitted_matrix_words: usize,
    coverage: Coverage,
    proprietary_firmware_images: usize,
    firmware: []const Firmware,
    oracle_sources: []const Oracle,

    const Coverage = struct {
        instruction_classes: usize,
        alu_modes: usize,
        sources: usize,
        destinations: usize,
        p_selects: usize,
        accumulator_selects: usize,
        dp_low_modes: usize,
        dp_high_masks: usize,
        rp_modes: usize,
        defined_branch_modes: usize,
        reserved_branch_modes: usize,
        host_handshake_words: usize,
    };

    const Firmware = struct {
        id: []const u8,
        revision: []const u8,
        file: []const u8,
        bytes: usize,
        sha256: []const u8,
    };

    const Oracle = struct {
        name: []const u8,
        revision: []const u8,
        files: []const OracleFile,
    };

    const OracleFile = struct {
        path: []const u8,
        sha256: []const u8,
    };
};

const ExpectedFirmware = struct {
    id: []const u8,
    revision_name: []const u8,
    revision: ndsp.Revision,
    file: []const u8,
    sha256: []const u8,
    signature: u16,
};

const expected_firmware = [_]ExpectedFirmware{
    .{ .id = "dsp1", .revision_name = "DSP-1", .revision = .dsp1, .file = "r4snes_dsp1.open.rom", .sha256 = "3da27ea1a3f35c4adba873b296e7566b8107e9097949f7995440e8695827dc28", .signature = 0x11 },
    .{ .id = "dsp1a", .revision_name = "DSP-1A", .revision = .dsp1a, .file = "r4snes_dsp1a.open.rom", .sha256 = "b171c3a264d554e3209b33a8ee620b475261347b75d38fd7d808dd0bf541f838", .signature = 0x1a },
    .{ .id = "dsp1b", .revision_name = "DSP-1B", .revision = .dsp1b, .file = "r4snes_dsp1b.open.rom", .sha256 = "1eae39b14a9be6cd1cee0150cef580ed444be4a0092a5def0e8295d27f400c9f", .signature = 0x1b },
    .{ .id = "dsp2", .revision_name = "DSP-2", .revision = .dsp2, .file = "r4snes_dsp2.open.rom", .sha256 = "ce4f9ae68ff74d384a54648da1011157d49e53adaadcd1070aef58e125b95359", .signature = 0x22 },
    .{ .id = "dsp3", .revision_name = "DSP-3", .revision = .dsp3, .file = "r4snes_dsp3.open.rom", .sha256 = "adf490789ba5d5961de143c99000dd1ee9ee7d27e3a4b95ce892d2ecd093703f", .signature = 0x33 },
    .{ .id = "dsp4", .revision_name = "DSP-4", .revision = .dsp4, .file = "r4snes_dsp4.open.rom", .sha256 = "384b744f1f79d237624c61099646e8679566d211f9015a27e59a0697a8d20c5d", .signature = 0x44 },
};

const ExpectedOracleFile = struct { path: []const u8, sha256: []const u8 };
const ares_files = [_]ExpectedOracleFile{
    .{ .path = "Implementations/Ares/ares/component/processor/upd96050/upd96050.hpp", .sha256 = "cb2e205743649aa9b213dbfe29e3023821f04ae742780c1d667640d65f168164" },
    .{ .path = "Implementations/Ares/ares/component/processor/upd96050/instructions.cpp", .sha256 = "3e020f8fd8b5e6f710a79c4d28e3fbda4b57a250db50bf3fef05a57fa5c6a25c" },
    .{ .path = "Implementations/Ares/ares/component/processor/upd96050/memory.cpp", .sha256 = "6fde8b9fab1c01b462fbbe9c25d81394ce4fad406be7894059c4d051234133fa" },
    .{ .path = "Implementations/Ares/ares/sfc/coprocessor/necdsp/memory.cpp", .sha256 = "94ac70acde0d5552754606a27db78c40cd8fe3543814b9b32d594a8114082556" },
};
const mesen_files = [_]ExpectedOracleFile{
    .{ .path = "Implementations/Mesen2/Core/SNES/Coprocessors/DSP/NecDsp.cpp", .sha256 = "c4f0d7c74b5869995335d73666fb0f2b503c7365baff6eb8d03a522b947fabb5" },
    .{ .path = "Implementations/Mesen2/Core/SNES/Coprocessors/DSP/NecDsp.h", .sha256 = "bb00bac90fceb6acb177b82ebd6535fb40e4cc17e58129ad600fa8292579ddd1" },
    .{ .path = "Implementations/Mesen2/Core/SNES/Coprocessors/DSP/NecDspTypes.h", .sha256 = "3f8be8f9043a2da1ddb484fbb51387d8b2ca78c28c421e9a851242ddb88fbf6a" },
};

pub fn main(init: std.process.Init) void {
    run(init) catch |fault| {
        std.debug.print("R4SNES NEC-DSP firmware harness FAILED: {s}\n", .{@errorName(fault)});
        std.process.exit(1);
    };
}

fn run(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const cwd = std.Io.Dir.cwd();
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const output_root = if (args.len >= 2) args[1] else "../../../Temp/R4SNES-NECDSP";
    const private_root: ?[]const u8 = if (args.len >= 3 and args[2].len != 0) args[2] else null;

    const manifest_path = try std.fs.path.join(allocator, &.{ output_root, "manifest.json" });
    defer allocator.free(manifest_path);
    const manifest_bytes = try cwd.readFileAlloc(io, manifest_path, allocator, .limited(maximum_manifest_bytes));
    defer allocator.free(manifest_bytes);
    var parsed = try std.json.parseFromSlice(Manifest, allocator, manifest_bytes, .{ .ignore_unknown_fields = false });
    defer parsed.deinit();
    try verifyManifest(parsed.value);

    var aggregate: u64 = 0xcbf29ce484222325;
    for (expected_firmware, parsed.value.firmware) |expected, actual| {
        const path = try std.fs.path.join(allocator, &.{ output_root, actual.file });
        defer allocator.free(path);
        const bytes = try cwd.readFileAlloc(io, path, allocator, .limited(ndsp.firmware_bytes + 1));
        defer {
            @memset(bytes, 0);
            allocator.free(bytes);
        }
        if (bytes.len != ndsp.firmware_bytes) return error.OpenNecDspFirmwareSizeMismatch;
        try expectSha256(bytes, expected.sha256);
        try exerciseOpenFirmware(expected, bytes, &aggregate);
    }

    if (aggregate != expected_aggregate) {
        std.debug.print("NEC-DSP aggregate mismatch: expected={x:0>16} actual={x:0>16}\n", .{ expected_aggregate, aggregate });
        return error.NecDspAggregateMismatch;
    }

    const private_count = if (private_root) |root| try exercisePrivateFirmware(allocator, io, cwd, root) else 0;
    std.debug.print(
        "R4SNES NEC-DSP firmware harness OK: variants=6 matrix-words=122 instruction-classes=4 ALUs=16 sources=16 destinations=16 branches=39+1 independent-oracles=2 private-firmware={d} digest={x:0>16}\n",
        .{ private_count, aggregate },
    );
}

fn verifyManifest(manifest: Manifest) !void {
    if (manifest.schema != 1 or
        !std.mem.eql(u8, manifest.tool, "R4SNES deterministic uPD7725 encoder v1") or
        !std.mem.eql(u8, manifest.source, "Repositories/Subsystems/R4SNES/Tests/Build-NecDspFirmware.ps1") or
        !std.mem.eql(u8, manifest.source_sha256, "f5a8c4e4977c2497aac5c320c9b77e0f792b40358c4d09ccdabb7f30b29bbefa") or
        manifest.program_words != ndsp.program_words or manifest.data_words != ndsp.data_words or
        manifest.emitted_matrix_words != 122 or manifest.proprietary_firmware_images != 0 or
        manifest.firmware.len != expected_firmware.len or manifest.oracle_sources.len != 2)
    {
        return error.InvalidNecDspBuildManifest;
    }
    const coverage = manifest.coverage;
    if (coverage.instruction_classes != 4 or coverage.alu_modes != 16 or coverage.sources != 16 or
        coverage.destinations != 16 or coverage.p_selects != 4 or coverage.accumulator_selects != 2 or
        coverage.dp_low_modes != 4 or coverage.dp_high_masks != 16 or coverage.rp_modes != 2 or
        coverage.defined_branch_modes != 39 or coverage.reserved_branch_modes != 1 or
        coverage.host_handshake_words != 5)
    {
        return error.InvalidNecDspCoverageManifest;
    }
    for (expected_firmware, manifest.firmware) |expected, actual| {
        if (!std.mem.eql(u8, expected.id, actual.id) or
            !std.mem.eql(u8, expected.revision_name, actual.revision) or
            !std.mem.eql(u8, expected.file, actual.file) or actual.bytes != ndsp.firmware_bytes or
            !std.mem.eql(u8, expected.sha256, actual.sha256))
        {
            return error.NecDspFirmwareManifestMismatch;
        }
    }
    try verifyOracle(manifest.oracle_sources[0], "Ares uPD7725", "7b51c8ab719e403a150aa700e0933d9e93a06851", &ares_files);
    try verifyOracle(manifest.oracle_sources[1], "Mesen2 NEC DSP", "b9fa69ddc6d0a331fb103fdb5eef6904305703c2", &mesen_files);
}

fn verifyOracle(actual: Manifest.Oracle, name: []const u8, revision: []const u8, files: []const ExpectedOracleFile) !void {
    if (!std.mem.eql(u8, actual.name, name) or !std.mem.eql(u8, actual.revision, revision) or actual.files.len != files.len)
        return error.NecDspOracleManifestMismatch;
    for (files, actual.files) |expected, actual_file| {
        if (!std.mem.eql(u8, expected.path, actual_file.path) or !std.mem.eql(u8, expected.sha256, actual_file.sha256))
            return error.NecDspOracleManifestMismatch;
    }
}

fn exerciseOpenFirmware(expected: ExpectedFirmware, bytes: []const u8, aggregate: *u64) !void {
    const mapping: core.board.Mapping = if (expected.revision == .dsp1b) .hi_rom else .lo_rom;
    const ram_size: usize = if (expected.revision == .dsp1a or expected.revision == .dsp2) 8 * 1024 else 0;
    var device = try ndsp.Device.init(expected.revision, mapping, 1024 * 1024, ram_size, bytes, .allow_open_test, .open_test);
    defer device.close();
    if (device.data_rom[0] != expected.signature) return error.OpenNecDspDataRomMismatch;

    const first = device.runSlice(32);
    if (first.state != .waiting_host or first.executed != 2 or !device.requestForMaster())
        return error.OpenNecDspHandshakeMismatch;
    const ports = canonicalPorts(device.host_map);
    if (device.readCpu(ports.status, 0) != 0x80 or device.readCpu(ports.data, 0) != 0x34 or
        device.readCpu(ports.data, 0) != 0x12 or device.requestForMaster())
        return error.OpenNecDspHostReadMismatch;
    const second = device.runSlice(32);
    if (second.state != .waiting_host or device.readCpu(ports.data, 0) != 0x78 or
        device.readCpu(ports.data, 0) != 0x56)
        return error.OpenNecDspSecondHandshakeMismatch;

    var classes = [_]usize{0} ** 4;
    for (device.program_rom[0..122]) |opcode| classes[opcode >> 22] += 1;
    for (classes) |count| if (count == 0) return error.OpenNecDspInstructionClassMissing;
    mixQword(aggregate, device.stateDigest());
    mixByte(aggregate, @intFromEnum(expected.revision));
}

const Ports = struct { data: u32, status: u32 };
fn canonicalPorts(map: ndsp.HostMap) Ports {
    return switch (map) {
        .dsp1_lo_small => .{ .data = 0x308000, .status = 0x30c000 },
        .dsp1_lo_small_ram => .{ .data = 0x208000, .status = 0x20c000 },
        .dsp1_lo_large => .{ .data = 0x600000, .status = 0x604000 },
        .dsp1_hi => .{ .data = 0x006000, .status = 0x007000 },
        .dsp2 => .{ .data = 0x206000, .status = 0x20c000 },
        .dsp3 => .{ .data = 0x208000, .status = 0x20c000 },
        .dsp4 => .{ .data = 0x308000, .status = 0x30c000 },
    };
}

fn exercisePrivateFirmware(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: std.Io.Dir,
    root: []const u8,
) !usize {
    const files = [_][]const u8{ "dsp1.rom", "dsp1.rom", "dsp1b.rom", "dsp2.rom", "dsp3.rom", "dsp4.rom" };
    var completed: usize = 0;
    for (expected_firmware, files) |expected, file| {
        const path = try std.fs.path.join(allocator, &.{ root, file });
        defer allocator.free(path);
        const bytes = try cwd.readFileAlloc(io, path, allocator, .limited(ndsp.firmware_bytes + 1));
        defer {
            @memset(bytes, 0);
            allocator.free(bytes);
        }
        _ = try ndsp.validateFirmware(expected.revision, bytes, .known_only);
        const mapping: core.board.Mapping = if (expected.revision == .dsp1b) .hi_rom else .lo_rom;
        var device = try ndsp.Device.init(expected.revision, mapping, 1024 * 1024, 0, bytes, .known_only, .separate);
        defer device.close();
        try runPrivateUntilReady(&device);
        if (expected.revision == .dsp1b) {
            // Public DSP-1 command $00: signed Q15 multiply. This proves that
            // a known user image runs beyond reset through the generic core;
            // no command implementation or firmware byte is embedded here.
            const port = canonicalPorts(device.host_map).data;
            const request = [_]u8{ 0x00, 0x00, 0x40, 0x00, 0x40 };
            for (request) |value| {
                if (!device.writeCpu(port, value)) return error.PrivateNecDspHostWriteFailure;
                try runPrivateUntilReady(&device);
            }
            const low = device.readCpu(port, 0) orelse return error.PrivateNecDspHostReadFailure;
            try runPrivateUntilReady(&device);
            const high = device.readCpu(port, 0) orelse return error.PrivateNecDspHostReadFailure;
            if (low != 0x00 or high != 0x20) return error.PrivateNecDspMultiplyOracleMismatch;
        }
        completed += 1;
    }
    return completed;
}

fn runPrivateUntilReady(device: *ndsp.Device) !void {
    var budget: usize = 1_000_000;
    while (budget != 0 and !device.requestForMaster()) {
        const slice = @min(budget, 4096);
        const result = device.runSlice(slice);
        if (result.state == .closed) return error.PrivateNecDspClosedUnexpectedly;
        budget -= slice;
    }
    if (!device.requestForMaster()) return error.PrivateNecDspHandshakeTimeout;
}

fn expectSha256(bytes: []const u8, text: []const u8) !void {
    var actual: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &actual, .{});
    var expected: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected, text);
    if (!std.mem.eql(u8, &actual, &expected)) return error.NecDspFirmwareHashMismatch;
}

fn mixByte(result: *u64, value: u8) void {
    result.* = (result.* ^ value) *% 0x100000001b3;
}

fn mixQword(result: *u64, value: u64) void {
    var remaining = value;
    for (0..8) |_| {
        mixByte(result, @truncate(remaining));
        remaining >>= 8;
    }
}
