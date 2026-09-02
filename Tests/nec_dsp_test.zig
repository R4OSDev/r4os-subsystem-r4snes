const std = @import("std");
const core = @import("core");

const ndsp = core.nec_dsp;

test "NEC-DSP firmware contract binds names sizes revisions and known digests" {
    try std.testing.expectEqual(@as(usize, 0x2000), ndsp.firmware_bytes);
    try std.testing.expectEqual(@as(usize, 0x1800), ndsp.program_bytes);
    try std.testing.expectEqual(@as(usize, 0x0800), ndsp.data_bytes);
    const revisions = [_]ndsp.Revision{ .dsp1, .dsp1a, .dsp1b, .dsp2, .dsp3, .dsp4 };
    const names = [_][]const u8{ "DSP1.ROM", "DSP1A.ROM", "DSP1B.ROM", "DSP2.ROM", "DSP3.ROM", "DSP4.ROM" };
    for (revisions, names) |revision, name| {
        try std.testing.expectEqualStrings(name, revision.fileName());
        try std.testing.expect(std.mem.endsWith(u8, revision.firmwarePath(), name));
        try std.testing.expectEqual(@as(usize, 32), revision.knownDigest().len);
    }
    try std.testing.expectEqualSlices(u8, &ndsp.Revision.dsp1.knownDigest(), &ndsp.Revision.dsp1a.knownDigest());
    try std.testing.expect(!std.mem.eql(u8, &ndsp.Revision.dsp1a.knownDigest(), &ndsp.Revision.dsp1b.knownDigest()));

    var open = makeFirmware(0x11);
    try std.testing.expectError(error.InvalidNecDspFirmwareDigest, ndsp.validateFirmware(.dsp1b, &open, .known_only));
    try std.testing.expectError(error.InvalidNecDspFirmwareSize, ndsp.validateFirmware(.dsp1b, open[0 .. open.len - 1], .allow_open_test));
    _ = try ndsp.validateFirmware(.dsp1b, &open, .allow_open_test);
}

test "uPD7725 decodes every instruction class source destination ALU and pointer mode" {
    var firmware = makeFirmware(0x22);
    var device = try makeDevice(.dsp1b, .lo_rom, 1024 * 1024, 0, &firmware);

    for (0..16) |raw_source| {
        device.trb = 0x1000;
        device.a = 0x1001;
        device.b = 0x1002;
        device.tr = 0x1003;
        device.dp = 0x24;
        device.rp = 0x35;
        device.data_rom[0x35] = 0x1006;
        device.flags_a.sign1 = true;
        device.dr = 0x1009;
        device.sr = 0x2345;
        device.serial_input = 0x100b;
        device.k = 0x100d;
        device.l = 0x100e;
        device.data_ram[0x24] = 0x100f;
        const expected = [_]u16{
            0x1000, 0x1001, 0x1002, 0x1003, 0x0024, 0x0035, 0x1006, 0x7fff,
            0x1009, 0x1009, 0x2345, 0x100b, 0x100b, 0x100d, 0x100e, 0x100f,
        };
        try std.testing.expectEqual(ndsp.OpcodeClass.operation, device.executeOpcode(operation(0, 0, false, 0, 0, false, @intCast(raw_source), 3)));
        try std.testing.expectEqual(expected[raw_source], device.tr);
        if (raw_source == 8) try std.testing.expect(device.requestForMaster());
    }

    for (0..16) |raw_destination| {
        var isolated = try makeDevice(.dsp1b, .lo_rom, 1024 * 1024, 0, &firmware);
        isolated.rp = 7;
        isolated.dp = 8;
        isolated.data_rom[7] = 0x7654;
        isolated.data_ram[0x48] = 0x4567;
        try std.testing.expectEqual(ndsp.OpcodeClass.immediate_load, isolated.executeOpcode(loadImmediate(0x3210, @intCast(raw_destination))));
        switch (raw_destination) {
            0 => {},
            1 => try std.testing.expectEqual(@as(u16, 0x3210), isolated.a),
            2 => try std.testing.expectEqual(@as(u16, 0x3210), isolated.b),
            3 => try std.testing.expectEqual(@as(u16, 0x3210), isolated.tr),
            4 => try std.testing.expectEqual(@as(u16, 0x10), isolated.dp),
            5 => try std.testing.expectEqual(@as(u16, 0x210), isolated.rp),
            6 => {
                try std.testing.expectEqual(@as(u16, 0x3210), isolated.dr);
                try std.testing.expect(isolated.requestForMaster());
            },
            7 => try std.testing.expectEqual(@as(u16, 0x2200), isolated.sr),
            8, 9 => try std.testing.expectEqual(@as(u16, 0x3210), isolated.serial_output),
            10 => try std.testing.expectEqual(@as(u16, 0x3210), isolated.k),
            11 => {
                try std.testing.expectEqual(@as(u16, 0x3210), isolated.k);
                try std.testing.expectEqual(@as(u16, 0x7654), isolated.l);
            },
            12 => {
                try std.testing.expectEqual(@as(u16, 0x3210), isolated.l);
                try std.testing.expectEqual(@as(u16, 0x4567), isolated.k);
            },
            13 => try std.testing.expectEqual(@as(u16, 0x3210), isolated.l),
            14 => try std.testing.expectEqual(@as(u16, 0x3210), isolated.trb),
            15 => try std.testing.expectEqual(@as(u16, 0x3210), isolated.data_ram[8]),
            else => unreachable,
        }
    }

    const expected_results = [_]u16{
        0x0000, 0x7fd7, 0x1301, 0x6cd6, 0x6c2a, 0x92d8, 0x6c29, 0x92d9,
        0x7f80, 0x7f82, 0x807e, 0x3fc0, 0xff03, 0xfe07, 0xf81f, 0x817f,
    };
    for (1..16) |raw_alu| {
        var isolated = try makeDevice(.dsp1b, .lo_rom, 1024 * 1024, 0, &firmware);
        isolated.a = 0x7f81;
        isolated.trb = 0x1357;
        isolated.flags_b.carry = true;
        _ = isolated.executeOpcode(operation(1, @intCast(raw_alu), false, 0, 0, false, 0, 0));
        try std.testing.expectEqual(expected_results[raw_alu], isolated.a);
    }

    device.dp = 0x2f;
    device.rp = 0;
    _ = device.executeOpcode(operation(1, 0, false, 1, 3, true, 0, 0));
    try std.testing.expectEqual(@as(u16, 0x10), device.dp);
    try std.testing.expectEqual(@as(u16, 0x03ff), device.rp);
    device.dp = 0x20;
    _ = device.executeOpcode(operation(1, 0, false, 2, 0, false, 0, 0));
    try std.testing.expectEqual(@as(u16, 0x2f), device.dp);
    device.dp = 0x2a;
    _ = device.executeOpcode(operation(1, 0, false, 3, 0, false, 0, 0));
    try std.testing.expectEqual(@as(u16, 0x20), device.dp);
}

test "uPD7725 branches calls returns multiplier pipeline and reserved encodings are bounded" {
    var firmware = makeFirmware(0x33);
    var device = try makeDevice(.dsp1b, .lo_rom, 1024 * 1024, 0, &firmware);
    const branch_pairs = [_]struct { clear: u9, set: u9 }{
        .{ .clear = 0x080, .set = 0x082 },
        .{ .clear = 0x084, .set = 0x086 },
        .{ .clear = 0x088, .set = 0x08a },
        .{ .clear = 0x08c, .set = 0x08e },
        .{ .clear = 0x090, .set = 0x092 },
        .{ .clear = 0x094, .set = 0x096 },
        .{ .clear = 0x098, .set = 0x09a },
        .{ .clear = 0x09c, .set = 0x09e },
        .{ .clear = 0x0a0, .set = 0x0a2 },
        .{ .clear = 0x0a4, .set = 0x0a6 },
        .{ .clear = 0x0a8, .set = 0x0aa },
        .{ .clear = 0x0ac, .set = 0x0ae },
    };
    for (branch_pairs) |pair| {
        device.pc = 0x20;
        setAllFlags(&device, false);
        _ = device.executeOpcode(jump(pair.clear, 0x123));
        try std.testing.expectEqual(@as(u16, 0x123), device.pc);
        device.pc = 0x20;
        setAllFlags(&device, true);
        _ = device.executeOpcode(jump(pair.set, 0x124));
        try std.testing.expectEqual(@as(u16, 0x124), device.pc);
    }

    const dp_cases = [_]struct { branch: u9, dp: u16, taken: bool }{
        .{ .branch = 0x0b0, .dp = 0x20, .taken = true },
        .{ .branch = 0x0b1, .dp = 0x21, .taken = true },
        .{ .branch = 0x0b2, .dp = 0x2f, .taken = true },
        .{ .branch = 0x0b3, .dp = 0x2e, .taken = true },
    };
    for (dp_cases) |case| {
        device.pc = 0x20;
        device.dp = case.dp;
        _ = device.executeOpcode(jump(case.branch, 0x155));
        try std.testing.expectEqual(if (case.taken) @as(u16, 0x155) else @as(u16, 0x20), device.pc);
    }
    device.serial_input_ack = false;
    device.serial_output_ack = true;
    device.pc = 0;
    _ = device.executeOpcode(jump(0x0b4, 0x101));
    try std.testing.expectEqual(@as(u16, 0x101), device.pc);
    _ = device.executeOpcode(jump(0x0ba, 0x102));
    try std.testing.expectEqual(@as(u16, 0x102), device.pc);

    device.pc = 0x44;
    _ = device.executeOpcode(jump(0x140, 0x222));
    try std.testing.expectEqual(@as(u16, 0x222), device.pc);
    try std.testing.expectEqual(@as(u16, 0x44), device.stack[0]);
    try std.testing.expectEqual(@as(u8, 1), device.sp);
    _ = device.executeOpcode(operationReturn(0, 0, false, 0, 0, false, 0, 0));
    try std.testing.expectEqual(@as(u16, 0x44), device.pc);
    try std.testing.expectEqual(@as(u8, 0), device.sp);

    device.pc = 0x777;
    const reserved_before = device.reserved_branches;
    _ = device.executeOpcode(jump(0x1ff, 0x001));
    try std.testing.expectEqual(@as(u16, 0x777), device.pc);
    try std.testing.expectEqual(reserved_before + 1, device.reserved_branches);

    device.k = @bitCast(@as(i16, -16384));
    device.l = @bitCast(@as(i16, 8192));
    device.firmware_installed = true;
    device.program_rom[0] = loadImmediate(0, 0);
    device.pc = 0;
    device.step();
    try std.testing.expectEqual(@as(u16, @bitCast(@as(i16, -4096))), device.m);
    try std.testing.expectEqual(@as(u16, 0), device.n);
    try std.testing.expectEqual(@as(u64, 1), device.cycles);
}

test "NEC-DSP host handshake reset slices and close are deterministic" {
    var firmware = makeHandshakeFirmware();
    var one = try makeDevice(.dsp1b, .lo_rom, 1024 * 1024, 0, &firmware);
    const first_wait = one.runSlice(16);
    try std.testing.expectEqual(ndsp.RunState.waiting_host, first_wait.state);
    try std.testing.expectEqual(@as(usize, 2), first_wait.executed);
    try std.testing.expect(one.requestForMaster());
    try std.testing.expectEqual(@as(u8, 0x80), one.readStatus());
    try std.testing.expectEqual(@as(?u8, 0x34), one.readCpu(0x308000, 0));
    try std.testing.expect(one.requestForMaster());
    try std.testing.expectEqual(@as(u8, 0x90), one.readStatus());
    try std.testing.expectEqual(@as(?u8, 0x12), one.readCpu(0x308000, 0));
    try std.testing.expect(!one.requestForMaster());
    const second_wait = one.runSlice(16);
    try std.testing.expectEqual(ndsp.RunState.waiting_host, second_wait.state);
    try std.testing.expectEqual(@as(?u8, 0x78), one.readCpu(0x308000, 0));
    try std.testing.expectEqual(@as(?u8, 0x56), one.readCpu(0x308000, 0));

    one.sr = 0x8400;
    one.dr = 0xab00;
    try std.testing.expect(one.writeCpu(0x308000, 0x5a));
    try std.testing.expectEqual(@as(u16, 0xab5a), one.dr);
    try std.testing.expect(!one.requestForMaster());
    try std.testing.expectEqual(@as(u8, 0x04), one.readStatus());
    const sr_before = one.sr;
    try std.testing.expect(one.writeCpu(0x30c000, 0xff));
    try std.testing.expectEqual(sr_before, one.sr);
    try std.testing.expectEqual(@as(u64, 1), one.status_writes);

    one.data_ram[3] = 0xbeef;
    one.pc = 0x456;
    one.reset();
    try std.testing.expectEqual(@as(u16, 0), one.pc);
    try std.testing.expectEqual(@as(u16, 0), one.data_ram[3]);
    try std.testing.expectEqual(@as(u64, 1), one.resets);
    try std.testing.expect(one.firmware_installed);

    var linear_firmware = makeLinearFirmware();
    var linear = try makeDevice(.dsp1b, .lo_rom, 1024 * 1024, 0, &linear_firmware);
    var partitioned = try makeDevice(.dsp1b, .lo_rom, 1024 * 1024, 0, &linear_firmware);
    _ = linear.runSlice(1000);
    var remaining: usize = 1000;
    var amount: usize = 1;
    while (remaining != 0) {
        const slice = @min(amount, remaining);
        _ = partitioned.runSlice(slice);
        remaining -= slice;
        amount = (amount * 7) % 31 + 1;
    }
    try std.testing.expectEqual(linear.stateDigest(), partitioned.stateDigest());

    one.close();
    one.close();
    try std.testing.expect(one.closed);
    try std.testing.expect(!one.firmware_installed);
    try std.testing.expectEqual(@as(u24, 0), one.program_rom[0]);
    try std.testing.expectEqual(@as(u16, 0), one.data_rom[0]);
    try std.testing.expectEqualSlices(u8, &([_]u8{0} ** 32), &one.firmware_digest);
}

test "all DSP boards parse with explicit firmware and expose exact canonical windows" {
    const allocator = std.testing.allocator;
    var firmware = makeHandshakeFirmware();
    const cases = [_]struct {
        revision: ndsp.Revision,
        map_mode: u8,
        rom_type: u8,
        licensee: u8,
        size: usize,
        ram_code: u8,
        data_address: u32,
        status_address: u32,
    }{
        .{ .revision = .dsp1, .map_mode = 0x20, .rom_type = 0x03, .licensee = 0x33, .size = 1024 * 1024, .ram_code = 0, .data_address = 0x308000, .status_address = 0x30c000 },
        .{ .revision = .dsp1a, .map_mode = 0x20, .rom_type = 0x05, .licensee = 0x33, .size = 1024 * 1024, .ram_code = 3, .data_address = 0x208000, .status_address = 0x20c000 },
        .{ .revision = .dsp1b, .map_mode = 0x21, .rom_type = 0x03, .licensee = 0x33, .size = 1024 * 1024, .ram_code = 0, .data_address = 0x006000, .status_address = 0x007000 },
        .{ .revision = .dsp2, .map_mode = 0x20, .rom_type = 0x05, .licensee = 0x33, .size = 1024 * 1024, .ram_code = 3, .data_address = 0x206000, .status_address = 0x20c000 },
        .{ .revision = .dsp3, .map_mode = 0x30, .rom_type = 0x05, .licensee = 0xb2, .size = 1024 * 1024, .ram_code = 0, .data_address = 0x208000, .status_address = 0x20c000 },
        .{ .revision = .dsp4, .map_mode = 0x30, .rom_type = 0x03, .licensee = 0x33, .size = 1024 * 1024, .ram_code = 0, .data_address = 0x308000, .status_address = 0x30c000 },
    };
    for (cases) |case| {
        const image = try makeImage(allocator, case.size, case.map_mode, case.rom_type, case.ram_code, case.licensee, false);
        defer allocator.free(image);
        var cart = try core.cartridge.Cartridge.parseWithOptions(allocator, image, .{
            .nec_dsp_revision = case.revision,
            .nec_dsp_firmware = &firmware,
            .nec_dsp_firmware_validation = .allow_open_test,
        });
        defer cart.deinit();
        try std.testing.expect(cart.board.readyForExecution());
        try std.testing.expectEqual(core.board.Enhancement.dsp1_family, cart.board.capability.enhancement);
        try std.testing.expectEqual(case.revision, cart.nec_dsp_device.?.revision);
        try std.testing.expect(cart.nec_dsp_device.?.readCpu(case.data_address, 0) != null);
        try std.testing.expect(cart.nec_dsp_device.?.readCpu(case.status_address, 0) != null);
        try std.testing.expect(cart.nec_dsp_device.?.readCpu(0x400000, 0) == null);
    }

    const large = try makeImage(allocator, 2 * 1024 * 1024, 0x20, 0x03, 0, 0x33, false);
    defer allocator.free(large);
    var large_cart = try core.cartridge.Cartridge.parseWithOptions(allocator, large, .{
        .nec_dsp_revision = .dsp1b,
        .nec_dsp_firmware = &firmware,
        .nec_dsp_firmware_validation = .allow_open_test,
    });
    defer large_cart.deinit();
    try std.testing.expect(large_cart.nec_dsp_device.?.readCpu(0x600000, 0) != null);
    try std.testing.expect(large_cart.nec_dsp_device.?.readCpu(0x604000, 0) != null);
}

test "separate appended and copier-header firmware normalize to one cartridge identity" {
    const allocator = std.testing.allocator;
    var firmware = makeHandshakeFirmware();
    const plain = try makeImage(allocator, 1024 * 1024, 0x20, 0x03, 0, 0x33, false);
    defer allocator.free(plain);
    const appended = try allocator.alloc(u8, plain.len + firmware.len);
    defer allocator.free(appended);
    @memcpy(appended[0..plain.len], plain);
    @memcpy(appended[plain.len..], &firmware);

    var separate = try core.cartridge.Cartridge.parseWithOptions(allocator, plain, .{
        .nec_dsp_revision = .dsp1b,
        .nec_dsp_firmware = &firmware,
        .nec_dsp_firmware_validation = .allow_open_test,
    });
    defer separate.deinit();
    var joined = try core.cartridge.Cartridge.parseWithOptions(allocator, appended, .{
        .nec_dsp_revision = .dsp1b,
        .nec_dsp_firmware_validation = .allow_open_test,
    });
    defer joined.deinit();
    try std.testing.expect(!separate.had_appended_firmware);
    try std.testing.expect(joined.had_appended_firmware);
    try std.testing.expectEqualSlices(u8, separate.rom(), joined.rom());
    try std.testing.expectEqualSlices(u8, &separate.identity, &joined.identity);
    try std.testing.expectEqual(separate.nec_dsp_device.?.stateDigest(), joined.nec_dsp_device.?.stateDigest());

    const headed = try makeImage(allocator, 1024 * 1024, 0x20, 0x03, 0, 0x33, true);
    defer allocator.free(headed);
    const headed_appended = try allocator.alloc(u8, headed.len + firmware.len);
    defer allocator.free(headed_appended);
    @memcpy(headed_appended[0..headed.len], headed);
    @memcpy(headed_appended[headed.len..], &firmware);
    var copier_joined = try core.cartridge.Cartridge.parseWithOptions(allocator, headed_appended, .{
        .nec_dsp_revision = .dsp1b,
        .nec_dsp_firmware_validation = .allow_open_test,
    });
    defer copier_joined.deinit();
    try std.testing.expect(copier_joined.had_copier_header);
    try std.testing.expect(copier_joined.had_appended_firmware);
    try std.testing.expectEqualSlices(u8, &separate.identity, &copier_joined.identity);

    try std.testing.expectError(error.MissingNecDspFirmware, core.cartridge.Cartridge.parse(allocator, plain));
    try std.testing.expectError(error.AmbiguousNecDspFirmwareSource, core.cartridge.Cartridge.parseWithOptions(allocator, appended, .{
        .nec_dsp_firmware = &firmware,
        .nec_dsp_firmware_validation = .allow_open_test,
    }));
    try std.testing.expectError(error.ContradictoryNecDspBoard, core.cartridge.Cartridge.parseWithOptions(allocator, plain, .{
        .nec_dsp_revision = .dsp4,
        .nec_dsp_firmware = &firmware,
        .nec_dsp_firmware_validation = .allow_open_test,
    }));

    const normal = try makeImage(allocator, 1024 * 1024, 0x20, 0x00, 0, 0x33, false);
    defer allocator.free(normal);
    const false_append = try allocator.alloc(u8, normal.len + firmware.len);
    defer allocator.free(false_append);
    @memcpy(false_append[0..normal.len], normal);
    @memcpy(false_append[normal.len..], &firmware);
    try std.testing.expectError(error.UnexpectedAppendedFirmware, core.cartridge.Cartridge.parseWithOptions(allocator, false_append, .{
        .nec_dsp_firmware_validation = .allow_open_test,
    }));
}

test "NEC-DSP bus accesses and multiple cartridges remain instance-isolated" {
    const allocator = std.testing.allocator;
    var firmware = makeHandshakeFirmware();
    const image = try makeImage(allocator, 1024 * 1024, 0x20, 0x03, 0, 0x33, false);
    defer allocator.free(image);
    var first = try core.cartridge.Cartridge.parseWithOptions(allocator, image, .{
        .nec_dsp_revision = .dsp1b,
        .nec_dsp_firmware = &firmware,
        .nec_dsp_firmware_validation = .allow_open_test,
    });
    defer first.deinit();
    var second = try core.cartridge.Cartridge.parseWithOptions(allocator, image, .{
        .nec_dsp_revision = .dsp1b,
        .nec_dsp_firmware = &firmware,
        .nec_dsp_firmware_validation = .allow_open_test,
    });
    defer second.deinit();
    var bus = core.bus.Bus{};
    var mmio = core.bus.NullMmio{};
    const second_before = second.nec_dsp_device.?.stateDigest();
    _ = first.runNecDspSlice(16).?;
    const status = bus.read(&first, &mmio, 0x30c000);
    try std.testing.expectEqual(core.bus.AccessClass.cartridge_chip, status.class);
    try std.testing.expectEqual(@as(u8, ndsp.access_master_cycles), status.master_cycles);
    const low = bus.read(&first, &mmio, 0x308000);
    const high = bus.read(&first, &mmio, 0x308000);
    try std.testing.expectEqual(@as(u8, 0x34), low.value);
    try std.testing.expectEqual(@as(u8, 0x12), high.value);
    try std.testing.expectEqual(second_before, second.nec_dsp_device.?.stateDigest());

    _ = bus.write(&first, &mmio, 0x308000, 0xaa);
    _ = bus.write(&first, &mmio, 0x308000, 0xbb);
    try std.testing.expectEqual(@as(u16, 0xbbaa), first.nec_dsp_device.?.dr);
    try std.testing.expectEqual(@as(u16, 0), second.nec_dsp_device.?.dr);
}

fn makeDevice(
    revision: ndsp.Revision,
    mapping: core.board.Mapping,
    rom_size: usize,
    ram_size: usize,
    firmware: []const u8,
) !ndsp.Device {
    return ndsp.Device.init(revision, mapping, rom_size, ram_size, firmware, .allow_open_test, .open_test);
}

fn operation(p: u2, alu: u4, select_b: bool, dp_low: u2, dp_high: u4, rp_dec: bool, source: u4, destination: u4) u24 {
    return (@as(u24, p) << 20) |
        (@as(u24, alu) << 16) |
        (@as(u24, @intFromBool(select_b)) << 15) |
        (@as(u24, dp_low) << 13) |
        (@as(u24, dp_high) << 9) |
        (@as(u24, @intFromBool(rp_dec)) << 8) |
        (@as(u24, source) << 4) |
        destination;
}

fn operationReturn(p: u2, alu: u4, select_b: bool, dp_low: u2, dp_high: u4, rp_dec: bool, source: u4, destination: u4) u24 {
    return 0x400000 | operation(p, alu, select_b, dp_low, dp_high, rp_dec, source, destination);
}

fn loadImmediate(value: u16, destination: u4) u24 {
    return 0xc00000 | (@as(u24, value) << 6) | destination;
}

fn jump(branch: u9, target: u11) u24 {
    return 0x800000 | (@as(u24, branch) << 13) | (@as(u24, target) << 2);
}

fn setAllFlags(device: *ndsp.Device, value: bool) void {
    device.flags_a = .{
        .overflow0 = value,
        .overflow1 = value,
        .zero = value,
        .carry = value,
        .sign0 = value,
        .sign1 = value,
    };
    device.flags_b = device.flags_a;
}

fn makeFirmware(signature: u8) [ndsp.firmware_bytes]u8 {
    var result = [_]u8{0} ** ndsp.firmware_bytes;
    for (0..ndsp.data_words) |index| {
        const value: u16 = @truncate(index *% 257 +% signature);
        const offset = ndsp.program_bytes + index * 2;
        result[offset] = @truncate(value);
        result[offset + 1] = @truncate(value >> 8);
    }
    return result;
}

fn makeHandshakeFirmware() [ndsp.firmware_bytes]u8 {
    var result = makeFirmware(0x44);
    const program = [_]u24{
        loadImmediate(0x1234, 6),
        jump(0x0be, 1),
        loadImmediate(0x5678, 6),
        jump(0x0be, 3),
        jump(0x100, 4),
    };
    installProgram(&result, &program);
    return result;
}

fn makeLinearFirmware() [ndsp.firmware_bytes]u8 {
    var result = makeFirmware(0x55);
    var program: [ndsp.program_words]u24 = undefined;
    for (&program, 0..) |*opcode, index| {
        opcode.* = if (index == program.len - 1)
            jump(0x100, 0)
        else
            loadImmediate(@truncate(index *% 73 +% 11), @intCast(index % 15 + 1));
    }
    installProgram(&result, &program);
    return result;
}

fn installProgram(firmware: *[ndsp.firmware_bytes]u8, program: []const u24) void {
    for (program, 0..) |opcode, index| {
        firmware[index * 3] = @truncate(opcode);
        firmware[index * 3 + 1] = @truncate(opcode >> 8);
        firmware[index * 3 + 2] = @truncate(opcode >> 16);
    }
}

fn makeImage(
    allocator: std.mem.Allocator,
    rom_size: usize,
    map_mode: u8,
    rom_type: u8,
    ram_code: u8,
    licensee: u8,
    copier_header: bool,
) ![]u8 {
    const prefix: usize = if (copier_header) core.cartridge.copier_header_size else 0;
    const image = try allocator.alloc(u8, rom_size + prefix);
    @memset(image, 0xea);
    if (copier_header) @memset(image[0..prefix], 0x5a);
    const rom = image[prefix..];
    const header_offset: usize = if ((map_mode & 0x0f) == 1) 0xffc0 else 0x7fc0;
    const header = rom[header_offset .. header_offset + core.cartridge.header_length];
    @memset(header, 0);
    @memset(header[0..core.cartridge.title_length], ' ');
    @memcpy(header[0..18], "R4SNES NEC DSP TST");
    header[0x15] = map_mode;
    header[0x16] = rom_type;
    header[0x17] = romSizeCode(rom_size);
    header[0x18] = ram_code;
    header[0x19] = 1;
    header[0x1a] = licensee;
    header[0x3c] = 0x00;
    header[0x3d] = 0x80;
    rom[0] = 0x78;
    finalizeChecksum(rom, header);
    return image;
}

fn romSizeCode(size: usize) u8 {
    var value = size;
    var log2: u8 = 0;
    while (value > 1) : (value >>= 1) log2 += 1;
    return log2 - 10;
}

fn finalizeChecksum(image: []u8, header: []u8) void {
    header[0x1c] = 0xff;
    header[0x1d] = 0xff;
    header[0x1e] = 0;
    header[0x1f] = 0;
    var sum: u16 = 0;
    for (image) |value| sum +%= value;
    const checksum = sum -% 0x01fe;
    const complement = ~checksum;
    header[0x1c] = @truncate(complement);
    header[0x1d] = @truncate(complement >> 8);
    header[0x1e] = @truncate(checksum);
    header[0x1f] = @truncate(checksum >> 8);
}
