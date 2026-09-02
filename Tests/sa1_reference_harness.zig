const std = @import("std");
const core = @import("core");

const max_rom_bytes: usize = 512 * 1024;
const instruction_limit: usize = 20_000_000;
const master_clock_limit: u64 = 12 * 21_477_272;
const expected_aggregate_digest: u64 = 0x62d2b8acd2c164b6;

const Case = struct {
    name: []const u8,
    relative_path: []const u8,
    bytes: usize,
    sha256: []const u8,
    tilemap_address: usize,
    expected_status: ?u8,
    backup_wait_pc: ?u16 = null,
    expected_tilemap_sha256: ?[]const u8 = null,
    expected_wram_sha256: ?[]const u8 = null,
    expected_sa1_digest: ?u64 = null,
    expected_defined_register_digest: ?u64 = null,
};

const cases = [_]Case{
    .{ .name = "PpuMultiplierUtility", .relative_path = "PpuMultiplierUtility/PpuMultiplierUtility.sfc", .bytes = 262_144, .sha256 = "414ef1830efc2ce95fd1fcad615034ec8339051f464dbbb0f7a1a07315acc41e", .tilemap_address = 0x2000, .expected_status = 1, .expected_tilemap_sha256 = "b41fd00ea5dc365cf41eb47d6d786d1bd607943f3e99a9e928254ea1a645db19", .expected_wram_sha256 = "1015b4bcb7f6198af7cc4b8e4e5950f5a36500d7d08c2f7c7a781040aee66afc", .expected_sa1_digest = 0 },
    .{ .name = "SA1BackupUtility", .relative_path = "SA1BackupUtility/SA1BackupUtility.sfc", .bytes = 32_768, .sha256 = "0d4ee1c016dc95b4b88558f72e66a68e18e1a9e513bb5e1963c19fb6234c571b", .tilemap_address = 0x2000, .expected_status = null, .backup_wait_pc = 0x8063, .expected_tilemap_sha256 = "33c8e08f3e0461e05783ad953ad4aa6915f4d4894fbbb03a045a04573bfad6dd", .expected_wram_sha256 = "3eb909d00169c7805a7e932a4994310df7b8186ca64a5d55676f05f190d1c280", .expected_sa1_digest = 0x506d03f5a43a0092 },
    .{ .name = "SA1OpenbusUtility", .relative_path = "SA1OpenbusUtility/SA1OpenbusUtility.sfc", .bytes = 32_768, .sha256 = "f65738cc4f8b97f094157d4041cb0122bca37e45100d4f13d5ad83f9de026a74", .tilemap_address = 0x1000, .expected_status = 1, .expected_defined_register_digest = 0x622fd733c6a74b7a },
    .{ .name = "SA1RamProtectionTest", .relative_path = "SA1RamProtectionTest/SA1RamProtectionTest.sfc", .bytes = 32_768, .sha256 = "c6cb6433047e5573eea97a45a093f0c2d39c9d3a6f8f860f4c506c01650bc8cb", .tilemap_address = 0x1000, .expected_status = 1, .expected_tilemap_sha256 = "e5a00aa9991ac8a5ee3109844d84a55583bd20572ad3ffcd42792f3c36b183ad", .expected_wram_sha256 = "d76e123ebf2b466f9919752c77cd2b24728b3b316a1d6935ce3d6bb4958bfbf8", .expected_sa1_digest = 0x5b5d9b8f5102d8d2 },
    .{ .name = "SA1ReadRegisterDumpUtility", .relative_path = "SA1ReadRegisterDumpUtility/SA1ReadRegisterDumpUtility.sfc", .bytes = 32_768, .sha256 = "17409fb19a30dbce47af7ba194c501940358f2cea6ecc47435ff01cecbcf5215", .tilemap_address = 0x1000, .expected_status = 1, .expected_defined_register_digest = 0x5f546e2cc24b7a37 },
    .{ .name = "SA1RebootTest", .relative_path = "SA1RebootTest/SA1RebootTest.sfc", .bytes = 32_768, .sha256 = "f19e6ff21d5f0c95eb6d892ccbd4c389285ae229a58c06bacf8dc9112cf04d82", .tilemap_address = 0x1000, .expected_status = 1, .expected_defined_register_digest = 0x345ea338353c657f },
};

const Result = struct {
    status: u8,
    instructions: usize,
    master_cycles: u64,
    cpu_pc: u16,
    cpu_pb: u8,
    tilemap_sha256: [32]u8,
    wram_sha256: [32]u8,
    sa1_digest: u64,
    defined_register_digest: u64,
    bwram: []u8,
    iram: [core.sa1.internal_ram_bytes]u8,
    backup_iram_bytes: u16 = 0,
    backup_iram_bits: u16 = 0,
    backup_bwram_bytes: u16 = 0,
    backup_bwram_bits: u16 = 0,
    backup_detected_size: u32 = 0,
    diagnostic: [0x20]u8,
    first_failure_id: u8 = 0,
    first_failure_result: u8 = 0,
    first_failure_actual: u8 = 0,
    first_failure_expected: u8 = 0,
};

const Machine = struct {
    bus: core.bus.Bus = .{},
    clock: core.timing.Clock,
    ports: core.controller.Ports = .{},
    cpu: core.cpu.Cpu = .{},
    scpu: core.scpu.Scpu = .{},
    ppu: core.ppu.Ppu = .{},
    smp: core.smp.Smp = .{},

    fn init(region: core.board.Region) Machine {
        var result = Machine{ .clock = core.timing.Clock.init(if (region == .pal) .pal else .ntsc) };
        result.smp.powerSemanticIpl();
        return result;
    }
};

const TestMmio = struct {
    ppu: *core.ppu.Ppu,
    smp: *core.smp.Smp,

    pub fn read(self: *TestMmio, address: u32, cpu_open_bus: u8, ppu_open_bus: u8) core.bus.MmioRead {
        const offset: u16 = @truncate(address);
        if (offset >= 0x2140 and offset <= 0x2143) {
            return .{ .handled = true, .value = self.smp.cpuReadPort(@truncate(offset - 0x2140)), .latch = .none };
        }
        return self.ppu.read(address, cpu_open_bus, ppu_open_bus);
    }

    pub fn write(self: *TestMmio, address: u32, value: u8, cpu_open_bus: u8, ppu_open_bus: u8) bool {
        const offset: u16 = @truncate(address);
        if (offset >= 0x2140 and offset <= 0x2143) {
            self.smp.cpuWritePort(@truncate(offset - 0x2140), value);
            return true;
        }
        return self.ppu.write(address, value, cpu_open_bus, ppu_open_bus);
    }

    pub fn onMasterTick(self: *TestMmio, clock: *const core.timing.Clock) void {
        self.ppu.onMasterTick(clock);
        _ = self.smp.advanceOscillator(clock.profile().master_hz, 1);
    }

    pub fn synchronizeClock(self: *const TestMmio, clock: *core.timing.Clock) void {
        self.ppu.synchronizeClock(clock);
    }
};

pub fn main(init: std.process.Init) void {
    run(init) catch |fault| {
        std.debug.print("R4SNES SA-1 reference harness FAILED: {s}\n", .{@errorName(fault)});
        std.process.exit(1);
    };
}

fn run(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const cwd = std.Io.Dir.cwd();
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const root = if (args.len >= 2) args[1] else "../../../ExFiles/Reference/SNES/Tests/Binaries/Generated/SA1-e824a9d";
    const output_root = if (args.len >= 3) args[2] else "../../../Temp/R4SNES-SA1";
    const case_filter: ?[]const u8 = if (args.len >= 4) args[3] else null;
    try cwd.createDirPath(io, output_root);

    var aggregate: u64 = 0xcbf29ce484222325;
    var executed_roms: usize = 0;
    var first_backup: ?Result = null;
    defer if (first_backup) |result| allocator.free(result.bwram);

    for (cases) |case| {
        if (case_filter) |filter| if (!std.mem.eql(u8, filter, case.name)) continue;
        const path = try std.fs.path.join(allocator, &.{ root, case.relative_path });
        defer allocator.free(path);
        const rom = try cwd.readFileAlloc(io, path, allocator, .limited(max_rom_bytes));
        defer allocator.free(rom);
        if (rom.len != case.bytes) return error.Sa1ReferenceSizeMismatch;
        try expectSha256(rom, case.sha256);
        executed_roms += 1;

        const result = try execute(allocator, io, cwd, output_root, rom, case, "cold", null);
        if (case.expected_status) |expected| {
            if (result.status != expected) {
                reportDivergence(case, result);
                allocator.free(result.bwram);
                return if (result.status == 0xfe) error.Sa1ReferenceHalted else error.Sa1ReferenceStatusMismatch;
            }
        }
        try verifyOracle(case, result);
        printResult(case, result, "cold");
        mixResult(&aggregate, case, result);

        if (case.backup_wait_pc != null) {
            if (result.backup_iram_bytes != 2 or result.backup_iram_bits != 1071 or
                result.backup_bwram_bytes != 0 or result.backup_bwram_bits != 1010 or
                result.backup_detected_size != 128 * 1024)
            {
                return error.Sa1BackupColdStateMismatch;
            }
            first_backup = result;
            const second = try execute(allocator, io, cwd, output_root, rom, case, "warm-bwram", result.bwram);
            defer allocator.free(second.bwram);
            if (second.backup_bwram_bytes != 256 or second.backup_bwram_bits != 2048 or
                second.backup_iram_bytes != 2 or second.backup_iram_bits != 1071 or
                second.backup_detected_size != 128 * 1024)
            {
                reportDivergence(case, second);
                return error.Sa1BackupPersistenceOracleMismatch;
            }
            try expectDigest(second.tilemap_sha256, "969090742d1c604bf4f2c6bba38349e0f8563b3a9ee80bf5c77b7847fe0d9537");
            try expectDigest(second.wram_sha256, "ee9206d1ddf4862f380bfbd4eb738c27689d79d2e841b6b8bf6ce49940dfab5b");
            if (second.sa1_digest != 0x5f8f2ecfc77e3426) return error.Sa1BackupWarmStateMismatch;
            printResult(case, second, "warm-bwram");
            mixResult(&aggregate, case, second);
        } else {
            allocator.free(result.bwram);
        }
    }

    if (case_filter == null) {
        if (executed_roms != cases.len) return error.Sa1ReferenceCorpusIncomplete;
        if (aggregate != expected_aggregate_digest) return error.Sa1AggregateOracleMismatch;
    }
    std.debug.print("R4SNES SA-1 reference harness OK: ROMs={d} self-tests=2 utilities=4 two-starts=1 digest={x:0>16} artifacts={s}\n", .{ executed_roms, aggregate, output_root });
}

fn execute(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: std.Io.Dir,
    output_root: []const u8,
    rom: []const u8,
    case: Case,
    phase: []const u8,
    persisted_bwram: ?[]const u8,
) !Result {
    var cart = try core.cartridge.Cartridge.parse(allocator, rom);
    defer cart.deinit();
    if (persisted_bwram) |saved| {
        if (saved.len != cart.sram_storage.len) return error.Sa1BackupGeometryChanged;
        @memcpy(cart.sram_storage, saved);
    }
    var machine = Machine.init(cart.board.region);
    var mmio = TestMmio{ .ppu = &machine.ppu, .smp = &machine.smp };
    var port = core.scpu.TimedPortWithDevice(*TestMmio){
        .bus = &machine.bus,
        .cartridge = &cart,
        .scpu = &machine.scpu,
        .clock = &machine.clock,
        .controllers = &machine.ports,
        .cpu = &machine.cpu,
        .device = &mmio,
    };

    var instructions: usize = 0;
    var completion: u8 = 0;
    while (instructions < instruction_limit and machine.clock.master_cycles < master_clock_limit) : (instructions += 1) {
        machine.cpu.setIrqLine(machine.scpu.irq_flag or cart.sa1CpuIrqPending());
        if (port.cpuReady()) {
            _ = machine.cpu.step(&port) catch |fault| {
                std.debug.print("SA-1 reference {s}: CPU fault={s} at {x:0>2}:{x:0>4}\n", .{ case.name, @errorName(fault), machine.cpu.pb, machine.cpu.pc });
                return error.Sa1ReferenceCpuFault;
            };
        } else {
            const dma = port.serviceDmaStep();
            if (!dma.progressed) return error.Sa1ReferenceDmaStalled;
        }
        if (cart.runSa1UntilMasterClock(machine.clock.master_cycles, 8192)) |sa1_result| {
            if (sa1_result.state == .fault) {
                std.debug.print("SA-1 reference {s}: SA-1 fault={s} SCPU={x:0>2}:{x:0>4} SA1={x:0>2}:{x:0>4}\n", .{ case.name, @errorName(sa1_result.fault.?), machine.cpu.pb, machine.cpu.pc, cart.sa1_device.?.cpu.pb, cart.sa1_device.?.cpu.pc });
                return error.Sa1ReferenceCoprocessorFault;
            }
        }

        completion = machine.bus.wram[0];
        if (case.expected_status != null and completion != 0) break;
        if (case.backup_wait_pc) |wait_pc| {
            if (machine.cpu.waiting and machine.cpu.pb == 0 and machine.cpu.pc == wait_pc) {
                completion = 1;
                break;
            }
        }
    }
    if (completion == 0) {
        reportTimeout(case, &machine, &cart, instructions);
        return error.Sa1ReferenceTimeout;
    }
    try writeArtifacts(allocator, io, cwd, output_root, case, phase, &machine);

    var tilemap_sha256: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(machine.bus.wram[case.tilemap_address .. case.tilemap_address + 0x800], &tilemap_sha256, .{});
    var wram_sha256: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&machine.bus.wram, &wram_sha256, .{});
    const saved = try allocator.dupe(u8, cart.sram_storage);
    const device = if (cart.sa1_device) |*sa1_device| sa1_device else null;
    var result = Result{
        .status = completion,
        .instructions = instructions + 1,
        .master_cycles = machine.clock.master_cycles,
        .cpu_pc = machine.cpu.pc,
        .cpu_pb = machine.cpu.pb,
        .tilemap_sha256 = tilemap_sha256,
        .wram_sha256 = wram_sha256,
        .sa1_digest = if (device) |sa1_device| sa1_device.stateDigest(cart.sram_storage) else 0,
        .defined_register_digest = if (device) |sa1_device| definedRegisterDigest(case.name, &sa1_device.iram) else 0,
        .bwram = saved,
        .iram = if (device) |sa1_device| sa1_device.iram else .{0} ** core.sa1.internal_ram_bytes,
        .diagnostic = .{0} ** 0x20,
    };
    @memcpy(&result.diagnostic, machine.bus.wram[0x30..0x50]);
    result.first_failure_id = machine.bus.wram[0x31];
    const failure_index: usize = result.first_failure_id;
    result.first_failure_result = machine.bus.wram[0x200 + failure_index];
    result.first_failure_actual = machine.bus.wram[0x300 + failure_index];
    result.first_failure_expected = machine.bus.wram[0x400 + failure_index];
    if (case.backup_wait_pc != null) {
        result.backup_iram_bytes = read16(&machine.bus.wram, 1);
        result.backup_iram_bits = read16(&machine.bus.wram, 3);
        result.backup_bwram_bytes = read16(&machine.bus.wram, 5);
        result.backup_bwram_bits = read16(&machine.bus.wram, 7);
        result.backup_detected_size = @as(u32, machine.bus.wram[9]) |
            (@as(u32, machine.bus.wram[10]) << 8) | (@as(u32, machine.bus.wram[11]) << 16);
    }
    return result;
}

fn writeArtifacts(
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: std.Io.Dir,
    output_root: []const u8,
    case: Case,
    phase: []const u8,
    machine: *const Machine,
) !void {
    const stem = try std.fmt.allocPrint(allocator, "{s}-{s}", .{ case.name, phase });
    defer allocator.free(stem);
    const tilemap_name = try std.fmt.allocPrint(allocator, "{s}.tilemap.bin", .{stem});
    defer allocator.free(tilemap_name);
    const tilemap_path = try std.fs.path.join(allocator, &.{ output_root, tilemap_name });
    defer allocator.free(tilemap_path);
    try cwd.writeFile(io, .{
        .sub_path = tilemap_path,
        .data = machine.bus.wram[case.tilemap_address .. case.tilemap_address + 0x800],
    });

    const frame = machine.ppu.frameInfo();
    const pixel_count = @as(usize, frame.width) * frame.height;
    const pixels = try allocator.alloc(u32, pixel_count);
    defer allocator.free(pixels);
    _ = try machine.ppu.copyFrame(pixels);

    var header_buffer: [64]u8 = undefined;
    const header = try std.fmt.bufPrint(&header_buffer, "P6\n{d} {d}\n255\n", .{ frame.width, frame.height });
    const ppm = try allocator.alloc(u8, header.len + pixel_count * 3);
    defer allocator.free(ppm);
    @memcpy(ppm[0..header.len], header);
    for (pixels, 0..) |pixel, index| {
        const offset = header.len + index * 3;
        ppm[offset] = @truncate(pixel >> 16);
        ppm[offset + 1] = @truncate(pixel >> 8);
        ppm[offset + 2] = @truncate(pixel);
    }
    const image_name = try std.fmt.allocPrint(allocator, "{s}.ppm", .{stem});
    defer allocator.free(image_name);
    const image_path = try std.fs.path.join(allocator, &.{ output_root, image_name });
    defer allocator.free(image_path);
    try cwd.writeFile(io, .{ .sub_path = image_path, .data = ppm });
}

fn reportTimeout(case: Case, machine: *const Machine, cart: *const core.cartridge.Cartridge, instructions: usize) void {
    const sa1_pc: u16 = if (cart.sa1_device) |device| device.cpu.pc else 0;
    const sa1_pb: u8 = if (cart.sa1_device) |device| device.cpu.pb else 0;
    const sa1_state = if (cart.sa1_device) |device| if (device.reset_hold) "reset" else if (device.ready_hold) "ready" else if (device.cpu.stopped) "stopped" else if (device.cpu.waiting) "waiting" else "running" else "absent";
    std.debug.print("SA-1 reference {s}: TIMEOUT instructions={d} clocks={d} SCPU={x:0>2}:{x:0>4} wait={} stop={} DMA={} status={x:0>2} SA1={x:0>2}:{x:0>4} state={s}\n", .{ case.name, instructions, machine.clock.master_cycles, machine.cpu.pb, machine.cpu.pc, machine.cpu.waiting, machine.cpu.stopped, !machine.scpu.cpuMayRun(), machine.bus.wram[0], sa1_pb, sa1_pc, sa1_state });
}

fn reportDivergence(case: Case, result: Result) void {
    std.debug.print("SA-1 reference {s}: DIVERGENCE status={x:0>2} instructions={d} clocks={d} SCPU={x:0>2}:{x:0>4} tilemap={x} wram={x} first-id={d} result={x:0>2} actual={x:0>2} expected={x:0>2} diagnostic={x}\n", .{ case.name, result.status, result.instructions, result.master_cycles, result.cpu_pb, result.cpu_pc, result.tilemap_sha256, result.wram_sha256, result.first_failure_id, result.first_failure_result, result.first_failure_actual, result.first_failure_expected, result.diagnostic });
}

fn printResult(case: Case, result: Result, phase: []const u8) void {
    std.debug.print("SA-1 {s}/{s}: status={x:0>2} instructions={d} clocks={d} tilemap={x} wram={x} sa1={x:0>16} defined-registers={x:0>16}", .{ case.name, phase, result.status, result.instructions, result.master_cycles, result.tilemap_sha256, result.wram_sha256, result.sa1_digest, result.defined_register_digest });
    if (case.backup_wait_pc != null) {
        std.debug.print(" iram={d}/{d} bwram={d}/{d} detected={d}", .{ result.backup_iram_bytes, result.backup_iram_bits, result.backup_bwram_bytes, result.backup_bwram_bits, result.backup_detected_size });
    }
    std.debug.print("\n", .{});
}

fn mixResult(aggregate: *u64, case: Case, result: Result) void {
    for (case.name) |value| digestByte(aggregate, value);
    digestByte(aggregate, result.status);
    if (case.expected_defined_register_digest != null or std.mem.eql(u8, case.name, "SA1OpenbusUtility")) {
        inline for (0..8) |index| digestByte(aggregate, @truncate(result.defined_register_digest >> @intCast(index * 8)));
    } else {
        for (result.tilemap_sha256) |value| digestByte(aggregate, value);
        for (result.wram_sha256) |value| digestByte(aggregate, value);
        inline for (0..8) |index| digestByte(aggregate, @truncate(result.sa1_digest >> @intCast(index * 8)));
    }
}

fn verifyOracle(case: Case, result: Result) !void {
    if (case.expected_tilemap_sha256) |expected| try expectDigest(result.tilemap_sha256, expected);
    if (case.expected_wram_sha256) |expected| try expectDigest(result.wram_sha256, expected);
    if (case.expected_sa1_digest) |expected| if (result.sa1_digest != expected) return error.Sa1StateOracleMismatch;
    if (case.expected_defined_register_digest) |expected| {
        if (result.defined_register_digest != expected) return error.Sa1DefinedRegisterOracleMismatch;
    }
}

fn expectDigest(actual: [32]u8, expected_hex: []const u8) !void {
    var expected: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected, expected_hex);
    if (!std.mem.eql(u8, &actual, &expected)) return error.Sa1ResultDigestMismatch;
}

fn expectSha256(bytes: []const u8, expected_hex: []const u8) !void {
    var actual: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &actual, .{});
    var expected: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected, expected_hex);
    if (!std.mem.eql(u8, &actual, &expected)) return error.Sa1ReferenceDigestMismatch;
}

fn definedRegisterDigest(name: []const u8, iram: *const [core.sa1.internal_ram_bytes]u8) u64 {
    var digest: u64 = 0xcbf29ce484222325;
    if (std.mem.eql(u8, name, "SA1ReadRegisterDumpUtility")) {
        // CPU-side SFR and SA-1-side SFR/CFR/H/V counters are specified. The
        // arithmetic/VBR power values, nonexistent VC and undefined register
        // reads are intentionally excluded as electrically indeterminate.
        for (iram[0x00..0x02]) |value| digestByte(&digest, value);
        for (iram[0x40..0x4c]) |value| digestByte(&digest, value);
        return digest;
    }
    if (std.mem.eql(u8, name, "SA1OpenbusUtility")) {
        // Each row records an address-derived probe and a fixed-bus probe for
        // both processors. Only the deliberately forced AA/BB columns are a
        // portable oracle; floating address-derived values stay diagnostic.
        for (0..18) |row| {
            digestByte(&digest, iram[0x200 + row * 4 + 1]);
            digestByte(&digest, iram[0x200 + row * 4 + 3]);
        }
        return digest;
    }
    if (std.mem.eql(u8, name, "SA1RebootTest")) {
        const blocks = [_]usize{ 0x40, 0x60, 0x80, 0xa0 };
        for (blocks, 0..) |base, block_index| {
            for (0..0x18) |offset| {
                const stack_low = offset == 0x06;
                const reset_indeterminate = block_index == 0 and offset >= 0x10 and offset <= 0x15;
                if (!stack_low and !reset_indeterminate) digestByte(&digest, iram[base + offset]);
            }
        }
        return digest;
    }
    for (iram) |value| digestByte(&digest, value);
    return digest;
}

fn read16(bytes: []const u8, address: usize) u16 {
    return @as(u16, bytes[address]) | (@as(u16, bytes[address + 1]) << 8);
}

fn digestByte(digest: *u64, value: u8) void {
    digest.* ^= value;
    digest.* *%= 0x100000001b3;
}
