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

test "original S-DD1 and SPC7110 streams match all pinned independent-oracle vectors" {
    const allocator = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(
        EnhancementReferences,
        allocator,
        @embedFile("enhancement_reference_cases.json"),
        .{},
    );
    defer parsed.deinit();
    try std.testing.expectEqual(@as(u8, 1), parsed.value.schema);
    try std.testing.expectEqual(@as(usize, 3), parsed.value.oracles.len);
    try std.testing.expectEqual(@as(usize, 7), parsed.value.cases.len);
    try std.testing.expectEqual(@as(usize, 2), parsed.value.trace.verified_oracles.len);
    try std.testing.expectEqualStrings("byte-identical", parsed.value.trace.result);
    try std.testing.expectEqualStrings("1a68e3f6a5e92a506b6944f99e4e9999563536fca595aabeb41d9cc75f547ad8", parsed.value.trace.sha256);

    var source: [65536]u8 = undefined;
    fillReferenceInput(&source);
    for (parsed.value.cases) |case| {
        try std.testing.expectEqual(@as(usize, 64), case.output_bytes);
        var expected: [64]u8 = undefined;
        const decoded = try std.fmt.hexToBytes(expected[0..], case.expected_hex);
        try std.testing.expectEqual(expected.len, decoded.len);

        if (std.mem.eql(u8, case.chip, "sdd1")) {
            fillReferenceInput(&source);
            source[0] = case.first_byte orelse return error.MissingSdd1Header;
            var whole = core.sdd1.Decompressor{};
            var sliced = core.sdd1.Decompressor{};
            whole.init(source[0..], .{ 0, 1, 2, 3 }, 0xC00000);
            sliced.init(source[0..], .{ 0, 1, 2, 3 }, 0xC00000);
            var actual: [64]u8 = undefined;
            var partitioned: [64]u8 = undefined;
            for (&actual) |*byte| byte.* = whole.read(source[0..], .{ 0, 1, 2, 3 });
            var at: usize = 0;
            for ([_]usize{ 1, 7, 2, 19, 3, 11, 21 }) |slice| {
                for (partitioned[at .. at + slice]) |*byte| byte.* = sliced.read(source[0..], .{ 0, 1, 2, 3 });
                at += slice;
            }
            try std.testing.expectEqual(partitioned.len, at);
            try std.testing.expectEqualSlices(u8, expected[0..], actual[0..]);
            try std.testing.expectEqualSlices(u8, actual[0..], partitioned[0..]);
        } else if (std.mem.eql(u8, case.chip, "spc7110")) {
            fillReferenceInput(&source);
            var actual: [64]u8 = undefined;
            try decodeSpcStream(source[0..], case.mode, actual[0..]);
            try std.testing.expectEqualSlices(u8, expected[0..], actual[0..]);
        } else return error.UnknownReferenceChip;
    }
}

test "S-DD1 production bus shadows DMA and streams exact bytes with bank SRAM and reset ownership" {
    const allocator = std.testing.allocator;
    const image = try makeEnhancementImage(allocator, .sdd1, 4 * 1024 * 1024, 5);
    defer allocator.free(image);
    var source: [65536]u8 = undefined;
    fillReferenceInput(&source);
    source[0] = 0x00;
    @memcpy(image[0x10000 .. 0x10000 + source.len], source[0..]);
    finalizeChecksum(image, .lo_rom);

    var cart = try core.cartridge.Cartridge.parse(allocator, image);
    defer cart.deinit();
    var bus = core.bus.Bus{};
    const mmio = core.bus.NullMmio{};
    const headers = [_]u8{ 0x00, 0x50, 0xA0, 0xF0 };
    const expected_hex = [_][]const u8{
        "2807d4fc99114a9fd4b0aa8b6b17dcadab8fff3c527ac191d506b2507e909ea8230b24d4ada73d384d6d8ab5af6a4450d7864e7bfef2fde493b9d6886b2a4bcc",
        "2807a4c5e1017343331eb71daad925bba804956013388744cf368670105faabd15bf0307aa7f540ec8c6ecb58bb15d6d50ff3aa94d1aea153f8ce98aec0276fe",
        "2807d5ff7b9db5c4a5c747f341fb49f1a43fe97faa79bcf39cfbb43f95dfb5ae497b56085e7f9391b7c3e5f7eb37adf3982e9bae73a1928c961c93deb11f97fe",
        "1029153f04a33c92299201f620fa49db9a8fb2a5582ce2605fc0c2e2830a2a2bc0f779b9aebe63b86b5091553026b226a8202833b3728ad18cef4ceb1409850a",
    };
    for (headers, expected_hex) |header, hex| {
        fillReferenceInput(&source);
        source[0] = header;
        @memcpy(cart.rom_storage[0x10000 .. 0x10000 + source.len], source[0..]);
        cart.sdd1_device.?.reset();
        var expected: [64]u8 = undefined;
        _ = try std.fmt.hexToBytes(expected[0..], hex);
        _ = bus.write(&cart, mmio, 0x004302, 0x00);
        _ = bus.write(&cart, mmio, 0x004303, 0x00);
        _ = bus.write(&cart, mmio, 0x004304, 0xC1);
        _ = bus.write(&cart, mmio, 0x004305, @intCast(expected.len));
        _ = bus.write(&cart, mmio, 0x004306, 0x00);
        try std.testing.expectEqual(core.bus.AccessClass.cartridge_chip, bus.write(&cart, mmio, 0x004800, 1).class);
        _ = bus.write(&cart, mmio, 0x004801, 1);
        var actual: [64]u8 = undefined;
        for (&actual) |*byte| {
            const access = bus.read(&cart, mmio, 0xC10000);
            try std.testing.expectEqual(core.bus.AccessClass.cartridge_chip, access.class);
            try std.testing.expectEqual(core.sdd1.access_master_cycles, access.master_cycles);
            byte.* = access.value;
        }
        try std.testing.expectEqualSlices(u8, expected[0..], actual[0..]);
        try std.testing.expectEqual(@as(u8, 0), cart.sdd1_device.?.soft_enable);
        try std.testing.expect(!cart.sdd1_device.?.dma_ready);
    }

    cart.rom_storage[0x100000] = 0xA6;
    _ = bus.write(&cart, mmio, 0x004804, 1);
    try std.testing.expectEqual(@as(u8, 0xA6), bus.read(&cart, mmio, 0xC00000).value);
    _ = bus.write(&cart, mmio, 0x006123, 0x5C);
    try std.testing.expectEqual(@as(u8, 0x5C), bus.read(&cart, mmio, 0x806123).value);
    const dirty = cart.dirtyRange().?;
    try std.testing.expectEqual(@as(usize, 0x123), dirty.first);
    try std.testing.expectEqual(@as(usize, 0x124), dirty.end);

    cart.sdd1_device.?.reset();
    try std.testing.expectEqual([4]u8{ 0, 1, 2, 3 }, cart.sdd1_device.?.banks);
    try std.testing.expectEqual(@as(u8, 0), cart.sdd1_device.?.hard_enable);
    try std.testing.expectEqual(@as(u8, 0), cart.sdd1_device.?.soft_enable);
    try std.testing.expectEqual(@as(u8, 0x5C), cart.sram_storage[0x123]);
}

test "S-DD1 and SPC7110 exact header profiles reject contradictions and unknown revisions" {
    const allocator = std.testing.allocator;
    const sdd1_battery = try makeEnhancementImage(allocator, .sdd1, 4 * 1024 * 1024, 5);
    defer allocator.free(sdd1_battery);
    var parsed_sdd1 = try core.cartridge.Cartridge.parse(allocator, sdd1_battery);
    defer parsed_sdd1.deinit();
    try std.testing.expectEqual(@as(usize, 32 * 1024), parsed_sdd1.sram().len);
    try std.testing.expect(parsed_sdd1.sdd1_device != null);

    const sdd1_plain = try makeEnhancementImage(allocator, .sdd1, 4 * 1024 * 1024, 0);
    defer allocator.free(sdd1_plain);
    setHeaderByte(sdd1_plain, .lo_rom, 0x16, 0x43);
    finalizeChecksum(sdd1_plain, .lo_rom);
    var parsed_plain = try core.cartridge.Cartridge.parse(allocator, sdd1_plain);
    defer parsed_plain.deinit();
    try std.testing.expectEqual(@as(usize, 0), parsed_plain.sram().len);
    try std.testing.expect(!parsed_plain.board.battery);

    const bad_sdd1 = try makeEnhancementImage(allocator, .sdd1, 4 * 1024 * 1024, 4);
    defer allocator.free(bad_sdd1);
    try std.testing.expectError(error.ContradictorySdd1Board, core.cartridge.Cartridge.parse(allocator, bad_sdd1));
    const unknown_sdd1 = try makeEnhancementImage(allocator, .sdd1, 4 * 1024 * 1024, 5);
    defer allocator.free(unknown_sdd1);
    setHeaderByte(unknown_sdd1, .lo_rom, 0x16, 0x44);
    finalizeChecksum(unknown_sdd1, .lo_rom);
    try std.testing.expectError(error.UnsupportedSdd1Revision, core.cartridge.Cartridge.parse(allocator, unknown_sdd1));
    {
        const large_sdd1 = try makeEnhancementImage(allocator, .sdd1, 6 * 1024 * 1024, 5);
        defer allocator.free(large_sdd1);
        var parsed_large_sdd1 = try core.cartridge.Cartridge.parse(allocator, large_sdd1);
        defer parsed_large_sdd1.deinit();
        try std.testing.expectEqual(@as(usize, 6 * 1024 * 1024), parsed_large_sdd1.rom().len);
    }

    const spc_rtc = try makeEnhancementImage(allocator, .spc7110_epson_rtc, 2 * 1024 * 1024, 3);
    defer allocator.free(spc_rtc);
    var parsed_spc_rtc = try core.cartridge.Cartridge.parse(allocator, spc_rtc);
    defer parsed_spc_rtc.deinit();
    try std.testing.expect(parsed_spc_rtc.spc7110_device.?.has_rtc);
    try std.testing.expectEqual(@as(usize, 8 * 1024), parsed_spc_rtc.sram().len);

    const spc_plain = try makeEnhancementImage(allocator, .spc7110_epson_rtc, 2 * 1024 * 1024, 3);
    defer allocator.free(spc_plain);
    setHeaderByte(spc_plain, .hi_rom, 0x16, 0xF5);
    finalizeChecksum(spc_plain, .hi_rom);
    var parsed_spc_plain = try core.cartridge.Cartridge.parse(allocator, spc_plain);
    defer parsed_spc_plain.deinit();
    try std.testing.expect(!parsed_spc_plain.spc7110_device.?.has_rtc);

    const bad_spc = try makeEnhancementImage(allocator, .spc7110_epson_rtc, 2 * 1024 * 1024, 2);
    defer allocator.free(bad_spc);
    try std.testing.expectError(error.ContradictorySpc7110Board, core.cartridge.Cartridge.parse(allocator, bad_spc));
    const unknown_spc = try makeEnhancementImage(allocator, .spc7110_epson_rtc, 2 * 1024 * 1024, 3);
    defer allocator.free(unknown_spc);
    setHeaderByte(unknown_spc, .hi_rom, 0x16, 0xFA);
    finalizeChecksum(unknown_spc, .hi_rom);
    try std.testing.expectError(error.UnsupportedSpc7110Revision, core.cartridge.Cartridge.parse(allocator, unknown_spc));
    {
        const large_spc = try makeEnhancementImage(allocator, .spc7110_epson_rtc, 6 * 1024 * 1024, 3);
        defer allocator.free(large_spc);
        var parsed_large_spc = try core.cartridge.Cartridge.parse(allocator, large_spc);
        defer parsed_large_spc.deinit();
        try std.testing.expectEqual(@as(usize, 2 * 1024 * 1024), core.spc7110.programSlice(parsed_large_spc.rom()).len);
        try std.testing.expectEqual(@as(usize, 4 * 1024 * 1024), core.spc7110.dataSlice(parsed_large_spc.rom()).len);
    }
}

test "SPC7110 production DCU emits every mode exactly and is slice deterministic" {
    const allocator = std.testing.allocator;
    const image = try makeEnhancementImage(allocator, .spc7110_epson_rtc, 2 * 1024 * 1024, 3);
    defer allocator.free(image);
    var source: [65536]u8 = undefined;
    fillReferenceInput(&source);
    @memcpy(image[0x100000 .. 0x100000 + source.len], source[0..]);
    finalizeChecksum(image, .hi_rom);
    var cart = try core.cartridge.Cartridge.parse(allocator, image);
    defer cart.deinit();
    var bus = core.bus.Bus{};
    const mmio = core.bus.NullMmio{};
    const expected_hex = [_][]const u8{
        "5db8f0155da8e0643f8983dc366583c03e7c82c1df7448c9856438d9a1441cf1b14d08f2974e00f39d36298bf6363481863617a9aaf5f74942fcf76b6abeae43",
        "3986f5a5401f11eaef2f5cf7295b72a5a35280cb5698c0572b824f00b44170c7816bd007c5dbdcd6b014e36457a86aed01fbfc7e00574a858f56246a8fe07674",
        "6dc11b23e72c5850bfd1bd95b7746c6214f3d3aa56a87ae1a25818eb23cd5c2adbc7d5246d831b28a7d39a24d66d973d305dc27028ca87328d64599696a3418e",
    };

    for (expected_hex, 0..) |hex, mode| {
        cart.rom_storage[0x1F0000] = @intCast(mode);
        cart.rom_storage[0x1F0001] = 0;
        cart.rom_storage[0x1F0002] = 0;
        cart.rom_storage[0x1F0003] = 0;
        cart.spc7110_device.?.reset();
        _ = bus.write(&cart, mmio, 0x004801, 0x00);
        _ = bus.write(&cart, mmio, 0x004802, 0x00);
        _ = bus.write(&cart, mmio, 0x004803, 0x0F);
        _ = bus.write(&cart, mmio, 0x004804, 0x00);
        _ = bus.write(&cart, mmio, 0x004806, 0x00);
        try std.testing.expectEqual(core.spc7110.Fault.none, cart.spc7110_device.?.fault);
        var actual: [64]u8 = undefined;
        var at: usize = 0;
        for ([_]usize{ 3, 1, 12, 5, 17, 26 }) |slice| {
            for (actual[at .. at + slice]) |*byte| {
                const access = bus.read(&cart, mmio, 0x004800);
                try std.testing.expectEqual(core.bus.AccessClass.cartridge_chip, access.class);
                try std.testing.expectEqual(core.spc7110.access_master_cycles, access.master_cycles);
                byte.* = access.value;
            }
            at += slice;
        }
        var expected: [64]u8 = undefined;
        _ = try std.fmt.hexToBytes(expected[0..], hex);
        try std.testing.expectEqualSlices(u8, expected[0..], actual[0..]);
    }
    for ([_]u8{ 3, 4 }) |invalid_mode| {
        cart.rom_storage[0x1F0000] = invalid_mode;
        cart.spc7110_device.?.reset();
        _ = bus.write(&cart, mmio, 0x004801, 0x00);
        _ = bus.write(&cart, mmio, 0x004802, 0x00);
        _ = bus.write(&cart, mmio, 0x004803, 0x0F);
        _ = bus.write(&cart, mmio, 0x004804, 0x00);
        _ = bus.write(&cart, mmio, 0x004806, 0x00);
        try std.testing.expectEqual(core.spc7110.Fault.invalid_decompression_mode, cart.spc7110_device.?.fault);
        try std.testing.expectEqual(@as(u8, 0), bus.read(&cart, mmio, 0x004800).value);
    }
}

test "SPC7110 data port mapping arithmetic SRAM gate reset and open bus are exact" {
    const allocator = std.testing.allocator;
    const image = try makeEnhancementImage(allocator, .spc7110_epson_rtc, 2 * 1024 * 1024, 3);
    defer allocator.free(image);
    image[0] = 0x11;
    image[0x100000] = 0x22;
    image[0x100123] = 0xA1;
    image[0x100124] = 0xA2;
    image[0x100125] = 0xA5;
    image[0x100127] = 0xA7;
    image[0x100128] = 0xA8;
    finalizeChecksum(image, .hi_rom);
    var cart = try core.cartridge.Cartridge.parse(allocator, image);
    defer cart.deinit();
    var bus = core.bus.Bus{};
    const mmio = core.bus.NullMmio{};

    try std.testing.expectEqual(@as(u8, 0x11), bus.read(&cart, mmio, 0xC00000).value);
    try std.testing.expectEqual(@as(u8, 0x22), bus.read(&cart, mmio, 0xD00000).value);
    _ = bus.write(&cart, mmio, 0x004834, 4);
    try std.testing.expectEqual(@as(u8, 0x11), bus.read(&cart, mmio, 0xD00000).value);
    _ = bus.write(&cart, mmio, 0x004834, 0);
    _ = bus.write(&cart, mmio, 0x004811, 0x23);
    _ = bus.write(&cart, mmio, 0x004812, 0x01);
    _ = bus.write(&cart, mmio, 0x004813, 0x00);
    try std.testing.expectEqual(@as(u8, 0xA1), bus.read(&cart, mmio, 0x004810).value);
    try std.testing.expectEqual(@as(u8, 0xA2), bus.read(&cart, mmio, 0x004810).value);
    _ = bus.write(&cart, mmio, 0x004816, 3);
    _ = bus.write(&cart, mmio, 0x004817, 0);
    _ = bus.write(&cart, mmio, 0x004818, 1);
    try std.testing.expectEqual(@as(u8, 0xA5), bus.read(&cart, mmio, 0x004810).value);
    try std.testing.expectEqual(@as(u8, 0xA8), bus.read(&cart, mmio, 0x004810).value);

    cart.spc7110_device.?.reset();
    _ = bus.write(&cart, mmio, 0x004811, 0x23);
    _ = bus.write(&cart, mmio, 0x004812, 0x01);
    _ = bus.write(&cart, mmio, 0x004813, 0x00);
    _ = bus.write(&cart, mmio, 0x004818, 0x02);
    _ = bus.write(&cart, mmio, 0x004814, 4);
    try std.testing.expectEqual(@as(u8, 0xA1), bus.read(&cart, mmio, 0x004810).value);
    cart.spc7110_device.?.reset();
    _ = bus.write(&cart, mmio, 0x004811, 0x23);
    _ = bus.write(&cart, mmio, 0x004812, 0x01);
    _ = bus.write(&cart, mmio, 0x004813, 0x00);
    _ = bus.write(&cart, mmio, 0x004818, 0x20);
    _ = bus.write(&cart, mmio, 0x004814, 4);
    try std.testing.expectEqual(@as(u8, 0xA7), bus.read(&cart, mmio, 0x004810).value);

    _ = bus.write(&cart, mmio, 0x004820, 0x34);
    _ = bus.write(&cart, mmio, 0x004821, 0x12);
    _ = bus.write(&cart, mmio, 0x004824, 0x10);
    _ = bus.write(&cart, mmio, 0x004825, 0x00);
    try expectPorts(&bus, &cart, mmio, 0x4828, &.{ 0x40, 0x23, 0x01, 0x00 });
    _ = bus.write(&cart, mmio, 0x00482E, 1);
    _ = bus.write(&cart, mmio, 0x004820, 0xFE);
    _ = bus.write(&cart, mmio, 0x004821, 0xFF);
    _ = bus.write(&cart, mmio, 0x004824, 3);
    _ = bus.write(&cart, mmio, 0x004825, 0);
    try expectPorts(&bus, &cart, mmio, 0x4828, &.{ 0xFA, 0xFF, 0xFF, 0xFF });
    _ = bus.write(&cart, mmio, 0x00482E, 0);
    _ = bus.write(&cart, mmio, 0x004820, 0xE8);
    _ = bus.write(&cart, mmio, 0x004821, 0x03);
    _ = bus.write(&cart, mmio, 0x004822, 0);
    _ = bus.write(&cart, mmio, 0x004823, 0);
    _ = bus.write(&cart, mmio, 0x004826, 7);
    _ = bus.write(&cart, mmio, 0x004827, 0);
    try expectPorts(&bus, &cart, mmio, 0x4828, &.{ 0x8E, 0, 0, 0, 6, 0 });
    _ = bus.write(&cart, mmio, 0x004826, 0);
    _ = bus.write(&cart, mmio, 0x004827, 0);
    try expectPorts(&bus, &cart, mmio, 0x4828, &.{ 0, 0, 0, 0, 0xE8, 0x03 });

    try std.testing.expectEqual(@as(u8, 0), bus.read(&cart, mmio, 0x006000).value);
    _ = bus.write(&cart, mmio, 0x004830, 0x80);
    _ = bus.write(&cart, mmio, 0x006000, 0x5E);
    try std.testing.expectEqual(@as(u8, 0x5E), bus.read(&cart, mmio, 0x806000).value);
    try std.testing.expect(cart.sram_dirty);
    cart.spc7110_device.?.reset();
    try std.testing.expectEqual(@as(u8, 0), cart.spc7110_device.?.regs[0x30]);
    try std.testing.expectEqual(@as(u8, 1), cart.spc7110_device.?.regs[0x32]);
    try std.testing.expectEqual(@as(u8, 2), cart.spc7110_device.?.regs[0x33]);
    bus.cpu_open_bus = 0xC7;
    const chip_open = bus.read(&cart, mmio, 0x00483F);
    try std.testing.expectEqual(core.bus.AccessClass.cartridge_chip, chip_open.class);
    try std.testing.expectEqual(@as(u8, 0xC7), chip_open.value);
    try std.testing.expectEqual(@as(u8, 0xC7), bus.read(&cart, mmio, 0x004819).value);
    try std.testing.expectEqual(core.bus.AccessClass.open_bus, bus.read(&cart, mmio, 0x004900).class);
    try std.testing.expectEqual(@as(u8, 0xC7), bus.read(&cart, mmio, 0x004900).value);
}

test "Epson RTC protocol validates BCD calendar status stop reset leap and century wrap" {
    var rtc = core.epson_rtc.Device{};
    rtc.power();
    const leap = [16]u8{ 8, 5, 9, 5, 3, 2, 9, 2, 2, 0, 4, 2, 4, 2, 0, 4 };
    writeEpsonRegisters(&rtc, leap);
    try std.testing.expect(!rtc.isHalted());
    try std.testing.expectEqual(@as(u8, 4), rtc.readPort(0x4841, 0));
    try std.testing.expect((rtc.readPort(0x4842, 0) & 0x80) != 0);
    try std.testing.expectEqual(@as(u8, 0x80), rtc.readPort(0x4842, 0));
    rtc.advanceSeconds(2);
    const march = try core.epson_rtc.calendarFromRegisters(&rtc.live);
    try std.testing.expectEqual(@as(u8, 0), march.second);
    try std.testing.expectEqual(@as(u8, 1), march.day);
    try std.testing.expectEqual(@as(u8, 3), march.month);

    writeEpsonRegister(&rtc, 15, 0);
    const midnight12 = [16]u8{ 0, 8, 0, 8, 2, 9, 1, 8, 3, 8, 4, 2, 0x0D, 2, 0, 0 };
    writeEpsonRegisters(&rtc, midnight12);
    const twelve_hour = try core.epson_rtc.calendarFromRegisters(&rtc.live);
    try std.testing.expectEqual(@as(u8, 0), twelve_hour.hour);
    try std.testing.expectEqual(@as(u8, 5), twelve_hour.weekday);
    writeEpsonRegister(&rtc, 5, 0x0D);
    try std.testing.expectEqual(@as(u8, 12), (try core.epson_rtc.calendarFromRegisters(&rtc.live)).hour);

    writeEpsonRegister(&rtc, 0, 7);
    writeEpsonRegister(&rtc, 1, 3);
    const minute_before_round = (try core.epson_rtc.calendarFromRegisters(&rtc.live)).minute;
    writeEpsonRegister(&rtc, 13, 0x0A);
    const rounded = try core.epson_rtc.calendarFromRegisters(&rtc.live);
    try std.testing.expectEqual(@as(u8, 0), rounded.second);
    try std.testing.expectEqual(@as(u8, minute_before_round + 1), rounded.minute);
    writeEpsonRegister(&rtc, 13, 3);
    const held = rtc.live;
    rtc.advanceSeconds(3600);
    try std.testing.expectEqualSlices(u8, held[0..], rtc.live[0..]);
    writeEpsonRegister(&rtc, 13, 2);
    try std.testing.expectEqual(@as(u8, 1), (try core.epson_rtc.calendarFromRegisters(&rtc.live)).second);

    _ = rtc.writePort(0x4840, 1);
    _ = rtc.writePort(0x4841, 0x0C);
    _ = rtc.writePort(0x4841, 6);
    try std.testing.expectEqual(@as(u8, 1), rtc.readPort(0x4841, 0));
    try std.testing.expectEqual(@as(u8, 8), rtc.readPort(0x4841, 0));

    const last_good = rtc.live;
    const invalid = [16]u8{ 0, 0, 0, 0, 2, 1, 0, 3, 2, 0, 5, 2, 4, 2, 0, 4 };
    writeEpsonRegisters(&rtc, invalid);
    try std.testing.expectEqual(core.epson_rtc.Fault.invalid_write, rtc.fault);
    _ = try core.epson_rtc.calendarFromRegisters(&rtc.live);
    try std.testing.expect(!std.mem.eql(u8, invalid[0..], rtc.live[0..]));
    try std.testing.expect(!std.mem.eql(u8, last_good[0..], invalid[0..]));

    var stopped = leap;
    stopped[0] = 7;
    stopped[1] = 3;
    stopped[15] = 5;
    writeEpsonRegisters(&rtc, stopped);
    try std.testing.expect(rtc.isHalted());
    try std.testing.expectEqual(@as(u8, 0), rtc.live[0]);
    try std.testing.expectEqual(@as(u8, 0), rtc.live[1]);
    const frozen = rtc.live;
    rtc.advanceSeconds(3600);
    try std.testing.expectEqualSlices(u8, frozen[0..], rtc.live[0..]);

    const wrap = [16]u8{ 9, 5, 9, 5, 3, 2, 1, 3, 2, 1, 9, 8, 6, 2, 0, 4 };
    writeEpsonRegisters(&rtc, wrap);
    rtc.advanceSeconds(1);
    const wrapped = try core.epson_rtc.calendarFromRegisters(&rtc.live);
    try std.testing.expectEqual(@as(u8, 90), wrapped.year);
    try std.testing.expectEqual(@as(u8, 1), wrapped.day);
    try std.testing.expectEqual(@as(u8, 1), wrapped.month);
    try std.testing.expect(rtc.overflow);
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

const EnhancementReferences = struct {
    schema: u8,
    generator: struct {
        algorithm: []const u8,
        seed: u32,
        multiplier: u32,
        increment: u32,
        input_bytes: usize,
    },
    trace: struct {
        format: []const u8,
        sha256: []const u8,
        verified_oracles: []const []const u8,
        result: []const u8,
        cases: usize,
    },
    oracles: []const struct {
        name: []const u8,
        verification: []const u8,
        sdd1: []const u8,
        spc7110: []const u8,
    },
    cases: []const struct {
        id: []const u8,
        chip: []const u8,
        mode: u8,
        first_byte: ?u8,
        output_bytes: usize,
        expected_hex: []const u8,
    },
};

fn fillReferenceInput(bytes: *[65536]u8) void {
    var state: u32 = 0x12345678;
    for (bytes) |*byte| {
        state = state *% 1664525 +% 1013904223;
        byte.* = @truncate(state >> 24);
    }
}

fn decodeSpcStream(data: []const u8, mode: u8, output: []u8) !void {
    var decoder = core.spc7110.Decompressor{};
    try decoder.init(data, mode, 0);
    _ = decoder.decode(data);
    var at: usize = 0;
    while (at < output.len) {
        var tile: [32]u8 = .{0} ** 32;
        for (0..8) |row| {
            const result = decoder.result;
            switch (decoder.bpp) {
                1 => tile[row] = @truncate(result),
                2 => {
                    tile[row * 2] = @truncate(result);
                    tile[row * 2 + 1] = @truncate(result >> 8);
                },
                4 => {
                    tile[row * 2] = @truncate(result);
                    tile[row * 2 + 1] = @truncate(result >> 8);
                    tile[row * 2 + 16] = @truncate(result >> 16);
                    tile[row * 2 + 17] = @truncate(result >> 24);
                },
                else => return error.InvalidSpcBpp,
            }
            _ = decoder.decode(data);
        }
        const tile_bytes: usize = @as(usize, decoder.bpp) * 8;
        const count = @min(tile_bytes, output.len - at);
        @memcpy(output[at .. at + count], tile[0..count]);
        at += count;
    }
}

fn expectPorts(
    bus: *core.bus.Bus,
    cart: *core.cartridge.Cartridge,
    mmio: core.bus.NullMmio,
    first: u16,
    expected: []const u8,
) !void {
    for (expected, 0..) |value, index| {
        const address = @as(u32, first) + @as(u32, @intCast(index));
        try std.testing.expectEqual(value, bus.read(cart, mmio, address).value);
    }
}

fn writeEpsonRegisters(device: *core.epson_rtc.Device, registers: [16]u8) void {
    _ = device.writePort(0x4840, 1);
    _ = device.writePort(0x4841, 0x03);
    _ = device.writePort(0x4841, 0);
    for (registers) |value| _ = device.writePort(0x4841, value);
}

fn writeEpsonRegister(device: *core.epson_rtc.Device, index: u8, value: u8) void {
    _ = device.writePort(0x4840, 1);
    _ = device.writePort(0x4841, 0x03);
    _ = device.writePort(0x4841, index);
    _ = device.writePort(0x4841, value);
}

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
        .obc1, .sdd1 => .lo_rom,
        .spc7110_epson_rtc => .hi_rom,
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
        .sdd1 => 0x32,
        .spc7110_epson_rtc => 0x3A,
        .srtc => 0x35,
        else => unreachable,
    };
    header[0x16] = switch (enhancement) {
        .obc1 => 0x25,
        .sdd1 => 0x45,
        .spc7110_epson_rtc => 0xF9,
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
