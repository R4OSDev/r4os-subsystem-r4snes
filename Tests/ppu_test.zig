const std = @import("std");
const core = @import("core");

test "PPU VRAM CGRAM and OAM ports preserve latches remapping and active-display locks" {
    var ppu = core.ppu.Ppu{};

    write(&ppu, 0x2115, 0x81);
    write(&ppu, 0x2116, 0x01);
    write(&ppu, 0x2117, 0x00);
    write(&ppu, 0x2118, 0xaa);
    write(&ppu, 0x2119, 0xbb);
    try std.testing.expectEqual(@as(u8, 0xaa), ppu.vram[2]);
    try std.testing.expectEqual(@as(u8, 0xbb), ppu.vram[3]);
    try std.testing.expectEqual(@as(u16, 33), ppu.vram_address);

    write(&ppu, 0x2115, 0x84);
    write(&ppu, 0x2116, 0x23);
    write(&ppu, 0x2117, 0x01);
    write(&ppu, 0x2118, 0x5a);
    write(&ppu, 0x2119, 0xa5);
    const remapped: usize = ((0x0123 & 0xff00) | ((0x0123 & 0x001f) << 3) | ((0x0123 & 0x00e0) >> 5)) * 2;
    try std.testing.expectEqual(@as(u8, 0x5a), ppu.vram[remapped]);
    try std.testing.expectEqual(@as(u8, 0xa5), ppu.vram[remapped + 1]);

    write(&ppu, 0x2121, 3);
    write(&ppu, 0x2122, 0x34);
    write(&ppu, 0x2122, 0xff);
    try std.testing.expectEqualSlices(u8, &.{ 0x34, 0x7f }, ppu.cgram[6..8]);
    write(&ppu, 0x2121, 3);
    try std.testing.expectEqual(@as(u8, 0x34), ppu.read(0x213b, 0, 0).value);
    try std.testing.expectEqual(@as(u8, 0xff), ppu.read(0x213b, 0, 0x80).value);

    write(&ppu, 0x2102, 0);
    write(&ppu, 0x2103, 0);
    write(&ppu, 0x2104, 0x12);
    try std.testing.expectEqual(@as(u8, 0), ppu.oam[0]);
    write(&ppu, 0x2104, 0x34);
    try std.testing.expectEqualSlices(u8, &.{ 0x12, 0x34 }, ppu.oam[0..2]);
    write(&ppu, 0x2102, 0);
    write(&ppu, 0x2103, 1);
    write(&ppu, 0x2104, 0x56);
    try std.testing.expectEqual(@as(u8, 0x56), ppu.oam[512]);

    write(&ppu, 0x2100, 0x0f);
    ppu.setBeam(100, 1, 0);
    const before = ppu.vram[0];
    write(&ppu, 0x2115, 0x80);
    write(&ppu, 0x2116, 0);
    write(&ppu, 0x2117, 0);
    write(&ppu, 0x2118, before +% 1);
    try std.testing.expectEqual(before, ppu.vram[0]);

    ppu.cgram_internal_address = 7;
    write(&ppu, 0x2121, 2);
    write(&ppu, 0x2122, 0xcd);
    write(&ppu, 0x2122, 0xab);
    try std.testing.expectEqualSlices(u8, &.{ 0xcd, 0x2b }, ppu.cgram[14..16]);
    try std.testing.expectEqual(@as(u8, 0), ppu.cgram[4]);

    ppu.setBeam(0, ppu.visibleHeight() + 1, 0);
    write(&ppu, 0x2116, 0);
    write(&ppu, 0x2117, 0);
    write(&ppu, 0x2118, 0x99);
    try std.testing.expectEqual(@as(u8, 0x99), ppu.vram[0]);
}

test "PPU modes zero through four produce exact repeatable pixel generations" {
    const expected_colours = [_]u32{ 0xffff0000, 0xff00ff00, 0xff0000ff, 0xffffff00, 0xffff00ff };
    const expected_digests = [_]u64{
        0x84eefc2777a6e325,
        0xa71592d0a1312325,
        0xf24128f9b0f3e325,
        0x488f665ded0f2325,
        0x9ef804ce64d52325,
    };
    for (0..5) |mode| {
        var ppu = core.ppu.Ppu{};
        hideAllSprites(&ppu);
        const colour_index: u8 = @intCast(mode + 1);
        configureSolidBackground(&ppu, @intCast(mode), colour_index, colourForMode(mode));
        const info = ppu.renderCompleteFrame();
        try std.testing.expectEqual(@as(u16, 256), info.width);
        try std.testing.expectEqual(@as(u16, 224), info.height);
        try std.testing.expectEqual(@as(u64, 1), info.generation);
        try std.testing.expectEqual(expected_colours[mode], ppu.published_frame[0]);
        try std.testing.expectEqual(expected_colours[mode], ppu.published_frame[223 * 256 + 255]);
        try std.testing.expectEqual(expected_digests[mode], info.digest);

        var repeat = core.ppu.Ppu{};
        hideAllSprites(&repeat);
        configureSolidBackground(&repeat, @intCast(mode), colour_index, colourForMode(mode));
        try std.testing.expectEqual(info.digest, repeat.renderCompleteFrame().digest);
    }
}

test "PPU sprite evaluation applies transparency flip size priority and overflow limits" {
    var ppu = core.ppu.Ppu{};
    hideAllSprites(&ppu);
    setColour(&ppu, 129, 0x001f);
    setVramWord(&ppu, 0, 0x0080);
    ppu.oam[0] = 10;
    ppu.oam[1] = 5;
    ppu.oam[2] = 0;
    ppu.oam[3] = 0x30;
    ppu.prepareSpriteLine(5);
    try std.testing.expect(ppu.object_present[10]);
    try std.testing.expect(!ppu.object_present[11]);
    try std.testing.expectEqual(@as(u2, 3), ppu.object_priority[10]);

    ppu.oam[3] = 0x70;
    ppu.sprite_line_valid = false;
    ppu.prepareSpriteLine(5);
    try std.testing.expect(!ppu.object_present[10]);
    try std.testing.expect(ppu.object_present[17]);

    hideAllSprites(&ppu);
    write(&ppu, 0x2101, 3 << 5);
    var sprite: usize = 0;
    while (sprite < 33) : (sprite += 1) {
        ppu.oam[sprite * 4] = @intCast((sprite * 8) & 0xff);
        ppu.oam[sprite * 4 + 1] = 20;
    }
    ppu.prepareSpriteLine(20);
    try std.testing.expect(ppu.range_over);
    try std.testing.expect(ppu.time_over);
    try std.testing.expectEqual(@as(u8, 0xc1), ppu.read(0x213e, 0, 0).value);
}

test "PPU complete generations are copied snapshots independent of later frames and host waits" {
    var ppu = core.ppu.Ppu{};
    hideAllSprites(&ppu);
    configureSolidBackground(&ppu, 0, 1, 0x001f);
    const first_info = ppu.renderCompleteFrame();
    var first: [core.ppu.frame_width * core.ppu.overscan_height]u32 = undefined;
    _ = try ppu.copyFrame(first[0..]);

    setColour(&ppu, 1, 0x03e0);
    const second_info = ppu.renderCompleteFrame();
    var second: [core.ppu.frame_width * core.ppu.overscan_height]u32 = undefined;
    _ = try ppu.copyFrame(second[0..]);
    try std.testing.expectEqual(@as(u64, 1), first_info.generation);
    try std.testing.expectEqual(@as(u64, 2), second_info.generation);
    try std.testing.expect(first_info.digest != second_info.digest);
    try std.testing.expectEqual(@as(u32, 0xffff0000), first[0]);
    try std.testing.expectEqual(@as(u32, 0xff00ff00), second[0]);
    try std.testing.expectEqual(@as(u32, 0xffff0000), first[0]);
    try std.testing.expectError(error.FrameBufferTooSmall, ppu.copyFrame(second[0..100]));

    write(&ppu, 0x2133, 0x04);
    const overscan = ppu.renderCompleteFrame();
    try std.testing.expectEqual(@as(u16, 239), overscan.height);
}

test "PPU publishes every native hires overscan and interlace geometry without unchanged generations" {
    const Case = struct { mode: u3, setini: u8, width: u16, height: u16 };
    const cases = [_]Case{
        .{ .mode = 0, .setini = 0x00, .width = 256, .height = 224 },
        .{ .mode = 0, .setini = 0x04, .width = 256, .height = 239 },
        .{ .mode = 0, .setini = 0x01, .width = 256, .height = 448 },
        .{ .mode = 0, .setini = 0x05, .width = 256, .height = 478 },
        .{ .mode = 5, .setini = 0x00, .width = 512, .height = 224 },
        .{ .mode = 5, .setini = 0x04, .width = 512, .height = 239 },
        .{ .mode = 5, .setini = 0x01, .width = 512, .height = 448 },
        .{ .mode = 5, .setini = 0x05, .width = 512, .height = 478 },
        .{ .mode = 0, .setini = 0x08, .width = 512, .height = 224 },
    };
    for (cases) |case| {
        var ppu = core.ppu.Ppu{};
        hideAllSprites(&ppu);
        write(&ppu, 0x2105, case.mode);
        write(&ppu, 0x2133, case.setini);
        const first = ppu.renderCompleteFrame();
        try std.testing.expectEqual(case.width, first.width);
        try std.testing.expectEqual(case.height, first.height);
        try std.testing.expectEqual(@as(u64, 1), first.generation);
        const damage = ppu.takeDamage().?;
        try std.testing.expectEqual(case.width, damage.width);
        try std.testing.expectEqual(case.height, damage.height);
        const unchanged = ppu.renderCompleteFrame();
        try std.testing.expectEqual(first.generation, unchanged.generation);
        try std.testing.expect(ppu.takeDamage() == null);
    }
}

test "PPU modes five six and seven produce exact native pixel generations" {
    const Case = struct { mode: u3, colour_index: u8, colour: u16, pixel: u32, digest: u64 };
    const planar_cases = [_]Case{
        .{ .mode = 5, .colour_index = 6, .colour = 0x03ff, .pixel = 0xffffff00, .digest = 0x0e1cf24d55fc2325 },
        .{ .mode = 6, .colour_index = 7, .colour = 0x7fe0, .pixel = 0xff00ffff, .digest = 0x4d176b91742c2325 },
    };
    for (planar_cases) |case| {
        var ppu = core.ppu.Ppu{};
        hideAllSprites(&ppu);
        configureSolidBackground(&ppu, case.mode, case.colour_index, case.colour);
        const info = ppu.renderCompleteFrame();
        try std.testing.expectEqual(@as(u16, 512), info.width);
        try std.testing.expectEqual(case.pixel, ppu.published_frame[0]);
        try std.testing.expectEqual(case.pixel, ppu.published_frame[511]);
        try std.testing.expectEqual(case.digest, info.digest);
        if (case.mode == 5) {
            write(&ppu, 0x212d, 0);
            _ = ppu.renderCompleteFrame();
            try std.testing.expectEqual(@as(u32, 0xff000000), ppu.published_frame[0]);
            try std.testing.expectEqual(case.pixel, ppu.published_frame[1]);
        }
    }

    var mode7 = core.ppu.Ppu{};
    hideAllSprites(&mode7);
    configureMode7Identity(&mode7, 0x001f, false);
    const base = mode7.renderCompleteFrame();
    try std.testing.expectEqual(@as(u16, 256), base.width);
    try std.testing.expectEqual(@as(u32, 0xffff0000), mode7.published_frame[0]);
    try std.testing.expectEqual(@as(u32, 0xffff0000), mode7.published_frame[223 * 256 + 255]);
    try std.testing.expectEqual(@as(u64, 0x84eefc2777a6e325), base.digest);

    configureMode7Identity(&mode7, 0x03e0, true);
    const extbg = mode7.renderCompleteFrame();
    try std.testing.expect(extbg.digest != base.digest);
    try std.testing.expectEqual(@as(u32, 0xff00ff00), mode7.published_frame[0]);
    try std.testing.expectEqual(@as(u64, 0xa71592d0a1312325), extbg.digest);

    write(&mode7, 0x211b, 0x00);
    write(&mode7, 0x211b, 0x01);
    write(&mode7, 0x211c, 0x00);
    write(&mode7, 0x211c, 0x02);
    try std.testing.expectEqual(@as(u8, 0x00), mode7.read(0x2134, 0, 0).value);
    try std.testing.expectEqual(@as(u8, 0x02), mode7.read(0x2135, 0, 0).value);
    try std.testing.expectEqual(@as(u8, 0x00), mode7.read(0x2136, 0, 0).value);
}

test "PPU windows fixed color math mosaic and mid scanline writes are pixel exact" {
    var ppu = core.ppu.Ppu{};
    hideAllSprites(&ppu);
    configureSolidBackground(&ppu, 1, 1, 0x001f);
    write(&ppu, 0x2132, 0x5f); // fixed green = 31
    write(&ppu, 0x2131, 0x01); // BG1 add
    write(&ppu, 0x2125, 0x20); // color window 1 enabled
    write(&ppu, 0x2126, 64);
    write(&ppu, 0x2127, 127);
    write(&ppu, 0x2130, 0x10); // math only inside color window
    _ = ppu.renderCompleteFrame();
    try std.testing.expectEqual(@as(u64, 0x18e3f9c9ab60f325), ppu.frameInfo().digest);
    try std.testing.expectEqual(@as(u32, 0xffff0000), ppu.published_frame[63]);
    try std.testing.expectEqual(@as(u32, 0xffffff00), ppu.published_frame[64]);
    try std.testing.expectEqual(@as(u32, 0xffffff00), ppu.published_frame[127]);
    try std.testing.expectEqual(@as(u32, 0xffff0000), ppu.published_frame[128]);

    write(&ppu, 0x2123, 0x02); // BG1 window 1 enabled
    write(&ppu, 0x212e, 0x01);
    _ = ppu.renderCompleteFrame();
    try std.testing.expectEqual(@as(u64, 0x6b59fc2d52c67325), ppu.frameInfo().digest);
    try std.testing.expectEqual(@as(u32, 0xff000000), ppu.published_frame[64]);

    var mosaic = core.ppu.Ppu{};
    hideAllSprites(&mosaic);
    configureStripedBackground(&mosaic);
    write(&mosaic, 0x2106, 0x31); // groups of four on BG1
    _ = mosaic.renderCompleteFrame();
    try std.testing.expectEqual(@as(u64, 0xfc18121383760325), mosaic.frameInfo().digest);
    try std.testing.expectEqual(mosaic.published_frame[0], mosaic.published_frame[3]);
    try std.testing.expect(mosaic.published_frame[3] != mosaic.published_frame[4]);

    var timed = core.ppu.Ppu{};
    hideAllSprites(&timed);
    configureSolidBackground(&timed, 1, 1, 0x001f);
    var clock = core.timing.Clock.init(.ntsc);
    timed.onMasterTick(&clock);
    clock.v_counter = 1;
    var x: u16 = 0;
    while (x < 256) : (x += 1) {
        if (x == 128) write(&timed, 0x2100, 0x80);
        clock.h_counter = 88 + x * 4;
        timed.onMasterTick(&clock);
    }
    try std.testing.expectEqual(@as(u32, 0xffff0000), timed.working_frame[127]);
    try std.testing.expectEqual(@as(u32, 0xff000000), timed.working_frame[128]);
}

test "PPU pseudo hires window logic clipping and subscreen math preserve screen roles" {
    var ppu = core.ppu.Ppu{};
    hideAllSprites(&ppu);
    configureTwoMode0Screens(&ppu);
    write(&ppu, 0x2133, 0x08);
    _ = ppu.renderCompleteFrame();
    try std.testing.expectEqual(@as(u16, 512), ppu.frameInfo().width);
    try std.testing.expectEqual(@as(u32, 0xff00ff00), ppu.published_frame[0]);
    try std.testing.expectEqual(@as(u32, 0xffff0000), ppu.published_frame[1]);

    write(&ppu, 0x2133, 0);
    write(&ppu, 0x2123, 0x0a); // BG1 uses both windows
    write(&ppu, 0x2126, 10);
    write(&ppu, 0x2127, 20);
    write(&ppu, 0x2128, 15);
    write(&ppu, 0x2129, 25);
    write(&ppu, 0x212e, 0x01);
    const expected_visible = [_][4]bool{
        .{ true, false, false, false }, // OR: 0 visible, 12/17/23 masked
        .{ true, true, false, true }, // AND: only overlap masked
        .{ true, false, true, false }, // XOR: overlap visible
        .{ false, true, false, true }, // XNOR: outside and overlap masked
    };
    for (0..4) |logic| {
        write(&ppu, 0x212a, @intCast(logic));
        _ = ppu.renderCompleteFrame();
        const samples = [_]usize{ 0, 12, 17, 23 };
        for (samples, 0..) |sample, index| {
            const expected: u32 = if (expected_visible[logic][index]) 0xffff0000 else 0xff000000;
            try std.testing.expectEqual(expected, ppu.published_frame[sample]);
        }
    }

    write(&ppu, 0x212e, 0);
    write(&ppu, 0x2130, 0x02); // subscreen is the math operand
    write(&ppu, 0x2131, 0x01);
    _ = ppu.renderCompleteFrame();
    try std.testing.expectEqual(@as(u32, 0xffffff00), ppu.published_frame[0]);
    write(&ppu, 0x2131, 0x41);
    _ = ppu.renderCompleteFrame();
    try std.testing.expectEqual(@as(u32, 0xff7b7b00), ppu.published_frame[0]);

    setColour(&ppu, 1, 0x03ff);
    write(&ppu, 0x2131, 0x81);
    _ = ppu.renderCompleteFrame();
    try std.testing.expectEqual(@as(u32, 0xffff0000), ppu.published_frame[0]);

    write(&ppu, 0x2131, 0);
    write(&ppu, 0x2125, 0x20); // color window 1
    write(&ppu, 0x2130, 0x40); // main color only inside
    _ = ppu.renderCompleteFrame();
    try std.testing.expectEqual(@as(u32, 0xff000000), ppu.published_frame[0]);
    try std.testing.expectEqual(@as(u32, 0xffffff00), ppu.published_frame[10]);
}

test "PPU Mode 7 origin flip and outside repeat paths are deterministic" {
    var ppu = core.ppu.Ppu{};
    hideAllSprites(&ppu);
    configureMode7Identity(&ppu, 0x001f, false);
    setVramWord(&ppu, 0, 0x0100);
    setVramWord(&ppu, 1, 0x0200);
    setVramWord(&ppu, 7, 0x0200);
    setColour(&ppu, 1, 0x001f);
    setColour(&ppu, 2, 0x03e0);
    _ = ppu.renderCompleteFrame();
    try std.testing.expectEqual(@as(u32, 0xffff0000), ppu.published_frame[0]);
    try std.testing.expectEqual(@as(u32, 0xff00ff00), ppu.published_frame[1]);

    write(&ppu, 0x211a, 0x01);
    _ = ppu.renderCompleteFrame();
    try std.testing.expectEqual(@as(u32, 0xff00ff00), ppu.published_frame[0]);

    write(&ppu, 0x211a, 0);
    ppu.backgrounds[0].horizontal_scroll = 1;
    _ = ppu.renderCompleteFrame();
    try std.testing.expectEqual(@as(u32, 0xff00ff00), ppu.published_frame[0]);

    ppu.backgrounds[0].horizontal_scroll = 1023;
    write(&ppu, 0x211a, 0x40); // outside becomes transparent
    _ = ppu.renderCompleteFrame();
    try std.testing.expectEqual(@as(u32, 0xff000000), ppu.published_frame[1]);
    write(&ppu, 0x211a, 0xc0); // outside samples tile zero
    _ = ppu.renderCompleteFrame();
    try std.testing.expectEqual(@as(u32, 0xffff0000), ppu.published_frame[1]);
}

test "PPU interlace publishes only after a complete pair of fields and synchronizes the clock" {
    var ppu = core.ppu.Ppu{};
    write(&ppu, 0x2133, 0x01);
    var clock = core.timing.Clock.init(.ntsc);
    ppu.synchronizeClock(&clock);
    try std.testing.expect(clock.interlace);
    ppu.onMasterTick(&clock);
    clock.v_counter = ppu.visibleHeight() + 1;
    ppu.onMasterTick(&clock);
    try std.testing.expectEqual(@as(u64, 0), ppu.frame_generation);
    clock.v_counter = 0;
    clock.field = true;
    clock.frame = 1;
    ppu.onMasterTick(&clock);
    clock.v_counter = ppu.visibleHeight() + 1;
    ppu.onMasterTick(&clock);
    try std.testing.expectEqual(@as(u64, 1), ppu.frame_generation);
    try std.testing.expectEqual(@as(u16, 448), ppu.frameInfo().height);
}

fn write(ppu: *core.ppu.Ppu, address: u32, value: u8) void {
    std.debug.assert(ppu.write(address, value, 0, 0));
}

fn setVramWord(ppu: *core.ppu.Ppu, word: u16, value: u16) void {
    const index = @as(usize, word & 0x7fff) * 2;
    ppu.vram[index] = @truncate(value);
    ppu.vram[index + 1] = @truncate(value >> 8);
}

fn setColour(ppu: *core.ppu.Ppu, index: u16, value: u16) void {
    const byte = @as(usize, index & 0xff) * 2;
    ppu.cgram[byte] = @truncate(value);
    ppu.cgram[byte + 1] = @truncate(value >> 8);
}

fn hideAllSprites(ppu: *core.ppu.Ppu) void {
    for (0..128) |sprite| ppu.oam[sprite * 4 + 1] = 0xf0;
    ppu.sprite_line_valid = false;
}

fn configureSolidBackground(ppu: *core.ppu.Ppu, mode: u3, colour_index: u8, colour: u16) void {
    write(ppu, 0x2100, 0x8f);
    write(ppu, 0x2105, mode);
    write(ppu, 0x2107, 0x10);
    write(ppu, 0x210b, 0x02);
    write(ppu, 0x212c, 0x01);
    if (mode == 5 or mode == 6) write(ppu, 0x212d, 0x01);
    setVramWord(ppu, 0x1000, 0);
    const bpp: u4 = switch (mode) {
        0 => 2,
        1, 2 => 4,
        3, 4 => 8,
        5, 6 => 4,
        else => unreachable,
    };
    const characters: u16 = if (mode == 5 or mode == 6) 2 else 1;
    var character: u16 = 0;
    while (character < characters) : (character += 1) {
        var row: u16 = 0;
        while (row < 8) : (row += 1) {
            var pair: u4 = 0;
            while (pair < bpp / 2) : (pair += 1) {
                const low: u8 = if ((colour_index & (@as(u8, 1) << @intCast(pair * 2))) != 0) 0xff else 0;
                const high: u8 = if ((colour_index & (@as(u8, 2) << @intCast(pair * 2))) != 0) 0xff else 0;
                const character_base = 0x2000 + character * @as(u16, bpp) * 4;
                setVramWord(ppu, character_base + @as(u16, pair) * 8 + row, low | (@as(u16, high) << 8));
            }
        }
    }
    setColour(ppu, colour_index, colour);
    write(ppu, 0x2100, 0x0f);
}

fn configureMode7Identity(ppu: *core.ppu.Ppu, colour: u16, extbg: bool) void {
    write(ppu, 0x2100, 0x8f);
    write(ppu, 0x2105, 7);
    write(ppu, 0x212c, if (extbg) 0x03 else 0x01);
    write(ppu, 0x2133, if (extbg) 0x40 else 0x00);
    write(ppu, 0x211a, 0);
    writeMode7Word(ppu, 0x211b, 0x0100);
    writeMode7Word(ppu, 0x211c, 0);
    writeMode7Word(ppu, 0x211d, 0);
    writeMode7Word(ppu, 0x211e, 0x0100);
    writeMode7Word(ppu, 0x211f, 0);
    writeMode7Word(ppu, 0x2120, 0);
    var word: u16 = 0;
    while (word < 0x4000) : (word += 1) setVramWord(ppu, word, 0);
    word = 0;
    while (word < 64) : (word += 1) setVramWord(ppu, word, (@as(u16, if (extbg) 0x81 else 1)) << 8);
    setColour(ppu, 1, colour);
    setColour(ppu, 129, 0x001f);
    write(ppu, 0x2100, 0x0f);
}

fn writeMode7Word(ppu: *core.ppu.Ppu, address: u32, value: u16) void {
    write(ppu, address, @truncate(value));
    write(ppu, address, @truncate(value >> 8));
}

fn configureStripedBackground(ppu: *core.ppu.Ppu) void {
    write(ppu, 0x2100, 0x8f);
    write(ppu, 0x2105, 0);
    write(ppu, 0x2107, 0x10);
    write(ppu, 0x210b, 0x02);
    write(ppu, 0x212c, 0x01);
    setVramWord(ppu, 0x1000, 0);
    var row: u16 = 0;
    while (row < 8) : (row += 1) setVramWord(ppu, 0x2000 + row, 0x00f0);
    setColour(ppu, 1, 0x001f);
    write(ppu, 0x2100, 0x0f);
}

fn configureTwoMode0Screens(ppu: *core.ppu.Ppu) void {
    write(ppu, 0x2100, 0x8f);
    write(ppu, 0x2105, 0);
    write(ppu, 0x2107, 0x10);
    write(ppu, 0x2108, 0x14);
    write(ppu, 0x210b, 0x32);
    write(ppu, 0x212c, 0x01);
    write(ppu, 0x212d, 0x02);
    setVramWord(ppu, 0x1000, 0);
    setVramWord(ppu, 0x1400, 0);
    var row: u16 = 0;
    while (row < 8) : (row += 1) {
        setVramWord(ppu, 0x2000 + row, 0x00ff);
        setVramWord(ppu, 0x3000 + row, 0x00ff);
    }
    setColour(ppu, 1, 0x001f);
    setColour(ppu, 33, 0x03e0);
    write(ppu, 0x2100, 0x0f);
}

fn colourForMode(mode: usize) u16 {
    return switch (mode) {
        0 => 0x001f,
        1 => 0x03e0,
        2 => 0x7c00,
        3 => 0x03ff,
        4 => 0x7c1f,
        else => unreachable,
    };
}
