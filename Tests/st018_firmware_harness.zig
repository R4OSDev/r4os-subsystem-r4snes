const std = @import("std");
const core = @import("core");

const st018 = core.st018;
const maximum_manifest_bytes: usize = 256 * 1024;
const expected_firmware_sha256 = "2621d3e067cd23a94c74712eb1aa1d8e5035fca6ecae8ec5f765611966317ad1";
const expected_open_digest: u64 = 0xde70_6906_0a5e_262d;

const Manifest = struct {
    schema: u32,
    tool: []const u8,
    source: []const u8,
    source_sha256: []const u8,
    firmware: Firmware,
    geometry: Geometry,
    coverage: []const []const u8,
    proprietary_firmware_images: usize,
    oracle_sources: []const Oracle,

    const Firmware = struct {
        file: []const u8,
        bytes: usize,
        sha256: []const u8,
        proprietary: bool,
    };
    const Geometry = struct {
        program_rom_bytes: usize,
        data_rom_bytes: usize,
        work_ram_bytes: usize,
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

const ExpectedOracleFile = struct { path: []const u8, sha256: []const u8 };
const ares_files = [_]ExpectedOracleFile{
    .{ .path = "Implementations/Ares/ares/sfc/coprocessor/armdsp/armdsp.hpp", .sha256 = "dbbf4701c0d9d54775f9d52deb86c581d0e50a941394f590dcbccbe767a8762d" },
    .{ .path = "Implementations/Ares/ares/sfc/coprocessor/armdsp/memory.cpp", .sha256 = "443195a4bc3f5a52b7a8aa803c8764c16f4b370fadf86bdec8a076432c68c235" },
    .{ .path = "Implementations/Ares/ares/component/processor/arm7tdmi/arm7tdmi.hpp", .sha256 = "a9cb2640bf4aa8a15e39aefc2ba9b20df48d8ed181a5c7f8ed78f14c1cbbd515" },
    .{ .path = "Implementations/Ares/ares/component/processor/arm7tdmi/instructions-arm.cpp", .sha256 = "d597457a19fefaafd2477704ee4f6934858bd4fb8a572c773b85174943f1c2cc" },
    .{ .path = "Implementations/Ares/ares/component/processor/arm7tdmi/registers.cpp", .sha256 = "1921ab9982558b1ce7c08ba2573ca31846f3b24925589afdb6fbbc6dbc043e0e" },
    .{ .path = "Implementations/Ares/ares/component/processor/arm7tdmi/algorithms.cpp", .sha256 = "f5cc40b1615ec490f822760f93ca29cbb5e1eb38c02c3269e20c81363818e4cd" },
};
const mesen_files = [_]ExpectedOracleFile{
    .{ .path = "Implementations/Mesen2/Core/SNES/Coprocessors/ST018/ArmV3Cpu.cpp", .sha256 = "fda11c7649aff769826d98fc0e332387d78b0cbc8eeba05a1c85554a74311118" },
    .{ .path = "Implementations/Mesen2/Core/SNES/Coprocessors/ST018/ArmV3Cpu.h", .sha256 = "ba1e07c96383945ab748f76559e445a45b5d3fb0ddcf0c4a977036d6f15643e1" },
    .{ .path = "Implementations/Mesen2/Core/SNES/Coprocessors/ST018/ArmV3Types.h", .sha256 = "852b38ce19942801a0d647452215b6ac6c6cc5611a66d34cea6b525f1a477e38" },
    .{ .path = "Implementations/Mesen2/Core/SNES/Coprocessors/ST018/St018.cpp", .sha256 = "66bf98fed2d4b659e2950ac0cbb841f3711ab555c18a20f530a9effc6e965478" },
    .{ .path = "Implementations/Mesen2/Core/SNES/Coprocessors/ST018/St018.h", .sha256 = "9b89dd2baf45606bb754c112b1f8be3af271f9c0b4febbc5dff3db59cdd9c779" },
    .{ .path = "Implementations/Mesen2/Core/SNES/Coprocessors/ST018/St018Types.h", .sha256 = "cf3431155b5813e8a3e955e955ccfb03348ca093b4b1caf7aac16c11363b0b6b" },
};

pub fn main(init: std.process.Init) void {
    run(init) catch |fault| {
        std.debug.print("R4SNES ST018 firmware harness FAILED: {s}\n", .{@errorName(fault)});
        std.process.exit(1);
    };
}

fn run(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const cwd = std.Io.Dir.cwd();
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const output_root = if (args.len >= 2) args[1] else "../../../Temp/R4SNES-ST018";
    const private_root: ?[]const u8 = if (args.len >= 3 and args[2].len != 0) args[2] else null;

    const manifest_path = try std.fs.path.join(allocator, &.{ output_root, "manifest.json" });
    defer allocator.free(manifest_path);
    const manifest_bytes = try cwd.readFileAlloc(io, manifest_path, allocator, .limited(maximum_manifest_bytes));
    defer allocator.free(manifest_bytes);
    var parsed = try std.json.parseFromSlice(Manifest, allocator, manifest_bytes, .{ .ignore_unknown_fields = false });
    defer parsed.deinit();
    try verifyManifest(allocator, io, cwd, parsed.value);

    const open_path = try std.fs.path.join(allocator, &.{ output_root, parsed.value.firmware.file });
    defer allocator.free(open_path);
    const bytes = try cwd.readFileAlloc(io, open_path, allocator, .limited(st018.firmware_bytes + 1));
    defer {
        @memset(bytes, 0);
        allocator.free(bytes);
    }
    try expectSha256(bytes, expected_firmware_sha256);
    const digest = try exerciseOpenFirmware(allocator, bytes);
    if (digest != expected_open_digest) {
        std.debug.print("ST018 open state digest mismatch: expected={x:0>16} actual={x:0>16}\n", .{ expected_open_digest, digest });
        return error.St018OpenDigestMismatch;
    }

    const private_count = if (private_root) |root| try exercisePrivateFirmware(allocator, io, cwd, root) else 0;
    std.debug.print(
        "R4SNES ST018 firmware harness OK: ARMv3-classes=10 bridge=exact RAM=16384 reset-delay=65536 independent-oracles=2 private-firmware={d} digest={x:0>16}\n",
        .{ private_count, digest },
    );
}

fn verifyManifest(allocator: std.mem.Allocator, io: std.Io, cwd: std.Io.Dir, manifest: Manifest) !void {
    if (manifest.schema != 1 or
        !std.mem.eql(u8, manifest.tool, "R4SNES deterministic ARMv3/ST018 fixture v1") or
        !std.mem.eql(u8, manifest.source, "Tests/Build-St018Firmware.ps1") or
        manifest.firmware.bytes != st018.firmware_bytes or manifest.firmware.proprietary or
        !std.mem.eql(u8, manifest.firmware.file, "r4snes_st018.open.rom") or
        !std.mem.eql(u8, manifest.firmware.sha256, expected_firmware_sha256) or
        manifest.geometry.program_rom_bytes != st018.program_rom_bytes or
        manifest.geometry.data_rom_bytes != st018.data_rom_bytes or
        manifest.geometry.work_ram_bytes != st018.work_ram_bytes or
        manifest.coverage.len != 12 or manifest.proprietary_firmware_images != 0 or
        manifest.oracle_sources.len != 2)
    {
        return error.InvalidSt018BuildManifest;
    }
    const script = try cwd.readFileAlloc(io, manifest.source, allocator, .limited(256 * 1024));
    defer allocator.free(script);
    try expectSha256(script, manifest.source_sha256);
    try verifyOracle(manifest.oracle_sources[0], "Ares ARM6/ST018", "7b51c8ab719e403a150aa700e0933d9e93a06851", &ares_files);
    try verifyOracle(manifest.oracle_sources[1], "Mesen2 ARMv3/ST018", "b9fa69ddc6d0a331fb103fdb5eef6904305703c2", &mesen_files);
}

fn verifyOracle(actual: Manifest.Oracle, name: []const u8, revision: []const u8, files: []const ExpectedOracleFile) !void {
    if (!std.mem.eql(u8, actual.name, name) or !std.mem.eql(u8, actual.revision, revision) or actual.files.len != files.len)
        return error.St018OracleManifestMismatch;
    for (files, actual.files) |expected, actual_file| {
        if (!std.mem.eql(u8, expected.path, actual_file.path) or !std.mem.eql(u8, expected.sha256, actual_file.sha256))
            return error.St018OracleManifestMismatch;
    }
}

fn exerciseOpenFirmware(allocator: std.mem.Allocator, bytes: []const u8) !u64 {
    _ = try st018.validateFirmware(bytes, .allow_open_test, .open_test);
    var device = try st018.Device.init(allocator, bytes, .allow_open_test, .open_test);
    defer device.close();

    const delay = device.runSlice(st018.reset_delay_cycles);
    if (delay.state != .running or delay.instructions != 0 or delay.cycles != st018.reset_delay_cycles or !device.ready)
        return error.St018ResetDelayMismatch;
    if (!device.writeCpu(0x003802, 0x37)) return error.St018HostWriteFailure;
    const first = device.runSlice(4);
    if (first.instructions != 4 or device.status() != 0x89 or device.readCpu(0x803800, 0) != 0x5a)
        return error.St018FirstHandshakeMismatch;
    const second = device.runSlice(5);
    if (second.instructions != 5 or device.readCpu(0x003800, 0) != 0x38)
        return error.St018SecondHandshakeMismatch;
    const ram = device.runSlice(3);
    if (ram.instructions != 3 or device.work_ram[0x123] != 0xa5)
        return error.St018WorkRamMismatch;
    const dirty = device.takeDirtyRange() orelse return error.St018WorkRamNotDirty;
    if (dirty.first != 0x123 or dirty.end != 0x124) return error.St018DirtyRangeMismatch;
    return device.stateDigest();
}

fn exercisePrivateFirmware(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: std.Io.Dir,
    root: []const u8,
) !usize {
    const path = try std.fs.path.join(allocator, &.{ root, "st018.rom" });
    defer allocator.free(path);
    const bytes = try cwd.readFileAlloc(io, path, allocator, .limited(st018.firmware_bytes + 1));
    defer {
        @memset(bytes, 0);
        allocator.free(bytes);
    }
    _ = try st018.validateFirmware(bytes, .known_only, .separate);
    var device = try st018.Device.init(allocator, bytes, .known_only, .separate);
    defer device.close();
    const delay = device.runSlice(st018.reset_delay_cycles);
    if (delay.state != .running or !device.ready) return error.PrivateSt018ResetDelayMismatch;
    var remaining: usize = 250_000;
    while (remaining != 0) {
        const amount = @min(remaining, 4096);
        const result = device.runSlice(amount);
        if (result.state == .closed) return error.PrivateSt018ClosedUnexpectedly;
        remaining -= amount;
    }
    if (device.cpu.instruction_count == 0 or device.firmware_source != .separate)
        return error.PrivateSt018DidNotBoot;
    return 1;
}

fn expectSha256(bytes: []const u8, text: []const u8) !void {
    if (text.len != 64) return error.InvalidSha256Text;
    var actual: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &actual, .{});
    var expected: [32]u8 = undefined;
    for (0..expected.len) |index| {
        expected[index] = (try hexNibble(text[index * 2]) << 4) | try hexNibble(text[index * 2 + 1]);
    }
    if (!std.mem.eql(u8, &actual, &expected)) return error.Sha256Mismatch;
}

fn hexNibble(value: u8) !u8 {
    return switch (value) {
        '0'...'9' => value - '0',
        'a'...'f' => value - 'a' + 10,
        'A'...'F' => value - 'A' + 10,
        else => error.InvalidSha256Text,
    };
}
