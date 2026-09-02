const std = @import("std");

/// ARMv3/ARM60 execution core used by the ST018 owner.  The core deliberately
/// has no knowledge of the SNES cartridge map: callers provide the byte/word
/// bus and receive every prefetch, data access and idle cycle in order.
pub const Mode = enum(u5) {
    user = 0x10,
    fiq = 0x11,
    irq = 0x12,
    supervisor = 0x13,
    abort = 0x17,
    undefined = 0x1b,
    system = 0x1f,
};

pub const Exception = enum(u32) {
    reset = 0x00,
    undefined = 0x04,
    software_interrupt = 0x08,
    prefetch_abort = 0x0c,
    data_abort = 0x10,
    irq = 0x18,
    fiq = 0x1c,
};

pub const Psr = struct {
    negative: bool = false,
    zero: bool = false,
    carry: bool = false,
    overflow: bool = false,
    irq_disabled: bool = false,
    fiq_disabled: bool = false,
    mode: Mode = .supervisor,

    pub fn bits(self: Psr) u32 {
        return (@as(u32, @intFromBool(self.negative)) << 31) |
            (@as(u32, @intFromBool(self.zero)) << 30) |
            (@as(u32, @intFromBool(self.carry)) << 29) |
            (@as(u32, @intFromBool(self.overflow)) << 28) |
            (@as(u32, @intFromBool(self.irq_disabled)) << 7) |
            (@as(u32, @intFromBool(self.fiq_disabled)) << 6) |
            @as(u32, @intFromEnum(self.mode));
    }
};

pub const ReadResult = struct {
    value: u32 = 0,
    abort: bool = false,
};

pub const Stage = struct {
    address: u32 = 0,
    opcode: u32 = 0,
    valid: bool = false,
};

pub const Pipeline = struct {
    execute: Stage = .{},
    decode: Stage = .{},
    fetch: Stage = .{},
    next_address: u32 = 0,
    reload: bool = true,
};

pub const OpcodeClass = enum {
    data_processing,
    psr_transfer,
    multiply,
    multiply_long,
    single_transfer,
    block_transfer,
    swap,
    branch,
    software_interrupt,
    undefined,
    condition_failed,
};

pub const StepResult = struct {
    class: OpcodeClass,
    executed: bool,
    exception: ?Exception,
    cycles: u64,
};

pub const Cpu = struct {
    r: [16]u32 = .{0} ** 16,
    cpsr: Psr = .{ .irq_disabled = true, .fiq_disabled = true },
    user_regs: [7]u32 = .{0} ** 7,
    fiq_regs: [7]u32 = .{0} ** 7,
    irq_regs: [2]u32 = .{0} ** 2,
    supervisor_regs: [2]u32 = .{0} ** 2,
    abort_regs: [2]u32 = .{0} ** 2,
    undefined_regs: [2]u32 = .{0} ** 2,
    fiq_spsr: Psr = .{},
    irq_spsr: Psr = .{},
    supervisor_spsr: Psr = .{},
    abort_spsr: Psr = .{},
    undefined_spsr: Psr = .{},
    pipeline: Pipeline = .{},
    irq_line: bool = false,
    fiq_line: bool = false,
    cycle_count: u64 = 0,
    instruction_count: u64 = 0,
    condition_skips: u64 = 0,
    undefined_count: u64 = 0,
    last_exception: ?Exception = null,
    data_abort_active: bool = false,

    pub fn power(self: *Cpu) void {
        self.* = .{};
        self.cpsr = .{
            .mode = .supervisor,
            .irq_disabled = true,
            .fiq_disabled = true,
        };
        self.pipeline.reload = true;
    }

    pub fn reset(self: *Cpu) void {
        const cycles = self.cycle_count;
        self.power();
        self.cycle_count = cycles;
    }

    pub fn setIrq(self: *Cpu, asserted: bool) void {
        self.irq_line = asserted;
    }

    pub fn setFiq(self: *Cpu, asserted: bool) void {
        self.fiq_line = asserted;
    }

    pub fn setProgramCounter(self: *Cpu, address: u32) void {
        self.r[15] = address & ~@as(u32, 3);
        self.pipeline.reload = true;
    }

    pub fn step(self: *Cpu, bus: anytype) StepResult {
        const cycles_before = self.cycle_count;
        self.last_exception = null;
        self.data_abort_active = false;

        if (self.fiq_line and !self.cpsr.fiq_disabled) {
            self.enterException(.fiq);
            return self.result(.undefined, false, cycles_before);
        }
        if (self.irq_line and !self.cpsr.irq_disabled) {
            self.enterException(.irq);
            return self.result(.undefined, false, cycles_before);
        }
        if (self.pipeline.reload and !self.reloadPipeline(bus)) {
            return self.result(.undefined, false, cycles_before);
        }

        const instruction = self.pipeline.execute;
        self.r[15] = instruction.address +% 8;
        const condition: u4 = @truncate(instruction.opcode >> 28);
        var class = classify(instruction.opcode);
        var executed = false;
        if (conditionPassed(self.cpsr, condition)) {
            executed = true;
            self.execute(bus, instruction.opcode, class);
            self.instruction_count +%= 1;
        } else {
            class = .condition_failed;
            self.condition_skips +%= 1;
        }

        if (!self.pipeline.reload) self.advancePipeline(bus);
        return self.result(class, executed, cycles_before);
    }

    fn result(self: *const Cpu, class: OpcodeClass, executed: bool, cycles_before: u64) StepResult {
        return .{
            .class = class,
            .executed = executed,
            .exception = self.last_exception,
            .cycles = self.cycle_count -% cycles_before,
        };
    }

    fn reloadPipeline(self: *Cpu, bus: anytype) bool {
        const target = self.r[15] & ~@as(u32, 3);
        self.pipeline = .{ .reload = false, .next_address = target +% 8 };
        const execute_opcode = self.prefetch(bus, target) orelse return false;
        const decode = self.prefetch(bus, target +% 4) orelse return false;
        self.pipeline.execute = .{ .address = target, .opcode = execute_opcode, .valid = true };
        self.pipeline.decode = .{ .address = target +% 4, .opcode = decode, .valid = true };
        self.pipeline.fetch = .{ .address = target +% 8 };
        self.r[15] = target +% 8;
        return true;
    }

    fn advancePipeline(self: *Cpu, bus: anytype) void {
        const address = self.pipeline.next_address;
        const opcode = self.prefetch(bus, address) orelse return;
        self.pipeline.fetch = .{ .address = address, .opcode = opcode, .valid = true };
        self.pipeline.execute = self.pipeline.decode;
        self.pipeline.decode = self.pipeline.fetch;
        self.pipeline.next_address = address +% 4;
        self.r[15] = self.pipeline.execute.address +% 8;
    }

    fn prefetch(self: *Cpu, bus: anytype, address: u32) ?u32 {
        self.cycle_count +%= 1;
        const access: ReadResult = bus.readWord(address & ~@as(u32, 3), true);
        if (access.abort) {
            self.enterException(.prefetch_abort);
            return null;
        }
        return access.value;
    }

    fn readWord(self: *Cpu, bus: anytype, address: u32, rotate: bool) ?u32 {
        self.cycle_count +%= 1;
        const access: ReadResult = bus.readWord(address & ~@as(u32, 3), false);
        if (access.abort) {
            self.enterException(.data_abort);
            self.data_abort_active = true;
            return null;
        }
        if (!rotate) return access.value;
        return rotateRight(access.value, (address & 3) * 8);
    }

    fn readByte(self: *Cpu, bus: anytype, address: u32) ?u8 {
        self.cycle_count +%= 1;
        const access: ReadResult = bus.readByte(address, false);
        if (access.abort) {
            self.enterException(.data_abort);
            self.data_abort_active = true;
            return null;
        }
        return @truncate(access.value);
    }

    fn writeWord(self: *Cpu, bus: anytype, address: u32, value: u32) bool {
        self.cycle_count +%= 1;
        if (bus.writeWord(address & ~@as(u32, 3), value)) {
            self.enterException(.data_abort);
            self.data_abort_active = true;
            return false;
        }
        return true;
    }

    fn writeByte(self: *Cpu, bus: anytype, address: u32, value: u8) bool {
        self.cycle_count +%= 1;
        if (bus.writeByte(address, value)) {
            self.enterException(.data_abort);
            self.data_abort_active = true;
            return false;
        }
        return true;
    }

    fn idle(self: *Cpu, bus: anytype) void {
        self.cycle_count +%= 1;
        bus.idle();
    }

    fn execute(self: *Cpu, bus: anytype, opcode: u32, class: OpcodeClass) void {
        switch (class) {
            .data_processing => self.dataProcessing(bus, opcode),
            .psr_transfer => self.psrTransfer(opcode),
            .multiply => self.multiply(bus, opcode),
            .multiply_long => self.multiplyLong(bus, opcode),
            .single_transfer => self.singleTransfer(bus, opcode),
            .block_transfer => self.blockTransfer(bus, opcode),
            .swap => self.swap(bus, opcode),
            .branch => self.branch(opcode),
            .software_interrupt => self.enterException(.software_interrupt),
            .undefined => {
                self.undefined_count +%= 1;
                self.enterException(.undefined);
            },
            .condition_failed => {},
        }
    }

    fn dataProcessing(self: *Cpu, bus: anytype, opcode: u32) void {
        const immediate = (opcode & (@as(u32, 1) << 25)) != 0;
        const operation: u4 = @truncate(opcode >> 21);
        const set_flags = (opcode & (@as(u32, 1) << 20)) != 0;
        const rn: u4 = @truncate(opcode >> 16);
        const rd: u4 = @truncate(opcode >> 12);
        var left = self.readRegister(rn);
        var shifted: ShifterResult = undefined;

        if (immediate) {
            const amount: u32 = ((opcode >> 8) & 0x0f) * 2;
            const value = opcode & 0xff;
            shifted = if (amount == 0)
                .{ .value = value, .carry = self.cpsr.carry }
            else
                .{ .value = rotateRight(value, amount), .carry = ((value >> @intCast(amount - 1)) & 1) != 0 };
        } else {
            const rm: u4 = @truncate(opcode);
            const register_shift = (opcode & 0x10) != 0;
            var value = self.readRegister(rm);
            var amount: u32 = undefined;
            if (register_shift) {
                const rs: u4 = @truncate(opcode >> 8);
                amount = self.readRegister(rs) & 0xff;
                self.idle(bus);
                if (rm == 15) value +%= 4;
                if (rn == 15) left +%= 4;
            } else {
                amount = (opcode >> 7) & 0x1f;
            }
            shifted = shift(value, @truncate(opcode >> 5), amount, register_shift, self.cpsr.carry);
        }

        const right = shifted.value;
        var result_value: u32 = 0;
        var writes_result = true;
        switch (operation) {
            0x0 => result_value = self.logical(left & right, shifted.carry, set_flags),
            0x1 => result_value = self.logical(left ^ right, shifted.carry, set_flags),
            0x2 => result_value = self.subtract(left, right, true, set_flags),
            0x3 => result_value = self.subtract(right, left, true, set_flags),
            0x4 => result_value = self.add(left, right, false, set_flags),
            0x5 => result_value = self.add(left, right, self.cpsr.carry, set_flags),
            0x6 => result_value = self.subtract(left, right, self.cpsr.carry, set_flags),
            0x7 => result_value = self.subtract(right, left, self.cpsr.carry, set_flags),
            0x8 => {
                _ = self.logical(left & right, shifted.carry, true);
                writes_result = false;
            },
            0x9 => {
                _ = self.logical(left ^ right, shifted.carry, true);
                writes_result = false;
            },
            0xa => {
                _ = self.subtract(left, right, true, true);
                writes_result = false;
            },
            0xb => {
                _ = self.add(left, right, false, true);
                writes_result = false;
            },
            0xc => result_value = self.logical(left | right, shifted.carry, set_flags),
            0xd => result_value = self.logical(right, shifted.carry, set_flags),
            0xe => result_value = self.logical(left & ~right, shifted.carry, set_flags),
            0xf => result_value = self.logical(~right, shifted.carry, set_flags),
        }
        if (writes_result) self.setRegister(rd, result_value);
        if (writes_result and rd == 15 and set_flags) self.restoreFromSpsr();
    }

    fn psrTransfer(self: *Cpu, opcode: u32) void {
        if ((opcode & 0x0fbf_0fff) == 0x010f_0000) {
            const use_spsr = (opcode & (@as(u32, 1) << 22)) != 0;
            const rd: u4 = @truncate(opcode >> 12);
            const value = if (use_spsr) blk: {
                const saved = self.spsr() orelse self.cpsr;
                break :blk saved.bits();
            } else self.cpsr.bits();
            self.setRegister(rd, value);
            return;
        }

        const immediate = (opcode & (@as(u32, 1) << 25)) != 0;
        const to_spsr = (opcode & (@as(u32, 1) << 22)) != 0;
        const mask: u4 = @truncate(opcode >> 16);
        var value = if (immediate) opcode & 0xff else self.readRegister(@truncate(opcode));
        if (immediate) value = rotateRight(value, ((opcode >> 8) & 0x0f) * 2);
        if (to_spsr) {
            if (self.spsrPointer()) |saved| writePsr(saved, value, mask, true);
            return;
        }
        const privileged = self.cpsr.mode != .user;
        const old_mode = self.cpsr.mode;
        var next = self.cpsr;
        writePsr(&next, value, mask, privileged);
        if (next.mode != old_mode) self.switchMode(next.mode);
        self.cpsr = next;
    }

    fn multiply(self: *Cpu, bus: anytype, opcode: u32) void {
        const accumulate = (opcode & (@as(u32, 1) << 21)) != 0;
        const set_flags = (opcode & (@as(u32, 1) << 20)) != 0;
        const rd: u4 = @truncate(opcode >> 16);
        const rn: u4 = @truncate(opcode >> 12);
        const rs: u4 = @truncate(opcode >> 8);
        const rm: u4 = @truncate(opcode);
        const multiplier = self.readRegister(rs);
        var product = self.readRegister(rm) *% multiplier;
        var cycles = multiplyCycles(multiplier);
        while (cycles != 0) : (cycles -= 1) self.idle(bus);
        if (accumulate) {
            product +%= self.readRegister(rn);
            self.idle(bus);
        }
        if (rd != 15) self.setRegister(rd, product);
        if (set_flags) {
            self.cpsr.negative = (product & 0x8000_0000) != 0;
            self.cpsr.zero = product == 0;
        }
    }

    fn multiplyLong(self: *Cpu, bus: anytype, opcode: u32) void {
        const signed = (opcode & (@as(u32, 1) << 22)) != 0;
        const accumulate = (opcode & (@as(u32, 1) << 21)) != 0;
        const set_flags = (opcode & (@as(u32, 1) << 20)) != 0;
        const rd_hi: u4 = @truncate(opcode >> 16);
        const rd_lo: u4 = @truncate(opcode >> 12);
        const rs: u4 = @truncate(opcode >> 8);
        const rm: u4 = @truncate(opcode);
        const left = self.readRegister(rm);
        const right = self.readRegister(rs);
        var product: u64 = if (signed) blk: {
            const a: i32 = @bitCast(left);
            const b: i32 = @bitCast(right);
            const product: i64 = @as(i64, a) * @as(i64, b);
            break :blk @bitCast(product);
        } else @as(u64, left) * @as(u64, right);
        self.idle(bus);
        var cycles = multiplyCycles(right);
        while (cycles != 0) : (cycles -= 1) self.idle(bus);
        if (accumulate) {
            product +%= (@as(u64, self.readRegister(rd_hi)) << 32) | self.readRegister(rd_lo);
            self.idle(bus);
        }
        if (rd_lo != 15) self.setRegister(rd_lo, @truncate(product));
        if (rd_hi != 15) self.setRegister(rd_hi, @truncate(product >> 32));
        if (set_flags) {
            self.cpsr.negative = (product & (@as(u64, 1) << 63)) != 0;
            self.cpsr.zero = product == 0;
        }
    }

    fn singleTransfer(self: *Cpu, bus: anytype, opcode: u32) void {
        const register_offset = (opcode & (@as(u32, 1) << 25)) != 0;
        const pre = (opcode & (@as(u32, 1) << 24)) != 0;
        const up = (opcode & (@as(u32, 1) << 23)) != 0;
        const byte = (opcode & (@as(u32, 1) << 22)) != 0;
        const write_back = (opcode & (@as(u32, 1) << 21)) != 0;
        const load = (opcode & (@as(u32, 1) << 20)) != 0;
        const rn: u4 = @truncate(opcode >> 16);
        const rd: u4 = @truncate(opcode >> 12);
        var address = self.readRegister(rn);
        const offset = if (!register_offset)
            opcode & 0xfff
        else blk: {
            if ((opcode & 0x10) != 0) {
                self.undefined_count +%= 1;
                self.enterException(.undefined);
                return;
            }
            const rm: u4 = @truncate(opcode);
            const shifted = shift(
                self.readRegister(rm),
                @truncate(opcode >> 5),
                (opcode >> 7) & 0x1f,
                false,
                self.cpsr.carry,
            );
            break :blk shifted.value;
        };
        if (pre) address = if (up) address +% offset else address -% offset;

        if (load) {
            const value: u32 = if (byte)
                self.readByte(bus, address) orelse return
            else
                self.readWord(bus, address, true) orelse return;
            self.setRegister(rd, value);
            self.idle(bus);
        } else {
            var value = self.readRegister(rd);
            if (rd == 15) value +%= 4;
            const ok = if (byte)
                self.writeByte(bus, address, @truncate(value))
            else
                self.writeWord(bus, address, value);
            if (!ok) return;
        }

        if (!pre) address = if (up) address +% offset else address -% offset;
        if ((rd != rn or !load) and (write_back or !pre)) self.setRegister(rn, address);
    }

    fn blockTransfer(self: *Cpu, bus: anytype, opcode: u32) void {
        const pre = (opcode & (@as(u32, 1) << 24)) != 0;
        const up = (opcode & (@as(u32, 1) << 23)) != 0;
        const force_user = (opcode & (@as(u32, 1) << 22)) != 0;
        const write_back = (opcode & (@as(u32, 1) << 21)) != 0;
        const load = (opcode & (@as(u32, 1) << 20)) != 0;
        const rn: u4 = @truncate(opcode >> 16);
        var register_mask: u16 = @truncate(opcode);
        var count: u32 = @popCount(register_mask);
        if (register_mask == 0) {
            register_mask = 0x8000;
            count = 16;
        }
        const base = self.readRegister(rn) +% (if (rn == 15) @as(u32, 4) else 0);
        var address = base;
        if (!up) {
            const words = count - (if (pre) @as(u32, 0) else 1);
            address -%= words * 4;
        } else if (pre) {
            address +%= 4;
        }
        const final_base = if (up) base +% count * 4 else base -% count * 4;
        const original_mode = self.cpsr.mode;
        const uses_user_bank = force_user and (!load or (register_mask & 0x8000) == 0);
        if (uses_user_bank) self.switchMode(.user);

        var first = true;
        var register: u5 = 0;
        while (register < 16) : (register += 1) {
            const bit = @as(u16, 1) << @intCast(register);
            if ((register_mask & bit) == 0) continue;
            const index: u4 = @intCast(register);
            if (!load) {
                var value = self.readRegister(index);
                if (index == 15) value +%= 4;
                if (!self.writeWord(bus, address, value)) break;
            }
            if (first and write_back) {
                self.setRegister(rn, final_base);
                first = false;
            }
            if (load) {
                const value = self.readWord(bus, address, false) orelse break;
                self.setRegister(index, value);
            }
            address +%= 4;
        }
        if (load and !self.data_abort_active) self.idle(bus);
        if (uses_user_bank) self.switchMode(original_mode);
        if (force_user and load and (register_mask & 0x8000) != 0 and !self.data_abort_active) {
            self.restoreFromSpsr();
        }
    }

    fn swap(self: *Cpu, bus: anytype, opcode: u32) void {
        const byte = (opcode & (@as(u32, 1) << 22)) != 0;
        const rn: u4 = @truncate(opcode >> 16);
        const rd: u4 = @truncate(opcode >> 12);
        const rm: u4 = @truncate(opcode);
        const address = self.readRegister(rn);
        const loaded: u32 = if (byte)
            self.readByte(bus, address) orelse return
        else
            self.readWord(bus, address, true) orelse return;
        self.idle(bus);
        var stored = self.readRegister(rm);
        if (rm == 15) stored +%= 4;
        const ok = if (byte)
            self.writeByte(bus, address, @truncate(stored))
        else
            self.writeWord(bus, address, stored);
        if (ok) self.setRegister(rd, loaded);
    }

    fn branch(self: *Cpu, opcode: u32) void {
        const link = (opcode & (@as(u32, 1) << 24)) != 0;
        const raw = (opcode & 0x00ff_ffff) << 2;
        const signed: i32 = @bitCast(if ((raw & 0x0200_0000) != 0) raw | 0xfc00_0000 else raw);
        const base = self.pipeline.execute.address +% 8;
        if (link) self.r[14] = self.pipeline.execute.address +% 4;
        self.setProgramCounter(base +% @as(u32, @bitCast(signed)));
    }

    fn enterException(self: *Cpu, exception: Exception) void {
        const old = self.cpsr;
        const instruction_address = if (self.pipeline.execute.valid)
            self.pipeline.execute.address
        else
            self.r[15] & ~@as(u32, 3);
        const target_mode: Mode = switch (exception) {
            .reset, .software_interrupt => .supervisor,
            .undefined => .undefined,
            .prefetch_abort, .data_abort => .abort,
            .irq => .irq,
            .fiq => .fiq,
        };
        const link = switch (exception) {
            .reset => 0,
            .undefined, .software_interrupt, .prefetch_abort => instruction_address +% 4,
            .data_abort, .irq, .fiq => instruction_address +% 8,
        };
        self.switchMode(target_mode);
        if (self.spsrPointer()) |saved| saved.* = old;
        self.r[14] = link;
        self.cpsr.irq_disabled = true;
        if (exception == .fiq or exception == .reset) self.cpsr.fiq_disabled = true;
        self.r[15] = @intFromEnum(exception);
        self.pipeline.reload = true;
        self.last_exception = exception;
    }

    fn restoreFromSpsr(self: *Cpu) void {
        const saved = self.spsr() orelse return;
        self.switchMode(saved.mode);
        self.cpsr = saved;
    }

    fn readRegister(self: *const Cpu, register: u4) u32 {
        return self.r[register];
    }

    fn setRegister(self: *Cpu, register: u4, value: u32) void {
        self.r[register] = value;
        if (register == 15) {
            self.r[15] &= ~@as(u32, 3);
            self.pipeline.reload = true;
        }
    }

    pub fn switchMode(self: *Cpu, mode: Mode) void {
        if (self.cpsr.mode == mode) return;
        switch (self.cpsr.mode) {
            .user, .system => @memcpy(self.user_regs[0..], self.r[8..15]),
            .fiq => @memcpy(self.fiq_regs[0..], self.r[8..15]),
            .irq => {
                @memcpy(self.user_regs[0..5], self.r[8..13]);
                @memcpy(self.irq_regs[0..], self.r[13..15]);
            },
            .supervisor => {
                @memcpy(self.user_regs[0..5], self.r[8..13]);
                @memcpy(self.supervisor_regs[0..], self.r[13..15]);
            },
            .abort => {
                @memcpy(self.user_regs[0..5], self.r[8..13]);
                @memcpy(self.abort_regs[0..], self.r[13..15]);
            },
            .undefined => {
                @memcpy(self.user_regs[0..5], self.r[8..13]);
                @memcpy(self.undefined_regs[0..], self.r[13..15]);
            },
        }
        self.cpsr.mode = mode;
        if (mode == .fiq) {
            @memcpy(self.r[8..15], self.fiq_regs[0..]);
            return;
        }
        @memcpy(self.r[8..15], self.user_regs[0..]);
        switch (mode) {
            .irq => @memcpy(self.r[13..15], self.irq_regs[0..]),
            .supervisor => @memcpy(self.r[13..15], self.supervisor_regs[0..]),
            .abort => @memcpy(self.r[13..15], self.abort_regs[0..]),
            .undefined => @memcpy(self.r[13..15], self.undefined_regs[0..]),
            else => {},
        }
    }

    fn spsr(self: *const Cpu) ?Psr {
        return switch (self.cpsr.mode) {
            .fiq => self.fiq_spsr,
            .irq => self.irq_spsr,
            .supervisor => self.supervisor_spsr,
            .abort => self.abort_spsr,
            .undefined => self.undefined_spsr,
            .user, .system => null,
        };
    }

    fn spsrPointer(self: *Cpu) ?*Psr {
        return switch (self.cpsr.mode) {
            .fiq => &self.fiq_spsr,
            .irq => &self.irq_spsr,
            .supervisor => &self.supervisor_spsr,
            .abort => &self.abort_spsr,
            .undefined => &self.undefined_spsr,
            .user, .system => null,
        };
    }

    fn logical(self: *Cpu, value: u32, carry: bool, update: bool) u32 {
        if (update) {
            self.cpsr.negative = (value & 0x8000_0000) != 0;
            self.cpsr.zero = value == 0;
            self.cpsr.carry = carry;
        }
        return value;
    }

    fn add(self: *Cpu, left: u32, right: u32, carry_in: bool, update: bool) u32 {
        const sum = @as(u64, left) + @as(u64, right) + @intFromBool(carry_in);
        const value: u32 = @truncate(sum);
        if (update) {
            self.cpsr.negative = (value & 0x8000_0000) != 0;
            self.cpsr.zero = value == 0;
            self.cpsr.carry = (sum >> 32) != 0;
            self.cpsr.overflow = ((~(left ^ right) & (left ^ value)) & 0x8000_0000) != 0;
        }
        return value;
    }

    fn subtract(self: *Cpu, left: u32, right: u32, carry_in: bool, update: bool) u32 {
        const borrow: u64 = if (carry_in) 0 else 1;
        const subtrahend = @as(u64, right) + borrow;
        const value = left -% right -% @as(u32, @intCast(borrow));
        if (update) {
            self.cpsr.negative = (value & 0x8000_0000) != 0;
            self.cpsr.zero = value == 0;
            self.cpsr.carry = @as(u64, left) >= subtrahend;
            self.cpsr.overflow = (((left ^ right) & (left ^ value)) & 0x8000_0000) != 0;
        }
        return value;
    }

    pub fn stateDigest(self: *const Cpu) u64 {
        var hash: u64 = 0xcbf2_9ce4_8422_2325;
        for (self.r) |value| mix(&hash, value);
        mix(&hash, self.cpsr.bits());
        mix(&hash, self.pipeline.execute.address);
        mix(&hash, self.pipeline.execute.opcode);
        mix(&hash, self.pipeline.decode.address);
        mix(&hash, self.pipeline.decode.opcode);
        mix64(&hash, self.cycle_count);
        mix64(&hash, self.instruction_count);
        mix(&hash, @intFromEnum(self.cpsr.mode));
        return hash;
    }
};

pub fn classify(opcode: u32) OpcodeClass {
    if ((opcode & 0x0f00_0000) == 0x0f00_0000) return .software_interrupt;
    if ((opcode & 0x0e00_0000) == 0x0a00_0000) return .branch;
    if ((opcode & 0x0e00_0000) == 0x0800_0000) return .block_transfer;
    if ((opcode & 0x0c00_0000) == 0x0400_0000) return .single_transfer;
    if ((opcode & 0x0f80_00f0) == 0x0080_0090) return .multiply_long;
    if ((opcode & 0x0fc0_00f0) == 0x0000_0090) return .multiply;
    if ((opcode & 0x0fb0_0ff0) == 0x0100_0090) return .swap;
    if ((opcode & 0x0fbf_0fff) == 0x010f_0000 or
        (opcode & 0x0fb0_fff0) == 0x0120_f000 or
        (opcode & 0x0fb0_f000) == 0x0320_f000)
        return .psr_transfer;
    if ((opcode & 0x0c00_0000) == 0) {
        // ARMv3 has no halfword/signed-transfer class; encodings with both
        // bit 7 and bit 4 set that were not recognized above are undefined.
        if ((opcode & 0x90) == 0x90) return .undefined;
        return .data_processing;
    }
    return .undefined;
}

pub fn conditionPassed(psr: Psr, condition: u4) bool {
    return switch (condition) {
        0x0 => psr.zero,
        0x1 => !psr.zero,
        0x2 => psr.carry,
        0x3 => !psr.carry,
        0x4 => psr.negative,
        0x5 => !psr.negative,
        0x6 => psr.overflow,
        0x7 => !psr.overflow,
        0x8 => psr.carry and !psr.zero,
        0x9 => !psr.carry or psr.zero,
        0xa => psr.negative == psr.overflow,
        0xb => psr.negative != psr.overflow,
        0xc => !psr.zero and psr.negative == psr.overflow,
        0xd => psr.zero or psr.negative != psr.overflow,
        0xe => true,
        0xf => false,
    };
}

const ShifterResult = struct { value: u32, carry: bool };

fn shift(value: u32, kind: u2, raw_amount: u32, register: bool, old_carry: bool) ShifterResult {
    var amount = raw_amount;
    return switch (kind) {
        0 => blk: {
            if (amount == 0) break :blk .{ .value = value, .carry = old_carry };
            if (amount < 32) break :blk .{
                .value = value << @intCast(amount),
                .carry = ((value >> @intCast(32 - amount)) & 1) != 0,
            };
            if (amount == 32) break :blk .{ .value = 0, .carry = (value & 1) != 0 };
            break :blk .{ .value = 0, .carry = false };
        },
        1 => blk: {
            if (!register and amount == 0) amount = 32;
            if (register and amount == 0) break :blk .{ .value = value, .carry = old_carry };
            if (amount < 32) break :blk .{
                .value = value >> @intCast(amount),
                .carry = ((value >> @intCast(amount - 1)) & 1) != 0,
            };
            if (amount == 32) break :blk .{ .value = 0, .carry = (value & 0x8000_0000) != 0 };
            break :blk .{ .value = 0, .carry = false };
        },
        2 => blk: {
            if (!register and amount == 0) amount = 32;
            if (register and amount == 0) break :blk .{ .value = value, .carry = old_carry };
            if (amount >= 32) break :blk .{
                .value = if ((value & 0x8000_0000) != 0) 0xffff_ffff else 0,
                .carry = (value & 0x8000_0000) != 0,
            };
            const signed: i32 = @bitCast(value);
            break :blk .{
                .value = @bitCast(signed >> @intCast(amount)),
                .carry = ((value >> @intCast(amount - 1)) & 1) != 0,
            };
        },
        3 => blk: {
            if (!register and amount == 0) break :blk .{
                .value = (value >> 1) | (@as(u32, @intFromBool(old_carry)) << 31),
                .carry = (value & 1) != 0,
            };
            if (register and amount == 0) break :blk .{ .value = value, .carry = old_carry };
            const normalized = amount & 31;
            if (normalized == 0) break :blk .{ .value = value, .carry = (value & 0x8000_0000) != 0 };
            const result = rotateRight(value, normalized);
            break :blk .{ .value = result, .carry = (result & 0x8000_0000) != 0 };
        },
    };
}

fn rotateRight(value: u32, raw_amount: u32) u32 {
    const amount = raw_amount & 31;
    if (amount == 0) return value;
    return (value >> @intCast(amount)) | (value << @intCast(32 - amount));
}

fn multiplyCycles(value: u32) u8 {
    if ((value & 0xffff_ff00) == 0 or (value & 0xffff_ff00) == 0xffff_ff00) return 1;
    if ((value & 0xffff_0000) == 0 or (value & 0xffff_0000) == 0xffff_0000) return 2;
    if ((value & 0xff00_0000) == 0 or (value & 0xff00_0000) == 0xff00_0000) return 3;
    return 4;
}

fn modeFromBits(bits: u32) ?Mode {
    return switch (bits & 0x1f) {
        0x10 => .user,
        0x11 => .fiq,
        0x12 => .irq,
        0x13 => .supervisor,
        0x17 => .abort,
        0x1b => .undefined,
        0x1f => .system,
        else => null,
    };
}

fn writePsr(psr: *Psr, value: u32, mask: u4, privileged: bool) void {
    if ((mask & 0x8) != 0) {
        psr.negative = (value & 0x8000_0000) != 0;
        psr.zero = (value & 0x4000_0000) != 0;
        psr.carry = (value & 0x2000_0000) != 0;
        psr.overflow = (value & 0x1000_0000) != 0;
    }
    if ((mask & 0x1) != 0 and privileged) {
        psr.irq_disabled = (value & 0x80) != 0;
        psr.fiq_disabled = (value & 0x40) != 0;
        if (modeFromBits(value)) |mode| psr.mode = mode;
    }
}

fn mix(hash: *u64, value: u32) void {
    var work = value;
    var count: u3 = 0;
    while (count < 4) : (count += 1) {
        hash.* = (hash.* ^ @as(u8, @truncate(work))) *% 0x0000_0100_0000_01b3;
        work >>= 8;
    }
}

fn mix64(hash: *u64, value: u64) void {
    mix(hash, @truncate(value));
    mix(hash, @truncate(value >> 32));
}
