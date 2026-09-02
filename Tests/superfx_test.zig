const std = @import("std");
const core = @import("core");

const rom_bytes = 32 * 1024;
const ram_bytes = 32 * 1024;

const FakeMmio = struct {
    pub fn read(_: *FakeMmio, _: u32, _: u8, _: u8) core.bus.MmioRead {
        return .{};
    }

    pub fn write(_: *FakeMmio, _: u32, _: u8, _: u8, _: u8) bool {
        return false;
    }
};

test "Super FX headers select GSU-2 compatibly and explicit metadata enforces GSU-1 geometry" {
    const allocator = std.testing.allocator;

    const slow = try makeSuperFxImage(allocator, 512 * 1024, 0x15, 0x20, 6, .ntsc_u);
    defer allocator.free(slow);
    var default_cart = try core.cartridge.Cartridge.parse(allocator, slow);
    defer default_cart.deinit();
    try std.testing.expectEqual(core.board.Enhancement.super_fx, default_cart.board.capability.enhancement);
    try std.testing.expectEqual(core.superfx.Revision.gsu2, default_cart.superfx_device.?.revision);
    try std.testing.expectEqual(@as(usize, 64 * 1024), default_cart.sram_storage.len);
    try std.testing.expect(default_cart.board.battery);
    try std.testing.expectEqual(@as(u8, 0x04), default_cart.readEnhancement(0x00303B, 0).?);

    var explicit_gsu1 = try core.cartridge.Cartridge.parseWithOptions(allocator, slow, .{ .superfx_revision = .gsu1 });
    defer explicit_gsu1.deinit();
    try std.testing.expectEqual(core.superfx.Revision.gsu1, explicit_gsu1.superfx_device.?.revision);
    try std.testing.expectEqual(@as(u8, 0x03), explicit_gsu1.readEnhancement(0x00303B, 0).?);

    const fast = try makeSuperFxImage(allocator, 2 * 1024 * 1024, 0x1A, 0x30, 7, .pal);
    defer allocator.free(fast);
    var gsu2 = try core.cartridge.Cartridge.parse(allocator, fast);
    defer gsu2.deinit();
    try std.testing.expect(gsu2.board.fast_rom);
    try std.testing.expectEqual(@as(usize, 128 * 1024), gsu2.sram_storage.len);
    try std.testing.expectError(error.ContradictorySuperFxBoard, core.cartridge.Cartridge.parseWithOptions(allocator, fast, .{ .superfx_revision = .gsu1 }));

    const gsu1_too_much_ram = try makeSuperFxImage(allocator, 1024 * 1024, 0x15, 0x20, 7, .ntsc_j);
    defer allocator.free(gsu1_too_much_ram);
    try std.testing.expectError(error.ContradictorySuperFxBoard, core.cartridge.Cartridge.parseWithOptions(allocator, gsu1_too_much_ram, .{ .superfx_revision = .gsu1 }));

    const unknown_revision = try makeSuperFxImage(allocator, 512 * 1024, 0x16, 0x20, 6, .ntsc_u);
    defer allocator.free(unknown_revision);
    try std.testing.expectError(error.UnsupportedSuperFxRevision, core.cartridge.Cartridge.parse(allocator, unknown_revision));

    const invalid_mapping = try makeSuperFxImage(allocator, 512 * 1024, 0x15, 0x21, 6, .ntsc_u);
    defer allocator.free(invalid_mapping);
    try std.testing.expectError(error.NoValidHeader, core.cartridge.Cartridge.parse(allocator, invalid_mapping));

    const pal_image = try makeSuperFxImage(allocator, 512 * 1024, 0x15, 0x20, 6, .pal);
    defer allocator.free(pal_image);
    var pal_cart = try core.cartridge.Cartridge.parse(allocator, pal_image);
    defer pal_cart.deinit();
    default_cart.rom_storage[0] = 0xD1;
    default_cart.rom_storage[1] = 0x00;
    pal_cart.rom_storage[0] = 0xD1;
    pal_cart.rom_storage[1] = 0x00;
    default_cart.superfx_device.?.scmr = 0x18;
    pal_cart.superfx_device.?.scmr = 0x18;
    startDevice(&default_cart.superfx_device.?, default_cart.sram_storage, 0);
    startDevice(&pal_cart.superfx_device.?, pal_cart.sram_storage, 0);
    try std.testing.expectEqual(core.superfx.RunState.stopped, default_cart.runSuperFxSlice(16).?.state);
    try std.testing.expectEqual(core.superfx.RunState.running, pal_cart.runSuperFxSlice(1).?.state);
    try std.testing.expectEqual(core.superfx.RunState.stopped, pal_cart.runSuperFxSlice(15).?.state);
    try std.testing.expectEqual(default_cart.superfx_device.?.stateDigest(), pal_cart.superfx_device.?.stateDigest());
}

test "production cartridge bus owns GSU registers ROM RAM arbitration and IRQ acknowledgement" {
    const allocator = std.testing.allocator;
    const image = try makeSuperFxImage(allocator, 512 * 1024, 0x15, 0x20, 6, .ntsc_u);
    defer allocator.free(image);
    var cart = try core.cartridge.Cartridge.parse(allocator, image);
    defer cart.deinit();
    cart.rom_storage[0] = 0x00; // STOP after the documented startup pipeline NOP.
    cart.sram_storage[0] = 0x11;

    var bus = core.bus.Bus{};
    var mmio = FakeMmio{};
    const version = bus.read(&cart, &mmio, 0x00303B);
    try std.testing.expectEqual(core.bus.AccessClass.cartridge_chip, version.class);
    try std.testing.expectEqual(core.superfx.access_master_cycles, version.master_cycles);
    try std.testing.expectEqual(@as(u8, 4), version.value);

    _ = bus.write(&cart, &mmio, 0x00303A, 0x18);
    startThroughBus(&bus, &cart, &mmio, 0);
    try std.testing.expect(cart.superfx_device.?.running());
    try std.testing.expectEqual(@as(u8, 0x00), bus.read(&cart, &mmio, 0x008000).value);
    try std.testing.expectEqual(@as(u8, 0x04), bus.read(&cart, &mmio, 0x008004).value);

    _ = bus.write(&cart, &mmio, 0x700000, 0x5A);
    try std.testing.expectEqual(@as(u8, 0x11), cart.sram_storage[0]);
    try std.testing.expectEqual(@as(u8, 0x5A), bus.read(&cart, &mmio, 0x700000).value);
    try std.testing.expectEqual(@as(u8, 0), bus.read(&cart, &mmio, 0x003000).value);

    const stopped = cart.runSuperFxSlice(8).?;
    try std.testing.expectEqual(core.superfx.RunState.stopped, stopped.state);
    try std.testing.expectEqual(@as(usize, 2), stopped.instructions);
    try std.testing.expect(cart.superfx_device.?.irqPending());
    try std.testing.expect(cart.superfx_device.?.irq_line);
    try std.testing.expectEqual(@as(u8, 0x80), bus.read(&cart, &mmio, 0x003031).value);
    try std.testing.expect(!cart.superfx_device.?.irqPending());
    try std.testing.expect(!cart.superfx_device.?.irq_line);

    _ = bus.write(&cart, &mmio, 0x003037, 0x80);
    startThroughBus(&bus, &cart, &mmio, 0);
    try std.testing.expectEqual(core.superfx.RunState.stopped, cart.runSuperFxSlice(8).?.state);
    try std.testing.expect(!cart.superfx_device.?.irqPending());

    _ = bus.write(&cart, &mmio, 0x00303A, 0x08);
    _ = bus.write(&cart, &mmio, 0x003034, 0x00); // PBR writes invalidate the opcode cache.
    startThroughBus(&bus, &cart, &mmio, 0);
    const waiting = cart.runSuperFxSlice(1).?;
    try std.testing.expectEqual(core.superfx.RunState.waiting_rom, waiting.state);
    try std.testing.expectEqual(core.superfx.Fault.rom_bus_unavailable, waiting.fault);
    _ = bus.write(&cart, &mmio, 0x00303A, 0x18);
    try std.testing.expectEqual(core.superfx.RunState.running, cart.runSuperFxSlice(1).?.state);
}

test "cache refill clock select branch delay and ordered RAM write buffer are exact" {
    var rom = [_]u8{0x01} ** rom_bytes;
    var ram = [_]u8{0} ** ram_bytes;
    rom[0] = 0x00;

    var slow = core.superfx.Device.init(.gsu2);
    try slow.power(.gsu2, rom.len, ram.len);
    slow.scmr = 0x18;
    startDevice(&slow, &ram, 0);
    const slow_result = slow.runSlice(&rom, &ram, 8);
    try std.testing.expectEqual(@as(u64, 98), slow_result.clocks);

    var fast = core.superfx.Device.init(.gsu2);
    try fast.power(.gsu2, rom.len, ram.len);
    fast.scmr = 0x18;
    fast.clsr = true;
    startDevice(&fast, &ram, 0);
    try std.testing.expectEqual(@as(u64, 81), fast.runSlice(&rom, &ram, 8).clocks);

    var preloaded = core.superfx.Device.init(.gsu2);
    try preloaded.power(.gsu2, rom.len, ram.len);
    preloaded.scmr = 0x18;
    for (0..16) |index| {
        _ = preloaded.writeCpu(&ram, 0x003100 + @as(u32, @intCast(index)), rom[index]);
    }
    startDevice(&preloaded, &ram, 0);
    try std.testing.expectEqual(@as(u64, 4), preloaded.runSlice(&rom, &ram, 8).clocks);

    @memset(rom[0..], 0x01);
    rom[0] = 0x05; // BRA +2; the instruction at PC 2 remains the delay slot.
    rom[1] = 0x02;
    rom[2] = 0xD1;
    rom[3] = 0xD2;
    rom[4] = 0x00;
    var branch = core.superfx.Device.init(.gsu2);
    try branch.power(.gsu2, rom.len, ram.len);
    branch.scmr = 0x18;
    startDevice(&branch, &ram, 0);
    try std.testing.expectEqual(core.superfx.RunState.stopped, branch.runSlice(&rom, &ram, 16).state);
    try std.testing.expectEqual(@as(u16, 1), branch.r[1]);
    try std.testing.expectEqual(@as(u16, 0), branch.r[2]);

    @memset(ram[0..], 0);
    var buffered = core.superfx.Device.init(.gsu2);
    try buffered.power(.gsu2, rom.len, ram.len);
    buffered.scmr = 0x08;
    buffered.r[0] = 0x0010;
    buffered.r[1] = 0xBEEF;
    buffered.source_register = 1;
    try buffered.executeDecoded(&rom, &ram, 0x30);
    try std.testing.expectEqual(@as(u8, 0xEF), ram[0x10]);
    try std.testing.expectEqual(@as(u8, 0x00), ram[0x11]);
    try std.testing.expect(buffered.ram_delay != 0);
    try buffered.drain(&rom, &ram);
    try std.testing.expectEqual(@as(u8, 0xBE), ram[0x11]);
    const dirty = buffered.takeDirtyRange().?;
    try std.testing.expectEqual(@as(usize, 0x10), dirty.first);
    try std.testing.expectEqual(@as(usize, 0x12), dirty.end);
}

test "all conditional branches take and fall through and multiply variants use exact low-byte semantics" {
    const BranchCase = struct { opcode: u8, take_flags: u8, fallthrough_flags: u8 };
    const cases = [_]BranchCase{
        .{ .opcode = 0x06, .take_flags = 0x00, .fallthrough_flags = 0x08 }, // BGE
        .{ .opcode = 0x07, .take_flags = 0x08, .fallthrough_flags = 0x00 }, // BLT
        .{ .opcode = 0x08, .take_flags = 0x00, .fallthrough_flags = 0x02 }, // BNE
        .{ .opcode = 0x09, .take_flags = 0x02, .fallthrough_flags = 0x00 }, // BEQ
        .{ .opcode = 0x0A, .take_flags = 0x00, .fallthrough_flags = 0x08 }, // BPL
        .{ .opcode = 0x0B, .take_flags = 0x08, .fallthrough_flags = 0x00 }, // BMI
        .{ .opcode = 0x0C, .take_flags = 0x00, .fallthrough_flags = 0x04 }, // BCC
        .{ .opcode = 0x0D, .take_flags = 0x04, .fallthrough_flags = 0x00 }, // BCS
        .{ .opcode = 0x0E, .take_flags = 0x00, .fallthrough_flags = 0x10 }, // BVC
        .{ .opcode = 0x0F, .take_flags = 0x10, .fallthrough_flags = 0x00 }, // BVS
    };
    var rom = [_]u8{0x01} ** rom_bytes;
    var ram = [_]u8{0} ** ram_bytes;
    for (cases) |case| {
        var taken = try branchFixture(&ram, case.take_flags);
        try taken.executeDecoded(&rom, &ram, case.opcode);
        try std.testing.expectEqual(@as(u16, 3), taken.r[15]);
        var fallthrough = try branchFixture(&ram, case.fallthrough_flags);
        try fallthrough.executeDecoded(&rom, &ram, case.opcode);
        try std.testing.expectEqual(@as(u16, 2), fallthrough.r[15]);
    }
    var backward = try branchFixture(&ram, 0);
    backward.pipeline = 0xFE;
    try backward.executeDecoded(&rom, &ram, 0x05);
    try std.testing.expectEqual(@as(u16, 0xFFFF), backward.r[15]);

    var multiply = core.superfx.Device.init(.gsu2);
    try multiply.power(.gsu2, rom.len, ram.len);
    multiply.r[0] = 0x1234;
    multiply.r[1] = 0x02FF;
    try multiply.executeDecoded(&rom, &ram, 0x3D);
    try multiply.executeDecoded(&rom, &ram, 0x81); // UMULT R1: $34 * $ff
    try std.testing.expectEqual(@as(u16, 0x33CC), multiply.r[0]);
    try std.testing.expectEqual(@as(u64, 2), multiply.cycles);

    try multiply.power(.gsu2, rom.len, ram.len);
    multiply.cfgr = 0x20;
    multiply.r[0] = 0x00FE;
    multiply.r[1] = 0x0002;
    try multiply.executeDecoded(&rom, &ram, 0x81); // signed MULT: -2 * 2
    try std.testing.expectEqual(@as(u16, 0xFFFC), multiply.r[0]);
    try std.testing.expectEqual(@as(u64, 0), multiply.cycles);

    try multiply.power(.gsu2, rom.len, ram.len);
    multiply.r[0] = 0x1800;
    multiply.r[6] = 0x3000;
    try multiply.executeDecoded(&rom, &ram, 0x9F);
    try std.testing.expectEqual(@as(u16, 0x0480), multiply.r[0]);
    try std.testing.expectEqual(@as(u64, 14), multiply.cycles);
    try multiply.power(.gsu2, rom.len, ram.len);
    multiply.clsr = true;
    multiply.cfgr = 0x20;
    multiply.r[0] = 0x1800;
    multiply.r[6] = 0x3000;
    try multiply.executeDecoded(&rom, &ram, 0x3D);
    try multiply.executeDecoded(&rom, &ram, 0x9F); // LMULT
    try std.testing.expectEqual(@as(u16, 0x0000), multiply.r[4]);
    try std.testing.expectEqual(@as(u16, 0x0480), multiply.r[0]);
    try std.testing.expectEqual(@as(u64, 3), multiply.cycles);
}

test "PLOT RPIX all color depths height layouts partial merge transparency dither and timing" {
    const bpps = [_]u4{ 2, 4, 4, 8 };
    const colors = [_]u8{ 0x03, 0x05, 0x0A, 0xA5 };
    var screen_mode: u8 = 0;
    while (screen_mode < 4) : (screen_mode += 1) {
        var rom = [_]u8{0x01} ** rom_bytes;
        var ram = [_]u8{0x5A} ** ram_bytes;
        var device = core.superfx.Device.init(.gsu2);
        try device.power(.gsu2, rom.len, ram.len);
        device.scmr = screen_mode | 0x08;
        device.colr = colors[screen_mode];
        device.r[1] = 0;
        device.r[2] = 0;
        const before = device.cycles;
        for (0..8) |_| try device.executeDecoded(&rom, &ram, 0x4C);
        try device.drain(&rom, &ram);
        try std.testing.expectEqual(@as(u64, bpps[screen_mode]) * 6, device.cycles - before);
        var plane: u4 = 0;
        while (plane < bpps[screen_mode]) : (plane += 1) {
            const offset: usize = (@as(usize, plane >> 1) << 4) + (plane & 1);
            const expected: u8 = if (((colors[screen_mode] >> @truncate(plane)) & 1) != 0) 0xFF else 0;
            try std.testing.expectEqual(expected, ram[offset]);
        }
        device.r[1] = 3;
        device.r[2] = 0;
        try device.executeDecoded(&rom, &ram, 0x3D);
        try device.executeDecoded(&rom, &ram, 0x4C);
        try std.testing.expectEqual(@as(u16, colors[screen_mode]), device.r[0]);
    }

    var height_mode: u8 = 0;
    while (height_mode < 4) : (height_mode += 1) {
        var rom = [_]u8{0x01} ** rom_bytes;
        var ram = [_]u8{0} ** ram_bytes;
        var device = core.superfx.Device.init(.gsu2);
        try device.power(.gsu2, rom.len, ram.len);
        device.scmr = 0x08 | heightBits(height_mode);
        try std.testing.expectEqual(@as(u2, @truncate(height_mode)), device.screenHeightMode());
        device.colr = 3;
        device.r[1] = 0x18;
        device.r[2] = 0x28;
        for (0..8) |_| try device.executeDecoded(&rom, &ram, 0x4C);
        try device.drain(&rom, &ram);
        const tile = expectedTile(height_mode, 0x18, 0x28);
        const address: usize = tile * 16;
        try std.testing.expectEqual(@as(u8, 0xFF), ram[address]);
        try std.testing.expectEqual(@as(u8, 0xFF), ram[address + 1]);
    }

    var rom = [_]u8{0x01} ** rom_bytes;
    var ram = [_]u8{0xAA} ** ram_bytes;
    var partial = core.superfx.Device.init(.gsu2);
    try partial.power(.gsu2, rom.len, ram.len);
    partial.scmr = 0x08;
    partial.colr = 3;
    try partial.executeDecoded(&rom, &ram, 0x4C);
    try partial.drain(&rom, &ram);
    try std.testing.expectEqual(@as(u8, 0xAA | 0x80), ram[0]);
    try std.testing.expectEqual(@as(u8, 0xAA | 0x80), ram[1]);

    @memset(ram[0..], 0xAA);
    try partial.power(.gsu2, rom.len, ram.len);
    partial.scmr = 0x08;
    partial.colr = 0;
    try partial.executeDecoded(&rom, &ram, 0x4C);
    try partial.drain(&rom, &ram);
    try std.testing.expectEqual(@as(u8, 0xAA), ram[0]);
    partial.por = 1;
    partial.r[1] = 0;
    try partial.executeDecoded(&rom, &ram, 0x4C);
    try partial.drain(&rom, &ram);
    try std.testing.expectEqual(@as(u8, 0x2A), ram[0]);

    @memset(ram[0..], 0);
    try partial.power(.gsu2, rom.len, ram.len);
    partial.scmr = 0x09;
    partial.colr = 0xA3;
    partial.por = 0x03;
    for (0..8) |_| try partial.executeDecoded(&rom, &ram, 0x4C);
    try partial.drain(&rom, &ram);
    var x: u8 = 0;
    while (x < 8) : (x += 1) {
        const expected: u8 = if ((x & 1) == 0) 3 else 10;
        try std.testing.expectEqual(expected, try partial.readPixel(&rom, &ram, x, 0));
    }

    var fast = core.superfx.Device.init(.gsu2);
    @memset(ram[0..], 0);
    try fast.power(.gsu2, rom.len, ram.len);
    fast.scmr = 0x0B;
    fast.clsr = true;
    fast.colr = 0xFF;
    for (0..8) |_| try fast.executeDecoded(&rom, &ram, 0x4C);
    try fast.drain(&rom, &ram);
    try std.testing.expectEqual(@as(u64, 40), fast.cycles);
}

test "all 256 opcodes under every ALT prefix have a pinned exact aggregate state and RAM digest" {
    var aggregate: u64 = 0xCBF29CE484222325;
    inline for (.{ core.superfx.Revision.gsu1, core.superfx.Revision.gsu2 }) |revision| {
        var prefix: u8 = 0;
        while (prefix < 4) : (prefix += 1) {
            var opcode: u16 = 0;
            while (opcode < 256) : (opcode += 1) {
                var rom = [_]u8{0} ** rom_bytes;
                var ram = [_]u8{0} ** ram_bytes;
                for (&rom, 0..) |*value, index| value.* = @truncate(index *% 73 +% 19);
                for (&ram, 0..) |*value, index| value.* = @truncate(index *% 29 +% 7);
                var device = core.superfx.Device.init(revision);
                try device.power(revision, rom.len, ram.len);
                device.scmr = 0x18;
                device.cbr = 0x0100;
                device.r[15] = 0x0100;
                device.colr = 0xA5;
                device.ram_address = 0x0080;
                for (&device.r, 0..) |*value, index| value.* = @truncate(0x1021 *% index +% 0x0317);
                device.r[0] = 0x1234;
                device.r[1] = 0x0040;
                device.r[2] = 0x0008;
                device.r[14] = 0x0020;
                device.r[15] = 0x0100;
                for (&device.cache, 0..) |*value, index| value.* = @truncate(index *% 41 +% 3);
                @memset(device.cache_valid[0..], true);
                if (prefix != 0) try device.executeDecoded(&rom, &ram, 0x3C + prefix);
                try device.executeDecoded(&rom, &ram, @truncate(opcode));
                try device.drain(&rom, &ram);
                digestByte(&aggregate, @intFromEnum(revision));
                digestByte(&aggregate, prefix);
                digestByte(&aggregate, @truncate(opcode));
                digestU64(&aggregate, device.stateDigest());
                for (ram[0..256]) |value| digestByte(&aggregate, value);
            }
        }
    }
    try std.testing.expectEqual(@as(u64, 0xD6E7_4E65_B12A_54A5), aggregate);
}

test "WITH TO FROM reset restart arbitrary host slices and independent devices are deterministic" {
    var rom = [_]u8{0x01} ** rom_bytes;
    var ram_a = [_]u8{0} ** ram_bytes;
    var ram_b = [_]u8{0} ** ram_bytes;

    var moves = core.superfx.Device.init(.gsu2);
    try moves.power(.gsu2, rom.len, ram_a.len);
    moves.r[3] = 0xCAFE;
    try moves.executeDecoded(&rom, &ram_a, 0x23); // WITH R3
    try moves.executeDecoded(&rom, &ram_a, 0x14); // MOVE R3 -> R4
    try std.testing.expectEqual(@as(u16, 0xCAFE), moves.r[4]);
    try moves.executeDecoded(&rom, &ram_a, 0x25); // WITH R5
    moves.r[6] = 0xBEEF;
    try moves.executeDecoded(&rom, &ram_a, 0xB6); // MOVES R6 -> R5
    try std.testing.expectEqual(@as(u16, 0xBEEF), moves.r[5]);

    rom[0] = 0xD1;
    rom[1] = 0xD2;
    rom[2] = 0xD3;
    rom[3] = 0x00;
    var whole = core.superfx.Device.init(.gsu2);
    var sliced = core.superfx.Device.init(.gsu2);
    try whole.power(.gsu2, rom.len, ram_a.len);
    try sliced.power(.gsu2, rom.len, ram_b.len);
    whole.scmr = 0x18;
    sliced.scmr = 0x18;
    startDevice(&whole, &ram_a, 0);
    startDevice(&sliced, &ram_b, 0);
    try std.testing.expectEqual(core.superfx.RunState.stopped, whole.runSlice(&rom, &ram_a, 64).state);
    while (sliced.running()) _ = sliced.runSlice(&rom, &ram_b, 1);
    try std.testing.expectEqualSlices(u8, &ram_a, &ram_b);
    try std.testing.expectEqual(whole.stateDigest(), sliced.stateDigest());

    ram_a[17] = 0xA7;
    try whole.reset(rom.len, ram_a.len);
    try std.testing.expectEqual(@as(u8, 0xA7), ram_a[17]);
    try std.testing.expect(!whole.running());
    whole.scmr = 0x18;
    startDevice(&whole, &ram_a, 0);
    try std.testing.expectEqual(core.superfx.RunState.stopped, whole.runSlice(&rom, &ram_a, 64).state);
    startDevice(&whole, &ram_a, 0);
    try std.testing.expect(whole.running());
}

fn startThroughBus(bus: *core.bus.Bus, cart: *core.cartridge.Cartridge, mmio: *FakeMmio, address: u16) void {
    _ = bus.write(cart, mmio, 0x00301E, @truncate(address));
    _ = bus.write(cart, mmio, 0x00301F, @truncate(address >> 8));
}

fn startDevice(device: *core.superfx.Device, ram: []u8, address: u16) void {
    _ = device.writeCpu(ram, 0x00301E, @truncate(address));
    _ = device.writeCpu(ram, 0x00301F, @truncate(address >> 8));
}

fn branchFixture(ram: []u8, flags: u8) !core.superfx.Device {
    var device = core.superfx.Device.init(.gsu2);
    try device.power(.gsu2, rom_bytes, ram.len);
    device.scmr = 0x18;
    device.pipeline = 2;
    device.r[15] = 0;
    @memset(device.cache_valid[0..], true);
    _ = device.writeCpu(ram, 0x003030, flags);
    return device;
}

fn heightBits(mode: u8) u8 {
    return ((mode & 1) << 2) | ((mode & 2) << 4);
}

fn expectedTile(mode: u8, x: u8, y: u8) usize {
    return switch (mode) {
        0 => (@as(usize, x & 0xF8) << 1) + ((y & 0xF8) >> 3),
        1 => (@as(usize, x & 0xF8) << 1) + (@as(usize, x & 0xF8) >> 1) + ((y & 0xF8) >> 3),
        2 => (@as(usize, x & 0xF8) << 1) + @as(usize, x & 0xF8) + ((y & 0xF8) >> 3),
        3 => (@as(usize, y & 0x80) << 2) + (@as(usize, x & 0x80) << 1) +
            (@as(usize, y & 0x78) << 1) + ((x & 0x78) >> 3),
        else => unreachable,
    };
}

fn digestByte(digest: *u64, value: u8) void {
    digest.* ^= value;
    digest.* *%= 0x100000001B3;
}

fn digestU64(digest: *u64, value: u64) void {
    inline for (0..8) |index| digestByte(digest, @truncate(value >> @intCast(index * 8)));
}

fn makeSuperFxImage(
    allocator: std.mem.Allocator,
    size: usize,
    rom_type: u8,
    map_mode: u8,
    expansion_ram_size_code: u8,
    region: core.board.Region,
) ![]u8 {
    const rom = try allocator.alloc(u8, size);
    @memset(rom, 0xEA);
    const header = rom[0x7FC0 .. 0x7FC0 + core.cartridge.header_length];
    @memset(header, 0);
    @memset(header[0..core.cartridge.title_length], ' ');
    @memcpy(header[0..19], "R4SNES SUPERFX TEST");
    rom[0x7FBD] = expansion_ram_size_code;
    rom[0x7FBF] = 0;
    header[0x15] = map_mode;
    header[0x16] = rom_type;
    header[0x17] = romSizeCode(size);
    header[0x18] = 0;
    header[0x19] = switch (region) {
        .ntsc_j => 0,
        .ntsc_u => 1,
        .pal => 2,
    };
    header[0x1A] = 0x33;
    header[0x1B] = 0;
    header[0x3C] = 0;
    header[0x3D] = 0x80;
    rom[0] = 0x78;
    finalizeChecksum(rom, header);
    return rom;
}

fn romSizeCode(size: usize) u8 {
    var value = size;
    var log2: u8 = 0;
    while (value > 1) : (value >>= 1) log2 += 1;
    return log2 - 10;
}

fn finalizeChecksum(rom: []u8, header: []u8) void {
    header[0x1C] = 0;
    header[0x1D] = 0;
    header[0x1E] = 0;
    header[0x1F] = 0;
    var sum: u16 = 0;
    for (rom) |value| sum +%= value;
    const checksum = sum +% 0x01FE;
    const complement = ~checksum;
    header[0x1C] = @truncate(complement);
    header[0x1D] = @truncate(complement >> 8);
    header[0x1E] = @truncate(checksum);
    header[0x1F] = @truncate(checksum >> 8);
}
