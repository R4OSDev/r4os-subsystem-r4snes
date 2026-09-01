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
    var first: [core.ppu.frame_capacity]u32 = undefined;
    _ = try ppu.copyFrame(first[0..]);

    setColour(&ppu, 1, 0x03e0);
    const second_info = ppu.renderCompleteFrame();
    var second: [core.ppu.frame_capacity]u32 = undefined;
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
    setVramWord(ppu, 0x1000, 0);
    const bpp: u4 = switch (mode) {
        0 => 2,
        1, 2 => 4,
        3, 4 => 8,
        else => unreachable,
    };
    var row: u16 = 0;
    while (row < 8) : (row += 1) {
        var pair: u4 = 0;
        while (pair < bpp / 2) : (pair += 1) {
            const low: u8 = if ((colour_index & (@as(u8, 1) << @intCast(pair * 2))) != 0) 0xff else 0;
            const high: u8 = if ((colour_index & (@as(u8, 2) << @intCast(pair * 2))) != 0) 0xff else 0;
            setVramWord(ppu, 0x2000 + @as(u16, pair) * 8 + row, low | (@as(u16, high) << 8));
        }
    }
    setColour(ppu, colour_index, colour);
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
