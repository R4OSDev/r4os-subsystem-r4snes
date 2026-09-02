const std = @import("std");
const core = @import("core");

const rom_bytes: usize = 256 * 1024;
const maximum_program_bytes: usize = 64 * 1024;

const Manifest = struct {
    schema: u32,
    tool: []const u8,
    wla_revision: []const u8,
    programs: []const Program,
    oracle_sources: []const OracleSource,

    const Program = struct {
        name: []const u8,
        origin: []const u8,
        source: []const u8,
        source_sha256: []const u8,
        binary: []const u8,
        bytes: usize,
        sha256: []const u8,
    };

    const OracleSource = struct {
        name: []const u8,
        revision: []const u8,
        files: []const OracleFile,
    };

    const OracleFile = struct {
        path: []const u8,
        sha256: []const u8,
    };
};

const ExpectedProgram = struct {
    name: []const u8,
    origin: []const u8,
    source: []const u8,
    source_sha256: []const u8,
    bytes: usize,
    sha256: []const u8,
};

const expected_programs = [_]ExpectedProgram{
    .{
        .name = "wla_hello",
        .origin = "WLA-DX",
        .source = "ExFiles/Reference/SNES/Tools/WLA-DX/tests/cx4/hello_world_test/cx4_prog.s",
        .source_sha256 = "b15c3c6f08d6866076c65211715f3c0f9a6a1862b521255940536e37e1fe492b",
        .bytes = 14,
        .sha256 = "b563d3b02e2486fb63ad2c3d9a36b2f00b7560d0d20e72638fbe2cf088311a30",
    },
    .{
        .name = "wla_hg51b_instructions",
        .origin = "WLA-DX",
        .source = "ExFiles/Reference/SNES/Tools/WLA-DX/tests/cx4/hg51b_instructions_test/cx4_prog.s",
        .source_sha256 = "07220c5cf68373c6c08e895262ebd68bf3c932b175497c66bfe160ad1fa70170",
        .bytes = 1170,
        .sha256 = "54174d5d698d1267e3f25b2f7899f50d39d9986265632822d00670cbccd906ba",
    },
    .{
        .name = "r4snes_geometry",
        .origin = "R4SNES",
        .source = "Repositories/Subsystems/R4SNES/Tests/Cx4Programs/r4snes_geometry.s",
        .source_sha256 = "bc26f6cbe9c2fa86e1e2579c95c85796826a2c2ad4a4afcaa2d693676daacaa4",
        .bytes = 100,
        .sha256 = "9e771d8d8d0748874f7adf9d3fc98f23da1906f28e9708fce5c4d677c4b6780b",
    },
    .{
        .name = "r4snes_bus",
        .origin = "R4SNES",
        .source = "Repositories/Subsystems/R4SNES/Tests/Cx4Programs/r4snes_bus.s",
        .source_sha256 = "19169f8aff3e894078aa469dc1bb0e28d1bc627773307f831ae76d5b927a9bb0",
        .bytes = 32,
        .sha256 = "d1e65c721aa5d9b719c9de1c35204f00864ec44dada2de669a923491d96b8bd0",
    },
};

const ExpectedOracle = struct {
    name: []const u8,
    revision: []const u8,
    files: []const ExpectedOracleFile,
};

const ExpectedOracleFile = struct {
    path: []const u8,
    sha256: []const u8,
};

const ares_files = [_]ExpectedOracleFile{
    .{ .path = "Implementations/Ares/ares/component/processor/hg51b/instruction.cpp", .sha256 = "4fbad0dceaf5aa0b79e4aa307a30bb8c1dc70ce43951001c2938c419f5504d09" },
    .{ .path = "Implementations/Ares/ares/component/processor/hg51b/instructions.cpp", .sha256 = "169b92467bb6879a26df6e91bdebe5b92340fd792566e4316beee3deeec3023c" },
    .{ .path = "Implementations/Ares/ares/component/processor/hg51b/registers.cpp", .sha256 = "8037c5e9a259487bc098c424a7d77739de439d7b0a1be27c80e0d9ee573a8d7b" },
    .{ .path = "Implementations/Ares/ares/sfc/coprocessor/hitachidsp/memory.cpp", .sha256 = "ee68fe412f1437e0c7be8147252055f2f04a33c59d9de5615f9a5fe7a6775fec" },
};

const mesen_files = [_]ExpectedOracleFile{
    .{ .path = "Implementations/Mesen2/Core/SNES/Coprocessors/CX4/Cx4.cpp", .sha256 = "8f89a595f0873b6024e94c4d729652c1d4b03a8b4d7f952f143607e3e67133f0" },
    .{ .path = "Implementations/Mesen2/Core/SNES/Coprocessors/CX4/Cx4.Instructions.cpp", .sha256 = "37f02e8e4bd77ae689e63b82fcecc0fe44189e881a5ce5052658817864eab548" },
};

const expected_oracles = [_]ExpectedOracle{
    .{ .name = "Ares HG51B/HitachiDSP", .revision = "7b51c8ab719e403a150aa700e0933d9e93a06851", .files = &ares_files },
    .{ .name = "Mesen2 CX4", .revision = "b9fa69ddc6d0a331fb103fdb5eef6904305703c2", .files = &mesen_files },
};

pub fn main(init: std.process.Init) void {
    run(init) catch |fault| {
        std.debug.print("R4SNES CX4 program harness FAILED: {s}\n", .{@errorName(fault)});
        std.process.exit(1);
    };
}

fn run(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const cwd = std.Io.Dir.cwd();
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const output_root = if (args.len >= 2) args[1] else "../../../Temp/R4SNES-CX4";
    const manifest_path = try std.fs.path.join(allocator, &.{ output_root, "manifest.json" });
    defer allocator.free(manifest_path);
    const manifest_bytes = try cwd.readFileAlloc(io, manifest_path, allocator, .limited(256 * 1024));
    defer allocator.free(manifest_bytes);
    var parsed = try std.json.parseFromSlice(Manifest, allocator, manifest_bytes, .{ .ignore_unknown_fields = false });
    defer parsed.deinit();
    const manifest = parsed.value;
    try verifyManifest(manifest);

    var binaries: [expected_programs.len][]u8 = undefined;
    var loaded: usize = 0;
    defer for (binaries[0..loaded]) |bytes| allocator.free(bytes);
    for (expected_programs, manifest.programs, 0..) |expected, actual, index| {
        const binary_path = try std.fs.path.join(allocator, &.{ output_root, actual.binary });
        defer allocator.free(binary_path);
        binaries[index] = try cwd.readFileAlloc(io, binary_path, allocator, .limited(maximum_program_bytes));
        loaded += 1;
        if (binaries[index].len != expected.bytes) return error.Cx4ProgramSizeMismatch;
        try expectSha256(binaries[index], expected.sha256);
    }

    var aggregate: u64 = 0xcbf29ce484222325;
    try runHello(allocator, binaries[0], &aggregate);
    try runInstructionSuite(allocator, binaries[1], &aggregate);
    try runGeometry(allocator, binaries[2], &aggregate);
    try runBus(allocator, binaries[3], &aggregate);

    if (aggregate != 0x43ef_b663_69fe_7449) {
        std.debug.print("CX4 aggregate mismatch: expected={x:0>16} actual={x:0>16}\n", .{ @as(u64, 0x43ef_b663_69fe_7449), aggregate });
        return error.Cx4AggregateDigestMismatch;
    }

    std.debug.print(
        "R4SNES CX4 program harness OK: WLA-DX=10.7 programs=4 independent-oracles=2 data-rom-words=1024 pixel-oracles=64 digest={x:0>16}\n",
        .{aggregate},
    );
}

fn verifyManifest(manifest: Manifest) !void {
    if (manifest.schema != 1 or
        !std.mem.eql(u8, manifest.tool, "WLA-DX 10.7 wla-cx4/wlalink") or
        !std.mem.eql(u8, manifest.wla_revision, "91c52b1f4ef3cc8ba3c0638f7536539579af6a9f") or
        manifest.programs.len != expected_programs.len or manifest.oracle_sources.len != expected_oracles.len)
    {
        return error.InvalidCx4BuildManifest;
    }
    for (expected_programs, manifest.programs) |expected, actual| {
        var binary_buffer: [64]u8 = undefined;
        const expected_binary = try std.fmt.bufPrint(&binary_buffer, "{s}.bin", .{expected.name});
        if (!std.mem.eql(u8, actual.name, expected.name) or
            !std.mem.eql(u8, actual.origin, expected.origin) or
            !std.mem.eql(u8, actual.source, expected.source) or
            !std.mem.eql(u8, actual.source_sha256, expected.source_sha256) or
            !std.mem.eql(u8, actual.binary, expected_binary) or
            actual.bytes != expected.bytes or !std.mem.eql(u8, actual.sha256, expected.sha256))
        {
            return error.Cx4BuildManifestMismatch;
        }
    }
    for (expected_oracles, manifest.oracle_sources) |expected, actual| {
        if (!std.mem.eql(u8, actual.name, expected.name) or
            !std.mem.eql(u8, actual.revision, expected.revision) or actual.files.len != expected.files.len)
        {
            return error.Cx4OracleManifestMismatch;
        }
        for (expected.files, actual.files) |expected_file, actual_file| {
            if (!std.mem.eql(u8, actual_file.path, expected_file.path) or
                !std.mem.eql(u8, actual_file.sha256, expected_file.sha256))
            {
                return error.Cx4OracleManifestMismatch;
            }
        }
    }
}

fn runHello(allocator: std.mem.Allocator, program: []const u8, aggregate: *u64) !void {
    const rom = try makeRom(allocator, program);
    defer allocator.free(rom);
    var save_ram: [0]u8 = .{};
    var device = core.cx4.Device{};
    try device.power(rom.len, 0);
    device.gpr[0] = 17;
    device.gpr[1] = 9;
    try kick(&device, rom, &save_ram, 0x008000, 20_000);
    if (device.gpr[2] != 553 or device.gpr[15] != 0xab) return error.Cx4HelloOracleMismatch;
    mixDevice(aggregate, &device);
}

fn runInstructionSuite(allocator: std.mem.Allocator, program: []const u8, aggregate: *u64) !void {
    const rom = try makeRom(allocator, program);
    defer allocator.free(rom);
    var save_ram: [0]u8 = .{};
    var device = core.cx4.Device{};
    try device.power(rom.len, 0);
    device.gpr[0] = 0;
    device.gpr[1] = 0x11;
    try kick(&device, rom, &save_ram, 0x008000, 100_000);
    try kick(&device, rom, &save_ram, 0x008400, 100_000);

    const expected = [_]u24{
        0xb5ba00, 0x6eee11, 0x222a16, 0xee3f3f,
        0x2208f0, 0x1101fc, 0xff8055, 0xff8000,
        0x44aa33, 0x204020, 0x77aa55, 0xffffff,
        0x302010, 0x003255, 0x77552a, 0x0000ab,
    };
    if (!std.mem.eql(u24, &device.gpr, &expected)) return error.Cx4InstructionOracleMismatch;
    // The upstream source comments call these two sequences RAM round-trips,
    // but the encoded WRRAM instruction writes the independent RAM latch at
    // the address in A.  With a zeroed latch the exact observable RAM result
    // is therefore unchanged; the owner geometry fixture below verifies the
    // intended non-zero latch path separately.
    if (device.data_ram[0] != 0 or device.data_ram[1] != 0) return error.Cx4InstructionRamMismatch;
    mixDevice(aggregate, &device);
}

fn runGeometry(allocator: std.mem.Allocator, program: []const u8, aggregate: *u64) !void {
    const rom = try makeRom(allocator, program);
    defer allocator.free(rom);
    var save_ram: [0]u8 = .{};
    var device = core.cx4.Device{};
    try device.power(rom.len, 0);
    device.gpr[0] = 1;
    device.gpr[1] = 2;
    device.gpr[2] = 2;
    device.gpr[3] = 1;
    device.gpr[4] = 0xffffff;
    device.gpr[5] = 2;
    try kick(&device, rom, &save_ram, 0x008000, 50_000);

    if (device.gpr[8] != 4 or device.gpr[9] != 3 or device.gpr[10] != 0xb504f3 or
        device.gpr[11] != 0x006a09 or device.gpr[12] != 0x2aaaaa or
        device.gpr[13] != 0x0ccccc or device.gpr[14] != 6 or device.gpr[15] != 0xab)
    {
        return error.Cx4GeometryRegisterMismatch;
    }
    if (device.data_ram[0x20] != 4 or device.data_ram[0x21] != 3) return error.Cx4WireframeOracleMismatch;
    for (0..8) |y| for (0..8) |x| {
        const expected: u8 = if (x == 4 and y == 3) 3 else 0;
        const actual = pixel2bpp(device.data_ram[0..16], @intCast(x), @intCast(y));
        if (actual != expected) {
            std.debug.print("CX4 sprite oracle mismatch x={d} y={d} expected={d} actual={d} tile={any}\n", .{
                x,
                y,
                expected,
                actual,
                device.data_ram[0..16],
            });
            return error.Cx4SpritePixelOracleMismatch;
        }
    };
    mixDevice(aggregate, &device);
}

fn runBus(allocator: std.mem.Allocator, program: []const u8, aggregate: *u64) !void {
    const rom = try makeRom(allocator, program);
    defer allocator.free(rom);
    var save_ram: [0]u8 = .{};
    var device = core.cx4.Device{};
    try device.power(rom.len, 0);
    device.gpr[0] = 0x008000;
    device.gpr[2] = 0x006020;
    start(&device, rom, &save_ram, 0x008000);

    var observed_contention = false;
    var cycles: usize = 0;
    while (device.running() and cycles < 50_000) : (cycles += 1) {
        _ = device.runSlice(rom, &save_ram, 1);
        if (!observed_contention and device.bus_enabled and device.bus_address == 0x008000) {
            const blocked = device.readCpu(rom, &save_ram, 0x008000, 0xa5) orelse
                return error.Cx4BusContentionWasNotHandled;
            if (blocked != 0xa5) return error.Cx4BusContentionOracleMismatch;
            observed_contention = true;
        }
    }
    if (device.running()) return error.Cx4ProgramTimeout;
    if (!observed_contention or device.gpr[1] != program[0] or device.gpr[3] != 0x5a or
        device.gpr[15] != 0xab or device.data_ram[0x20] != 0x5a or device.bus_conflicts != 1)
    {
        return error.Cx4BusOracleMismatch;
    }
    mixDevice(aggregate, &device);
}

fn kick(device: *core.cx4.Device, rom: []const u8, save_ram: []u8, base: u24, cycle_limit: usize) !void {
    start(device, rom, save_ram, base);
    var cycles: usize = 0;
    while (device.running() and cycles < cycle_limit) : (cycles += 257)
        _ = device.runSlice(rom, save_ram, @min(257, cycle_limit - cycles));
    if (device.running()) return error.Cx4ProgramTimeout;
    if (device.last_fault != null) return error.Cx4ProgramFault;
}

fn start(device: *core.cx4.Device, rom: []const u8, save_ram: []u8, base: u24) void {
    writeIo(device, rom, save_ram, 0x7f49, @truncate(base));
    writeIo(device, rom, save_ram, 0x7f4a, @truncate(base >> 8));
    writeIo(device, rom, save_ram, 0x7f4b, @truncate(base >> 16));
    writeIo(device, rom, save_ram, 0x7f48, 0);
    writeIo(device, rom, save_ram, 0x7f4d, 0);
    writeIo(device, rom, save_ram, 0x7f4e, 0);
    writeIo(device, rom, save_ram, 0x7f4f, 0);
}

fn writeIo(device: *core.cx4.Device, rom: []const u8, save_ram: []u8, address: u16, value: u8) void {
    std.debug.assert(device.writeCpu(rom, save_ram, address, value).handled);
}

fn makeRom(allocator: std.mem.Allocator, program: []const u8) ![]u8 {
    if (program.len > rom_bytes) return error.Cx4ProgramTooLarge;
    const rom = try allocator.alloc(u8, rom_bytes);
    @memset(rom, 0);
    @memcpy(rom[0..program.len], program);
    return rom;
}

fn pixel2bpp(tile: []const u8, x: u3, y: u3) u8 {
    const shift: u3 = x ^ 7;
    return ((tile[@as(usize, y) * 2] >> shift) & 1) |
        (((tile[@as(usize, y) * 2 + 1] >> shift) & 1) << 1);
}

fn expectSha256(bytes: []const u8, expected_hex: []const u8) !void {
    var actual: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &actual, .{});
    var expected: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected, expected_hex);
    if (!std.mem.eql(u8, &actual, &expected)) return error.Cx4ProgramDigestMismatch;
}

fn mixDevice(aggregate: *u64, device: *const core.cx4.Device) void {
    digestU64(aggregate, device.stateDigest());
    for (device.gpr) |value| digestU24(aggregate, value);
    for (device.data_ram) |value| digestByte(aggregate, value);
}

fn digestU24(digest: *u64, value: u24) void {
    inline for (0..3) |index| digestByte(digest, @truncate(value >> @intCast(index * 8)));
}

fn digestU64(digest: *u64, value: u64) void {
    inline for (0..8) |index| digestByte(digest, @truncate(value >> @intCast(index * 8)));
}

fn digestByte(digest: *u64, value: u8) void {
    digest.* ^= value;
    digest.* *%= 0x100000001b3;
}
