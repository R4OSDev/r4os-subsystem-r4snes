const std = @import("std");
const core = @import("core");

test "OBC-1 primary and cartridge mirrors address exactly one 8 KiB RAM" {
    var ram = [_]u8{0} ** core.obc1.ram_bytes;
    var device = core.obc1.Device{};
    try device.power(ram[0..]);

    const direct = device.write(ram[0..], 0x006123, 0xA5);
    try std.testing.expect(direct.handled and direct.changed);
    try std.testing.expectEqual(@as(usize, 0x123), direct.first);
    try std.testing.expectEqual(@as(?u8, 0xA5), device.read(ram[0..], 0x806123));
    try std.testing.expectEqual(@as(?u8, 0xA5), device.read(ram[0..], 0x706123));
    try std.testing.expectEqual(@as(?u8, 0xA5), device.read(ram[0..], 0x70E123));
    try std.testing.expect(device.read(ram[0..], 0x726123) == null);

    _ = device.write(ram[0..], 0x007FF5, 1);
    _ = device.write(ram[0..], 0x007FF6, 0x7F);
    try std.testing.expectEqual(@as(u16, 0x1800), device.base);
    try std.testing.expectEqual(@as(u8, 0x7F), device.object);
    try std.testing.expectEqual(@as(u3, 6), device.attribute_shift);
    inline for (0..4) |index| {
        const result = device.write(ram[0..], 0x007FF0 + index, @intCast(0x40 + index));
        try std.testing.expect(result.changed);
        try std.testing.expectEqual(@as(usize, 0x19FC + index), result.first);
    }
    try std.testing.expectEqualSlices(u8, &.{ 0x40, 0x41, 0x42, 0x43 }, ram[0x19FC..0x1A00]);
    const attribute = device.write(ram[0..], 0x007FF4, 3);
    try std.testing.expectEqual(@as(usize, 0x1A1F), attribute.first);
    try std.testing.expectEqual(@as(u8, 0xC0), ram[0x1A1F]);
    try std.testing.expectEqual(@as(?u8, 0xC0), device.read(ram[0..], 0x007FF4));
}

test "OBC-1 reset restores selectors from battery RAM without erasing it" {
    var ram = [_]u8{0xFF} ** core.obc1.ram_bytes;
    ram[0x1FF5] = 0;
    ram[0x1FF6] = 0x42;
    ram[0x1D08] = 0x5A;
    var device = core.obc1.Device{ .base = 0x1800, .object = 1, .attribute_shift = 0 };
    try device.reset(ram[0..]);
    try std.testing.expectEqual(@as(u16, 0x1C00), device.base);
    try std.testing.expectEqual(@as(u8, 0x42), device.object);
    try std.testing.expectEqual(@as(u3, 4), device.attribute_shift);
    try std.testing.expectEqual(@as(u8, 0x5A), ram[0x1D08]);
    try std.testing.expectError(error.InvalidOBC1RamSize, device.power(ram[0 .. ram.len - 1]));
}

test "OBC-1 production bus owns chip windows timing and exact dirty bounds" {
    const allocator = std.testing.allocator;
    const image = try makeEnhancementImage(allocator, .obc1, 2 * 1024 * 1024, 3);
    defer allocator.free(image);
    var cart = try core.cartridge.Cartridge.parse(allocator, image);
    defer cart.deinit();
    var bus = core.bus.Bus{};
    const mmio = core.bus.NullMmio{};

    const selector = bus.write(&cart, mmio, 0x007FF6, 2);
    try std.testing.expectEqual(core.bus.AccessClass.cartridge_chip, selector.class);
    try std.testing.expectEqual(core.obc1.access_master_cycles, selector.master_cycles);
    const object = bus.write(&cart, mmio, 0x007FF2, 0x77);
    try std.testing.expectEqual(core.bus.AccessClass.cartridge_chip, object.class);
    try std.testing.expectEqual(@as(u8, 0x77), bus.read(&cart, mmio, 0x807FF2).value);
    const dirty = cart.dirtyRange().?;
    try std.testing.expectEqual(@as(usize, 0x1FF6), dirty.end - 1);
    try std.testing.expectEqual(@as(usize, 0x1C0A), dirty.first);
    cart.clearSramDirty();
    _ = bus.write(&cart, mmio, 0x007FF2, 0x77);
    try std.testing.expect(cart.dirtyRange() == null);
}

test "OBC-1 and S-RTC header profiles reject contradictions and unknown revisions" {
    const allocator = std.testing.allocator;
    const obc = try makeEnhancementImage(allocator, .obc1, 2 * 1024 * 1024, 3);
    defer allocator.free(obc);
    var parsed_obc = try core.cartridge.Cartridge.parse(allocator, obc);
    defer parsed_obc.deinit();
    try std.testing.expect(parsed_obc.board.readyForExecution());
    try std.testing.expect(parsed_obc.obc1_device != null);
    try std.testing.expectEqual(@as(usize, core.obc1.ram_bytes), parsed_obc.sram().len);

    const bad_obc_ram = try makeEnhancementImage(allocator, .obc1, 2 * 1024 * 1024, 2);
    defer allocator.free(bad_obc_ram);
    try std.testing.expectError(error.ContradictoryOBC1Board, core.cartridge.Cartridge.parse(allocator, bad_obc_ram));
    const unknown_obc = try makeEnhancementImage(allocator, .obc1, 2 * 1024 * 1024, 3);
    defer allocator.free(unknown_obc);
    setHeaderByte(unknown_obc, .lo_rom, 0x16, 0x26);
    finalizeChecksum(unknown_obc, .lo_rom);
    try std.testing.expectError(error.UnsupportedOBC1Revision, core.cartridge.Cartridge.parse(allocator, unknown_obc));

    const rtc = try makeEnhancementImage(allocator, .srtc, 5 * 1024 * 1024, 3);
    defer allocator.free(rtc);
    var parsed_rtc = try core.cartridge.Cartridge.parse(allocator, rtc);
    defer parsed_rtc.deinit();
    try std.testing.expectEqual(core.board.Mapping.ex_hi_rom, parsed_rtc.board.mapping);
    try std.testing.expect(parsed_rtc.board.readyForExecution());
    try std.testing.expect(parsed_rtc.srtc_device != null);
    const bad_rtc_ram = try makeEnhancementImage(allocator, .srtc, 5 * 1024 * 1024, 0);
    defer allocator.free(bad_rtc_ram);
    try std.testing.expectError(error.ContradictorySrtcBoard, core.cartridge.Cartridge.parse(allocator, bad_rtc_ram));
    const unknown_rtc = try makeEnhancementImage(allocator, .srtc, 5 * 1024 * 1024, 3);
    defer allocator.free(unknown_rtc);
    setHeaderByte(unknown_rtc, .ex_hi_rom, 0x16, 0x56);
    finalizeChecksum(unknown_rtc, .ex_hi_rom);
    try std.testing.expectError(error.UnsupportedSrtcRevision, core.cartridge.Cartridge.parse(allocator, unknown_rtc));
}

test "S-RTC command stream latches BCD calendar and crosses leap midnight" {
    var rtc = core.srtc.Device{};
    rtc.power();
    writeCalendar(&rtc, .{
        .second = 58,
        .minute = 59,
        .hour = 23,
        .day = 29,
        .month = 2,
        .year = 996,
        .weekday = 0,
    });
    try std.testing.expect(!rtc.halted);
    try std.testing.expectEqual(core.srtc.Fault.none, rtc.fault);
    const before = try core.srtc.calendarFromRegisters(&rtc.live, true);
    try std.testing.expectEqual(@as(u8, 29), before.day);
    try std.testing.expectEqual(@as(u8, 2), before.month);

    try std.testing.expect(rtc.write(0x002801, 0x0D));
    try std.testing.expectEqual(@as(?u8, 0x0F), rtc.read(0x002800, 0));
    rtc.advanceSeconds(2);
    var latched: [core.srtc.register_count]u8 = undefined;
    for (&latched) |*value| value.* = rtc.read(0x802800, 0).?;
    try std.testing.expectEqual(@as(u8, 8), latched[0]);
    try std.testing.expectEqual(@as(u8, 5), latched[1]);
    try std.testing.expectEqual(@as(?u8, 0x0F), rtc.read(0x002800, 0));

    _ = rtc.write(0x002801, 0x0D);
    _ = rtc.read(0x002800, 0);
    var next: [core.srtc.persisted_register_count]u8 = .{0} ** core.srtc.persisted_register_count;
    for (next[0..core.srtc.register_count]) |*value| value.* = rtc.read(0x002800, 0).?;
    const after = try core.srtc.calendarFromRegisters(&next, true);
    try std.testing.expectEqual(@as(u8, 0), after.second);
    try std.testing.expectEqual(@as(u8, 0), after.hour);
    try std.testing.expectEqual(@as(u8, 1), after.day);
    try std.testing.expectEqual(@as(u8, 3), after.month);
}

test "S-RTC rejects invalid staged calendars and exposes reset halt state" {
    var rtc = core.srtc.Device{};
    writeCalendar(&rtc, .{ .second = 0, .minute = 0, .hour = 12, .day = 1, .month = 1, .year = 25, .weekday = 0 });
    const last_good = rtc.live;
    writeCalendar(&rtc, .{ .second = 0, .minute = 0, .hour = 12, .day = 30, .month = 2, .year = 25, .weekday = 0 });
    try std.testing.expectEqual(core.srtc.Fault.invalid_write, rtc.fault);
    try std.testing.expectEqualSlices(u8, last_good[0..], rtc.live[0..]);
    try std.testing.expect(!rtc.halted);

    _ = rtc.write(0x002801, 0x0E);
    _ = rtc.write(0x002801, 0x04);
    try std.testing.expect(rtc.halted);
    try std.testing.expectEqual(core.srtc.Mode.ready, rtc.mode);
    try std.testing.expectEqualSlices(u8, &(.{0} ** core.srtc.persisted_register_count), rtc.live[0..]);
    try core.srtc.validatePersistent(&rtc.live, &rtc.latched, rtc.halted);
}

test "S-RTC Gregorian boundaries and year wrap are partition invariant" {
    var leap = core.srtc.Device{};
    writeCalendar(&leap, .{ .second = 59, .minute = 59, .hour = 23, .day = 28, .month = 2, .year = 996, .weekday = 0 });
    leap.advanceSeconds(1);
    const leap_day = try core.srtc.calendarFromRegisters(&leap.live, true);
    try std.testing.expectEqual(@as(u8, 29), leap_day.day);

    var century = core.srtc.Device{};
    writeCalendar(&century, .{ .second = 59, .minute = 59, .hour = 23, .day = 28, .month = 2, .year = 900, .weekday = 0 });
    century.advanceSeconds(1);
    const march = try core.srtc.calendarFromRegisters(&century.live, true);
    try std.testing.expectEqual(@as(u8, 1), march.day);
    try std.testing.expectEqual(@as(u8, 3), march.month);

    var whole = core.srtc.Device{};
    var sliced = core.srtc.Device{};
    const start = core.srtc.Calendar{ .second = 55, .minute = 58, .hour = 23, .day = 31, .month = 12, .year = 999, .weekday = 0 };
    writeCalendar(&whole, start);
    writeCalendar(&sliced, start);
    whole.advanceSeconds(172_805);
    for ([_]u64{ 5, 60, 3600, 80_000, 89_140 }) |slice| sliced.advanceSeconds(slice);
    try std.testing.expectEqualSlices(u8, whole.live[0..], sliced.live[0..]);
    try std.testing.expect(whole.overflow and sliced.overflow);
    const wrapped = try core.srtc.calendarFromRegisters(&whole.live, true);
    try std.testing.expectEqual(@as(u16, 0), wrapped.year);
    try std.testing.expectEqual(@as(u8, 2), wrapped.day);
}

test "S-RTC production bus precedes MMIO with exact chip timing" {
    const allocator = std.testing.allocator;
    const image = try makeEnhancementImage(allocator, .srtc, 5 * 1024 * 1024, 3);
    defer allocator.free(image);
    var cart = try core.cartridge.Cartridge.parse(allocator, image);
    defer cart.deinit();
    var bus = core.bus.Bus{};
    var mmio = CountingMmio{};

    const command = bus.write(&cart, &mmio, 0x002801, 0x0D);
    try std.testing.expectEqual(core.bus.AccessClass.cartridge_chip, command.class);
    try std.testing.expectEqual(core.srtc.access_master_cycles, command.master_cycles);
    const start = bus.read(&cart, &mmio, 0x802800);
    try std.testing.expectEqual(core.bus.AccessClass.cartridge_chip, start.class);
    try std.testing.expectEqual(@as(u8, 0x0F), start.value);
    try std.testing.expectEqual(@as(usize, 0), mmio.reads);
    try std.testing.expectEqual(@as(usize, 0), mmio.writes);
}

const CountingMmio = struct {
    reads: usize = 0,
    writes: usize = 0,

    pub fn read(self: *CountingMmio, _: u32, _: u8, _: u8) core.bus.MmioRead {
        self.reads += 1;
        return .{ .handled = true, .value = 0xEE };
    }

    pub fn write(self: *CountingMmio, _: u32, _: u8, _: u8, _: u8) bool {
        self.writes += 1;
        return true;
    }
};

fn writeCalendar(device: *core.srtc.Device, calendar: core.srtc.Calendar) void {
    var registers: [core.srtc.persisted_register_count]u8 = .{0} ** core.srtc.persisted_register_count;
    var normalized = calendar;
    normalized.weekday = core.srtc.calculateWeekday(calendar.year, calendar.month, calendar.day);
    core.srtc.registersFromCalendar(normalized, &registers);
    _ = device.write(0x002801, 0x0E);
    _ = device.write(0x002801, 0);
    for (registers[0..12]) |value| _ = device.write(0x002801, value);
}

fn makeEnhancementImage(
    allocator: std.mem.Allocator,
    enhancement: core.board.Enhancement,
    rom_size: usize,
    ram_size_code: u8,
) ![]u8 {
    const mapping: core.board.Mapping = switch (enhancement) {
        .obc1 => .lo_rom,
        .srtc => .ex_hi_rom,
        else => return error.UnsupportedFixture,
    };
    const image = try allocator.alloc(u8, rom_size);
    @memset(image, 0xEA);
    const offset = headerOffset(mapping);
    const header = image[offset .. offset + core.cartridge.header_length];
    @memset(header, 0);
    @memset(header[0..core.cartridge.title_length], ' ');
    @memcpy(header[0..19], "R4SNES CHIP FIXTURE");
    header[0x15] = switch (enhancement) {
        .obc1 => 0x30,
        .srtc => 0x35,
        else => unreachable,
    };
    header[0x16] = switch (enhancement) {
        .obc1 => 0x25,
        .srtc => 0x55,
        else => unreachable,
    };
    header[0x17] = declaredRomCode(rom_size);
    header[0x18] = ram_size_code;
    header[0x19] = 1;
    header[0x1A] = 0x33;
    header[0x3C] = 0x00;
    header[0x3D] = 0x80;
    const startup = core.board.decodeRomIndex(mapping, 0x008000, image.len).?;
    image[startup] = 0x78;
    finalizeChecksum(image, mapping);
    return image;
}

fn declaredRomCode(size: usize) u8 {
    var declared: usize = core.cartridge.minimum_rom_size;
    var code: u8 = 5;
    while (declared < size) : (declared *= 2) code += 1;
    return code;
}

fn headerOffset(mapping: core.board.Mapping) usize {
    return switch (mapping) {
        .lo_rom => 0x7FC0,
        .hi_rom => 0xFFC0,
        .ex_lo_rom => 0x407FC0,
        .ex_hi_rom => 0x40FFC0,
    };
}

fn setHeaderByte(image: []u8, mapping: core.board.Mapping, relative: usize, value: u8) void {
    image[headerOffset(mapping) + relative] = value;
}

fn finalizeChecksum(image: []u8, mapping: core.board.Mapping) void {
    const offset = headerOffset(mapping);
    const header = image[offset .. offset + core.cartridge.header_length];
    header[0x1C] = 0;
    header[0x1D] = 0;
    header[0x1E] = 0;
    header[0x1F] = 0;
    var sum: u16 = 0;
    for (image) |value| sum +%= value;
    const checksum = sum +% 0x01FE;
    const complement = ~checksum;
    header[0x1C] = @truncate(complement);
    header[0x1D] = @truncate(complement >> 8);
    header[0x1E] = @truncate(checksum);
    header[0x1F] = @truncate(checksum >> 8);
}
