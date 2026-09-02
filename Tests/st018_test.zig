const std = @import("std");
const core = @import("core");

const arm = core.armv3;
const chip = core.st018;

const Access = struct {
    address: u32 = 0,
    value: u32 = 0,
    write: bool = false,
    byte: bool = false,
    prefetch: bool = false,
};

const FlatBus = struct {
    memory: [4096]u8 = .{0} ** 4096,
    trace: [256]Access = .{Access{}} ** 256,
    trace_len: usize = 0,
    idle_cycles: usize = 0,
    abort_prefetch: ?u32 = null,
    abort_data: ?u32 = null,

    pub fn readWord(self: *FlatBus, address: u32, prefetch: bool) arm.ReadResult {
        const aligned = address & ~@as(u32, 3);
        if ((prefetch and self.abort_prefetch == aligned) or (!prefetch and self.abort_data == aligned)) {
            self.record(.{ .address = aligned, .prefetch = prefetch });
            return .{ .abort = true };
        }
        const index = @as(usize, aligned) & (self.memory.len - 1);
        const value = @as(u32, self.memory[index]) |
            (@as(u32, self.memory[(index + 1) & (self.memory.len - 1)]) << 8) |
            (@as(u32, self.memory[(index + 2) & (self.memory.len - 1)]) << 16) |
            (@as(u32, self.memory[(index + 3) & (self.memory.len - 1)]) << 24);
        self.record(.{ .address = aligned, .value = value, .prefetch = prefetch });
        return .{ .value = value };
    }

    pub fn readByte(self: *FlatBus, address: u32, prefetch: bool) arm.ReadResult {
        if ((prefetch and self.abort_prefetch == address) or (!prefetch and self.abort_data == address)) {
            self.record(.{ .address = address, .byte = true, .prefetch = prefetch });
            return .{ .abort = true };
        }
        const value = self.memory[@as(usize, address) & (self.memory.len - 1)];
        self.record(.{ .address = address, .value = value, .byte = true, .prefetch = prefetch });
        return .{ .value = value };
    }

    pub fn writeWord(self: *FlatBus, address: u32, value: u32) bool {
        const aligned = address & ~@as(u32, 3);
        self.record(.{ .address = aligned, .value = value, .write = true });
        if (self.abort_data == aligned) return true;
        const index = @as(usize, aligned) & (self.memory.len - 1);
        self.memory[index] = @truncate(value);
        self.memory[(index + 1) & (self.memory.len - 1)] = @truncate(value >> 8);
        self.memory[(index + 2) & (self.memory.len - 1)] = @truncate(value >> 16);
        self.memory[(index + 3) & (self.memory.len - 1)] = @truncate(value >> 24);
        return false;
    }

    pub fn writeByte(self: *FlatBus, address: u32, value: u8) bool {
        self.record(.{ .address = address, .value = value, .write = true, .byte = true });
        if (self.abort_data == address) return true;
        self.memory[@as(usize, address) & (self.memory.len - 1)] = value;
        return false;
    }

    pub fn idle(self: *FlatBus) void {
        self.idle_cycles += 1;
    }

    fn record(self: *FlatBus, access: Access) void {
        if (self.trace_len < self.trace.len) {
            self.trace[self.trace_len] = access;
            self.trace_len += 1;
        }
    }
};

test "ST018 firmware contract is exact revision-bound and never relaxes product policy" {
    try std.testing.expectEqual(@as(usize, 0x28000), chip.firmware_bytes);
    try std.testing.expectEqual(@as(usize, 128 * 1024), chip.program_rom_bytes);
    try std.testing.expectEqual(@as(usize, 32 * 1024), chip.data_rom_bytes);
    try std.testing.expectEqual(@as(usize, 16 * 1024), chip.work_ram_bytes);
    try std.testing.expectEqual(@as(u32, 21_440_000), chip.frequency_hz);
    try std.testing.expectEqual(@as(u32, 65_536), chip.reset_delay_cycles);
    try std.testing.expectEqualStrings("ST018.ROM", chip.firmware_file);
    try std.testing.expect(std.mem.endsWith(u8, chip.firmware_path, "\\ST018.ROM"));
    try std.testing.expectEqualSlices(u8, &try decodeSha256("6df209ab5d2524d1839c038be400ae5eb20dafc14a3771a3239cd9e8acd53806"), &chip.knownDigest());

    const firmware = try makeFirmware(std.testing.allocator);
    defer std.testing.allocator.free(firmware);
    _ = try chip.validateFirmware(firmware, .allow_open_test, .open_test);
    try std.testing.expectError(error.InvalidSt018FirmwarePolicy, chip.validateFirmware(firmware, .allow_open_test, .separate));
    try std.testing.expectError(error.InvalidSt018FirmwareDigest, chip.validateFirmware(firmware, .known_only, .separate));
    try std.testing.expectError(error.InvalidSt018FirmwareSize, chip.validateFirmware(firmware[0 .. firmware.len - 1], .allow_open_test, .open_test));

    var device = try chip.Device.init(std.testing.allocator, firmware, .allow_open_test, .open_test);
    try std.testing.expectEqualSlices(u8, firmware[0..chip.program_rom_bytes], device.program_rom);
    try std.testing.expectEqualSlices(u8, firmware[chip.program_rom_bytes..], device.data_rom);
    try std.testing.expect(allZero(device.work_ram));
    device.close();
    device.close();
    try std.testing.expect(device.closed);
    try std.testing.expectEqual(@as(usize, 0), device.program_rom.len);
    try std.testing.expectEqual(@as(usize, 0), device.data_rom.len);
    try std.testing.expectEqual(@as(usize, 0), device.work_ram.len);
}

test "ARMv3 classifies every decoder key and all condition codes" {
    var seen = [_]bool{false} ** @typeInfo(arm.OpcodeClass).@"enum".fields.len;
    for (0..0x1000) |key| {
        const opcode = @as(u32, 0xe000_0000) |
            (@as(u32, @intCast(key & 0xff0)) << 16) |
            (@as(u32, @intCast(key & 0x00f)) << 4);
        seen[@intFromEnum(arm.classify(opcode))] = true;
    }
    // PSR transfers also constrain operand bits outside the compact
    // bits-27:20/bits-7:4 decoder key, so cover the canonical MRS form too.
    seen[@intFromEnum(arm.classify(0xe10f_0000))] = true;
    for ([_]arm.OpcodeClass{
        .data_processing,
        .psr_transfer,
        .multiply,
        .multiply_long,
        .single_transfer,
        .block_transfer,
        .swap,
        .branch,
        .software_interrupt,
        .undefined,
    }) |class| {
        try std.testing.expect(seen[@intFromEnum(class)]);
    }

    var psr = arm.Psr{};
    psr.zero = true;
    psr.carry = true;
    psr.negative = true;
    psr.overflow = false;
    const expected = [_]bool{
        true,  false, true,  false, true,  false, false, true,
        false, true,  false, true,  false, true,  true,  false,
    };
    for (expected, 0..) |value, condition| {
        try std.testing.expectEqual(value, arm.conditionPassed(psr, @intCast(condition)));
    }

    var cpu = arm.Cpu{};
    cpu.power();
    cpu.r[13] = 0x1111;
    cpu.r[14] = 0x2222;
    cpu.switchMode(.irq);
    try std.testing.expectEqual(@as(u32, 0), cpu.r[13]);
    cpu.r[13] = 0x3333;
    cpu.switchMode(.fiq);
    cpu.r[8] = 0x8888;
    cpu.switchMode(.supervisor);
    try std.testing.expectEqual(@as(u32, 0x1111), cpu.r[13]);
    try std.testing.expectEqual(@as(u32, 0), cpu.r[8]);
    cpu.switchMode(.irq);
    try std.testing.expectEqual(@as(u32, 0x3333), cpu.r[13]);
    cpu.switchMode(.fiq);
    try std.testing.expectEqual(@as(u32, 0x8888), cpu.r[8]);
}

test "ARMv3 ALU shifter multiply long multiply and PSR transfers execute through the pipeline" {
    var bus = FlatBus{};
    var cpu = arm.Cpu{};

    prepare(&bus, &cpu, 0xe090_2001); // ADDS r2,r0,r1
    cpu.r[0] = 0x7fff_ffff;
    cpu.r[1] = 1;
    const add = cpu.step(&bus);
    try std.testing.expectEqual(arm.OpcodeClass.data_processing, add.class);
    try std.testing.expectEqual(@as(u32, 0x8000_0000), cpu.r[2]);
    try std.testing.expect(cpu.cpsr.negative and cpu.cpsr.overflow and !cpu.cpsr.carry and !cpu.cpsr.zero);
    try std.testing.expectEqual(@as(u32, 0), bus.trace[0].address);
    try std.testing.expectEqual(@as(u32, 4), bus.trace[1].address);
    try std.testing.expectEqual(@as(u32, 8), bus.trace[2].address);

    prepare(&bus, &cpu, 0xe1b0_3021); // MOVS r3,r1,LSR #32
    cpu.r[1] = 0x8000_0001;
    _ = cpu.step(&bus);
    try std.testing.expectEqual(@as(u32, 0), cpu.r[3]);
    try std.testing.expect(cpu.cpsr.zero and cpu.cpsr.carry);

    prepare(&bus, &cpu, 0xe1a0_2110); // MOV r2,r0,LSL r1
    cpu.r[0] = 3;
    cpu.r[1] = 4;
    _ = cpu.step(&bus);
    try std.testing.expectEqual(@as(u32, 48), cpu.r[2]);
    try std.testing.expectEqual(@as(usize, 1), bus.idle_cycles);

    prepare(&bus, &cpu, 0xe004_0291); // MUL r4,r1,r2
    cpu.r[1] = 7;
    cpu.r[2] = 9;
    _ = cpu.step(&bus);
    try std.testing.expectEqual(@as(u32, 63), cpu.r[4]);
    try std.testing.expect(bus.idle_cycles >= 1);

    prepare(&bus, &cpu, 0xe085_4291); // UMULL r4,r5,r1,r2
    cpu.r[1] = 0xffff_ffff;
    cpu.r[2] = 2;
    _ = cpu.step(&bus);
    try std.testing.expectEqual(@as(u32, 0xffff_fffe), cpu.r[4]);
    try std.testing.expectEqual(@as(u32, 1), cpu.r[5]);

    prepare(&bus, &cpu, 0xe10f_6000); // MRS r6,CPSR
    cpu.cpsr.negative = true;
    cpu.cpsr.carry = true;
    _ = cpu.step(&bus);
    try std.testing.expectEqual(cpu.cpsr.bits(), cpu.r[6]);

    prepare(&bus, &cpu, 0xe128_f001); // MSR CPSR_f,r1
    cpu.r[1] = 0x5000_0000;
    _ = cpu.step(&bus);
    try std.testing.expect(!cpu.cpsr.negative and cpu.cpsr.zero and !cpu.cpsr.carry and cpu.cpsr.overflow);
}

test "ARMv3 executes all sixteen ALU operations and every barrel-shifter boundary family" {
    const alu_expected = [_]u32{
        0x0000_0001, 0x0000_0006, 0x0000_0002, 0xffff_fffe,
        0x0000_0008, 0x0000_0009, 0x0000_0002, 0xffff_fffe,
        0xfeed_face, 0xfeed_face, 0xfeed_face, 0xfeed_face,
        0x0000_0007, 0x0000_0003, 0x0000_0004, 0xffff_fffc,
    };
    for (alu_expected, 0..) |expected, operation| {
        var bus = FlatBus{};
        var cpu = arm.Cpu{};
        const opcode = @as(u32, 0xe010_2001) | (@as(u32, @intCast(operation)) << 21);
        prepare(&bus, &cpu, opcode);
        cpu.r[0] = 5;
        cpu.r[1] = 3;
        cpu.r[2] = 0xfeed_face;
        cpu.cpsr.carry = true;
        const result = cpu.step(&bus);
        try std.testing.expectEqual(arm.OpcodeClass.data_processing, result.class);
        try std.testing.expectEqual(expected, cpu.r[2]);
        try std.testing.expect(result.executed);
    }

    const cases = [_]struct {
        kind: u2,
        amount: u8,
        register: bool,
        input: u32,
        carry_in: bool,
        expected: u32,
        carry_out: bool,
    }{
        .{ .kind = 0, .amount = 0, .register = false, .input = 0x8000_0001, .carry_in = true, .expected = 0x8000_0001, .carry_out = true },
        .{ .kind = 0, .amount = 31, .register = false, .input = 1, .carry_in = true, .expected = 0x8000_0000, .carry_out = false },
        .{ .kind = 0, .amount = 32, .register = true, .input = 1, .carry_in = false, .expected = 0, .carry_out = true },
        .{ .kind = 0, .amount = 33, .register = true, .input = 1, .carry_in = true, .expected = 0, .carry_out = false },
        .{ .kind = 1, .amount = 0, .register = false, .input = 0x8000_0001, .carry_in = false, .expected = 0, .carry_out = true },
        .{ .kind = 1, .amount = 0, .register = true, .input = 0x8000_0001, .carry_in = true, .expected = 0x8000_0001, .carry_out = true },
        .{ .kind = 1, .amount = 32, .register = true, .input = 0x8000_0001, .carry_in = false, .expected = 0, .carry_out = true },
        .{ .kind = 2, .amount = 0, .register = false, .input = 0x8000_0001, .carry_in = false, .expected = 0xffff_ffff, .carry_out = true },
        .{ .kind = 2, .amount = 33, .register = true, .input = 0x8000_0001, .carry_in = false, .expected = 0xffff_ffff, .carry_out = true },
        .{ .kind = 3, .amount = 0, .register = false, .input = 2, .carry_in = true, .expected = 0x8000_0001, .carry_out = false },
        .{ .kind = 3, .amount = 0, .register = true, .input = 0x8000_0001, .carry_in = false, .expected = 0x8000_0001, .carry_out = false },
        .{ .kind = 3, .amount = 32, .register = true, .input = 0x8000_0001, .carry_in = false, .expected = 0x8000_0001, .carry_out = true },
        .{ .kind = 3, .amount = 36, .register = true, .input = 0x1234_5678, .carry_in = false, .expected = 0x8123_4567, .carry_out = true },
    };
    for (cases) |case| {
        var bus = FlatBus{};
        var cpu = arm.Cpu{};
        const opcode = if (case.register)
            @as(u32, 0xe1b0_2010) | (@as(u32, case.kind) << 5) | (@as(u32, 1) << 8)
        else
            @as(u32, 0xe1b0_2000) | (@as(u32, case.kind) << 5) | (@as(u32, case.amount & 31) << 7);
        prepare(&bus, &cpu, opcode);
        cpu.r[0] = case.input;
        cpu.r[1] = case.amount;
        cpu.cpsr.carry = case.carry_in;
        _ = cpu.step(&bus);
        try std.testing.expectEqual(case.expected, cpu.r[2]);
        try std.testing.expectEqual(case.carry_out, cpu.cpsr.carry);
        try std.testing.expectEqual(@as(usize, @intFromBool(case.register)), bus.idle_cycles);
    }
}

test "ARMv3 multiply-accumulate and signed-long matrix preserves exact high and low words" {
    var bus = FlatBus{};
    var cpu = arm.Cpu{};

    prepare(&bus, &cpu, 0xe024_3291); // MLA r4,r1,r2,r3
    cpu.r[1] = 7;
    cpu.r[2] = 9;
    cpu.r[3] = 5;
    _ = cpu.step(&bus);
    try std.testing.expectEqual(@as(u32, 68), cpu.r[4]);

    prepare(&bus, &cpu, 0xe0a5_4291); // UMLAL r4,r5,r1,r2
    cpu.r[1] = 7;
    cpu.r[2] = 9;
    cpu.r[4] = 10;
    cpu.r[5] = 1;
    _ = cpu.step(&bus);
    try std.testing.expectEqual(@as(u32, 73), cpu.r[4]);
    try std.testing.expectEqual(@as(u32, 1), cpu.r[5]);

    prepare(&bus, &cpu, 0xe0c5_4291); // SMULL r4,r5,r1,r2
    cpu.r[1] = @bitCast(@as(i32, -2));
    cpu.r[2] = 3;
    _ = cpu.step(&bus);
    try std.testing.expectEqual(@as(u32, 0xffff_fffa), cpu.r[4]);
    try std.testing.expectEqual(@as(u32, 0xffff_ffff), cpu.r[5]);

    prepare(&bus, &cpu, 0xe0e5_4291); // SMLAL r4,r5,r1,r2
    cpu.r[1] = @bitCast(@as(i32, -2));
    cpu.r[2] = 3;
    cpu.r[4] = 10;
    cpu.r[5] = 0;
    _ = cpu.step(&bus);
    try std.testing.expectEqual(@as(u32, 4), cpu.r[4]);
    try std.testing.expectEqual(@as(u32, 0), cpu.r[5]);
}

test "ARMv3 single block swap branch and exception paths preserve architectural ordering" {
    var bus = FlatBus{};
    var cpu = arm.Cpu{};

    prepare(&bus, &cpu, 0xe5a1_0004); // STR r0,[r1,#4]!
    cpu.r[0] = 0x1122_3344;
    cpu.r[1] = 0x200;
    _ = cpu.step(&bus);
    try std.testing.expectEqual(@as(u32, 0x204), cpu.r[1]);
    try std.testing.expectEqualSlices(u8, &.{ 0x44, 0x33, 0x22, 0x11 }, bus.memory[0x204..0x208]);

    prepare(&bus, &cpu, 0xe591_2001); // LDR r2,[r1,#1]
    cpu.r[1] = 0x200;
    putWord(&bus.memory, 0x200, 0x1122_3344);
    _ = cpu.step(&bus);
    try std.testing.expectEqual(@as(u32, 0x4411_2233), cpu.r[2]);
    try std.testing.expectEqual(@as(usize, 1), bus.idle_cycles);

    prepare(&bus, &cpu, 0xe8a4_0007); // STMIA r4!,{r0-r2}
    cpu.r[0] = 0x11;
    cpu.r[1] = 0x22;
    cpu.r[2] = 0x33;
    cpu.r[4] = 0x300;
    _ = cpu.step(&bus);
    try std.testing.expectEqual(@as(u32, 0x30c), cpu.r[4]);
    try std.testing.expectEqual(@as(u32, 0x11), readWord(&bus.memory, 0x300));
    try std.testing.expectEqual(@as(u32, 0x22), readWord(&bus.memory, 0x304));
    try std.testing.expectEqual(@as(u32, 0x33), readWord(&bus.memory, 0x308));

    prepare(&bus, &cpu, 0xe104_3090); // SWP r3,r0,[r4]
    cpu.r[0] = 0xaabb_ccdd;
    cpu.r[4] = 0x340;
    putWord(&bus.memory, 0x340, 0x5566_7788);
    _ = cpu.step(&bus);
    try std.testing.expectEqual(@as(u32, 0x5566_7788), cpu.r[3]);
    try std.testing.expectEqual(@as(u32, 0xaabb_ccdd), readWord(&bus.memory, 0x340));

    prepare(&bus, &cpu, 0xeb00_0006); // BL 0x20
    _ = cpu.step(&bus);
    try std.testing.expectEqual(@as(u32, 0x20), cpu.r[15]);
    try std.testing.expectEqual(@as(u32, 4), cpu.r[14]);
    try std.testing.expect(cpu.pipeline.reload);

    prepare(&bus, &cpu, 0xef00_0042); // SWI
    _ = cpu.step(&bus);
    try std.testing.expectEqual(arm.Exception.software_interrupt, cpu.last_exception.?);
    try std.testing.expectEqual(arm.Mode.supervisor, cpu.cpsr.mode);
    try std.testing.expectEqual(@as(u32, 8), cpu.r[15]);
    try std.testing.expectEqual(@as(u32, 4), cpu.r[14]);

    prepare(&bus, &cpu, 0xee00_0010); // coprocessor encoding: undefined on ARM60/ST018
    _ = cpu.step(&bus);
    try std.testing.expectEqual(arm.Exception.undefined, cpu.last_exception.?);
    try std.testing.expectEqual(arm.Mode.undefined, cpu.cpsr.mode);
    try std.testing.expectEqual(@as(u32, 4), cpu.r[15]);

    prepare(&bus, &cpu, 0xe591_2000); // data abort
    cpu.r[1] = 0x200;
    bus.abort_data = 0x200;
    _ = cpu.step(&bus);
    try std.testing.expectEqual(arm.Exception.data_abort, cpu.last_exception.?);
    try std.testing.expectEqual(arm.Mode.abort, cpu.cpsr.mode);
    try std.testing.expectEqual(@as(u32, 0x10), cpu.r[15]);

    prepare(&bus, &cpu, 0xe1a0_0000);
    bus.abort_prefetch = 0;
    _ = cpu.step(&bus);
    try std.testing.expectEqual(arm.Exception.prefetch_abort, cpu.last_exception.?);

    prepare(&bus, &cpu, 0xe1a0_0000);
    cpu.cpsr.irq_disabled = false;
    cpu.setIrq(true);
    _ = cpu.step(&bus);
    try std.testing.expectEqual(arm.Exception.irq, cpu.last_exception.?);
    try std.testing.expectEqual(arm.Mode.irq, cpu.cpsr.mode);
    try std.testing.expectEqual(@as(u32, 0x18), cpu.r[15]);
}

test "ST018 productive bridge mirrors handshake reset timer and exact RAM without shared state" {
    const firmware = try makeFirmware(std.testing.allocator);
    defer std.testing.allocator.free(firmware);
    installBridgeProgram(firmware);
    var first = try chip.Device.init(std.testing.allocator, firmware, .allow_open_test, .open_test);
    defer first.close();
    var second = try chip.Device.init(std.testing.allocator, firmware, .allow_open_test, .open_test);
    defer second.close();
    first.reset_delay = 0;
    first.ready = true;
    second.reset_delay = 0;
    second.ready = true;
    const second_before = second.stateDigest();

    const first_run = first.runSlice(4);
    try std.testing.expectEqual(@as(usize, 4), first_run.instructions);
    try std.testing.expectEqual(@as(u8, 0x81), first.readCpu(0x8038fc, 0).?);
    try std.testing.expectEqual(@as(u8, 0x5a), first.readCpu(0x003800, 0).?);
    try std.testing.expectEqual(@as(u8, 0x80), first.status());
    try std.testing.expect(first.writeCpu(0x0038fa, 0x37));
    try std.testing.expect((first.status() & 0x08) != 0);
    _ = first.runSlice(5);
    try std.testing.expectEqual(@as(u8, 0x38), first.readCpu(0x8038f8, 0).?);

    _ = first.writeByte(0x4000_0010, 0);
    try std.testing.expect((first.status() & 0x04) != 0);
    _ = first.readCpu(0x003802, 0).?;
    try std.testing.expect((first.status() & 0x04) == 0);
    _ = first.writeByte(0x4000_0020, 3);
    _ = first.writeByte(0x4000_0024, 0);
    _ = first.writeByte(0x4000_0028, 0);
    _ = first.writeByte(0x4000_002c, 0);
    first.idle();
    try std.testing.expectEqual(@as(u32, 2), first.timer);

    _ = first.writeByte(0xe000_0123, 0xa5);
    _ = first.writeWord(0xe000_3ffc, 0x4433_2211);
    try std.testing.expectEqual(@as(u8, 0xa5), first.work_ram[0x123]);
    const dirty = first.takeDirtyRange().?;
    try std.testing.expectEqual(@as(usize, 0x123), dirty.first);
    try std.testing.expectEqual(@as(usize, 0x4000), dirty.end);
    var saved = [_]u8{0} ** chip.work_ram_bytes;
    try first.copyPersistentRamRange(&saved, dirty.first, dirty.end);

    try std.testing.expect(first.writeCpu(0x003804, 1));
    try std.testing.expect(first.reset_hold);
    try std.testing.expectEqual(@as(u8, 0xa5), first.work_ram[0x123]);
    try std.testing.expectEqual(chip.RunState.reset_hold, first.runSlice(10).state);
    try std.testing.expect(first.writeCpu(0x003804, 0));
    try std.testing.expectEqual(chip.RunState.reset_delay, first.runSlice(7).state);
    try std.testing.expectEqual(second_before, second.stateDigest());

    try second.restorePersistentRam(&saved);
    try std.testing.expectEqual(@as(u8, 0xa5), second.work_ram[0x123]);
    try std.testing.expectError(error.InvalidSt018PersistentRamSize, second.restorePersistentRam(saved[0 .. saved.len - 1]));
}

test "ST018 slices and two instances are partition invariant after the fixed ready delay" {
    const firmware = try makeFirmware(std.testing.allocator);
    defer std.testing.allocator.free(firmware);
    installBridgeProgram(firmware);
    var one = try chip.Device.init(std.testing.allocator, firmware, .allow_open_test, .open_test);
    defer one.close();
    var many = try chip.Device.init(std.testing.allocator, firmware, .allow_open_test, .open_test);
    defer many.close();
    one.reset_delay = 0;
    one.ready = true;
    many.reset_delay = 0;
    many.ready = true;
    _ = one.runSlice(200);
    var remaining: usize = 200;
    var amount: usize = 1;
    while (remaining != 0) {
        const current = @min(amount, remaining);
        _ = many.runSlice(current);
        remaining -= current;
        amount = (amount * 7) % 19 + 1;
    }
    try std.testing.expectEqual(one.stateDigest(), many.stateDigest());
    try std.testing.expectEqual(one.cpu.cycle_count, many.cpu.cycle_count);
    try std.testing.expectEqual(one.cpu.instruction_count, many.cpu.instruction_count);

    var delayed = try chip.Device.init(std.testing.allocator, firmware, .allow_open_test, .open_test);
    defer delayed.close();
    const delay = delayed.runSlice(chip.reset_delay_cycles);
    try std.testing.expectEqual(chip.RunState.running, delay.state);
    try std.testing.expect(delayed.ready);
    try std.testing.expectEqual(@as(usize, 0), delay.instructions);
    try std.testing.expectEqual(@as(u64, chip.reset_delay_cycles), delay.cycles);
}

test "ST018 cartridge header firmware bus and 16-KiB canonical save boundary fail closed" {
    const allocator = std.testing.allocator;
    const firmware = try makeFirmware(allocator);
    defer allocator.free(firmware);
    const image = try makeSt018Image(allocator, 1024 * 1024, 0x02);
    defer allocator.free(image);

    const requirement = (try core.cartridge.inspectSt018Requirement(image)).?;
    try std.testing.expectEqual(@as(usize, chip.firmware_bytes), requirement.firmwareBytes());
    try std.testing.expectEqualStrings(chip.firmware_path, requirement.firmwarePath());
    try std.testing.expectError(error.MissingSt018Firmware, core.cartridge.Cartridge.parse(allocator, image));
    var cart = try core.cartridge.Cartridge.parseWithOptions(allocator, image, .{
        .st018_firmware = firmware,
        .st018_firmware_validation = .allow_open_test,
    });
    defer cart.deinit();
    try std.testing.expectEqual(core.board.Enhancement.st018, cart.board.capability.enhancement);
    try std.testing.expect(cart.board.readyForExecution());
    try std.testing.expect(cart.board.battery);
    try std.testing.expectEqual(@as(usize, chip.work_ram_bytes), cart.sram_storage.len);
    try std.testing.expect(cart.st018_device != null);
    try std.testing.expect(cart.board.sramIndex(0x700000) == null);

    var bus = core.bus.Bus{};
    var mmio = core.bus.NullMmio{};
    const status = bus.read(&cart, &mmio, 0x003804);
    try std.testing.expectEqual(core.bus.AccessClass.cartridge_chip, status.class);
    try std.testing.expectEqual(chip.access_master_cycles, status.master_cycles);
    const write = bus.write(&cart, &mmio, 0x803802, 0x91);
    try std.testing.expectEqual(core.bus.AccessClass.cartridge_chip, write.class);
    try std.testing.expectEqual(@as(u8, 0x08), cart.st018_device.?.status() & 0x08);

    _ = cart.st018_device.?.writeByte(0xe000_0222, 0x6d);
    _ = cart.runSt018Slice(0).?;
    try std.testing.expect(cart.sram_dirty);
    try std.testing.expectEqual(@as(u8, 0x6d), cart.sram_storage[0x222]);

    const wrong_subtype = try makeSt018Image(allocator, 1024 * 1024, 0x01);
    defer allocator.free(wrong_subtype);
    try std.testing.expectError(error.ContradictorySt018Board, core.cartridge.Cartridge.parseWithOptions(allocator, wrong_subtype, .{
        .st018_firmware = firmware,
        .st018_firmware_validation = .allow_open_test,
    }));
    const normal = try makeNormalImage(allocator, 1024 * 1024);
    defer allocator.free(normal);
    try std.testing.expectError(error.UnexpectedSt018Firmware, core.cartridge.Cartridge.parseWithOptions(allocator, normal, .{
        .st018_firmware = firmware,
        .st018_firmware_validation = .allow_open_test,
    }));
}

fn prepare(bus: *FlatBus, cpu: *arm.Cpu, opcode: u32) void {
    bus.* = .{};
    putWord(&bus.memory, 0, opcode);
    putWord(&bus.memory, 4, 0xe1a0_0000);
    putWord(&bus.memory, 8, 0xe1a0_0000);
    cpu.power();
}

fn makeFirmware(allocator: std.mem.Allocator) ![]u8 {
    const firmware = try allocator.alloc(u8, chip.firmware_bytes);
    @memset(firmware, 0);
    for (firmware[chip.program_rom_bytes..], 0..) |*value, index| value.* = @truncate(index *% 37 +% 11);
    putWord(firmware, 0, 0xeaff_fffe);
    return firmware;
}

fn installBridgeProgram(firmware: []u8) void {
    @memset(firmware[0..chip.program_rom_bytes], 0);
    putWord(firmware, 0x000, 0xea00_003e); // B 0x100
    putWord(firmware, 0x100, 0xe3a0_1101); // MOV r1,#0x40000000
    putWord(firmware, 0x104, 0xe3a0_005a); // MOV r0,#0x5a
    putWord(firmware, 0x108, 0xe5c1_0000); // STRB r0,[r1]
    putWord(firmware, 0x10c, 0xe281_1010); // ADD r1,r1,#0x10
    putWord(firmware, 0x110, 0xe5d1_2000); // LDRB r2,[r1]
    putWord(firmware, 0x114, 0xe241_1010); // SUB r1,r1,#0x10
    putWord(firmware, 0x118, 0xe282_0001); // ADD r0,r2,#1
    putWord(firmware, 0x11c, 0xe5c1_0000); // STRB r0,[r1]
    putWord(firmware, 0x120, 0xeaff_fffe); // B .
}

fn putWord(memory: []u8, index: usize, value: u32) void {
    memory[index] = @truncate(value);
    memory[index + 1] = @truncate(value >> 8);
    memory[index + 2] = @truncate(value >> 16);
    memory[index + 3] = @truncate(value >> 24);
}

fn readWord(memory: []const u8, index: usize) u32 {
    return @as(u32, memory[index]) |
        (@as(u32, memory[index + 1]) << 8) |
        (@as(u32, memory[index + 2]) << 16) |
        (@as(u32, memory[index + 3]) << 24);
}

fn makeSt018Image(allocator: std.mem.Allocator, rom_size: usize, subtype: u8) ![]u8 {
    const image = try makeNormalImage(allocator, rom_size);
    const header = image[0x7fc0 .. 0x7fc0 + core.cartridge.header_length];
    header[0x15] = 0x30;
    header[0x16] = 0xf5;
    header[0x18] = 4;
    image[0x7fbf] = subtype;
    finalizeChecksum(image, header);
    return image;
}

fn makeNormalImage(allocator: std.mem.Allocator, rom_size: usize) ![]u8 {
    const image = try allocator.alloc(u8, rom_size);
    @memset(image, 0xea);
    const header = image[0x7fc0 .. 0x7fc0 + core.cartridge.header_length];
    @memset(header, 0);
    @memset(header[0..core.cartridge.title_length], ' ');
    @memcpy(header[0..17], "R4SNES ST018 TEST");
    header[0x15] = 0x20;
    header[0x16] = 0x00;
    header[0x17] = romSizeCode(rom_size);
    header[0x18] = 0;
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

fn allZero(bytes: []const u8) bool {
    for (bytes) |value| if (value != 0) return false;
    return true;
}

fn decodeSha256(text: []const u8) ![32]u8 {
    if (text.len != 64) return error.InvalidHash;
    var result: [32]u8 = undefined;
    for (0..32) |index| {
        result[index] = (try hexNibble(text[index * 2]) << 4) | try hexNibble(text[index * 2 + 1]);
    }
    return result;
}

fn hexNibble(value: u8) !u8 {
    return switch (value) {
        '0'...'9' => value - '0',
        'a'...'f' => value - 'a' + 10,
        'A'...'F' => value - 'A' + 10,
        else => error.InvalidHash,
    };
}
