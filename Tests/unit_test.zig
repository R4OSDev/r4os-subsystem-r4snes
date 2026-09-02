const std = @import("std");
const r4os = @import("r4os");
const core = @import("core");

test {
    _ = @import("cpu_test.zig");
    _ = @import("dma_test.zig");
    _ = @import("enhancement_test.zig");
    _ = @import("ppu_test.zig");
    _ = @import("persistence_test.zig");
    _ = @import("sdsp_test.zig");
    _ = @import("smp_test.zig");
    _ = @import("superfx_test.zig");
    _ = @import("sa1_test.zig");
    _ = @import("cx4_test.zig");
    _ = @import("video_host_test.zig");
    _ = @import("system_test.zig");
}

test "all cartridge board and bus owners are analyzable" {
    std.testing.refAllDecls(core);
}

test "candidate geometry covers exact minimum maximum and one copier header" {
    const minimum = try core.cartridge.inspectCandidateSize(32 * 1024);
    try std.testing.expectEqual(@as(usize, 32 * 1024), minimum.rom_size);
    try std.testing.expect(!minimum.copier_header);
    const maximum = try core.cartridge.inspectCandidateSize(64 * 1024 * 1024 + 512);
    try std.testing.expectEqual(@as(usize, 64 * 1024 * 1024), maximum.rom_size);
    try std.testing.expect(maximum.copier_header);
    try std.testing.expectError(error.CartridgeTooSmall, core.cartridge.inspectCandidateSize(512));
    try std.testing.expectError(error.InvalidCartridgeGeometry, core.cartridge.inspectCandidateSize(32 * 1024 + 1));
    try std.testing.expectError(error.CartridgeTooLarge, core.cartridge.inspectCandidateSize(64 * 1024 * 1024 + 1024));
}

test "plain and copier-header images normalize byte-identically without source mutation" {
    const allocator = std.testing.allocator;
    const plain = try makeImage(allocator, .lo_rom, 128 * 1024, .ntsc_u, 0x02, 1, false, false);
    defer allocator.free(plain);
    const headed = try makeImage(allocator, .lo_rom, 128 * 1024, .ntsc_u, 0x02, 1, false, true);
    defer allocator.free(headed);
    const before = try allocator.dupe(u8, plain);
    defer allocator.free(before);

    var first = try core.cartridge.Cartridge.parse(allocator, plain);
    defer first.deinit();
    var second = try core.cartridge.Cartridge.parse(allocator, headed);
    defer second.deinit();
    try std.testing.expectEqualSlices(u8, before, plain);
    try std.testing.expectEqualSlices(u8, plain, headed[512..]);
    try std.testing.expectEqualSlices(u8, first.rom(), second.rom());
    try std.testing.expectEqualSlices(u8, first.identity[0..], second.identity[0..]);
    try std.testing.expect(!first.had_copier_header);
    try std.testing.expect(second.had_copier_header);
    try std.testing.expect(first.header.checksum_matches);
    try std.testing.expectEqual(@as(usize, 2048), first.sram().len);
    try std.testing.expect(first.board.battery);
}

test "all four mappings and three region profiles classify reproducibly" {
    const allocator = std.testing.allocator;
    const Cases = struct {
        mapping: core.board.Mapping,
        size: usize,
        region: core.board.Region,
    };
    const cases = [_]Cases{
        .{ .mapping = .lo_rom, .size = 128 * 1024, .region = .ntsc_j },
        .{ .mapping = .hi_rom, .size = 128 * 1024, .region = .ntsc_u },
        .{ .mapping = .ex_lo_rom, .size = 8 * 1024 * 1024, .region = .pal },
        .{ .mapping = .ex_hi_rom, .size = 8 * 1024 * 1024, .region = .pal },
    };
    for (cases) |case| {
        const image = try makeImage(allocator, case.mapping, case.size, case.region, 0x00, 0, false, false);
        defer allocator.free(image);
        var parsed = try core.cartridge.Cartridge.parse(allocator, image);
        defer parsed.deinit();
        try std.testing.expectEqual(case.mapping, parsed.board.mapping);
        try std.testing.expectEqual(case.region, parsed.board.region);
        try std.testing.expect(parsed.board.readyForExecution());
    }
}

test "header ambiguity reset checksum size and unsupported board contradictions fail closed" {
    const allocator = std.testing.allocator;

    const ambiguous = try makeImage(allocator, .lo_rom, 64 * 1024, .ntsc_u, 0x00, 0, false, false);
    defer allocator.free(ambiguous);
    @memcpy(ambiguous[0xFFC0 .. 0xFFC0 + core.cartridge.header_length], ambiguous[0x7FC0 .. 0x7FC0 + core.cartridge.header_length]);
    ambiguous[0xFFD5] = 0x21;
    ambiguous[0x8000] = 0x78;
    try std.testing.expectError(error.AmbiguousHeader, core.cartridge.Cartridge.parse(allocator, ambiguous));

    const bad_reset = try makeImage(allocator, .lo_rom, 64 * 1024, .ntsc_u, 0x00, 0, false, false);
    defer allocator.free(bad_reset);
    bad_reset[0x7FFC] = 0;
    bad_reset[0x7FFD] = 0;
    try std.testing.expectError(error.NoValidHeader, core.cartridge.Cartridge.parse(allocator, bad_reset));

    const bad_checksum = try makeImage(allocator, .lo_rom, 64 * 1024, .ntsc_u, 0x00, 0, false, false);
    defer allocator.free(bad_checksum);
    bad_checksum[0x7FDC] ^= 1;
    try std.testing.expectError(error.NoValidHeader, core.cartridge.Cartridge.parse(allocator, bad_checksum));

    const homebrew_checksum = try makeImage(allocator, .lo_rom, 64 * 1024, .ntsc_u, 0x00, 0, false, false);
    defer allocator.free(homebrew_checksum);
    homebrew_checksum[0x7FDE] +%= 1;
    homebrew_checksum[0x7FDF] = 0;
    const altered: u16 = @as(u16, homebrew_checksum[0x7FDE]) | (@as(u16, homebrew_checksum[0x7FDF]) << 8);
    const altered_complement = ~altered;
    homebrew_checksum[0x7FDC] = @truncate(altered_complement);
    homebrew_checksum[0x7FDD] = @truncate(altered_complement >> 8);
    var accepted_homebrew = try core.cartridge.Cartridge.parse(allocator, homebrew_checksum);
    defer accepted_homebrew.deinit();
    try std.testing.expect(!accepted_homebrew.header.checksum_matches);

    const truncated = try makeImage(allocator, .lo_rom, 64 * 1024, .ntsc_u, 0x00, 0, false, false);
    defer allocator.free(truncated);
    truncated[0x7FD7] = 8; // 256 KiB advertised by a 64 KiB source
    try std.testing.expectError(error.NoValidHeader, core.cartridge.Cartridge.parse(allocator, truncated));

    const unknown = try makeImage(allocator, .lo_rom, 64 * 1024, .ntsc_u, 0x99, 0, false, false);
    defer allocator.free(unknown);
    try std.testing.expectError(error.UnsupportedBoard, core.cartridge.Cartridge.parse(allocator, unknown));

    const adapter = try makeImage(allocator, .lo_rom, 64 * 1024, .ntsc_j, 0xE3, 0, false, false);
    defer allocator.free(adapter);
    try std.testing.expectError(error.ExcludedBoard, core.cartridge.Cartridge.parse(allocator, adapter));

    const invalid_headered = try allocator.alloc(u8, 64 * 1024 + 512);
    defer allocator.free(invalid_headered);
    @memset(invalid_headered, 0xFF);
    try std.testing.expectError(error.NoValidHeader, core.cartridge.Cartridge.parse(allocator, invalid_headered));
}

test "board decoders resolve exact ROM and SRAM boundaries" {
    const mib: usize = 1024 * 1024;
    try std.testing.expectEqual(@as(?usize, 0), core.board.decodeRomIndex(.lo_rom, 0x008000, 4 * mib));
    try std.testing.expectEqual(@as(?usize, 0x7FFF), core.board.decodeRomIndex(.lo_rom, 0x00FFFF, 4 * mib));
    try std.testing.expectEqual(@as(?usize, 0x8000), core.board.decodeRomIndex(.lo_rom, 0x018000, 4 * mib));
    try std.testing.expectEqual(@as(?usize, 0), core.board.decodeRomIndex(.lo_rom, 0x808000, 4 * mib));

    try std.testing.expectEqual(@as(?usize, 0), core.board.decodeRomIndex(.hi_rom, 0xC00000, 4 * mib));
    try std.testing.expectEqual(@as(?usize, 0xFFFF), core.board.decodeRomIndex(.hi_rom, 0xC0FFFF, 4 * mib));
    try std.testing.expectEqual(@as(?usize, 0x8000), core.board.decodeRomIndex(.hi_rom, 0x008000, 4 * mib));

    try std.testing.expectEqual(@as(?usize, 0), core.board.decodeRomIndex(.ex_lo_rom, 0x808000, 8 * mib));
    try std.testing.expectEqual(@as(?usize, 2 * mib), core.board.decodeRomIndex(.ex_lo_rom, 0xC08000, 8 * mib));
    try std.testing.expectEqual(@as(?usize, 4 * mib), core.board.decodeRomIndex(.ex_lo_rom, 0x008000, 8 * mib));
    try std.testing.expectEqual(@as(?usize, 6 * mib), core.board.decodeRomIndex(.ex_lo_rom, 0x408000, 8 * mib));

    try std.testing.expectEqual(@as(?usize, 0), core.board.decodeRomIndex(.ex_hi_rom, 0xC00000, 8 * mib));
    try std.testing.expectEqual(@as(?usize, 0x8000), core.board.decodeRomIndex(.ex_hi_rom, 0x808000, 8 * mib));
    try std.testing.expectEqual(@as(?usize, 4 * mib), core.board.decodeRomIndex(.ex_hi_rom, 0x400000, 8 * mib));
    try std.testing.expectEqual(@as(?usize, 4 * mib + 0x8000), core.board.decodeRomIndex(.ex_hi_rom, 0x008000, 8 * mib));

    const lo_board = testBoard(.lo_rom, 32 * 1024, false);
    try std.testing.expectEqual(@as(?usize, 0), lo_board.sramIndex(0x700000));
    try std.testing.expectEqual(@as(?usize, 0x7FFF), lo_board.sramIndex(0x707FFF));
    const hi_board = testBoard(.hi_rom, 32 * 1024, false);
    try std.testing.expectEqual(@as(?usize, 0), hi_board.sramIndex(0x206000));
    try std.testing.expectEqual(@as(?usize, 0x1FFF), hi_board.sramIndex(0x207FFF));
}

test "every decoded boundary remains within its private physical buffer" {
    const sizes = [_]usize{ 32 * 1024, 3 * 1024 * 1024, 4 * 1024 * 1024, 8 * 1024 * 1024 };
    const mappings = [_]core.board.Mapping{ .lo_rom, .hi_rom, .ex_lo_rom, .ex_hi_rom };
    const offsets = [_]u16{ 0x0000, 0x1FFF, 0x2000, 0x5FFF, 0x6000, 0x7FFF, 0x8000, 0xFFFF };
    for (mappings) |mapping| {
        for (sizes) |size| {
            var bank: u16 = 0;
            while (bank < 256) : (bank += 1) {
                for (offsets) |offset| {
                    const address = (@as(u32, bank) << 16) | offset;
                    if (core.board.decodeRomIndex(mapping, address, size)) |index| {
                        try std.testing.expect(index < size);
                    }
                }
            }
        }
    }
}

test "24-bit bus isolates WRAM ROM SRAM MMIO timing and both open-bus latches" {
    const allocator = std.testing.allocator;
    const image = try makeImage(allocator, .lo_rom, 128 * 1024, .ntsc_u, 0x02, 1, true, false);
    defer allocator.free(image);
    image[1] = 0x42;
    var cart = try core.cartridge.Cartridge.parse(allocator, image);
    defer cart.deinit();
    var bus = core.bus.Bus{};
    var mmio = FakeMmio{};

    _ = bus.write(&cart, &mmio, 0x7E1234, 0x66);
    const mirrored_wram = bus.read(&cart, &mmio, 0x001234);
    try std.testing.expectEqual(@as(u8, 0x66), mirrored_wram.value);
    try std.testing.expectEqual(core.bus.AccessClass.wram, mirrored_wram.class);
    try std.testing.expectEqual(@as(u8, 8), mirrored_wram.master_cycles);

    const slow_rom = bus.read(&cart, &mmio, 0x008001);
    const power_on_rom = bus.read(&cart, &mmio, 0x808001);
    try std.testing.expectEqual(@as(u8, 0x42), slow_rom.value);
    try std.testing.expectEqual(@as(u8, 8), slow_rom.master_cycles);
    try std.testing.expectEqual(@as(u8, 8), power_on_rom.master_cycles);
    bus.fast_rom_enabled = true;
    const fast_rom = bus.read(&cart, &mmio, 0x808001);
    try std.testing.expectEqual(@as(u8, 6), fast_rom.master_cycles);

    const ppu = bus.read(&cart, &mmio, 0x002134);
    try std.testing.expectEqual(@as(u8, 0xAB), ppu.value);
    try std.testing.expectEqual(@as(u8, 6), ppu.master_cycles);
    try std.testing.expectEqual(@as(u8, 0xAB), bus.ppu_open_bus);
    try std.testing.expectEqual(@as(u8, 0x42), bus.cpu_open_bus);
    const controller = bus.read(&cart, &mmio, 0x004016);
    try std.testing.expectEqual(@as(u8, 12), controller.master_cycles);

    const sram_write = bus.write(&cart, &mmio, 0x700000, 0x5A);
    try std.testing.expectEqual(core.bus.AccessClass.cartridge_ram, sram_write.class);
    try std.testing.expect(cart.sram_dirty);
    try std.testing.expectEqual(@as(u8, 0x5A), bus.read(&cart, &mmio, 0x700000).value);

    _ = bus.write(&cart, &mmio, 0x006000, 0xCC);
    const open = bus.read(&cart, &mmio, 0x006000);
    try std.testing.expectEqual(core.bus.AccessClass.open_bus, open.class);
    try std.testing.expectEqual(@as(u8, 0xCC), open.value);
    try std.testing.expect(bus.last_address <= core.bus.address_mask);
}

test "capability matrix names every planned firmware and excluded family without claiming support" {
    const expected = [_]struct { kind: core.board.Enhancement, disposition: core.board.Disposition }{
        .{ .kind = .none, .disposition = .base_implemented },
        .{ .kind = .obc1, .disposition = .base_implemented },
        .{ .kind = .srtc, .disposition = .base_implemented },
        .{ .kind = .sdd1, .disposition = .base_implemented },
        .{ .kind = .spc7110_epson_rtc, .disposition = .base_implemented },
        .{ .kind = .super_fx, .disposition = .base_implemented },
        .{ .kind = .sa1, .disposition = .base_implemented },
        .{ .kind = .cx4, .disposition = .base_implemented },
        .{ .kind = .dsp1_family, .disposition = .planned_user_firmware },
        .{ .kind = .st010_st011, .disposition = .planned_user_firmware },
        .{ .kind = .st018, .disposition = .planned_user_firmware },
        .{ .kind = .msu1, .disposition = .excluded },
        .{ .kind = .adapter_system, .disposition = .excluded },
        .{ .kind = .unknown, .disposition = .unsupported },
    };
    try std.testing.expectEqual(expected.len, core.board.capability_table.len);
    for (expected) |entry| {
        const capability = core.board.capability(entry.kind);
        try std.testing.expectEqual(entry.disposition, capability.disposition);
        if (entry.kind != .none and entry.kind != .obc1 and entry.kind != .srtc and
            entry.kind != .sdd1 and entry.kind != .spc7110_epson_rtc and entry.kind != .super_fx and entry.kind != .sa1 and entry.kind != .cx4)
        {
            try std.testing.expect(capability.disposition != .base_implemented);
        }
    }
    try std.testing.expectEqual(@as(usize, 0x2000), core.board.capability(.dsp1_family).firmware_bytes);
    try std.testing.expectEqual(@as(usize, 0xD000), core.board.capability(.st010_st011).firmware_bytes);
    try std.testing.expectEqual(@as(usize, 0x28000), core.board.capability(.st018).firmware_bytes);
    try std.testing.expectEqual(core.board.Enhancement.srtc, core.board.enhancementForHeader(0x55, 0x35));
    try std.testing.expectEqual(core.board.Enhancement.spc7110_epson_rtc, core.board.enhancementForHeader(0xF5, 0x3A));
    try std.testing.expectEqual(core.board.Enhancement.st018, core.board.enhancementForHeader(0xF5, 0x30));
    try std.testing.expectEqual(core.board.Enhancement.sa1, core.board.enhancementForHeader(0x35, 0x23));
    try std.testing.expectEqual(core.board.Enhancement.sdd1, core.board.enhancementForHeader(0x45, 0x32));
    try std.testing.expectEqual(core.board.Enhancement.super_fx, core.board.enhancementForHeader(0x15, 0x20));
    try std.testing.expectEqual(core.board.Enhancement.super_fx, core.board.enhancementForHeader(0x1A, 0x30));
    try std.testing.expectEqual(core.board.Enhancement.unknown, core.board.enhancementForHeader(0x99, 0x20));
}

test "keyboard policy controller isolation and persistence root remain exact" {
    const expected = [_]struct { usage: u32, button: core.controller.Button }{
        .{ .usage = r4os.abi.physical_key_usage_up, .button = .up },
        .{ .usage = r4os.abi.physical_key_usage_down, .button = .down },
        .{ .usage = r4os.abi.physical_key_usage_left, .button = .left },
        .{ .usage = r4os.abi.physical_key_usage_right, .button = .right },
        .{ .usage = r4os.abi.physical_key_usage_enter, .button = .start },
        .{ .usage = r4os.abi.physical_key_usage_right_control, .button = .select },
        .{ .usage = r4os.abi.physical_key_usage_keypad_8, .button = .x },
        .{ .usage = r4os.abi.physical_key_usage_keypad_6, .button = .a },
        .{ .usage = r4os.abi.physical_key_usage_keypad_2, .button = .b },
        .{ .usage = r4os.abi.physical_key_usage_keypad_4, .button = .y },
        .{ .usage = r4os.abi.physical_key_usage_keypad_7, .button = .l },
        .{ .usage = r4os.abi.physical_key_usage_keypad_9, .button = .r },
    };
    for (expected) |entry| try std.testing.expectEqual(entry.button, core.host_adapter.buttonForUsage(entry.usage).?);
    try std.testing.expect(core.host_adapter.buttonForUsage(0x25) == null);

    var ports = core.controller.Ports{};
    ports.port2.set(.a, true);
    ports.port2.latch();
    var bit: usize = 0;
    while (bit < 16) : (bit += 1) try std.testing.expectEqual(@as(u1, 1), ports.port2.serialBit());
    try std.testing.expectEqualStrings("C:\\R4OS\\SUBSYSTEMS\\r4os.snes\\SAVE\\", core.persistence.save_root);
}

test "machines retain private 128 KiB buses and idempotent close state" {
    var first = core.machine.Machine.init(1);
    var second = core.machine.Machine.init(2);
    first.bus.wram[0x1234] = 0xA5;
    first.cpu.a = 0xBEEF;
    try std.testing.expectEqual(@as(u8, 0), second.bus.wram[0x1234]);
    try std.testing.expectEqual(@as(u16, 0), second.cpu.a);
    first.scpu.dma.requestManual(1, 6);
    try std.testing.expect(!first.scpu.cpuMayRun());
    first.close();
    first.close();
    try std.testing.expect(first.closed);
    try std.testing.expect(first.scpu.cpuMayRun());
    try std.testing.expect(second.foundationReady());
}

const FakeMmio = struct {
    last_address: u32 = 0,

    pub fn read(self: *FakeMmio, address: u32, _: u8, _: u8) core.bus.MmioRead {
        self.last_address = address;
        if ((address & 0xFFFF) == 0x2134) return .{ .handled = true, .value = 0xAB, .latch = .ppu };
        if ((address & 0xFFFF) == 0x4016) return .{ .handled = true, .value = 1 };
        return .{};
    }

    pub fn write(self: *FakeMmio, address: u32, _: u8, _: u8, _: u8) bool {
        self.last_address = address;
        return true;
    }
};

fn testBoard(mapping: core.board.Mapping, sram_bytes: usize, fast_rom: bool) core.board.Board {
    return .{
        .mapping = mapping,
        .region = .ntsc_u,
        .fast_rom = fast_rom,
        .capability = core.board.capability(.none),
        .sram_bytes = sram_bytes,
        .battery = sram_bytes != 0,
    };
}

fn makeImage(
    allocator: std.mem.Allocator,
    mapping: core.board.Mapping,
    rom_size: usize,
    region: core.board.Region,
    rom_type: u8,
    ram_size_code: u8,
    fast_rom: bool,
    copier_header: bool,
) ![]u8 {
    const prefix: usize = if (copier_header) 512 else 0;
    const source = try allocator.alloc(u8, rom_size + prefix);
    @memset(source, 0xEA);
    if (copier_header) @memset(source[0..prefix], 0xCC);
    const rom = source[prefix..];
    const header_offset: usize = switch (mapping) {
        .lo_rom => 0x7FC0,
        .hi_rom => 0xFFC0,
        .ex_lo_rom => 0x407FC0,
        .ex_hi_rom => 0x40FFC0,
    };
    const header = rom[header_offset .. header_offset + core.cartridge.header_length];
    @memset(header, 0);
    @memset(header[0..core.cartridge.title_length], ' ');
    @memcpy(header[0..17], "R4SNES TEST IMAGE");
    const base_mode: u8 = switch (mapping) {
        .lo_rom => 0x20,
        .hi_rom => 0x21,
        .ex_lo_rom => 0x22,
        .ex_hi_rom => 0x25,
    };
    header[0x15] = base_mode | (if (fast_rom) @as(u8, 0x10) else 0);
    header[0x16] = rom_type;
    header[0x17] = romSizeCode(rom_size);
    header[0x18] = ram_size_code;
    header[0x19] = switch (region) {
        .ntsc_j => 0,
        .ntsc_u => 1,
        .pal => 2,
    };
    header[0x1A] = 0x33;
    header[0x1B] = 0;
    header[0x3C] = 0x00;
    header[0x3D] = 0x80;
    const startup = core.board.decodeRomIndex(mapping, 0x008000, rom.len).?;
    rom[startup] = 0x78;
    finalizeChecksum(rom, header);
    return source;
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
