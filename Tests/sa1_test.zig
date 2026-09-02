const std = @import("std");
const core = @import("core");

const rom_bytes: usize = 256 * 1024;
const bwram_bytes: usize = 64 * 1024;

test "SA-1 headers distinguish supported RAM and battery boards and reject unknown revisions" {
    const allocator = std.testing.allocator;
    const cases = [_]struct { rom_type: u8, ram_code: u8, ram_bytes: usize, battery: bool }{
        .{ .rom_type = 0x33, .ram_code = 0, .ram_bytes = 0, .battery = false },
        .{ .rom_type = 0x34, .ram_code = 6, .ram_bytes = 64 * 1024, .battery = false },
        .{ .rom_type = 0x35, .ram_code = 6, .ram_bytes = 64 * 1024, .battery = true },
    };
    for (cases) |case| {
        const image = try makeSa1Image(allocator, rom_bytes, case.rom_type, case.ram_code);
        defer allocator.free(image);
        var cart = try core.cartridge.Cartridge.parse(allocator, image);
        defer cart.deinit();
        try std.testing.expectEqual(core.board.Enhancement.sa1, cart.board.capability.enhancement);
        try std.testing.expect(cart.board.readyForExecution());
        try std.testing.expectEqual(case.ram_bytes, cart.sram_storage.len);
        try std.testing.expectEqual(case.battery, cart.board.battery);
        try std.testing.expect(cart.sa1_device != null);
        try std.testing.expect(cart.superfx_device == null);
    }

    const unknown = try makeSa1Image(allocator, rom_bytes, 0x36, 5);
    defer allocator.free(unknown);
    try std.testing.expectError(error.UnsupportedSa1Revision, core.cartridge.Cartridge.parse(allocator, unknown));

    const too_much_bwram = try makeSa1Image(allocator, rom_bytes, 0x35, 9);
    defer allocator.free(too_much_bwram);
    try std.testing.expectError(error.ContradictorySa1Board, core.cartridge.Cartridge.parse(allocator, too_much_bwram));
}

test "private 65C816 instance executes reset WAI STP and bidirectional interrupt communication" {
    var rom = [_]u8{0xea} ** rom_bytes;
    var bwram = [_]u8{0} ** bwram_bytes;
    const program = [_]u8{
        0xa9, 0x01, // LDA #$01
        0x8d, 0x2a, 0x22, // STA CIWP: SA-1 may write I-RAM page zero
        0xa9, 0x80, // LDA #$80
        0x8d, 0x27, 0x22, // STA CWBE
        0x8d, 0x0a, 0x22, // STA CIE: enable S-CPU IRQ request
        0xa9, 0x5a, // LDA #$5a
        0x8d, 0x00, 0x30, // STA $3000
        0xa9, 0xa5, // LDA #$a5
        0x8d, 0x00, 0x60, // STA mapped BW-RAM
        0xcb, // WAI
        0xdb, // STP after the masked IRQ wakes WAI
    };
    @memcpy(rom[0..program.len], &program);

    var device = core.sa1.Device{};
    try device.power(.ntsc, rom.len, bwram.len);
    cpuWrite(&device, &rom, &bwram, 0x002203, 0x00);
    cpuWrite(&device, &rom, &bwram, 0x002204, 0x80);
    cpuWrite(&device, &rom, &bwram, 0x002200, 0x00);
    const waiting = device.runSlice(&rom, &bwram, 64);
    try std.testing.expectEqual(core.sa1.RunState.waiting, waiting.state);
    try std.testing.expectEqual(@as(u8, 0x5a), device.iram[0]);
    try std.testing.expectEqual(@as(u8, 0xa5), bwram[0]);
    try std.testing.expectEqual(@as(u16, 0x00a5), device.cpu.a);

    cpuWrite(&device, &rom, &bwram, 0x002200, 0x80);
    try std.testing.expectEqual(core.sa1.RunState.stopped, device.runSlice(&rom, &bwram, 8).state);
    try std.testing.expect(device.cpu.stopped);

    cpuWrite(&device, &rom, &bwram, 0x002201, 0x80);
    sa1Write(&device, &rom, &bwram, 0x00220e, 0xef);
    sa1Write(&device, &rom, &bwram, 0x00220f, 0xbe);
    sa1Write(&device, &rom, &bwram, 0x002209, 0xca);
    try std.testing.expect(device.cpuIrqPending());
    try std.testing.expectEqual(@as(u8, 0xca), device.readCpu(&rom, &bwram, 0x002300, 0).?);
    try std.testing.expectEqual(@as(u8, 0xef), device.readCpu(&rom, &bwram, 0x00ffee, 0).?);
    try std.testing.expectEqual(@as(u8, 0xbe), device.readCpu(&rom, &bwram, 0x00ffef, 0).?);
    cpuWrite(&device, &rom, &bwram, 0x002202, 0x80);
    try std.testing.expect(!device.cpuIrqPending());

    device.cpu.x = 0xccdd;
    device.cpu.y = 0xeeff;
    device.cpu.s = 0x1234;
    device.cpu.d = 0x5678;
    device.cpu.db = 0x88;
    device.cpu.pb = 0x80;
    device.arithmetic_result = 0x5544_3322_11;
    cpuWrite(&device, &rom, &bwram, 0x002200, 0x20);
    cpuWrite(&device, &rom, &bwram, 0x002200, 0x00);
    try std.testing.expectEqual(core.sa1.RunState.reset, device.runSlice(&rom, &bwram, 1).state);
    try std.testing.expectEqual(@as(u16, 0x00a5), device.cpu.a);
    try std.testing.expectEqual(@as(u16, 0x00dd), device.cpu.x);
    try std.testing.expectEqual(@as(u16, 0x00ff), device.cpu.y);
    try std.testing.expectEqual(@as(u16, 0), device.cpu.d);
    try std.testing.expectEqual(@as(u8, 0), device.cpu.db);
    try std.testing.expectEqual(@as(u8, 0), device.cpu.pb);
    try std.testing.expect(device.cpu.emulation);
    try std.testing.expect(!device.cpu.stopped);
    try std.testing.expectEqual(@as(u8, 0), device.sa1_iram_write_pages);
    try std.testing.expectEqual(@as(u64, 0x5544_3322_11), device.arithmetic_result);
}

test "Super MMC I-RAM BW-RAM bitmap protection and contention are independently owned" {
    const allocator = std.testing.allocator;
    const rom = try allocator.alloc(u8, 4 * 1024 * 1024);
    defer allocator.free(rom);
    @memset(rom, 0);
    for (0..4) |quadrant| rom[quadrant * 1024 * 1024] = @intCast(0x10 + quadrant);
    var bwram = [_]u8{0} ** bwram_bytes;
    var device = core.sa1.Device{};
    try device.power(.ntsc, rom.len, bwram.len);

    try std.testing.expectEqual(@as(u8, 0x10), device.readCpu(rom, &bwram, 0xc00000, 0).?);
    try std.testing.expectEqual(@as(u8, 0x11), device.readCpu(rom, &bwram, 0xd00000, 0).?);
    try std.testing.expectEqual(@as(u8, 0x12), device.readCpu(rom, &bwram, 0x808000, 0).?);
    cpuWrite(&device, rom, &bwram, 0x002220, 0x82);
    try std.testing.expectEqual(@as(u8, 0x12), device.readCpu(rom, &bwram, 0xc00000, 0).?);
    try std.testing.expectEqual(@as(u8, 0x12), device.readCpu(rom, &bwram, 0x008000, 0).?);

    cpuWrite(&device, rom, &bwram, 0x003000, 0x11);
    try std.testing.expectEqual(@as(u8, 0), device.iram[0]);
    cpuWrite(&device, rom, &bwram, 0x002229, 0x01);
    cpuWrite(&device, rom, &bwram, 0x003000, 0x22);
    try std.testing.expectEqual(@as(u8, 0x22), device.iram[0]);
    sa1Write(&device, rom, &bwram, 0x000001, 0x33);
    try std.testing.expectEqual(@as(u8, 0), device.iram[1]);
    sa1Write(&device, rom, &bwram, 0x00222a, 0x01);
    sa1Write(&device, rom, &bwram, 0x000001, 0x44);
    try std.testing.expectEqual(@as(u8, 0x44), device.iram[1]);

    cpuWrite(&device, rom, &bwram, 0x006000, 0x51);
    try std.testing.expectEqual(@as(u8, 0), bwram[0]);
    cpuWrite(&device, rom, &bwram, 0x002228, 0x01);
    cpuWrite(&device, rom, &bwram, 0x006200, 0x52);
    try std.testing.expectEqual(@as(u8, 0x52), bwram[0x200]);
    cpuWrite(&device, rom, &bwram, 0x002228, 0x09);
    cpuWrite(&device, rom, &bwram, 0x420000, 0x5f);
    try std.testing.expectEqual(@as(u8, 0x5f), bwram[0]);
    cpuWrite(&device, rom, &bwram, 0x002228, 0x0a);
    cpuWrite(&device, rom, &bwram, 0x440000, 0x60);
    try std.testing.expectEqual(@as(u8, 0x5f), bwram[0]);
    sa1Write(&device, rom, &bwram, 0x002227, 0x80);
    cpuWrite(&device, rom, &bwram, 0x006000, 0x53);
    try std.testing.expectEqual(@as(u8, 0x53), bwram[0]);
    sa1Write(&device, rom, &bwram, 0x002227, 0x00);
    cpuWrite(&device, rom, &bwram, 0x002226, 0x80);
    sa1Write(&device, rom, &bwram, 0x400001, 0x54);
    try std.testing.expectEqual(@as(u8, 0x54), bwram[1]);

    cpuWrite(&device, rom, &bwram, 0x002224, 0x01);
    cpuWrite(&device, rom, &bwram, 0x006000, 0x61);
    try std.testing.expectEqual(@as(u8, 0x61), bwram[0x2000]);
    sa1Write(&device, rom, &bwram, 0x002225, 0x01);
    sa1Write(&device, rom, &bwram, 0x006001, 0x62);
    try std.testing.expectEqual(@as(u8, 0x62), bwram[0x2001]);

    sa1Write(&device, rom, &bwram, 0x002225, 0x80);
    sa1Write(&device, rom, &bwram, 0x600000, 0x0a);
    sa1Write(&device, rom, &bwram, 0x600001, 0x0b);
    try std.testing.expectEqual(@as(u8, 0xba), bwram[0]);
    try std.testing.expectEqual(@as(u8, 0x0a), device.readCoprocessor(rom, &bwram, 0x600000));
    try std.testing.expectEqual(@as(u8, 0x0b), device.readCoprocessor(rom, &bwram, 0x600001));
    sa1Write(&device, rom, &bwram, 0x00223f, 0x80);
    bwram[0] = 0;
    inline for (0..4) |pixel| sa1Write(&device, rom, &bwram, 0x600000 + pixel, @intCast(pixel));
    try std.testing.expectEqual(@as(u8, 0xe4), bwram[0]);

    const conflicts_before = device.bus_conflicts;
    _ = device.readCpu(rom, &bwram, 0xc00000, 0).?;
    const clocks_before = device.master_cycles;
    _ = device.readCoprocessor(rom, &bwram, 0xc00000);
    try std.testing.expectEqual(conflicts_before + 1, device.bus_conflicts);
    try std.testing.expectEqual(@as(u64, 4), device.master_cycles - clocks_before);
}

test "normal DMA is bounded and covers every valid source destination pair" {
    var rom = [_]u8{0} ** rom_bytes;
    var bwram = [_]u8{0} ** bwram_bytes;
    rom[0] = 0x11;
    rom[1] = 0x22;
    rom[2] = 0x33;
    var device = core.sa1.Device{};
    try device.power(.ntsc, rom.len, bwram.len);
    device.reset_hold = false;

    configureDma(&device, &rom, &bwram, 0x80, 0xc00000, 0x000100, 3);
    const rom_to_iram = device.runSlice(&rom, &bwram, 3);
    try std.testing.expectEqual(@as(u64, 6), rom_to_iram.master_cycles);
    try std.testing.expectEqualSlices(u8, &.{ 0x11, 0x22, 0x33 }, device.iram[0x100..0x103]);
    try std.testing.expect(device.dma_irq_flag);

    bwram[0x20] = 0x41;
    bwram[0x21] = 0x42;
    configureDma(&device, &rom, &bwram, 0x81, 0x000020, 0x000120, 2);
    try std.testing.expectEqual(@as(u64, 8), device.runSlice(&rom, &bwram, 2).master_cycles);
    try std.testing.expectEqualSlices(u8, &.{ 0x41, 0x42 }, device.iram[0x120..0x122]);

    device.iram[0x30] = 0x51;
    device.iram[0x31] = 0x52;
    configureDma(&device, &rom, &bwram, 0x86, 0x000030, 0x000040, 2);
    try std.testing.expectEqual(@as(u64, 8), device.runSlice(&rom, &bwram, 2).master_cycles);
    try std.testing.expectEqualSlices(u8, &.{ 0x51, 0x52 }, bwram[0x40..0x42]);

    configureDma(&device, &rom, &bwram, 0x84, 0xc00001, 0x000050, 2);
    _ = device.runSlice(&rom, &bwram, 2);
    try std.testing.expectEqualSlices(u8, &.{ 0x22, 0x33 }, bwram[0x50..0x52]);

    const transfers = device.dma_bytes;
    device.iram[0x140] = 0x99;
    configureDma(&device, &rom, &bwram, 0x83, 0, 0x000140, 1);
    _ = device.runSlice(&rom, &bwram, 1);
    try std.testing.expectEqual(@as(u8, 0x99), device.iram[0x140]);
    try std.testing.expectEqual(transfers, device.dma_bytes);

    configureDma(&device, &rom, &bwram, 0x80, 0xc00000, 0x000150, 0);
    try std.testing.expect(device.dma_running);
    _ = device.runSlice(&rom, &bwram, 1);
    try std.testing.expect(!device.dma_running);
    try std.testing.expectEqual(@as(u8, 0), device.iram[0x150]);
}

test "both character conversion DMA modes generate exact planar bytes" {
    var rom = [_]u8{0} ** rom_bytes;
    var bwram = [_]u8{0} ** bwram_bytes;
    var device = core.sa1.Device{};
    try device.power(.ntsc, rom.len, bwram.len);
    cpuWrite(&device, &rom, &bwram, 0x002226, 0x80);
    for (0..16) |index| bwram[index] = 0xe4;

    sa1Write(&device, &rom, &bwram, 0x002230, 0xb0);
    sa1Write(&device, &rom, &bwram, 0x002231, 0x02);
    writeAddress(&device, &rom, &bwram, 0x2232, 0x000000, true);
    sa1Write(&device, &rom, &bwram, 0x002235, 0x00);
    sa1Write(&device, &rom, &bwram, 0x002236, 0x02);
    try std.testing.expect(device.character_dma_active);
    try std.testing.expect(device.chdma_irq_flag);
    try std.testing.expectEqual(@as(u8, 0x55), device.readCpu(&rom, &bwram, 0x400000, 0).?);
    try std.testing.expectEqual(@as(u8, 0x33), device.readCpu(&rom, &bwram, 0x400001, 0).?);
    try std.testing.expectEqual(@as(u8, 0x55), device.iram[0x200]);
    try std.testing.expectEqual(@as(u8, 0x33), device.iram[0x201]);
    try std.testing.expectEqual(@as(u64, 1), device.character_conversions);
    sa1Write(&device, &rom, &bwram, 0x002231, 0x82);
    try std.testing.expect(!device.character_dma_active);

    sa1Write(&device, &rom, &bwram, 0x002230, 0xa0);
    sa1Write(&device, &rom, &bwram, 0x002231, 0x02);
    writeAddress(&device, &rom, &bwram, 0x2235, 0x000300, true);
    inline for (0..8) |index| sa1Write(&device, &rom, &bwram, 0x002240 + index, @intCast(index & 3));
    try std.testing.expectEqual(@as(u8, 0x55), device.iram[0x300]);
    try std.testing.expectEqual(@as(u8, 0x33), device.iram[0x301]);
    inline for (0..8) |index| sa1Write(&device, &rom, &bwram, 0x002248 + index, @intCast(3 - (index & 3)));
    try std.testing.expectEqual(@as(u8, 0xaa), device.iram[0x302]);
    try std.testing.expectEqual(@as(u8, 0xcc), device.iram[0x303]);
    try std.testing.expectEqual(@as(u64, 3), device.character_conversions);
}

test "arithmetic variable bit reader timers and clock partitioning are deterministic" {
    var rom = [_]u8{0} ** rom_bytes;
    var bwram = [_]u8{0} ** bwram_bytes;
    var device = core.sa1.Device{};
    try device.power(.ntsc, rom.len, bwram.len);

    mathOperation(&device, &rom, &bwram, 0x00, 0xfffe, 3);
    try std.testing.expectEqual(@as(u64, 0xffff_fffa), device.arithmetic_result);
    try std.testing.expectEqual(@as(u8, 0xfa), device.readCoprocessor(&rom, &bwram, 0x002306));
    try std.testing.expectEqual(@as(u8, 0xff), device.readCoprocessor(&rom, &bwram, 0x002309));

    mathOperation(&device, &rom, &bwram, 0x01, 0xfff9, 3);
    try std.testing.expectEqual(@as(u64, 0x0002_fffd), device.arithmetic_result);

    sa1Write(&device, &rom, &bwram, 0x002250, 0x02);
    var index: usize = 0;
    while (index < 513) : (index += 1) writeMathOperands(&device, &rom, &bwram, 0x7fff, 0x7fff);
    try std.testing.expect(device.arithmetic_overflow);
    try std.testing.expectEqual(@as(u8, 0x80), device.readCoprocessor(&rom, &bwram, 0x00230b));

    device.iram[0] = 0xac;
    device.iram[1] = 0x73;
    device.iram[2] = 0x5a;
    writeAddress(&device, &rom, &bwram, 0x2259, 0x000000, true);
    sa1Write(&device, &rom, &bwram, 0x002258, 0x83);
    try std.testing.expectEqual(@as(u8, 0xac), device.readCoprocessor(&rom, &bwram, 0x00230c));
    try std.testing.expectEqual(@as(u8, 0x73), device.readCoprocessor(&rom, &bwram, 0x00230d));
    try std.testing.expectEqual(@as(u3, 3), device.variable_bit);
    const shifted = @as(u24, 0x5a73ac) >> 3;
    try std.testing.expectEqual(@as(u8, @truncate(shifted)), device.readCoprocessor(&rom, &bwram, 0x00230c));
    try std.testing.expectEqual(@as(u8, @truncate(shifted >> 8)), device.readCoprocessor(&rom, &bwram, 0x00230d));
    try std.testing.expectEqual(@as(u3, 6), device.variable_bit);

    sa1Write(&device, &rom, &bwram, 0x002212, 0x01);
    sa1Write(&device, &rom, &bwram, 0x002213, 0x00);
    sa1Write(&device, &rom, &bwram, 0x002211, 0x00);
    sa1Write(&device, &rom, &bwram, 0x002210, 0x81);
    _ = device.readCoprocessor(&rom, &bwram, 0x002301);
    try std.testing.expect(device.timer_irq_flag);
    sa1Write(&device, &rom, &bwram, 0x00220b, 0x40);
    try std.testing.expect(!device.timer_irq_flag);

    var one = core.sa1.Device{};
    var many = core.sa1.Device{};
    try one.power(.pal, rom.len, bwram.len);
    try many.power(.pal, rom.len, bwram.len);
    _ = one.runUntilMasterClock(&rom, &bwram, 100_000, 16);
    var target: u64 = 137;
    while (target < 100_000) : (target += 137) _ = many.runUntilMasterClock(&rom, &bwram, @min(target, 100_000), 16);
    _ = many.runUntilMasterClock(&rom, &bwram, 100_000, 16);
    try std.testing.expectEqual(one.master_cycles, many.master_cycles);
    try std.testing.expectEqual(one.timer_h_counter, many.timer_h_counter);
    try std.testing.expectEqual(one.timer_v_counter, many.timer_v_counter);
    try std.testing.expectEqual(one.stateDigest(&bwram), many.stateDigest(&bwram));
}

fn cpuWrite(device: *core.sa1.Device, rom: []const u8, bwram: []u8, address: u32, value: u8) void {
    std.debug.assert(device.writeCpu(rom, bwram, address, value).handled);
}

fn sa1Write(device: *core.sa1.Device, rom: []const u8, bwram: []u8, address: u32, value: u8) void {
    device.writeCoprocessor(rom, bwram, address, value);
}

fn configureDma(device: *core.sa1.Device, rom: []const u8, bwram: []u8, control: u8, source: u32, destination: u32, count: u16) void {
    sa1Write(device, rom, bwram, 0x002230, control);
    writeAddress(device, rom, bwram, 0x2232, source, true);
    sa1Write(device, rom, bwram, 0x002238, @truncate(count));
    sa1Write(device, rom, bwram, 0x002239, @truncate(count >> 8));
    if ((control & 4) == 0) {
        sa1Write(device, rom, bwram, 0x002235, @truncate(destination));
        sa1Write(device, rom, bwram, 0x002236, @truncate(destination >> 8));
    } else {
        writeAddress(device, rom, bwram, 0x2235, destination, true);
    }
}

fn writeAddress(device: *core.sa1.Device, rom: []const u8, bwram: []u8, first_register: u16, address: u32, trigger_high: bool) void {
    sa1Write(device, rom, bwram, 0x000000 | first_register, @truncate(address));
    sa1Write(device, rom, bwram, 0x000000 | (first_register + 1), @truncate(address >> 8));
    if (trigger_high) sa1Write(device, rom, bwram, 0x000000 | (first_register + 2), @truncate(address >> 16));
}

fn mathOperation(device: *core.sa1.Device, rom: []const u8, bwram: []u8, control: u8, left: u16, right: u16) void {
    sa1Write(device, rom, bwram, 0x002250, control);
    writeMathOperands(device, rom, bwram, left, right);
}

fn writeMathOperands(device: *core.sa1.Device, rom: []const u8, bwram: []u8, left: u16, right: u16) void {
    sa1Write(device, rom, bwram, 0x002251, @truncate(left));
    sa1Write(device, rom, bwram, 0x002252, @truncate(left >> 8));
    sa1Write(device, rom, bwram, 0x002253, @truncate(right));
    sa1Write(device, rom, bwram, 0x002254, @truncate(right >> 8));
}

fn makeSa1Image(allocator: std.mem.Allocator, size: usize, rom_type: u8, ram_code: u8) ![]u8 {
    const rom = try allocator.alloc(u8, size);
    @memset(rom, 0xea);
    const header = rom[0x7fc0 .. 0x7fc0 + core.cartridge.header_length];
    @memset(header, 0);
    @memset(header[0..core.cartridge.title_length], ' ');
    @memcpy(header[0..16], "R4SNES SA1 TEST ");
    header[0x15] = 0x23;
    header[0x16] = rom_type;
    header[0x17] = romSizeCode(size);
    header[0x18] = ram_code;
    header[0x19] = 1;
    header[0x1a] = 0x33;
    header[0x3c] = 0;
    header[0x3d] = 0x80;
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
    header[0x1c] = 0;
    header[0x1d] = 0;
    header[0x1e] = 0;
    header[0x1f] = 0;
    var sum: u16 = 0;
    for (rom) |value| sum +%= value;
    const checksum = sum +% 0x01fe;
    const complement = ~checksum;
    header[0x1c] = @truncate(complement);
    header[0x1d] = @truncate(complement >> 8);
    header[0x1e] = @truncate(checksum);
    header[0x1f] = @truncate(checksum >> 8);
}
