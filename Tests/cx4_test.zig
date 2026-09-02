const std = @import("std");
const core = @import("core");

const rom_bytes: usize = 256 * 1024;

test "CX4 header geometry is executable and unknown revisions fail closed" {
    const allocator = std.testing.allocator;
    const image = try makeCx4Image(allocator, rom_bytes, 0xf3, 0);
    defer allocator.free(image);
    var cart = try core.cartridge.Cartridge.parse(allocator, image);
    defer cart.deinit();
    try std.testing.expectEqual(core.board.Enhancement.cx4, cart.board.capability.enhancement);
    try std.testing.expect(cart.board.readyForExecution());
    try std.testing.expect(cart.cx4_device != null);
    try std.testing.expectEqual(@as(usize, 0), cart.sram_storage.len);
    try std.testing.expect(!cart.board.battery);
    try std.testing.expectEqual(@as(usize, 0), cart.board.romIndex(0x008000, cart.rom().len).?);
    try std.testing.expectEqual(@as(usize, 0), cart.board.romIndex(0x808000, cart.rom().len).?);
    try std.testing.expectEqual(@as(usize, 0), cart.board.romIndex(0xc00000, cart.rom().len).?);
    try std.testing.expect(cart.board.romIndex(0x006000, cart.rom().len) == null);

    const unknown = try makeCx4Image(allocator, rom_bytes, 0xf4, 0);
    defer allocator.free(unknown);
    try std.testing.expectError(error.UnsupportedCx4Revision, core.cartridge.Cartridge.parse(allocator, unknown));

    const save_ram = try makeCx4Image(allocator, rom_bytes, 0xf3, 1);
    defer allocator.free(save_ram);
    try std.testing.expectError(error.ContradictoryCx4Board, core.cartridge.Cartridge.parse(allocator, save_ram));

    const oversized = try makeCx4Image(allocator, 4 * 1024 * 1024, 0xf3, 0);
    defer allocator.free(oversized);
    try std.testing.expectError(error.ContradictoryCx4Board, core.cartridge.Cartridge.parse(allocator, oversized));
}

test "CX4 mathematical data ROM is synthesized exactly without a firmware payload" {
    var bytes: [core.cx4.data_rom_words * 3]u8 = undefined;
    for (0..core.cx4.data_rom_words) |index| {
        const value = core.cx4.dataRomWord(@intCast(index));
        bytes[index * 3] = @truncate(value);
        bytes[index * 3 + 1] = @truncate(value >> 8);
        bytes[index * 3 + 2] = @truncate(value >> 16);
    }
    var actual: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&bytes, &actual, .{});
    const expected = try decodeSha256("ae8d4d1961b93421ff00b3caa1d0f0ce7783e749772a3369c36b3dbf0d37ef18");
    try std.testing.expectEqualSlices(u8, &expected, &actual);
    try std.testing.expectEqual(@as(u24, 0xffffff), core.cx4.dataRomWord(0));
    try std.testing.expectEqual(@as(u24, 0x800000), core.cx4.dataRomWord(1));
    try std.testing.expectEqual(@as(u24, 0x010000), core.cx4.dataRomWord(128));
    try std.testing.expectEqual(@as(u24, 0xffffff), core.cx4.dataRomWord(896));
}

test "CX4 cache executes real HG51B arithmetic and asserts completion IRQ" {
    var rom = [_]u8{0} ** rom_bytes;
    var save_ram: [0]u8 = .{};
    const program = [_]u16{
        0x6412, // LD A,$12
        0x8434, // ADD A,$34
        0xe060, // ST R0,A
        0x9c02, // MUL A,$02
        0x6002, // LD A,MUL low
        0xe061, // ST R1,A
        0xfc00, // HALT
    };
    installProgram(&rom, &program);

    var device = core.cx4.Device{};
    try device.power(rom.len, save_ram.len);
    writeIo(&device, &rom, &save_ram, 0x7f49, 0x00);
    writeIo(&device, &rom, &save_ram, 0x7f4a, 0x80);
    writeIo(&device, &rom, &save_ram, 0x7f4b, 0x00);
    writeIo(&device, &rom, &save_ram, 0x7f48, 0x00);
    writeIo(&device, &rom, &save_ram, 0x7f4f, 0x00);
    try std.testing.expect(device.busy());

    const blocked = device.readCpu(&rom, &save_ram, 0x008000, 0x5a).?;
    try std.testing.expectEqual(@as(u8, 0x5a), blocked);
    writeIo(&device, &rom, &save_ram, 0x7f60, 0xa5);
    try std.testing.expectEqual(@as(u8, 0xa5), device.readCpu(&rom, &save_ram, 0x00ffe0, 0).?);

    const result = device.runSlice(&rom, &save_ram, 4096);
    try std.testing.expectEqual(core.cx4.RunState.halted, result.state);
    try std.testing.expectEqual(@as(u24, 0x46), device.gpr[0]);
    try std.testing.expectEqual(@as(u24, 0x8c), device.gpr[1]);
    try std.testing.expect(device.irqPending());
    try std.testing.expect(device.irq_flag);
    try std.testing.expectEqual(@as(u64, 512), device.cache_bytes);
    try std.testing.expectEqual(@as(u64, 7), device.instruction_count);
    try std.testing.expectEqual(@as(u64, 2), device.bus_conflicts);

    writeIo(&device, &rom, &save_ram, 0x7f5e, 0);
    try std.testing.expect(!device.irq_flag);
    try std.testing.expect(device.irqPending());
    writeIo(&device, &rom, &save_ram, 0x7f51, 1);
    try std.testing.expect(!device.irqPending());
}

test "CX4 DMA timing reset and invalid transfers remain bounded" {
    var rom = [_]u8{0} ** rom_bytes;
    var save_ram: [0]u8 = .{};
    rom[0] = 0x11;
    rom[1] = 0x22;
    rom[2] = 0x33;
    var device = core.cx4.Device{};
    try device.power(rom.len, save_ram.len);

    configureDma(&device, &rom, &save_ram, 0x008000, 0x006000, 3);
    try std.testing.expect(device.busy());
    _ = device.runSlice(&rom, &save_ram, 2);
    writeIo(&device, &rom, &save_ram, 0x7f53, 0);
    try std.testing.expect(device.dma_enabled);
    const completed = device.runSlice(&rom, &save_ram, 32);
    try std.testing.expectEqual(core.cx4.RunState.halted, completed.state);
    try std.testing.expectEqualSlices(u8, &.{ 0x11, 0x22, 0x33 }, device.data_ram[0..3]);
    try std.testing.expectEqual(@as(u64, 3), device.dma_bytes);

    const before = device.data_ram;
    configureDma(&device, &rom, &save_ram, 0x006000, 0x006010, 4);
    const rejected = device.runSlice(&rom, &save_ram, 1);
    try std.testing.expectEqual(core.cx4.RunState.locked, rejected.state);
    try std.testing.expectEqual(core.cx4.Fault.invalid_dma, rejected.fault.?);
    try std.testing.expectEqualSlices(u8, &before, &device.data_ram);
    writeIo(&device, &rom, &save_ram, 0x7f53, 0);
    try std.testing.expect(!device.locked);
}

test "CX4 slices are partition invariant and every opcode is classified" {
    var rom = [_]u8{0} ** rom_bytes;
    var first_save: [0]u8 = .{};
    var second_save: [0]u8 = .{};
    const program = [_]u16{
        0x64ff, // LD A,$ff
        0x5900, // SXB
        0xdc01, // SHL A,1
        0xe060, // ST R0,A
        0x7401, // RDROM $001
        0x6008, // LD A,ROM
        0xe061, // ST R1,A
        0xfc00,
    };
    installProgram(&rom, &program);
    var one = core.cx4.Device{};
    var many = core.cx4.Device{};
    try one.power(rom.len, first_save.len);
    try many.power(rom.len, second_save.len);
    startProgram(&one, &rom, &first_save);
    startProgram(&many, &rom, &second_save);
    _ = one.runSlice(&rom, &first_save, 4096);
    var remaining: usize = 4096;
    var slice: usize = 1;
    while (remaining != 0) {
        const amount = @min(slice, remaining);
        _ = many.runSlice(&rom, &second_save, amount);
        remaining -= amount;
        slice = (slice * 13) % 47 + 1;
    }
    try std.testing.expectEqual(one.stateDigest(), many.stateDigest());
    try std.testing.expectEqual(@as(u24, 0xfffffe), one.gpr[0]);
    try std.testing.expectEqual(@as(u24, 0x800000), one.gpr[1]);

    var decoder = core.cx4.Device{};
    try decoder.power(rom.len, first_save.len);
    var defined: usize = 0;
    var reserved: usize = 0;
    for (0..65536) |raw| switch (decoder.executeDecoded(@intCast(raw))) {
        .defined => defined += 1,
        .reserved_nop => reserved += 1,
    };
    try std.testing.expectEqual(@as(usize, 55_808), defined);
    try std.testing.expectEqual(@as(usize, 9_728), reserved);
    try std.testing.expectEqual(@as(u64, reserved), decoder.reserved_opcodes);

    const memory_before = decoder.data_ram;
    const registers_before = decoder.gpr;
    try std.testing.expectEqual(core.cx4.OpcodeClass.reserved_nop, decoder.executeDecoded(0x04a5));
    try std.testing.expectEqualSlices(u8, &memory_before, &decoder.data_ram);
    try std.testing.expectEqualSlices(u24, &registers_before, &decoder.gpr);

    var isolated = core.cx4.Device{};
    try isolated.power(rom.len, 0);
    const isolated_before = isolated.stateDigest();
    decoder.data_ram[0] = 0xa5;
    decoder.gpr[0] = 0x123456;
    try std.testing.expectEqual(isolated_before, isolated.stateDigest());
}

test "CX4 arithmetic flags shifts sign extension and address wrap match HG51B edges" {
    var device = core.cx4.Device{};
    try device.power(rom_bytes, 0);

    device.accumulator = 0x7fffff;
    try std.testing.expectEqual(core.cx4.OpcodeClass.defined, device.executeDecoded(0x8401));
    try std.testing.expectEqual(@as(u24, 0x800000), device.accumulator);
    try std.testing.expect(device.negative);
    try std.testing.expect(!device.zero);
    try std.testing.expect(!device.carry);
    try std.testing.expect(device.overflow);

    device.accumulator = 0xffffff;
    _ = device.executeDecoded(0x8401);
    try std.testing.expectEqual(@as(u24, 0), device.accumulator);
    try std.testing.expect(!device.negative);
    try std.testing.expect(device.zero);
    try std.testing.expect(device.carry);
    try std.testing.expect(!device.overflow);

    device.accumulator = 0;
    _ = device.executeDecoded(0x9401);
    try std.testing.expectEqual(@as(u24, 0xffffff), device.accumulator);
    try std.testing.expect(device.negative);
    try std.testing.expect(!device.zero);
    try std.testing.expect(!device.carry);

    device.accumulator = 0x80;
    _ = device.executeDecoded(0x5900);
    try std.testing.expectEqual(@as(u24, 0xffff80), device.accumulator);
    device.accumulator = 0x8000;
    _ = device.executeDecoded(0x5a00);
    try std.testing.expectEqual(@as(u24, 0xff8000), device.accumulator);

    device.accumulator = 0x812345;
    _ = device.executeDecoded(0xc418);
    try std.testing.expectEqual(@as(u24, 0), device.accumulator);
    device.accumulator = 0x812345;
    _ = device.executeDecoded(0xcc18);
    try std.testing.expectEqual(@as(u24, 0xffffff), device.accumulator);
    device.accumulator = 0x812345;
    _ = device.executeDecoded(0xdc18);
    try std.testing.expectEqual(@as(u24, 0), device.accumulator);
    device.accumulator = 0x812345;
    _ = device.executeDecoded(0xd418);
    try std.testing.expectEqual(@as(u24, 0x812345), device.accumulator);
    device.accumulator = 0x812345;
    _ = device.executeDecoded(0xc419);
    try std.testing.expectEqual(@as(u24, 0x812345), device.accumulator);

    device.memory_address = 0xffffff;
    _ = device.executeDecoded(0x4000);
    try std.testing.expectEqual(@as(u24, 0), device.memory_address);
    device.data_ram[0x800] = 0xa5;
    device.accumulator = 0x000c00;
    _ = device.executeDecoded(0x6800);
    try std.testing.expectEqual(@as(u24, 0x0000a5), device.ram_buffer);
    device.ram_buffer = 0x332211;
    _ = device.executeDecoded(0xea00);
    try std.testing.expectEqual(@as(u8, 0x33), device.data_ram[0x800]);
}

test "CX4 exact cache DMA suspend and soft reset protocol is bounded" {
    var rom = [_]u8{0} ** rom_bytes;
    var save_ram: [0]u8 = .{};
    installProgram(&rom, &.{0xfc00});
    var device = core.cx4.Device{};
    try device.power(rom.len, 0);
    try std.testing.expect(device.writeCpu(&rom, &save_ram, 0x806123, 0xa5).handled);
    try std.testing.expectEqual(@as(u8, 0xa5), device.readCpu(&rom, &save_ram, 0x007123, 0).?);

    startProgram(&device, &rom, &save_ram);
    const cache_only = device.runSlice(&rom, &save_ram, 2048);
    try std.testing.expectEqual(core.cx4.RunState.running, cache_only.state);
    try std.testing.expectEqual(@as(u64, 512), device.cache_bytes);
    try std.testing.expectEqual(@as(u64, 0), device.instruction_count);
    const halt = device.runUntilCycle(&rom, &save_ram, 2049);
    try std.testing.expectEqual(core.cx4.RunState.halted, halt.state);
    try std.testing.expectEqual(@as(u64, 1), halt.cycles);
    try std.testing.expectEqual(@as(u64, 1), halt.instructions);

    rom[0] = 0x11;
    rom[1] = 0x22;
    rom[2] = 0x33;
    configureDma(&device, &rom, &save_ram, 0x008000, 0x006040, 3);
    _ = device.runSlice(&rom, &save_ram, 1);
    writeIo(&device, &rom, &save_ram, 0x7f53, 0);
    try std.testing.expect(device.dma_enabled);
    try std.testing.expectEqual(@as(u24, 0), device.gpr[0]);
    device.gpr[0] = 0x654321;
    _ = device.runSlice(&rom, &save_ram, 14);
    try std.testing.expect(!device.dma_enabled);
    try std.testing.expectEqualSlices(u8, &.{ 0x11, 0x22, 0x33 }, device.data_ram[0x40..0x43]);
    try std.testing.expectEqual(@as(u24, 0x654321), device.gpr[0]);

    writeIo(&device, &rom, &save_ram, 0x7f55, 0);
    _ = device.runSlice(&rom, &save_ram, 64);
    try std.testing.expect(device.suspend_enabled);
    writeIo(&device, &rom, &save_ram, 0x7f5d, 0);
    try std.testing.expect(!device.suspend_enabled);
    writeIo(&device, &rom, &save_ram, 0x7f56, 0);
    _ = device.runSlice(&rom, &save_ram, 31);
    try std.testing.expect(device.suspend_enabled);
    _ = device.runSlice(&rom, &save_ram, 1);
    try std.testing.expect(!device.suspend_enabled);

    writeIo(&device, &rom, &save_ram, 0x7f4c, 3);
    writeIo(&device, &rom, &save_ram, 0x7f49, 0x00);
    writeIo(&device, &rom, &save_ram, 0x7f4a, 0x90);
    writeIo(&device, &rom, &save_ram, 0x7f48, 0);
    writeIo(&device, &rom, &save_ram, 0x7f4f, 0);
    const locked = device.runSlice(&rom, &save_ram, 1);
    try std.testing.expectEqual(core.cx4.RunState.halted, locked.state);
    try std.testing.expectEqual(core.cx4.Fault.cache_locked, locked.fault.?);
    writeIo(&device, &rom, &save_ram, 0x7f53, 0);
    try std.testing.expect(device.last_fault == null);
    try std.testing.expectEqual(@as(u24, 0x654321), device.gpr[0]);
    try std.testing.expectEqual(@as(u8, 0x11), device.data_ram[0x40]);
}

fn installProgram(rom: []u8, program: []const u16) void {
    for (program, 0..) |opcode, index| {
        rom[index * 2] = @truncate(opcode);
        rom[index * 2 + 1] = @truncate(opcode >> 8);
    }
}

fn startProgram(device: *core.cx4.Device, rom: []const u8, save_ram: []u8) void {
    writeIo(device, rom, save_ram, 0x7f49, 0x00);
    writeIo(device, rom, save_ram, 0x7f4a, 0x80);
    writeIo(device, rom, save_ram, 0x7f4b, 0x00);
    writeIo(device, rom, save_ram, 0x7f48, 0x00);
    writeIo(device, rom, save_ram, 0x7f4f, 0x00);
}

fn configureDma(device: *core.cx4.Device, rom: []const u8, save_ram: []u8, source: u24, target: u24, length: u16) void {
    writeIo(device, rom, save_ram, 0x7f40, @truncate(source));
    writeIo(device, rom, save_ram, 0x7f41, @truncate(source >> 8));
    writeIo(device, rom, save_ram, 0x7f42, @truncate(source >> 16));
    writeIo(device, rom, save_ram, 0x7f43, @truncate(length));
    writeIo(device, rom, save_ram, 0x7f44, @truncate(length >> 8));
    writeIo(device, rom, save_ram, 0x7f45, @truncate(target));
    writeIo(device, rom, save_ram, 0x7f46, @truncate(target >> 8));
    writeIo(device, rom, save_ram, 0x7f47, @truncate(target >> 16));
}

fn writeIo(device: *core.cx4.Device, rom: []const u8, save_ram: []u8, address: u16, value: u8) void {
    std.debug.assert(device.writeCpu(rom, save_ram, address, value).handled);
}

fn decodeSha256(text: []const u8) ![32]u8 {
    var result: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&result, text);
    return result;
}

fn makeCx4Image(allocator: std.mem.Allocator, size: usize, rom_type: u8, ram_code: u8) ![]u8 {
    const image = try allocator.alloc(u8, size);
    @memset(image, 0xea);
    const header = image[0x7fc0 .. 0x7fc0 + core.cartridge.header_length];
    @memset(header, 0);
    @memset(header[0..core.cartridge.title_length], ' ');
    @memcpy(header[0..16], "R4SNES CX4 TEST ");
    header[0x15] = 0x20;
    header[0x16] = rom_type;
    header[0x17] = romSizeCode(size);
    header[0x18] = ram_code;
    header[0x19] = 1;
    header[0x1a] = 0x33;
    header[0x3c] = 0x00;
    header[0x3d] = 0x80;
    image[0] = 0x78;
    finalizeChecksum(image, header);
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
