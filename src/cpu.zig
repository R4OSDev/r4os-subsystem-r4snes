const opcode = @import("opcode.zig");

pub const Operation = opcode.Operation;
pub const Addressing = opcode.Addressing;
pub const Descriptor = opcode.Descriptor;
pub const opcode_table = opcode.table;

pub const Status = packed struct(u8) {
    carry: bool = false,
    zero: bool = false,
    irq_disable: bool = true,
    decimal: bool = false,
    index_width: bool = true,
    accumulator_width: bool = true,
    overflow: bool = false,
    negative: bool = false,

    pub fn byte(self: Status) u8 {
        return @bitCast(self);
    }

    pub fn fromByte(value: u8) Status {
        return @bitCast(value);
    }
};

pub const MicroOperationKind = enum {
    fetch,
    read,
    write,
    idle,
    vector_read,
};

pub const MicroOperation = struct {
    kind: MicroOperationKind,
    address: u32,
    value: u8,
    master_cycles: u8,
};

pub const StepState = enum {
    executed,
    interrupt,
    reset,
    waiting,
    awakened,
    stopped,
};

pub const StepResult = struct {
    state: StepState,
    has_opcode: bool = false,
    opcode: u8 = 0,
    micro_operations: u8,
    master_cycles: u64,
};

pub const CpuError = error{TraceOverflow};

const trace_capacity = 32;
const address_mask: u32 = 0x00ff_ffff;

const AddressIntent = enum { read, write, modify };

const Location = struct {
    low: u32,
    high: u32,
};

const Interrupt = enum { abort, nmi, irq };

pub const Cpu = struct {
    a: u16 = 0,
    x: u16 = 0,
    y: u16 = 0,
    s: u16 = 0x01ff,
    d: u16 = 0,
    db: u8 = 0,
    pb: u8 = 0,
    pc: u16 = 0,
    p: Status = .{},
    emulation: bool = true,
    stopped: bool = false,
    waiting: bool = false,
    reset_pending: bool = true,
    abort_pending: bool = false,
    nmi_pending: bool = false,
    irq_line: bool = false,
    instruction_address: u32 = 0,
    abort_restart_address: u32 = 0,
    master_cycles: u64 = 0,
    instructions: u64 = 0,
    trace: [trace_capacity]MicroOperation = undefined,
    trace_len: u8 = 0,

    pub fn requestReset(self: *Cpu) void {
        self.reset_pending = true;
    }

    pub fn requestNmi(self: *Cpu) void {
        self.nmi_pending = true;
    }

    pub fn setIrqLine(self: *Cpu, asserted: bool) void {
        self.irq_line = asserted;
    }

    pub fn requestAbort(self: *Cpu, restart_address: u32) void {
        self.abort_pending = true;
        self.abort_restart_address = restart_address & address_mask;
    }

    pub fn lastTrace(self: *const Cpu) []const MicroOperation {
        return self.trace[0..self.trace_len];
    }

    pub fn step(self: *Cpu, port: anytype) CpuError!StepResult {
        self.trace_len = 0;
        const cycles_before = self.master_cycles;

        if (self.reset_pending) {
            try self.serviceReset(port);
            return self.makeResult(.reset, false, 0, cycles_before);
        }
        self.enforceMode();
        if (self.stopped) {
            try self.idle(port);
            return self.makeResult(.stopped, false, 0, cycles_before);
        }
        if (self.waiting) {
            if (self.pendingInterrupt()) |kind| {
                self.waiting = false;
                try self.idle(port);
                try self.serviceHardwareInterrupt(port, kind);
                return self.makeResult(.interrupt, false, 0, cycles_before);
            }
            // A masked IRQ still releases WAI, but does not vector.
            if (self.irq_line) {
                self.waiting = false;
                try self.idle(port);
                return self.makeResult(.awakened, false, 0, cycles_before);
            }
            try self.idle(port);
            return self.makeResult(.waiting, false, 0, cycles_before);
        }
        if (self.pendingInterrupt()) |kind| {
            try self.serviceHardwareInterrupt(port, kind);
            return self.makeResult(.interrupt, false, 0, cycles_before);
        }

        self.instruction_address = self.programAddress();
        const byte = try self.fetch(port);
        const instruction = opcode.descriptor(byte);
        try self.execute(port, instruction);
        self.instructions +%= 1;
        return self.makeResult(.executed, true, byte, cycles_before);
    }

    fn makeResult(self: *const Cpu, state: StepState, has_opcode: bool, byte: u8, cycles_before: u64) StepResult {
        return .{
            .state = state,
            .has_opcode = has_opcode,
            .opcode = byte,
            .micro_operations = self.trace_len,
            .master_cycles = self.master_cycles -% cycles_before,
        };
    }

    fn execute(self: *Cpu, port: anytype, instruction: Descriptor) CpuError!void {
        switch (instruction.operation) {
            .adc, .and_, .bit, .cmp, .cpx, .cpy, .eor, .lda, .ldx, .ldy, .ora, .sbc => try self.executeRead(port, instruction),
            .sta, .stx, .sty, .stz => try self.executeWrite(port, instruction),
            .asl, .dec, .inc, .lsr, .rol, .ror, .trb, .tsb => try self.executeModify(port, instruction),
            else => try self.executeControl(port, instruction),
        }
    }

    fn executeRead(self: *Cpu, port: anytype, instruction: Descriptor) CpuError!void {
        const eight = self.eightBit(instruction.width);
        const value = try self.readOperand(port, instruction.addressing, eight);
        const mask: u16 = if (eight) 0x00ff else 0xffff;

        switch (instruction.operation) {
            .ora => {
                const result = (self.a & mask) | value;
                self.setAccumulator(result, eight);
                self.setNz(result, eight);
            },
            .and_ => {
                const result = (self.a & mask) & value;
                self.setAccumulator(result, eight);
                self.setNz(result, eight);
            },
            .eor => {
                const result = (self.a & mask) ^ value;
                self.setAccumulator(result, eight);
                self.setNz(result, eight);
            },
            .adc => self.adc(value, eight),
            .sbc => self.sbc(value, eight),
            .cmp => self.compare(self.a & mask, value, eight),
            .cpx => self.compare(self.x & mask, value, eight),
            .cpy => self.compare(self.y & mask, value, eight),
            .lda => {
                self.setAccumulator(value, eight);
                self.setNz(value, eight);
            },
            .ldx => {
                self.x = if (eight) value & 0x00ff else value;
                self.setNz(value, eight);
            },
            .ldy => {
                self.y = if (eight) value & 0x00ff else value;
                self.setNz(value, eight);
            },
            .bit => {
                self.p.zero = ((self.a & mask) & value) == 0;
                if (instruction.addressing != .immediate_m) {
                    self.p.negative = (value & (if (eight) @as(u16, 0x0080) else 0x8000)) != 0;
                    self.p.overflow = (value & (if (eight) @as(u16, 0x0040) else 0x4000)) != 0;
                }
            },
            else => unreachable,
        }
    }

    fn executeWrite(self: *Cpu, port: anytype, instruction: Descriptor) CpuError!void {
        const eight = self.eightBit(instruction.width);
        const value: u16 = switch (instruction.operation) {
            .sta => self.a,
            .stx => self.x,
            .sty => self.y,
            .stz => 0,
            else => unreachable,
        };
        try self.writeOperand(port, instruction.addressing, eight, value);
    }

    fn executeModify(self: *Cpu, port: anytype, instruction: Descriptor) CpuError!void {
        const eight = self.eightBit(instruction.width);
        if (instruction.addressing == .accumulator) {
            try self.idleInstruction(port, false);
            const result = self.modifyValue(instruction.operation, self.a, eight);
            self.setAccumulator(result, eight);
            return;
        }
        const location = try self.resolveLocation(port, instruction.addressing, .modify);
        var value = try self.readLocation(port, location, eight);
        try self.idle(port);
        value = self.modifyValue(instruction.operation, value, eight);
        // Sixteen-bit read-modify-write instructions expose high then low.
        if (!eight) try self.writeMemory(port, location.high, @truncate(value >> 8));
        try self.writeMemory(port, location.low, @truncate(value));
    }

    fn executeControl(self: *Cpu, port: anytype, instruction: Descriptor) CpuError!void {
        switch (instruction.operation) {
            .bcc => try self.branch(port, !self.p.carry),
            .bcs => try self.branch(port, self.p.carry),
            .beq => try self.branch(port, self.p.zero),
            .bmi => try self.branch(port, self.p.negative),
            .bne => try self.branch(port, !self.p.zero),
            .bpl => try self.branch(port, !self.p.negative),
            .bra => try self.branch(port, true),
            .bvc => try self.branch(port, !self.p.overflow),
            .bvs => try self.branch(port, self.p.overflow),
            .brl => try self.branchLong(port),
            .brk => try self.softwareInterrupt(port, if (self.emulation) 0xfffe else 0xffe6),
            .cop => try self.softwareInterrupt(port, if (self.emulation) 0xfff4 else 0xffe4),
            .clc => try self.setFlagInstruction(port, .carry, false),
            .cld => try self.setFlagInstruction(port, .decimal, false),
            .cli => try self.setFlagInstruction(port, .irq_disable, false),
            .clv => try self.setFlagInstruction(port, .overflow, false),
            .sec => try self.setFlagInstruction(port, .carry, true),
            .sed => try self.setFlagInstruction(port, .decimal, true),
            .sei => try self.setFlagInstruction(port, .irq_disable, true),
            .dex => try self.incrementRegister(port, &self.x, -1),
            .dey => try self.incrementRegister(port, &self.y, -1),
            .inx => try self.incrementRegister(port, &self.x, 1),
            .iny => try self.incrementRegister(port, &self.y, 1),
            .jmp, .jml => try self.jump(port, instruction.addressing),
            .jsr, .jsl => try self.call(port, instruction.addressing),
            .mvn => try self.blockMove(port, 1),
            .mvp => try self.blockMove(port, -1),
            .nop => try self.idleInstruction(port, false),
            .pea => try self.pushEffectiveAbsolute(port),
            .pei => try self.pushEffectiveIndirect(port),
            .per => try self.pushEffectiveRelative(port),
            .pha => try self.pushRegister(port, self.a, !self.p.accumulator_width),
            .phb => try self.pushRegister(port, self.db, false),
            .phd => try self.pushDirect(port),
            .phk => try self.pushRegister(port, self.pb, false),
            .php => try self.pushRegister(port, self.p.byte(), false),
            .phx => try self.pushRegister(port, self.x, !self.p.index_width),
            .phy => try self.pushRegister(port, self.y, !self.p.index_width),
            .pla => try self.pullAccumulator(port),
            .plb => try self.pullDataBank(port),
            .pld => try self.pullDirect(port),
            .plp => try self.pullStatus(port),
            .plx => try self.pullIndex(port, &self.x),
            .ply => try self.pullIndex(port, &self.y),
            .rep => try self.changeStatus(port, false),
            .sep => try self.changeStatus(port, true),
            .rti => try self.returnInterrupt(port),
            .rtl => try self.returnLong(port),
            .rts => try self.returnShort(port),
            .stp => {
                self.stopped = true;
                try self.idle(port);
            },
            .tax => try self.transfer(port, self.a, &self.x, !self.p.index_width),
            .tay => try self.transfer(port, self.a, &self.y, !self.p.index_width),
            .tcd => {
                try self.idleInstruction(port, false);
                self.d = self.a;
                self.setNz(self.d, false);
            },
            .tcs => {
                try self.idleInstruction(port, false);
                self.s = self.a;
                if (self.emulation) self.s = 0x0100 | @as(u16, @as(u8, @truncate(self.s)));
            },
            .tdc => {
                try self.idleInstruction(port, false);
                self.a = self.d;
                self.setNz(self.a, false);
            },
            .tsc => {
                try self.idleInstruction(port, false);
                self.a = self.s;
                self.setNz(self.a, false);
            },
            .tsx => try self.transfer(port, self.s, &self.x, !self.p.index_width),
            .txa => try self.transfer(port, self.x, &self.a, !self.p.accumulator_width),
            .txs => {
                try self.idleInstruction(port, false);
                self.s = if (self.emulation) 0x0100 | (self.x & 0x00ff) else self.x;
            },
            .txy => try self.transfer(port, self.x, &self.y, !self.p.index_width),
            .tya => try self.transfer(port, self.y, &self.a, !self.p.accumulator_width),
            .tyx => try self.transfer(port, self.y, &self.x, !self.p.index_width),
            .wai => {
                self.waiting = true;
                try self.idle(port);
            },
            .wdm => _ = try self.fetch(port),
            .xba => try self.exchangeAccumulatorBytes(port),
            .xce => try self.exchangeCarryEmulation(port),
            else => unreachable,
        }
    }

    fn readOperand(self: *Cpu, port: anytype, mode: Addressing, eight: bool) CpuError!u16 {
        switch (mode) {
            .immediate8, .immediate_m, .immediate_x => {
                const low = try self.fetch(port);
                if (eight or mode == .immediate8) return low;
                return @as(u16, low) | (@as(u16, try self.fetch(port)) << 8);
            },
            else => {
                const location = try self.resolveLocation(port, mode, .read);
                return self.readLocation(port, location, eight);
            },
        }
    }

    fn writeOperand(self: *Cpu, port: anytype, mode: Addressing, eight: bool, value: u16) CpuError!void {
        const location = try self.resolveLocation(port, mode, .write);
        try self.writeMemory(port, location.low, @truncate(value));
        if (!eight) try self.writeMemory(port, location.high, @truncate(value >> 8));
    }

    fn readLocation(self: *Cpu, port: anytype, location: Location, eight: bool) CpuError!u16 {
        const low = try self.readMemory(port, location.low, .read);
        if (eight) return low;
        const high = try self.readMemory(port, location.high, .read);
        return @as(u16, low) | (@as(u16, high) << 8);
    }

    fn resolveLocation(self: *Cpu, port: anytype, mode: Addressing, intent: AddressIntent) CpuError!Location {
        switch (mode) {
            .direct, .direct_x, .direct_y => {
                const operand = try self.fetch(port);
                if (@as(u8, @truncate(self.d)) != 0) try self.idle(port);
                var displacement: u16 = operand;
                if (mode == .direct_x) {
                    try self.idle(port);
                    displacement +%= self.x;
                } else if (mode == .direct_y) {
                    try self.idle(port);
                    displacement +%= self.y;
                }
                return .{
                    .low = self.directAddress(displacement),
                    .high = self.directAddress(displacement +% 1),
                };
            },
            .direct_indirect => {
                const operand = try self.fetch(port);
                if (@as(u8, @truncate(self.d)) != 0) try self.idle(port);
                const low = try self.readMemory(port, self.directAddress(operand), .read);
                const high = try self.readMemory(port, self.directAddress(@as(u16, operand) +% 1), .read);
                return self.bankLocation(self.db, @as(u16, low) | (@as(u16, high) << 8));
            },
            .direct_indexed_indirect => {
                const operand = try self.fetch(port);
                if (@as(u8, @truncate(self.d)) != 0) try self.idle(port);
                try self.idle(port);
                const pointer = self.directIndexedPointer(operand, self.x);
                const low = try self.readMemory(port, pointer.low, .read);
                const high = try self.readMemory(port, pointer.high, .read);
                return self.bankLocation(self.db, @as(u16, low) | (@as(u16, high) << 8));
            },
            .direct_indirect_indexed => {
                const operand = try self.fetch(port);
                if (@as(u8, @truncate(self.d)) != 0) try self.idle(port);
                const low = try self.readMemory(port, self.directAddress(operand), .read);
                const high = try self.readMemory(port, self.directAddress(@as(u16, operand) +% 1), .read);
                const base = @as(u16, low) | (@as(u16, high) << 8);
                const effective = base +% self.y;
                if (intent != .read or !self.p.index_width or (base & 0xff00) != (effective & 0xff00)) try self.idle(port);
                return self.longLocation(((@as(u32, self.db) << 16) | base) + self.y);
            },
            .direct_indirect_long, .direct_indirect_long_y => {
                const operand = try self.fetch(port);
                if (@as(u8, @truncate(self.d)) != 0) try self.idle(port);
                const pointer_low = self.directNaturalAddress(operand);
                const pointer_high = self.directNaturalAddress(@as(u16, operand) +% 1);
                const pointer_bank = self.directNaturalAddress(@as(u16, operand) +% 2);
                const low = try self.readMemory(port, pointer_low, .read);
                const high = try self.readMemory(port, pointer_high, .read);
                const bank = try self.readMemory(port, pointer_bank, .read);
                var address = (@as(u32, bank) << 16) | (@as(u32, high) << 8) | low;
                if (mode == .direct_indirect_long_y) address = (address + self.y) & address_mask;
                return self.longLocation(address);
            },
            .stack_relative => {
                const operand = try self.fetch(port);
                try self.idle(port);
                const address = self.s +% operand;
                return .{ .low = address, .high = address +% 1 };
            },
            .stack_relative_indirect_y => {
                const operand = try self.fetch(port);
                try self.idle(port);
                const pointer = self.s +% operand;
                const low = try self.readMemory(port, pointer, .read);
                const high = try self.readMemory(port, pointer +% 1, .read);
                try self.idle(port);
                const base = @as(u16, low) | (@as(u16, high) << 8);
                return self.longLocation(((@as(u32, self.db) << 16) | base) + self.y);
            },
            .absolute, .absolute_x, .absolute_y => {
                const base = try self.fetch16(port);
                var effective = base;
                if (mode == .absolute_x) effective +%= self.x;
                if (mode == .absolute_y) effective +%= self.y;
                if (mode != .absolute) {
                    if (intent != .read or !self.p.index_width or (base & 0xff00) != (effective & 0xff00)) try self.idle(port);
                }
                const indexed_address = ((@as(u32, self.db) << 16) | base) +
                    (if (mode == .absolute_x) @as(u32, self.x) else if (mode == .absolute_y) @as(u32, self.y) else 0);
                return self.longLocation(indexed_address);
            },
            .absolute_long, .absolute_long_x => {
                var address = try self.fetch24(port);
                if (mode == .absolute_long_x) address = (address + self.x) & address_mask;
                return self.longLocation(address);
            },
            else => unreachable,
        }
    }

    fn directAddress(self: *const Cpu, displacement: u16) u32 {
        if (self.emulation and @as(u8, @truncate(self.d)) == 0) {
            return (self.d & 0xff00) | @as(u8, @truncate(displacement));
        }
        return self.d +% displacement;
    }

    fn directNaturalAddress(self: *const Cpu, displacement: u16) u32 {
        return self.d +% displacement;
    }

    fn directIndexedPointer(self: *const Cpu, operand: u8, index: u16) Location {
        const displacement = @as(u16, operand) +% index;
        if (self.emulation and @as(u8, @truncate(self.d)) != 0) {
            const total = self.d +% displacement;
            return .{
                .low = total,
                .high = (total & 0xff00) | @as(u8, @truncate(total +% 1)),
            };
        }
        return .{
            .low = self.directAddress(displacement),
            .high = self.directAddress(displacement +% 1),
        };
    }

    fn bankLocation(self: *const Cpu, bank: u8, offset: u16) Location {
        return self.longLocation((@as(u32, bank) << 16) | offset);
    }

    fn longLocation(_: *const Cpu, address: u32) Location {
        return .{ .low = address & address_mask, .high = (address + 1) & address_mask };
    }

    fn modifyValue(self: *Cpu, operation: Operation, raw_value: u16, eight: bool) u16 {
        const mask: u16 = if (eight) 0x00ff else 0xffff;
        const sign: u16 = if (eight) 0x0080 else 0x8000;
        var value = raw_value & mask;
        switch (operation) {
            .asl => {
                self.p.carry = (value & sign) != 0;
                value = (value << 1) & mask;
                self.setNz(value, eight);
            },
            .lsr => {
                self.p.carry = (value & 1) != 0;
                value >>= 1;
                self.setNz(value, eight);
            },
            .rol => {
                const old_carry: u16 = @intFromBool(self.p.carry);
                self.p.carry = (value & sign) != 0;
                value = ((value << 1) | old_carry) & mask;
                self.setNz(value, eight);
            },
            .ror => {
                const old_carry: u16 = if (self.p.carry) sign else 0;
                self.p.carry = (value & 1) != 0;
                value = (value >> 1) | old_carry;
                self.setNz(value, eight);
            },
            .inc => {
                value +%= 1;
                value &= mask;
                self.setNz(value, eight);
            },
            .dec => {
                value -%= 1;
                value &= mask;
                self.setNz(value, eight);
            },
            .trb => {
                self.p.zero = (value & (self.a & mask)) == 0;
                value &= ~(self.a & mask);
            },
            .tsb => {
                self.p.zero = (value & (self.a & mask)) == 0;
                value |= self.a & mask;
            },
            else => unreachable,
        }
        return value;
    }

    fn setAccumulator(self: *Cpu, value: u16, eight: bool) void {
        if (eight) self.a = (self.a & 0xff00) | (value & 0x00ff) else self.a = value;
    }

    fn setNz(self: *Cpu, value: u16, eight: bool) void {
        const masked = if (eight) value & 0x00ff else value;
        self.p.zero = masked == 0;
        self.p.negative = (masked & (if (eight) @as(u16, 0x0080) else 0x8000)) != 0;
    }

    fn compare(self: *Cpu, left: u16, right: u16, eight: bool) void {
        const mask: u32 = if (eight) 0x00ff else 0xffff;
        const lhs: u32 = left;
        const rhs: u32 = right;
        const result: u16 = @truncate((lhs -% rhs) & mask);
        self.p.carry = (lhs & mask) >= (rhs & mask);
        self.setNz(result, eight);
    }

    fn adc(self: *Cpu, value: u16, eight: bool) void {
        if (eight) self.adc8(@truncate(value)) else self.adc16(value);
    }

    fn adc8(self: *Cpu, operand: u8) void {
        const accumulator: u8 = @truncate(self.a);
        var result: u32 = undefined;
        if (!self.p.decimal) {
            result = @as(u32, accumulator) + operand + @intFromBool(self.p.carry);
        } else {
            result = (accumulator & 0x0f) + (operand & 0x0f) + @intFromBool(self.p.carry);
            if (result > 0x09) result += 0x06;
            const nibble_carry: u32 = @intFromBool(result > 0x0f);
            result = @as(u32, accumulator & 0xf0) + (operand & 0xf0) + (nibble_carry << 4) + (result & 0x0f);
        }
        const overflow_bits: u32 = @bitCast(result);
        self.p.overflow = (~(accumulator ^ operand) & (accumulator ^ @as(u8, @truncate(overflow_bits))) & 0x80) != 0;
        if (self.p.decimal and result > 0x9f) result += 0x60;
        self.p.carry = result > 0xff;
        self.setAccumulator(@truncate(result), true);
        self.setNz(@truncate(result), true);
    }

    fn adc16(self: *Cpu, operand: u16) void {
        const accumulator = self.a;
        var result: u32 = undefined;
        if (!self.p.decimal) {
            result = @as(u32, accumulator) + operand + @intFromBool(self.p.carry);
        } else {
            result = @as(u32, accumulator & 0x000f) + (operand & 0x000f) + @intFromBool(self.p.carry);
            if (result > 0x0009) result += 0x0006;
            var carry: u32 = @intFromBool(result > 0x000f);
            result = @as(u32, accumulator & 0x00f0) + (operand & 0x00f0) + (carry << 4) + (result & 0x000f);
            if (result > 0x009f) result += 0x0060;
            carry = @intFromBool(result > 0x00ff);
            result = @as(u32, accumulator & 0x0f00) + (operand & 0x0f00) + (carry << 8) + (result & 0x00ff);
            if (result > 0x09ff) result += 0x0600;
            carry = @intFromBool(result > 0x0fff);
            result = @as(u32, accumulator & 0xf000) + (operand & 0xf000) + (carry << 12) + (result & 0x0fff);
        }
        self.p.overflow = (~(accumulator ^ operand) & (accumulator ^ @as(u16, @truncate(result))) & 0x8000) != 0;
        if (self.p.decimal and result > 0x9fff) result += 0x6000;
        self.p.carry = result > 0xffff;
        self.a = @truncate(result);
        self.setNz(self.a, false);
    }

    fn sbc(self: *Cpu, value: u16, eight: bool) void {
        if (eight) self.sbc8(@truncate(value)) else self.sbc16(value);
    }

    fn sbc8(self: *Cpu, raw_operand: u8) void {
        const accumulator: u8 = @truncate(self.a);
        const operand: u8 = ~raw_operand;
        var result: i32 = undefined;
        if (!self.p.decimal) {
            result = @as(i32, accumulator) + operand + @intFromBool(self.p.carry);
        } else {
            result = @as(i32, accumulator & 0x0f) + (operand & 0x0f) + @intFromBool(self.p.carry);
            if (result <= 0x0f) result -= 0x06;
            const carry: i32 = @intFromBool(result > 0x0f);
            result = @as(i32, accumulator & 0xf0) + (operand & 0xf0) + (carry << 4) + (result & 0x0f);
        }
        const overflow_bits: u32 = @bitCast(result);
        self.p.overflow = (~(accumulator ^ operand) & (accumulator ^ @as(u8, @truncate(overflow_bits))) & 0x80) != 0;
        if (self.p.decimal and result <= 0xff) result -= 0x60;
        self.p.carry = result > 0xff;
        const result_bits: u32 = @bitCast(result);
        const final: u8 = @truncate(result_bits);
        self.setAccumulator(final, true);
        self.setNz(final, true);
    }

    fn sbc16(self: *Cpu, raw_operand: u16) void {
        const accumulator = self.a;
        const operand: u16 = ~raw_operand;
        var result: i32 = undefined;
        if (!self.p.decimal) {
            result = @as(i32, accumulator) + operand + @intFromBool(self.p.carry);
        } else {
            result = @as(i32, accumulator & 0x000f) + (operand & 0x000f) + @intFromBool(self.p.carry);
            if (result <= 0x000f) result -= 0x0006;
            var carry: i32 = @intFromBool(result > 0x000f);
            result = @as(i32, accumulator & 0x00f0) + (operand & 0x00f0) + (carry << 4) + (result & 0x000f);
            if (result <= 0x00ff) result -= 0x0060;
            carry = @intFromBool(result > 0x00ff);
            result = @as(i32, accumulator & 0x0f00) + (operand & 0x0f00) + (carry << 8) + (result & 0x00ff);
            if (result <= 0x0fff) result -= 0x0600;
            carry = @intFromBool(result > 0x0fff);
            result = @as(i32, accumulator & 0xf000) + (operand & 0xf000) + (carry << 12) + (result & 0x0fff);
        }
        const overflow_bits: u32 = @bitCast(result);
        self.p.overflow = (~(accumulator ^ operand) & (accumulator ^ @as(u16, @truncate(overflow_bits))) & 0x8000) != 0;
        if (self.p.decimal and result <= 0xffff) result -= 0x6000;
        self.p.carry = result > 0xffff;
        const result_bits: u32 = @bitCast(result);
        self.a = @truncate(result_bits);
        self.setNz(self.a, false);
    }

    fn branch(self: *Cpu, port: anytype, take: bool) CpuError!void {
        const raw = try self.fetch(port);
        if (!take) return;
        const old_pc = self.pc;
        const displacement: i8 = @bitCast(raw);
        const target = self.pc +% @as(u16, @bitCast(@as(i16, displacement)));
        if (self.emulation and (old_pc & 0xff00) != (target & 0xff00)) try self.idle(port);
        try self.idle(port);
        self.pc = target;
    }

    fn branchLong(self: *Cpu, port: anytype) CpuError!void {
        const raw = try self.fetch16(port);
        const displacement: i16 = @bitCast(raw);
        self.pc +%= @as(u16, @bitCast(displacement));
        try self.idle(port);
    }

    fn jump(self: *Cpu, port: anytype, mode: Addressing) CpuError!void {
        switch (mode) {
            .absolute => self.pc = try self.fetch16(port),
            .absolute_long => {
                const target = try self.fetch24(port);
                self.pc = @truncate(target);
                self.pb = @truncate(target >> 16);
            },
            .absolute_indirect => {
                const pointer = try self.fetch16(port);
                const low = try self.readMemory(port, pointer, .read);
                const high = try self.readMemory(port, pointer +% 1, .read);
                self.pc = @as(u16, low) | (@as(u16, high) << 8);
            },
            .absolute_indexed_indirect => {
                const pointer = (try self.fetch16(port)) +% self.x;
                try self.idle(port);
                const bank = @as(u32, self.pb) << 16;
                const low = try self.readMemory(port, bank | pointer, .read);
                const high = try self.readMemory(port, bank | (pointer +% 1), .read);
                self.pc = @as(u16, low) | (@as(u16, high) << 8);
            },
            .absolute_indirect_long => {
                const pointer = try self.fetch16(port);
                const low = try self.readMemory(port, pointer, .read);
                const high = try self.readMemory(port, pointer +% 1, .read);
                const bank = try self.readMemory(port, pointer +% 2, .read);
                self.pc = @as(u16, low) | (@as(u16, high) << 8);
                self.pb = bank;
            },
            else => unreachable,
        }
    }

    fn call(self: *Cpu, port: anytype, mode: Addressing) CpuError!void {
        if (mode == .absolute) {
            const target = try self.fetch16(port);
            try self.idle(port);
            const return_address = self.pc -% 1;
            try self.push(port, @truncate(return_address >> 8));
            try self.push(port, @truncate(return_address));
            self.pc = target;
            return;
        }
        if (mode == .absolute_long) {
            const low = try self.fetch(port);
            const high = try self.fetch(port);
            try self.pushNative(port, self.pb);
            try self.idle(port);
            const bank = try self.fetch(port);
            const return_address = self.pc -% 1;
            try self.pushNative(port, @truncate(return_address >> 8));
            try self.pushNative(port, @truncate(return_address));
            self.pc = @as(u16, low) | (@as(u16, high) << 8);
            self.pb = bank;
            if (self.emulation) self.s = 0x0100 | (self.s & 0x00ff);
            return;
        }
        if (mode == .absolute_indexed_indirect) {
            const low_operand = try self.fetch(port);
            try self.pushNative(port, @truncate(self.pc >> 8));
            try self.pushNative(port, @truncate(self.pc));
            const high_operand = try self.fetch(port);
            try self.idle(port);
            const pointer = (@as(u16, low_operand) | (@as(u16, high_operand) << 8)) +% self.x;
            const bank = @as(u32, self.pb) << 16;
            const low = try self.readMemory(port, bank | pointer, .read);
            const high = try self.readMemory(port, bank | (pointer +% 1), .read);
            self.pc = @as(u16, low) | (@as(u16, high) << 8);
            if (self.emulation) self.s = 0x0100 | (self.s & 0x00ff);
            return;
        }
        unreachable;
    }

    fn blockMove(self: *Cpu, port: anytype, direction: i8) CpuError!void {
        const destination_bank = try self.fetch(port);
        const source_bank = try self.fetch(port);
        self.db = destination_bank;
        const source = (@as(u32, source_bank) << 16) | self.x;
        const destination = (@as(u32, destination_bank) << 16) | self.y;
        const value = try self.readMemory(port, source, .read);
        try self.writeMemory(port, destination, value);
        try self.idle(port);
        if (self.p.index_width) {
            const adjustment: u8 = @bitCast(direction);
            self.x = @as(u8, @truncate(self.x)) +% adjustment;
            self.y = @as(u8, @truncate(self.y)) +% adjustment;
        } else {
            const adjustment: u16 = @bitCast(@as(i16, direction));
            self.x +%= adjustment;
            self.y +%= adjustment;
        }
        try self.idle(port);
        const old_count = self.a;
        self.a -%= 1;
        if (old_count != 0) self.pc -%= 3;
    }

    fn pushEffectiveAbsolute(self: *Cpu, port: anytype) CpuError!void {
        const value = try self.fetch16(port);
        try self.pushNative(port, @truncate(value >> 8));
        try self.pushNative(port, @truncate(value));
        if (self.emulation) self.s = 0x0100 | (self.s & 0x00ff);
    }

    fn pushEffectiveIndirect(self: *Cpu, port: anytype) CpuError!void {
        const operand = try self.fetch(port);
        if (@as(u8, @truncate(self.d)) != 0) try self.idle(port);
        const low = try self.readMemory(port, self.directNaturalAddress(operand), .read);
        const high = try self.readMemory(port, self.directNaturalAddress(@as(u16, operand) +% 1), .read);
        try self.pushNative(port, high);
        try self.pushNative(port, low);
        if (self.emulation) self.s = 0x0100 | (self.s & 0x00ff);
    }

    fn pushEffectiveRelative(self: *Cpu, port: anytype) CpuError!void {
        const raw = try self.fetch16(port);
        const displacement: i16 = @bitCast(raw);
        const value = self.pc +% @as(u16, @bitCast(displacement));
        try self.idle(port);
        try self.pushNative(port, @truncate(value >> 8));
        try self.pushNative(port, @truncate(value));
        if (self.emulation) self.s = 0x0100 | (self.s & 0x00ff);
    }

    fn pushRegister(self: *Cpu, port: anytype, value: u16, sixteen: bool) CpuError!void {
        try self.idle(port);
        if (sixteen) try self.push(port, @truncate(value >> 8));
        try self.push(port, @truncate(value));
    }

    fn pushDirect(self: *Cpu, port: anytype) CpuError!void {
        try self.idle(port);
        try self.pushNative(port, @truncate(self.d >> 8));
        try self.pushNative(port, @truncate(self.d));
        if (self.emulation) self.s = 0x0100 | (self.s & 0x00ff);
    }

    fn pullAccumulator(self: *Cpu, port: anytype) CpuError!void {
        try self.idle(port);
        try self.idle(port);
        const eight = self.p.accumulator_width;
        const low = try self.pull(port);
        if (eight) {
            self.setAccumulator(low, true);
            self.setNz(low, true);
        } else {
            const high = try self.pull(port);
            self.a = @as(u16, low) | (@as(u16, high) << 8);
            self.setNz(self.a, false);
        }
    }

    fn pullIndex(self: *Cpu, port: anytype, register: *u16) CpuError!void {
        try self.idle(port);
        try self.idle(port);
        const eight = self.p.index_width;
        const low = try self.pull(port);
        if (eight) {
            register.* = low;
            self.setNz(low, true);
        } else {
            const high = try self.pull(port);
            register.* = @as(u16, low) | (@as(u16, high) << 8);
            self.setNz(register.*, false);
        }
    }

    fn pullDirect(self: *Cpu, port: anytype) CpuError!void {
        try self.idle(port);
        try self.idle(port);
        const low = try self.pullNative(port);
        const high = try self.pullNative(port);
        self.d = @as(u16, low) | (@as(u16, high) << 8);
        self.setNz(self.d, false);
        if (self.emulation) self.s = 0x0100 | (self.s & 0x00ff);
    }

    fn pullDataBank(self: *Cpu, port: anytype) CpuError!void {
        try self.idle(port);
        try self.idle(port);
        self.db = try self.pullNative(port);
        self.setNz(self.db, true);
        if (self.emulation) self.s = 0x0100 | (self.s & 0x00ff);
    }

    fn pullStatus(self: *Cpu, port: anytype) CpuError!void {
        try self.idle(port);
        try self.idle(port);
        self.p = Status.fromByte(try self.pull(port));
        self.enforceMode();
    }

    fn changeStatus(self: *Cpu, port: anytype, set: bool) CpuError!void {
        const mask = try self.fetch(port);
        try self.idle(port);
        const value = if (set) self.p.byte() | mask else self.p.byte() & ~mask;
        self.p = Status.fromByte(value);
        self.enforceMode();
    }

    fn returnInterrupt(self: *Cpu, port: anytype) CpuError!void {
        try self.idle(port);
        try self.idle(port);
        self.p = Status.fromByte(try self.pull(port));
        self.enforceMode();
        const low = try self.pull(port);
        const high = try self.pull(port);
        self.pc = @as(u16, low) | (@as(u16, high) << 8);
        if (!self.emulation) self.pb = try self.pull(port);
    }

    fn returnShort(self: *Cpu, port: anytype) CpuError!void {
        try self.idle(port);
        try self.idle(port);
        const low = try self.pull(port);
        const high = try self.pull(port);
        try self.idle(port);
        self.pc = (@as(u16, low) | (@as(u16, high) << 8)) +% 1;
    }

    fn returnLong(self: *Cpu, port: anytype) CpuError!void {
        try self.idle(port);
        try self.idle(port);
        const low = try self.pullNative(port);
        const high = try self.pullNative(port);
        self.pb = try self.pullNative(port);
        self.pc = (@as(u16, low) | (@as(u16, high) << 8)) +% 1;
        if (self.emulation) self.s = 0x0100 | (self.s & 0x00ff);
    }

    const StatusField = enum { carry, decimal, irq_disable, overflow };

    fn setFlagInstruction(self: *Cpu, port: anytype, field: StatusField, value: bool) CpuError!void {
        try self.idleInstruction(port, field == .irq_disable and !value);
        switch (field) {
            .carry => self.p.carry = value,
            .decimal => self.p.decimal = value,
            .irq_disable => self.p.irq_disable = value,
            .overflow => self.p.overflow = value,
        }
    }

    fn incrementRegister(self: *Cpu, port: anytype, register: *u16, delta: i8) CpuError!void {
        try self.idleInstruction(port, false);
        if (self.p.index_width) {
            const adjustment: u8 = @bitCast(delta);
            register.* = @as(u8, @truncate(register.*)) +% adjustment;
            self.setNz(register.*, true);
        } else {
            const adjustment: u16 = @bitCast(@as(i16, delta));
            register.* +%= adjustment;
            self.setNz(register.*, false);
        }
    }

    fn transfer(self: *Cpu, port: anytype, source: u16, target: *u16, sixteen: bool) CpuError!void {
        try self.idleInstruction(port, false);
        if (sixteen) {
            target.* = source;
            self.setNz(target.*, false);
        } else {
            if (target == &self.a) target.* = (target.* & 0xff00) | (source & 0x00ff) else target.* = source & 0x00ff;
            self.setNz(target.*, true);
        }
    }

    fn exchangeAccumulatorBytes(self: *Cpu, port: anytype) CpuError!void {
        try self.idle(port);
        try self.idle(port);
        self.a = (self.a << 8) | (self.a >> 8);
        self.setNz(self.a & 0x00ff, true);
    }

    fn exchangeCarryEmulation(self: *Cpu, port: anytype) CpuError!void {
        try self.idleInstruction(port, false);
        const old_carry = self.p.carry;
        self.p.carry = self.emulation;
        self.emulation = old_carry;
        self.enforceMode();
    }

    fn softwareInterrupt(self: *Cpu, port: anytype, vector: u16) CpuError!void {
        _ = try self.fetch(port); // BRK/COP signature byte
        if (!self.emulation) try self.push(port, self.pb);
        try self.push(port, @truncate(self.pc >> 8));
        try self.push(port, @truncate(self.pc));
        try self.push(port, self.p.byte());
        self.p.irq_disable = true;
        self.p.decimal = false;
        const low = try self.readMemory(port, vector, .vector_read);
        const high = try self.readMemory(port, vector +% 1, .vector_read);
        self.pc = @as(u16, low) | (@as(u16, high) << 8);
        self.pb = 0;
    }

    fn pendingInterrupt(self: *const Cpu) ?Interrupt {
        if (self.abort_pending) return .abort;
        if (self.nmi_pending) return .nmi;
        if (self.irq_line and !self.p.irq_disable) return .irq;
        return null;
    }

    fn serviceHardwareInterrupt(self: *Cpu, port: anytype, kind: Interrupt) CpuError!void {
        try self.readDiscard(port, self.programAddress());
        try self.idle(port);
        if (kind == .abort) {
            self.pb = @truncate(self.abort_restart_address >> 16);
            self.pc = @truncate(self.abort_restart_address);
            self.abort_pending = false;
        } else if (kind == .nmi) {
            self.nmi_pending = false;
        }
        if (!self.emulation) try self.push(port, self.pb);
        try self.push(port, @truncate(self.pc >> 8));
        try self.push(port, @truncate(self.pc));
        var pushed_status = self.p.byte();
        if (self.emulation) pushed_status &= ~@as(u8, 0x10);
        try self.push(port, pushed_status);
        self.p.irq_disable = true;
        self.p.decimal = false;
        const vector: u16 = switch (kind) {
            .abort => if (self.emulation) 0xfff8 else 0xffe8,
            .nmi => if (self.emulation) 0xfffa else 0xffea,
            .irq => if (self.emulation) 0xfffe else 0xffee,
        };
        const low = try self.readMemory(port, vector, .vector_read);
        const high = try self.readMemory(port, vector +% 1, .vector_read);
        self.pc = @as(u16, low) | (@as(u16, high) << 8);
        self.pb = 0;
    }

    fn serviceReset(self: *Cpu, port: anytype) CpuError!void {
        self.reset_pending = false;
        self.abort_pending = false;
        self.nmi_pending = false;
        self.stopped = false;
        self.waiting = false;
        self.emulation = true;
        self.p.irq_disable = true;
        self.p.decimal = false;
        self.p.index_width = true;
        self.p.accumulator_width = true;
        self.x &= 0x00ff;
        self.y &= 0x00ff;
        self.s = 0x0100 | ((self.s -% 3) & 0x00ff);
        self.pb = 0;
        self.db = 0;
        self.d = 0;
        try self.readDiscard(port, self.programAddress());
        try self.readDiscard(port, self.programAddress());
        try self.idle(port);
        try self.idle(port);
        try self.idle(port);
        const low = try self.readMemory(port, 0xfffc, .vector_read);
        const high = try self.readMemory(port, 0xfffd, .vector_read);
        self.pc = @as(u16, low) | (@as(u16, high) << 8);
    }

    fn enforceMode(self: *Cpu) void {
        if (self.emulation) {
            self.p.index_width = true;
            self.p.accumulator_width = true;
            self.s = 0x0100 | (self.s & 0x00ff);
        }
        if (self.p.index_width) {
            self.x &= 0x00ff;
            self.y &= 0x00ff;
        }
    }

    fn eightBit(self: *const Cpu, width: opcode.Width) bool {
        return switch (width) {
            .none => true,
            .accumulator => self.p.accumulator_width,
            .index => self.p.index_width,
        };
    }

    fn programAddress(self: *const Cpu) u32 {
        return (@as(u32, self.pb) << 16) | self.pc;
    }

    fn fetch(self: *Cpu, port: anytype) CpuError!u8 {
        const address = self.programAddress();
        self.pc +%= 1;
        return self.readMemory(port, address, .fetch);
    }

    fn fetch16(self: *Cpu, port: anytype) CpuError!u16 {
        const low = try self.fetch(port);
        const high = try self.fetch(port);
        return @as(u16, low) | (@as(u16, high) << 8);
    }

    fn fetch24(self: *Cpu, port: anytype) CpuError!u32 {
        const low = try self.fetch(port);
        const high = try self.fetch(port);
        const bank = try self.fetch(port);
        return (@as(u32, bank) << 16) | (@as(u32, high) << 8) | low;
    }

    fn push(self: *Cpu, port: anytype, value: u8) CpuError!void {
        try self.writeMemory(port, self.s, value);
        if (self.emulation) self.s = 0x0100 | @as(u16, @as(u8, @truncate(self.s -% 1))) else self.s -%= 1;
    }

    fn pull(self: *Cpu, port: anytype) CpuError!u8 {
        if (self.emulation) self.s = 0x0100 | @as(u16, @as(u8, @truncate(self.s +% 1))) else self.s +%= 1;
        return self.readMemory(port, self.s, .read);
    }

    fn pushNative(self: *Cpu, port: anytype, value: u8) CpuError!void {
        try self.writeMemory(port, self.s, value);
        self.s -%= 1;
    }

    fn pullNative(self: *Cpu, port: anytype) CpuError!u8 {
        self.s +%= 1;
        return self.readMemory(port, self.s, .read);
    }

    fn readDiscard(self: *Cpu, port: anytype, address: u32) CpuError!void {
        _ = try self.readMemory(port, address, .read);
    }

    fn readMemory(self: *Cpu, port: anytype, address: u32, kind: MicroOperationKind) CpuError!u8 {
        const access = port.read(address & address_mask);
        try self.record(.{
            .kind = kind,
            .address = address & address_mask,
            .value = access.value,
            .master_cycles = access.master_cycles,
        });
        return access.value;
    }

    fn writeMemory(self: *Cpu, port: anytype, address: u32, value: u8) CpuError!void {
        const access = port.write(address & address_mask, value);
        try self.record(.{
            .kind = .write,
            .address = address & address_mask,
            .value = value,
            .master_cycles = access.master_cycles,
        });
    }

    fn idle(self: *Cpu, port: anytype) CpuError!void {
        const cycles = port.idle(self.programAddress());
        try self.record(.{
            .kind = .idle,
            .address = self.programAddress(),
            .value = 0,
            .master_cycles = cycles,
        });
    }

    fn idleInstruction(self: *Cpu, port: anytype, enables_irq: bool) CpuError!void {
        const interrupt_after = self.abort_pending or self.nmi_pending or
            (self.irq_line and (!self.p.irq_disable or enables_irq));
        if (interrupt_after) {
            try self.readDiscard(port, self.programAddress());
        } else {
            try self.idle(port);
        }
    }

    fn record(self: *Cpu, operation: MicroOperation) CpuError!void {
        if (self.trace_len == trace_capacity) return error.TraceOverflow;
        self.trace[self.trace_len] = operation;
        self.trace_len += 1;
        self.master_cycles +%= operation.master_cycles;
    }
};
