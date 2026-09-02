const std = @import("std");
const core = @import("core");

const ram_bytes: usize = 64 * 1024;
const max_program_bytes: usize = 32 * 1024;

const Manifest = struct {
    schema: u32,
    tool: []const u8,
    programs: []const Program,

    const Program = struct {
        name: []const u8,
        origin: []const u8,
        source: []const u8,
        binary: []const u8,
        bytes: usize,
        sha256: []const u8,
    };
};

const ExpectedProgram = struct {
    name: []const u8,
    origin: []const u8,
    source: []const u8,
    bytes: usize,
    sha256: []const u8,
};

const expected_programs = [_]ExpectedProgram{
    .{ .name = "opensnes_hello", .origin = "OpenSNES", .source = "ExFiles/Reference/SNES/Documentation/OpenSNES/examples/chips/superfx_hello/gsu_hello.sfx", .bytes = 57, .sha256 = "c3f8561b16e6b5d57acfd0f9b8749fc556e18ffd9e3048d5579e58844736f4cf" },
    .{ .name = "opensnes_3d", .origin = "OpenSNES", .source = "ExFiles/Reference/SNES/Documentation/OpenSNES/examples/chips/superfx_3d/gsu_3d.sfx", .bytes = 211, .sha256 = "ebd4ad3cc0e02b97e2c423b0fa787bfaec02ad6fbd6396d546bec8c52b453a1f" },
    .{ .name = "r4snes_opcode", .origin = "R4SNES", .source = "Repositories/Subsystems/R4SNES/Tests/SuperFxPrograms/r4snes_opcode.sfx", .bytes = 42, .sha256 = "9a1108f25e8a2d4dd3c86c37beb63b18fe3be38befd2fa96d278731decbc752a" },
    .{ .name = "r4snes_cache", .origin = "R4SNES", .source = "Repositories/Subsystems/R4SNES/Tests/SuperFxPrograms/r4snes_cache.sfx", .bytes = 42, .sha256 = "f4bac7fb54c94d39f7299eeb72024e0387f6ca557172bfa35fa68574de42ea09" },
    .{ .name = "r4snes_pixel", .origin = "R4SNES", .source = "Repositories/Subsystems/R4SNES/Tests/SuperFxPrograms/r4snes_pixel.sfx", .bytes = 37, .sha256 = "a7bf127640c47bb95f281780a27443821c14a1c11237b0bc1c5cf422f7b3382b" },
    .{ .name = "r4snes_bus", .origin = "R4SNES", .source = "Repositories/Subsystems/R4SNES/Tests/SuperFxPrograms/r4snes_bus.sfx", .bytes = 28, .sha256 = "34aa6b5d8289f312ca5cfabe08e02310e4eb01640138f56574844b63eac4fe2e" },
};

const Edge = struct { x0: u8, y0: u8, x1: u8, y1: u8 };
const cube_edges = [_]Edge{
    .{ .x0 = 8, .y0 = 8, .x1 = 120, .y1 = 8 },
    .{ .x0 = 120, .y0 = 8, .x1 = 120, .y1 = 120 },
    .{ .x0 = 120, .y0 = 120, .x1 = 8, .y1 = 120 },
    .{ .x0 = 8, .y0 = 120, .x1 = 8, .y1 = 8 },
    .{ .x0 = 32, .y0 = 32, .x1 = 96, .y1 = 32 },
    .{ .x0 = 96, .y0 = 32, .x1 = 96, .y1 = 96 },
    .{ .x0 = 96, .y0 = 96, .x1 = 32, .y1 = 96 },
    .{ .x0 = 32, .y0 = 96, .x1 = 32, .y1 = 32 },
    .{ .x0 = 8, .y0 = 8, .x1 = 32, .y1 = 32 },
    .{ .x0 = 120, .y0 = 8, .x1 = 96, .y1 = 32 },
    .{ .x0 = 120, .y0 = 120, .x1 = 96, .y1 = 96 },
    .{ .x0 = 8, .y0 = 120, .x1 = 32, .y1 = 96 },
};

pub fn main(init: std.process.Init) void {
    run(init) catch |fault| {
        std.debug.print("R4SNES Super FX program harness FAILED: {s}\n", .{@errorName(fault)});
        std.process.exit(1);
    };
}

fn run(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const cwd = std.Io.Dir.cwd();
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const output_root = if (args.len >= 2) args[1] else "../../../Temp/R4SNES-SuperFX";
    const manifest_path = try std.fs.path.join(allocator, &.{ output_root, "manifest.json" });
    defer allocator.free(manifest_path);
    const manifest_bytes = try cwd.readFileAlloc(io, manifest_path, allocator, .limited(128 * 1024));
    defer allocator.free(manifest_bytes);
    var parsed = try std.json.parseFromSlice(Manifest, allocator, manifest_bytes, .{});
    defer parsed.deinit();
    const manifest = parsed.value;
    if (manifest.schema != 1 or !std.mem.eql(u8, manifest.tool, "WLA-DX 10.7 wla-superfx/wlalink") or
        manifest.programs.len != expected_programs.len)
    {
        return error.InvalidSuperFxBuildManifest;
    }

    var binaries: [expected_programs.len][]u8 = undefined;
    var loaded: usize = 0;
    defer for (binaries[0..loaded]) |bytes| allocator.free(bytes);
    for (expected_programs, manifest.programs, 0..) |expected, actual, index| {
        var binary_name_buffer: [64]u8 = undefined;
        const expected_binary = try std.fmt.bufPrint(&binary_name_buffer, "{s}.bin", .{expected.name});
        if (!std.mem.eql(u8, expected.name, actual.name) or !std.mem.eql(u8, expected.origin, actual.origin) or
            !std.mem.eql(u8, expected.source, actual.source) or expected.bytes != actual.bytes or
            !std.mem.eql(u8, expected.sha256, actual.sha256) or !std.mem.eql(u8, actual.binary, expected_binary))
        {
            return error.SuperFxBuildManifestMismatch;
        }
        const binary_path = try std.fs.path.join(allocator, &.{ output_root, actual.binary });
        defer allocator.free(binary_path);
        binaries[index] = try cwd.readFileAlloc(io, binary_path, allocator, .limited(max_program_bytes));
        loaded += 1;
        if (binaries[index].len != expected.bytes) return error.SuperFxProgramSizeMismatch;
        try expectSha256(binaries[index], expected.sha256);
    }

    var aggregate: u64 = 0xCBF29CE484222325;
    var ram = [_]u8{0} ** ram_bytes;

    var hello = try runProgram(binaries[0], &ram, 0x18, false, 0xA0, 0, 4096);
    try expectBytes(ram[0..8], &.{ 0x42, 0x55, 0xEF, 0xBE, 0x00, 0x40, 0x00, 0x48 });
    if (hello.r[0] != 0xCAFE) return error.OpenSnesHelloRegisterMismatch;
    mixResult(&aggregate, &hello, &ram);

    @memset(ram[0..], 0);
    for (cube_edges, 0..) |edge, index| {
        const base = 0x4000 + index * 4;
        ram[base + 0] = edge.x0;
        ram[base + 1] = edge.y0;
        ram[base + 2] = edge.x1;
        ram[base + 3] = edge.y1;
    }
    var cube = try runProgram(binaries[1], &ram, 0x19, true, 0x80, 0, 2_000_000);
    try verifyCubeFrame(&ram);
    mixResult(&aggregate, &cube, &ram);

    @memset(ram[0..], 0);
    var opcodes = try runProgram(binaries[2], &ram, 0x18, false, 0x80, 0, 4096);
    try expectBytes(ram[0x0100..0x0108], &.{ 0x34, 0x12, 0x36, 0x12, 0x80, 0x04, 0xDE, 0xC0 });
    if (opcodes.r[0] != 0xC0DE) return error.R4SnesOpcodeCompletionMismatch;
    mixResult(&aggregate, &opcodes, &ram);

    @memset(ram[0..], 0);
    var cache = try runProgram(binaries[3], &ram, 0x18, false, 0x80, 0, 4096);
    try expectBytes(ram[0x0120..0x0122], &.{ 0x04, 0x00 });
    mixResult(&aggregate, &cache, &ram);

    @memset(ram[0..], 0);
    var pixel = try runProgram(binaries[4], &ram, 0x19, false, 0x80, 0, 4096);
    try expectBytes(ram[0..2], &.{ 0xFF, 0xFF });
    if (ram[0x10] != 0 or ram[0x11] != 0xFF or ram[0x0200] != 0x0B) return error.R4SnesPixelFrameMismatch;
    mixResult(&aggregate, &pixel, &ram);

    @memset(ram[0..], 0);
    var bus = try runProgram(binaries[5], &ram, 0x18, false, 0x80, 0, 4096);
    try expectBytes(ram[0x0300..0x0304], &.{ 0x5A, 0x00, 0x0D, 0x60 });
    mixResult(&aggregate, &bus, &ram);

    if (aggregate != 0x5EF2_895F_A45D_5025) return error.SuperFxAggregateDigestMismatch;
    std.debug.print("R4SNES Super FX program harness OK: WLA-DX=10.7 programs=6 OpenSNES=2 owner=4 opcode-prefix-cases=2048 cube-pixels=16384 digest={x:0>16}\n", .{aggregate});
}

fn runProgram(
    rom: []const u8,
    ram: []u8,
    scmr: u8,
    fast_clock: bool,
    cfgr: u8,
    r8: u16,
    instruction_limit: usize,
) !core.superfx.Device {
    var device = core.superfx.Device.init(.gsu2);
    try device.power(.gsu2, rom.len, ram.len);
    device.scmr = scmr;
    device.clsr = fast_clock;
    device.cfgr = cfgr;
    device.r[8] = r8;
    _ = device.writeCpu(ram, 0x00301E, 0);
    _ = device.writeCpu(ram, 0x00301F, 0);
    var total: usize = 0;
    while (device.running()) {
        const result = device.runSlice(rom, ram, 257);
        total += result.instructions;
        switch (result.state) {
            .running, .stopped => {},
            .waiting_rom => return error.SuperFxProgramWaitedForRom,
            .waiting_ram => return error.SuperFxProgramWaitedForRam,
            .fault => return error.SuperFxProgramFault,
        }
        if (total > instruction_limit) return error.SuperFxProgramTimeout;
    }
    try device.drain(rom, ram);
    if (device.running()) return error.SuperFxProgramDidNotStop;
    return device;
}

fn verifyCubeFrame(ram: []const u8) !void {
    var expected = [_]bool{false} ** (128 * 128);
    for (cube_edges) |edge| drawLine(&expected, edge);
    for (expected, 0..) |is_set, index| {
        const x: u8 = @intCast(index % 128);
        const y: u8 = @intCast(index / 128);
        const color = pixel4bpp(ram, x, y);
        if (color != if (is_set) @as(u8, 0x0F) else 0) {
            std.debug.print("cube mismatch x={d} y={d} expected={d} actual={d}\n", .{ x, y, @as(u8, @intFromBool(is_set)) * 15, color });
            return error.OpenSnesCubeFrameMismatch;
        }
    }
}

fn drawLine(bitmap: *[128 * 128]bool, edge: Edge) void {
    var x0: i16 = edge.x0;
    var y0: i16 = edge.y0;
    const x1: i16 = edge.x1;
    const y1: i16 = edge.y1;
    const dx: i16 = @intCast(@abs(x1 - x0));
    const sx: i16 = if (x0 < x1) 1 else -1;
    const dy: i16 = -@as(i16, @intCast(@abs(y1 - y0)));
    const sy: i16 = if (y0 < y1) 1 else -1;
    var err = dx + dy;
    while (true) {
        bitmap[@as(usize, @intCast(y0)) * 128 + @as(usize, @intCast(x0))] = true;
        if (x0 == x1 and y0 == y1) break;
        const twice = err * 2;
        if (twice >= dy) {
            err += dy;
            x0 += sx;
        }
        if (twice <= dx) {
            err += dx;
            y0 += sy;
        }
    }
}

fn pixel4bpp(ram: []const u8, x: u8, y: u8) u8 {
    const tile = (@as(usize, x & 0xF8) << 1) + ((y & 0xF8) >> 3);
    const address = tile * 32 + @as(usize, y & 7) * 2;
    const bit: u3 = @truncate((x & 7) ^ 7);
    return ((ram[address] >> bit) & 1) |
        (((ram[address + 1] >> bit) & 1) << 1) |
        (((ram[address + 0x10] >> bit) & 1) << 2) |
        (((ram[address + 0x11] >> bit) & 1) << 3);
}

fn mixResult(aggregate: *u64, device: *const core.superfx.Device, ram: []const u8) void {
    digestU64(aggregate, device.stateDigest());
    for (ram) |value| digestByte(aggregate, value);
}

fn expectBytes(actual: []const u8, expected: []const u8) !void {
    if (!std.mem.eql(u8, actual, expected)) return error.SuperFxRamOracleMismatch;
}

fn expectSha256(bytes: []const u8, expected_hex: []const u8) !void {
    var actual: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &actual, .{});
    var expected: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected, expected_hex);
    if (!std.mem.eql(u8, &actual, &expected)) return error.SuperFxProgramDigestMismatch;
}

fn digestByte(digest: *u64, value: u8) void {
    digest.* ^= value;
    digest.* *%= 0x100000001B3;
}

fn digestU64(digest: *u64, value: u64) void {
    inline for (0..8) |index| digestByte(digest, @truncate(value >> @intCast(index * 8)));
}
