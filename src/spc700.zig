const std = @import("std");
const sdsp = @import("sdsp.zig");

pub const apu_bus_hz: u64 = 1_024_000;
pub const aram_size: usize = 64 * 1024;
pub const exact_ipl_size: usize = 64;
pub const maximum_trace_cycles: usize = 32;

pub const BusMode = enum { hardware, vector_ram };
pub const BusCycleKind = enum { read, write, wait };
pub const BusCycle = struct {
    address: ?u16,
    value: ?u8,
    kind: BusCycleKind,
};
pub const Fault = enum { trace_overflow, exact_ipl_unavailable };
pub const IplMode = enum { semantic, exact };
pub const SemanticIplState = enum { dormant, waiting_command, receiving, launch_ack, running };

pub const Timer = struct {
    frequency: u8,
    stage0: u16 = 0,
    stage1: bool = false,
    stage2: u8 = 0,
    output: u4 = 0,
    line: bool = false,
    enabled: bool = false,
    target: u8 = 0,

    fn resetOnEnable(self: *Timer) void {
        self.stage2 = 0;
        self.output = 0;
    }

    fn advance(self: *Timer, clocks: u32, globally_enabled: bool) void {
        var remaining = clocks;
        while (remaining != 0) : (remaining -= 1) {
            self.stage0 += 1;
            if (self.stage0 < self.frequency) continue;
            self.stage0 = 0;
            self.stage1 = !self.stage1;
            self.synchronizeLine(globally_enabled);
        }
    }

    fn synchronizeLine(self: *Timer, globally_enabled: bool) void {
        const level = self.stage1 and globally_enabled;
        const falling = self.line and !level;
        self.line = level;
        if (!falling or !self.enabled) return;
        self.stage2 +%= 1;
        if (self.stage2 != self.target) return;
        self.stage2 = 0;
        self.output +%= 1;
    }
};

pub const Io = struct {
    timers_disabled: bool = false,
    ram_writable: bool = true,
    ram_disabled: bool = false,
    timers_enabled: bool = true,
    external_wait_states: u2 = 0,
    internal_wait_states: u2 = 0,
    ipl_enabled: bool = true,
    dsp_address: u8 = 0,
    cpu_to_smp: [4]u8 = [_]u8{0} ** 4,
    smp_to_cpu: [4]u8 = [_]u8{0} ** 4,
    cpu_port_epoch: [4]u64 = [_]u64{0} ** 4,
    smp_port_epoch: [4]u64 = [_]u64{0} ** 4,
    cpu_port_tick: [4]u64 = [_]u64{0} ** 4,
    smp_port_tick: [4]u64 = [_]u64{0} ** 4,
    port_epoch: u64 = 0,
    auxiliary: [2]u8 = [_]u8{0} ** 2,
};

const Alu = enum { adc, and_, asl, cmp, dec, eor, inc, ld, lsr, or_, rol, ror, sbc };
const Register = enum { a, x, y, sp };

pub const Smp = struct {
    a: u8 = 0,
    x: u8 = 0,
    y: u8 = 0,
    sp: u8 = 0xef,
    pc: u16 = 0,
    psw: u8 = 0x02,
    cycles: u64 = 0,
    stopped: bool = false,
    waiting: bool = false,
    aram: [aram_size]u8 = [_]u8{0} ** aram_size,
    dsp: sdsp.Dsp = .{},
    io: Io = .{},
    timers: [3]Timer = .{
        .{ .frequency = 128 },
        .{ .frequency = 128 },
        .{ .frequency = 16 },
    },
    bus_mode: BusMode = .hardware,
    trace_enabled: bool = false,
    trace: [maximum_trace_cycles]BusCycle = undefined,
    trace_len: u8 = 0,
    fault: ?Fault = null,
    ipl_mode: IplMode = .semantic,
    exact_ipl: [exact_ipl_size]u8 = [_]u8{0} ** exact_ipl_size,
    exact_ipl_loaded: bool = false,
    semantic_ipl_state: SemanticIplState = .dormant,
    semantic_destination: u16 = 0,
    semantic_received: u32 = 0,
    semantic_counter: u8 = 0,
    semantic_port0_pending: bool = false,
    semantic_pending_port0: u8 = 0,
    oscillator_phase: u64 = 0,
    oscillator_ticks: u64 = 0,

    const c_mask: u8 = 1 << 0;
    const z_mask: u8 = 1 << 1;
    const i_mask: u8 = 1 << 2;
    const h_mask: u8 = 1 << 3;
    const b_mask: u8 = 1 << 4;
    const p_mask: u8 = 1 << 5;
    const v_mask: u8 = 1 << 6;
    const n_mask: u8 = 1 << 7;

    pub fn reset(self: *Smp) void {
        self.a = 0;
        self.x = 0;
        self.y = 0;
        self.sp = 0xef;
        self.psw = 0x02;
        self.cycles = 0;
        self.stopped = false;
        self.waiting = false;
        self.dsp.reset();
        self.io = .{};
        self.timers = .{
            .{ .frequency = 128 },
            .{ .frequency = 128 },
            .{ .frequency = 16 },
        };
        self.trace_len = 0;
        self.fault = null;
        self.pc = if (self.ipl_mode == .exact and self.exact_ipl_loaded)
            @as(u16, self.exact_ipl[62]) | (@as(u16, self.exact_ipl[63]) << 8)
        else
            0;
        self.semantic_ipl_state = .dormant;
        self.semantic_port0_pending = false;
        self.semantic_pending_port0 = 0;
    }

    pub fn installExactIpl(self: *Smp, bytes: []const u8) !void {
        if (bytes.len != exact_ipl_size) return error.InvalidIplSize;
        @memcpy(self.exact_ipl[0..], bytes);
        self.exact_ipl_loaded = true;
        self.ipl_mode = .exact;
    }

    pub fn removeExactIpl(self: *Smp) void {
        @memset(self.exact_ipl[0..], 0);
        self.exact_ipl_loaded = false;
        self.ipl_mode = .semantic;
    }

    pub fn powerSemanticIpl(self: *Smp) void {
        self.ipl_mode = .semantic;
        self.io.ipl_enabled = true;
        self.io.cpu_to_smp = [_]u8{0} ** 4;
        self.io.smp_to_cpu = .{ 0xaa, 0xbb, 0, 0 };
        self.semantic_ipl_state = .waiting_command;
        self.semantic_destination = 0;
        self.semantic_received = 0;
        self.semantic_counter = 0;
        self.semantic_port0_pending = false;
        self.semantic_pending_port0 = 0;
        self.stopped = false;
        self.waiting = false;
        self.fault = null;
    }

    pub fn exactIplByte(self: *const Smp, address: u16) !u8 {
        if (address < 0xffc0 or !self.exact_ipl_loaded) return error.ExactIplUnavailable;
        return self.exact_ipl[address & 0x3f];
    }

    pub fn cpuWritePort(self: *Smp, port: u2, value: u8) void {
        self.io.port_epoch +%= 1;
        self.io.cpu_to_smp[port] = value;
        self.io.cpu_port_epoch[port] = self.io.port_epoch;
        self.io.cpu_port_tick[port] = self.oscillator_ticks;
        // The S-CPU may use a 16-bit store at $2140: port 0 is written before
        // port 1 inside the same instruction. Defer the semantic IPL edge to
        // the instruction boundary so it observes the new data byte instead
        // of acknowledging and copying the stale port-1 latch.
        if (self.ipl_mode == .semantic and port == 0 and
            (self.semantic_ipl_state == .waiting_command or self.semantic_ipl_state == .receiving))
        {
            self.semantic_port0_pending = true;
            self.semantic_pending_port0 = value;
        }
    }

    pub fn cpuReadPort(self: *Smp, port: u2) u8 {
        self.serviceSemanticIpl();
        const value = self.io.smp_to_cpu[port];
        if (port == 0 and self.semantic_ipl_state == .launch_ack) self.semantic_ipl_state = .running;
        return value;
    }

    pub fn serviceSemanticIpl(self: *Smp) void {
        if (self.ipl_mode != .semantic or !self.semantic_port0_pending) return;
        const value = self.semantic_pending_port0;
        self.semantic_port0_pending = false;
        self.semanticIplPort0(value);
    }

    pub fn runSemanticInstructions(self: *Smp, budget: u32) !u32 {
        if (self.ipl_mode != .semantic or self.semantic_ipl_state != .running) return 0;
        var executed: u32 = 0;
        while (executed < budget and self.semantic_ipl_state == .running) : (executed += 1) {
            if (self.io.ipl_enabled and self.pc >= 0xffc0) {
                self.powerSemanticIpl();
                break;
            }
            try self.step();
        }
        return executed;
    }

    fn semanticIplPort0(self: *Smp, value: u8) void {
        switch (self.semantic_ipl_state) {
            .dormant, .launch_ack, .running => {},
            .waiting_command => {
                if (value != 0xcc or self.io.cpu_to_smp[1] == 0) return;
                self.semantic_destination = @as(u16, self.io.cpu_to_smp[2]) |
                    (@as(u16, self.io.cpu_to_smp[3]) << 8);
                self.semantic_received = 0;
                self.semantic_counter = 0;
                self.io.smp_to_cpu[0] = value;
                self.semantic_ipl_state = .receiving;
            },
            .receiving => {
                if (value == self.semantic_counter) {
                    const address = self.semantic_destination +% @as(u16, @truncate(self.semantic_received));
                    self.aram[address] = self.io.cpu_to_smp[1];
                    self.semantic_received +%= 1;
                    self.semantic_counter +%= 1;
                    self.io.smp_to_cpu[0] = value;
                    return;
                }
                // A valid command deliberately skips the next sequential
                // byte counter (software normally advances the last
                // acknowledgement by at least two). Port 1 selects whether
                // that non-sequential value starts another data block or
                // launches the uploaded program. It is not required to be
                // exactly `counter + 1`; commercial loaders commonly choose
                // a larger collision-free command value.
                if (self.io.cpu_to_smp[1] == 0) {
                    self.pc = @as(u16, self.io.cpu_to_smp[2]) | (@as(u16, self.io.cpu_to_smp[3]) << 8);
                    self.io.smp_to_cpu[0] = value;
                    self.semantic_ipl_state = .launch_ack;
                    self.stopped = false;
                    self.waiting = false;
                    return;
                }
                if (self.io.cpu_to_smp[1] != 0) {
                    self.semantic_destination = @as(u16, self.io.cpu_to_smp[2]) |
                        (@as(u16, self.io.cpu_to_smp[3]) << 8);
                    self.semantic_received = 0;
                    self.semantic_counter = 0;
                    self.io.smp_to_cpu[0] = value;
                }
            },
        }
    }

    pub fn advanceOscillator(self: *Smp, master_hz: u64, master_clocks: u64) u64 {
        if (master_hz == 0) return 0;
        const total: u128 = @as(u128, self.oscillator_phase) + @as(u128, master_clocks) * apu_bus_hz;
        const produced: u64 = @intCast(total / master_hz);
        self.oscillator_phase = @intCast(total % master_hz);
        self.oscillator_ticks +%= produced;
        return produced;
    }

    pub fn beginTrace(self: *Smp) void {
        self.trace_len = 0;
        self.fault = null;
        self.trace_enabled = true;
    }

    pub fn endTrace(self: *Smp) []const BusCycle {
        self.trace_enabled = false;
        return self.trace[0..self.trace_len];
    }

    pub fn step(self: *Smp) !void {
        self.trace_len = 0;
        self.fault = null;
        if (self.stopped or self.waiting) {
            self.lowPowerCycles();
        } else {
            self.execute(self.fetch());
        }
        return switch (self.fault orelse return) {
            .trace_overflow => error.TraceOverflow,
            .exact_ipl_unavailable => error.ExactIplUnavailable,
        };
    }

    fn record(self: *Smp, cycle: BusCycle) void {
        if (!self.trace_enabled) return;
        if (self.trace_len >= self.trace.len) {
            self.fault = .trace_overflow;
            return;
        }
        self.trace[self.trace_len] = cycle;
        self.trace_len += 1;
    }

    fn directBase(self: *const Smp) u16 {
        return if (self.flag(p_mask)) 0x0100 else 0;
    }

    fn read(self: *Smp, address: u16) u8 {
        var value = self.aram[address];
        if (self.bus_mode == .hardware) {
            if (address >= 0xffc0 and self.io.ipl_enabled) {
                if (self.ipl_mode == .exact and self.exact_ipl_loaded) {
                    value = self.exact_ipl[address & 0x3f];
                } else {
                    self.fault = .exact_ipl_unavailable;
                    value = 0;
                }
            } else if (self.io.ram_disabled) {
                value = 0x5a;
            }
            if ((address & 0xfff0) == 0x00f0) value = self.readIo(@truncate(address));
        }
        self.record(.{ .address = address, .value = value, .kind = .read });
        self.advanceCycle(address, false);
        return value;
    }

    fn write(self: *Smp, address: u16, value: u8) void {
        self.record(.{ .address = address, .value = value, .kind = .write });
        if (self.bus_mode == .vector_ram) {
            self.aram[address] = value;
        } else {
            if (self.io.ram_writable and !self.io.ram_disabled) self.aram[address] = value;
            if ((address & 0xfff0) == 0x00f0) self.writeIo(@truncate(address), value);
        }
        self.advanceCycle(address, false);
    }

    fn idle(self: *Smp) void {
        self.record(.{ .address = null, .value = null, .kind = .wait });
        self.advanceCycle(null, true);
    }

    fn advanceCycle(self: *Smp, address: ?u16, internal: bool) void {
        const cycle_wait = [_]u8{ 2, 4, 10, 20 };
        const timer_wait = [_]u8{ 2, 4, 8, 16 };
        var selector: u2 = self.io.external_wait_states;
        if (internal or address == null or ((address.? & 0xfff0) == 0x00f0) or
            (address.? >= 0xffc0 and self.io.ipl_enabled)) selector = self.io.internal_wait_states;
        self.cycles +%= cycle_wait[selector];
        self.dsp.runClocks(&self.aram, cycle_wait[selector]);
        const timers_active = self.io.timers_enabled and !self.io.timers_disabled;
        for (&self.timers) |*timer| timer.advance(timer_wait[selector], timers_active);
    }

    fn fetch(self: *Smp) u8 {
        const value = self.read(self.pc);
        self.pc +%= 1;
        return value;
    }

    fn load(self: *Smp, address: u8) u8 {
        return self.read(self.directBase() | address);
    }

    fn store(self: *Smp, address: u8, value: u8) void {
        self.write(self.directBase() | address, value);
    }

    fn push(self: *Smp, value: u8) void {
        self.write(0x0100 | @as(u16, self.sp), value);
        self.sp -%= 1;
    }

    fn pull(self: *Smp) u8 {
        self.sp +%= 1;
        return self.read(0x0100 | @as(u16, self.sp));
    }

    fn flag(self: *const Smp, mask: u8) bool {
        return self.psw & mask != 0;
    }

    fn setFlag(self: *Smp, mask: u8, value: bool) void {
        if (value) self.psw |= mask else self.psw &= ~mask;
    }

    fn setNz(self: *Smp, value: u8) void {
        self.setFlag(z_mask, value == 0);
        self.setFlag(n_mask, value & 0x80 != 0);
    }

    fn setNzWord(self: *Smp, value: u16) void {
        self.setFlag(z_mask, value == 0);
        self.setFlag(n_mask, value & 0x8000 != 0);
    }

    fn unary(self: *Smp, op: Alu, value: u8) u8 {
        var result = value;
        switch (op) {
            .asl => {
                self.setFlag(c_mask, value & 0x80 != 0);
                result = value << 1;
            },
            .dec => result -%= 1,
            .inc => result +%= 1,
            .lsr => {
                self.setFlag(c_mask, value & 1 != 0);
                result = value >> 1;
            },
            .rol => {
                const carry: u8 = @intFromBool(self.flag(c_mask));
                self.setFlag(c_mask, value & 0x80 != 0);
                result = (value << 1) | carry;
            },
            .ror => {
                const carry: u8 = if (self.flag(c_mask)) 0x80 else 0;
                self.setFlag(c_mask, value & 1 != 0);
                result = carry | (value >> 1);
            },
            else => unreachable,
        }
        self.setNz(result);
        return result;
    }

    fn binary(self: *Smp, op: Alu, lhs: u8, rhs: u8) u8 {
        return switch (op) {
            .adc => self.addWithCarry(lhs, rhs),
            .sbc => self.addWithCarry(lhs, ~rhs),
            .and_ => value: {
                const result = lhs & rhs;
                self.setNz(result);
                break :value result;
            },
            .eor => value: {
                const result = lhs ^ rhs;
                self.setNz(result);
                break :value result;
            },
            .or_ => value: {
                const result = lhs | rhs;
                self.setNz(result);
                break :value result;
            },
            .cmp => value: {
                const difference: i16 = @as(i16, lhs) - @as(i16, rhs);
                const result: u8 = @truncate(@as(u16, @bitCast(difference)));
                self.setFlag(c_mask, difference >= 0);
                self.setNz(result);
                break :value lhs;
            },
            .ld => value: {
                self.setNz(rhs);
                break :value rhs;
            },
            else => unreachable,
        };
    }

    fn addWithCarry(self: *Smp, lhs: u8, rhs: u8) u8 {
        const carry: u16 = @intFromBool(self.flag(c_mask));
        const wide: u16 = @as(u16, lhs) + @as(u16, rhs) + carry;
        const result: u8 = @truncate(wide);
        self.setFlag(c_mask, wide > 0xff);
        self.setFlag(h_mask, (lhs ^ rhs ^ result) & 0x10 != 0);
        self.setFlag(v_mask, (~(lhs ^ rhs) & (lhs ^ result) & 0x80) != 0);
        self.setNz(result);
        return result;
    }

    fn getRegister(self: *const Smp, register: Register) u8 {
        return switch (register) {
            .a => self.a,
            .x => self.x,
            .y => self.y,
            .sp => self.sp,
        };
    }

    fn setRegister(self: *Smp, register: Register, value: u8) void {
        switch (register) {
            .a => self.a = value,
            .x => self.x = value,
            .y => self.y = value,
            .sp => self.sp = value,
        }
    }

    fn readIo(self: *Smp, address: u8) u8 {
        return switch (address) {
            0xf0, 0xf1, 0xfa, 0xfb, 0xfc => 0,
            0xf2 => self.io.dsp_address,
            0xf3 => self.dsp.read(self.io.dsp_address),
            0xf4...0xf7 => self.io.cpu_to_smp[address - 0xf4],
            0xf8, 0xf9 => self.io.auxiliary[address - 0xf8],
            0xfd...0xff => value: {
                const timer = &self.timers[address - 0xfd];
                const result: u8 = timer.output;
                timer.output = 0;
                break :value result;
            },
            else => 0,
        };
    }

    fn writeIo(self: *Smp, address: u8, value: u8) void {
        switch (address) {
            0xf0 => {
                if (self.flag(p_mask)) return;
                self.io.timers_disabled = value & 0x01 != 0;
                self.io.ram_writable = value & 0x02 != 0;
                self.io.ram_disabled = value & 0x04 != 0;
                self.io.timers_enabled = value & 0x08 != 0;
                self.io.external_wait_states = @truncate(value >> 4);
                self.io.internal_wait_states = @truncate(value >> 6);
                const timers_active = self.io.timers_enabled and !self.io.timers_disabled;
                for (&self.timers) |*timer| timer.synchronizeLine(timers_active);
            },
            0xf1 => {
                inline for (0..3) |index| {
                    const enable = value & (@as(u8, 1) << @intCast(index)) != 0;
                    if (!self.timers[index].enabled and enable) self.timers[index].resetOnEnable();
                    self.timers[index].enabled = enable;
                }
                if (value & 0x10 != 0) self.io.cpu_to_smp[0..2].* = [_]u8{ 0, 0 };
                if (value & 0x20 != 0) self.io.cpu_to_smp[2..4].* = [_]u8{ 0, 0 };
                self.io.ipl_enabled = value & 0x80 != 0;
            },
            0xf2 => self.io.dsp_address = value,
            0xf3 => if (self.io.dsp_address & 0x80 == 0) {
                self.dsp.write(self.io.dsp_address, value);
            },
            0xf4...0xf7 => {
                const port = address - 0xf4;
                self.io.port_epoch +%= 1;
                self.io.smp_to_cpu[port] = value;
                self.io.smp_port_epoch[port] = self.io.port_epoch;
                self.io.smp_port_tick[port] = self.oscillator_ticks;
            },
            0xf8, 0xf9 => self.io.auxiliary[address - 0xf8] = value,
            0xfa...0xfc => self.timers[address - 0xfa].target = value,
            else => {},
        }
    }

    fn lowPowerCycles(self: *Smp) void {
        var count: u2 = 0;
        while (count < 3) : (count += 1) {
            _ = self.read(self.pc);
            self.idle();
        }
    }

    fn absoluteAddress(self: *Smp) u16 {
        const low = self.fetch();
        return @as(u16, low) | (@as(u16, self.fetch()) << 8);
    }

    fn addDisplacement(self: *Smp, displacement: u8) void {
        const signed: i8 = @bitCast(displacement);
        const wrapped: u16 = @bitCast(@as(i16, signed));
        self.pc +%= wrapped;
    }

    fn absoluteBitModify(self: *Smp, mode: u3) void {
        var encoded = self.absoluteAddress();
        const bit: u3 = @truncate(encoded >> 13);
        encoded &= 0x1fff;
        var value = self.read(encoded);
        const selected = value & (@as(u8, 1) << bit) != 0;
        switch (mode) {
            0 => {
                self.idle();
                self.setFlag(c_mask, self.flag(c_mask) or selected);
            },
            1 => {
                self.idle();
                self.setFlag(c_mask, self.flag(c_mask) or !selected);
            },
            2 => self.setFlag(c_mask, self.flag(c_mask) and selected),
            3 => self.setFlag(c_mask, self.flag(c_mask) and !selected),
            4 => {
                self.idle();
                self.setFlag(c_mask, self.flag(c_mask) != selected);
            },
            5 => self.setFlag(c_mask, selected),
            6 => {
                self.idle();
                const mask = @as(u8, 1) << bit;
                if (self.flag(c_mask)) value |= mask else value &= ~mask;
                self.write(encoded, value);
            },
            7 => {
                value ^= @as(u8, 1) << bit;
                self.write(encoded, value);
            },
        }
    }

    fn directBitSet(self: *Smp, bit: u3, enabled: bool) void {
        const address = self.fetch();
        var value = self.load(address);
        const mask = @as(u8, 1) << bit;
        if (enabled) value |= mask else value &= ~mask;
        self.store(address, value);
    }

    fn absoluteRead(self: *Smp, op: Alu, target: Register) void {
        const value = self.read(self.absoluteAddress());
        self.setRegister(target, self.binary(op, self.getRegister(target), value));
    }

    fn absoluteModify(self: *Smp, op: Alu) void {
        const address = self.absoluteAddress();
        const value = self.read(address);
        self.write(address, self.unary(op, value));
    }

    fn absoluteWrite(self: *Smp, source: Register) void {
        const address = self.absoluteAddress();
        _ = self.read(address);
        self.write(address, self.getRegister(source));
    }

    fn absoluteIndexedRead(self: *Smp, op: Alu, index: Register) void {
        const address = self.absoluteAddress();
        self.idle();
        const value = self.read(address +% self.getRegister(index));
        self.a = self.binary(op, self.a, value);
    }

    fn absoluteIndexedWrite(self: *Smp, index: Register) void {
        const address = self.absoluteAddress();
        self.idle();
        const target = address +% self.getRegister(index);
        _ = self.read(target);
        self.write(target, self.a);
    }

    fn branch(self: *Smp, take: bool) void {
        const displacement = self.fetch();
        if (!take) return;
        self.idle();
        self.idle();
        self.addDisplacement(displacement);
    }

    fn branchBit(self: *Smp, bit: u3, match: bool) void {
        const address = self.fetch();
        const value = self.load(address);
        self.idle();
        const displacement = self.fetch();
        const selected = value & (@as(u8, 1) << bit) != 0;
        if (selected != match) return;
        self.idle();
        self.idle();
        self.addDisplacement(displacement);
    }

    fn branchNotDirect(self: *Smp) void {
        const value = self.load(self.fetch());
        self.idle();
        const displacement = self.fetch();
        if (self.a == value) return;
        self.idle();
        self.idle();
        self.addDisplacement(displacement);
    }

    fn branchNotDirectDecrement(self: *Smp) void {
        const address = self.fetch();
        var value = self.load(address);
        value -%= 1;
        self.store(address, value);
        const displacement = self.fetch();
        if (value == 0) return;
        self.idle();
        self.idle();
        self.addDisplacement(displacement);
    }

    fn branchNotDirectIndexed(self: *Smp, index: Register) void {
        const address = self.fetch();
        self.idle();
        const value = self.load(address +% self.getRegister(index));
        self.idle();
        const displacement = self.fetch();
        if (self.a == value) return;
        self.idle();
        self.idle();
        self.addDisplacement(displacement);
    }

    fn branchNotYDecrement(self: *Smp) void {
        _ = self.read(self.pc);
        self.idle();
        const displacement = self.fetch();
        self.y -%= 1;
        if (self.y == 0) return;
        self.idle();
        self.idle();
        self.addDisplacement(displacement);
    }

    fn breakInstruction(self: *Smp) void {
        _ = self.read(self.pc);
        self.push(@truncate(self.pc >> 8));
        self.push(@truncate(self.pc));
        self.push(self.psw);
        self.idle();
        self.pc = @as(u16, self.read(0xffde)) | (@as(u16, self.read(0xffdf)) << 8);
        self.setFlag(i_mask, false);
        self.setFlag(b_mask, true);
    }

    fn callAbsolute(self: *Smp) void {
        const address = self.absoluteAddress();
        self.idle();
        self.push(@truncate(self.pc >> 8));
        self.push(@truncate(self.pc));
        self.idle();
        self.idle();
        self.pc = address;
    }

    fn callPage(self: *Smp) void {
        const address = self.fetch();
        self.idle();
        self.push(@truncate(self.pc >> 8));
        self.push(@truncate(self.pc));
        self.idle();
        self.pc = 0xff00 | @as(u16, address);
    }

    fn callTable(self: *Smp, vector: u4) void {
        _ = self.read(self.pc);
        self.idle();
        self.push(@truncate(self.pc >> 8));
        self.push(@truncate(self.pc));
        self.idle();
        const address: u16 = 0xffde - (@as(u16, vector) << 1);
        self.pc = @as(u16, self.read(address)) | (@as(u16, self.read(address + 1)) << 8);
    }

    fn complementCarry(self: *Smp) void {
        _ = self.read(self.pc);
        self.idle();
        self.setFlag(c_mask, !self.flag(c_mask));
    }

    fn decimalAdjustAdd(self: *Smp) void {
        _ = self.read(self.pc);
        self.idle();
        if (self.flag(c_mask) or self.a > 0x99) {
            self.a +%= 0x60;
            self.setFlag(c_mask, true);
        }
        if (self.flag(h_mask) or (self.a & 0x0f) > 9) self.a +%= 6;
        self.setNz(self.a);
    }

    fn decimalAdjustSubtract(self: *Smp) void {
        _ = self.read(self.pc);
        self.idle();
        if (!self.flag(c_mask) or self.a > 0x99) {
            self.a -%= 0x60;
            self.setFlag(c_mask, false);
        }
        if (!self.flag(h_mask) or (self.a & 0x0f) > 9) self.a -%= 6;
        self.setNz(self.a);
    }

    fn directRead(self: *Smp, op: Alu, target: Register) void {
        const value = self.load(self.fetch());
        self.setRegister(target, self.binary(op, self.getRegister(target), value));
    }

    fn directModify(self: *Smp, op: Alu) void {
        const address = self.fetch();
        const value = self.load(address);
        self.store(address, self.unary(op, value));
    }

    fn directWrite(self: *Smp, source: Register) void {
        const address = self.fetch();
        _ = self.load(address);
        self.store(address, self.getRegister(source));
    }

    fn directDirectCompare(self: *Smp, op: Alu) void {
        const rhs = self.load(self.fetch());
        const target = self.fetch();
        const lhs = self.load(target);
        _ = self.binary(op, lhs, rhs);
        self.idle();
    }

    fn directDirectModify(self: *Smp, op: Alu) void {
        const rhs = self.load(self.fetch());
        const target = self.fetch();
        const lhs = self.load(target);
        self.store(target, self.binary(op, lhs, rhs));
    }

    fn directDirectWrite(self: *Smp) void {
        const value = self.load(self.fetch());
        self.store(self.fetch(), value);
    }

    fn directImmediateCompare(self: *Smp, op: Alu) void {
        const immediate = self.fetch();
        const value = self.load(self.fetch());
        _ = self.binary(op, value, immediate);
        self.idle();
    }

    fn directImmediateModify(self: *Smp, op: Alu) void {
        const immediate = self.fetch();
        const address = self.fetch();
        const value = self.load(address);
        self.store(address, self.binary(op, value, immediate));
    }

    fn directImmediateWrite(self: *Smp) void {
        const immediate = self.fetch();
        const address = self.fetch();
        _ = self.load(address);
        self.store(address, immediate);
    }

    fn directCompareWord(self: *Smp) void {
        const address = self.fetch();
        const rhs = @as(u16, self.load(address)) | (@as(u16, self.load(address +% 1)) << 8);
        const lhs = @as(u16, self.a) | (@as(u16, self.y) << 8);
        const difference: i32 = @as(i32, lhs) - @as(i32, rhs);
        const result: u16 = @truncate(@as(u32, @bitCast(difference)));
        self.setFlag(c_mask, difference >= 0);
        self.setNzWord(result);
    }

    fn directReadWord(self: *Smp, operation: enum { add, subtract, load }) void {
        const address = self.fetch();
        const low = self.load(address);
        self.idle();
        const high = self.load(address +% 1);
        const rhs = @as(u16, low) | (@as(u16, high) << 8);
        const lhs = @as(u16, self.a) | (@as(u16, self.y) << 8);
        var result: u16 = rhs;
        switch (operation) {
            .add => {
                self.setFlag(c_mask, false);
                const result_low = self.addWithCarry(@truncate(lhs), @truncate(rhs));
                const result_high = self.addWithCarry(@truncate(lhs >> 8), @truncate(rhs >> 8));
                result = @as(u16, result_low) | (@as(u16, result_high) << 8);
            },
            .subtract => {
                self.setFlag(c_mask, true);
                const result_low = self.addWithCarry(@truncate(lhs), ~@as(u8, @truncate(rhs)));
                const result_high = self.addWithCarry(@truncate(lhs >> 8), ~@as(u8, @truncate(rhs >> 8)));
                result = @as(u16, result_low) | (@as(u16, result_high) << 8);
            },
            .load => {},
        }
        self.a = @truncate(result);
        self.y = @truncate(result >> 8);
        self.setNzWord(result);
    }

    fn directModifyWord(self: *Smp, increment: bool) void {
        const address = self.fetch();
        var result: u16 = self.load(address);
        if (increment) result +%= 1 else result -%= 1;
        self.store(address, @truncate(result));
        result +%= @as(u16, self.load(address +% 1)) << 8;
        self.store(address +% 1, @truncate(result >> 8));
        self.setNzWord(result);
    }

    fn directWriteWord(self: *Smp) void {
        const address = self.fetch();
        _ = self.load(address);
        self.store(address, self.a);
        self.store(address +% 1, self.y);
    }

    fn directIndexedRead(self: *Smp, op: Alu, target: Register, index: Register) void {
        const address = self.fetch();
        self.idle();
        const value = self.load(address +% self.getRegister(index));
        self.setRegister(target, self.binary(op, self.getRegister(target), value));
    }

    fn directIndexedModify(self: *Smp, op: Alu, index: Register) void {
        const address = self.fetch();
        self.idle();
        const target = address +% self.getRegister(index);
        const value = self.load(target);
        self.store(target, self.unary(op, value));
    }

    fn directIndexedWrite(self: *Smp, source: Register, index: Register) void {
        const address = self.fetch();
        self.idle();
        const target = address +% self.getRegister(index);
        _ = self.load(target);
        self.store(target, self.getRegister(source));
    }

    fn divide(self: *Smp) void {
        _ = self.read(self.pc);
        var waits: u4 = 0;
        while (waits < 10) : (waits += 1) self.idle();
        const ya = @as(u16, self.a) | (@as(u16, self.y) << 8);
        self.setFlag(h_mask, (self.y & 15) >= (self.x & 15));
        self.setFlag(v_mask, self.y >= self.x);
        if (@as(u16, self.y) < (@as(u16, self.x) << 1)) {
            self.a = @truncate(ya / self.x);
            self.y = @truncate(ya % self.x);
        } else {
            const numerator = ya -% (@as(u16, self.x) << 9);
            const denominator: u16 = 256 - @as(u16, self.x);
            self.a = @truncate(255 -% (numerator / denominator));
            self.y = @truncate(@as(u16, self.x) +% (numerator % denominator));
        }
        self.setNz(self.a);
    }

    fn exchangeNibble(self: *Smp) void {
        _ = self.read(self.pc);
        self.idle();
        self.idle();
        self.idle();
        self.a = (self.a >> 4) | (self.a << 4);
        self.setNz(self.a);
    }

    fn setStatusFlag(self: *Smp, mask: u8, value: bool) void {
        _ = self.read(self.pc);
        if (mask == i_mask) self.idle();
        self.setFlag(mask, value);
    }

    fn immediateRead(self: *Smp, op: Alu, target: Register) void {
        const value = self.fetch();
        self.setRegister(target, self.binary(op, self.getRegister(target), value));
    }

    fn impliedModify(self: *Smp, op: Alu, target: Register) void {
        _ = self.read(self.pc);
        self.setRegister(target, self.unary(op, self.getRegister(target)));
    }

    fn indexedIndirectRead(self: *Smp, op: Alu, index: Register) void {
        const indirect = self.fetch();
        self.idle();
        const offset = indirect +% self.getRegister(index);
        const address = @as(u16, self.load(offset)) | (@as(u16, self.load(offset +% 1)) << 8);
        self.a = self.binary(op, self.a, self.read(address));
    }

    fn indexedIndirectWrite(self: *Smp, source: Register, index: Register) void {
        const indirect = self.fetch();
        self.idle();
        const offset = indirect +% self.getRegister(index);
        const address = @as(u16, self.load(offset)) | (@as(u16, self.load(offset +% 1)) << 8);
        _ = self.read(address);
        self.write(address, self.getRegister(source));
    }

    fn indirectIndexedRead(self: *Smp, op: Alu, index: Register) void {
        const indirect = self.fetch();
        self.idle();
        const address = @as(u16, self.load(indirect)) | (@as(u16, self.load(indirect +% 1)) << 8);
        self.a = self.binary(op, self.a, self.read(address +% self.getRegister(index)));
    }

    fn indirectIndexedWrite(self: *Smp, source: Register, index: Register) void {
        const indirect = self.fetch();
        const address = @as(u16, self.load(indirect)) | (@as(u16, self.load(indirect +% 1)) << 8);
        self.idle();
        const target = address +% self.getRegister(index);
        _ = self.read(target);
        self.write(target, self.getRegister(source));
    }

    fn indirectXRead(self: *Smp, op: Alu) void {
        _ = self.read(self.pc);
        self.a = self.binary(op, self.a, self.load(self.x));
    }

    fn indirectXWrite(self: *Smp, source: Register) void {
        _ = self.read(self.pc);
        _ = self.load(self.x);
        self.store(self.x, self.getRegister(source));
    }

    fn indirectXIncrementRead(self: *Smp, target: Register) void {
        _ = self.read(self.pc);
        const value = self.load(self.x);
        self.x +%= 1;
        self.idle();
        self.setRegister(target, value);
        self.setNz(value);
    }

    fn indirectXIncrementWrite(self: *Smp, source: Register) void {
        _ = self.read(self.pc);
        self.idle();
        self.store(self.x, self.getRegister(source));
        self.x +%= 1;
    }

    fn indirectXCompareIndirectY(self: *Smp, op: Alu) void {
        _ = self.read(self.pc);
        const rhs = self.load(self.y);
        const lhs = self.load(self.x);
        _ = self.binary(op, lhs, rhs);
        self.idle();
    }

    fn indirectXWriteIndirectY(self: *Smp, op: Alu) void {
        _ = self.read(self.pc);
        const rhs = self.load(self.y);
        const lhs = self.load(self.x);
        self.store(self.x, self.binary(op, lhs, rhs));
    }

    fn jumpAbsolute(self: *Smp) void {
        self.pc = self.absoluteAddress();
    }

    fn jumpIndirectX(self: *Smp) void {
        const address = self.absoluteAddress();
        self.idle();
        const target = address +% self.x;
        self.pc = @as(u16, self.read(target)) | (@as(u16, self.read(target +% 1)) << 8);
    }

    fn multiply(self: *Smp) void {
        _ = self.read(self.pc);
        var waits: u3 = 0;
        while (waits < 7) : (waits += 1) self.idle();
        const result: u16 = @as(u16, self.y) * @as(u16, self.a);
        self.a = @truncate(result);
        self.y = @truncate(result >> 8);
        self.setNz(self.y);
    }

    fn noOperation(self: *Smp) void {
        _ = self.read(self.pc);
    }

    fn overflowClear(self: *Smp) void {
        _ = self.read(self.pc);
        self.setFlag(h_mask, false);
        self.setFlag(v_mask, false);
    }

    fn pullRegister(self: *Smp, target: Register) void {
        _ = self.read(self.pc);
        self.idle();
        self.setRegister(target, self.pull());
    }

    fn pullPsw(self: *Smp) void {
        _ = self.read(self.pc);
        self.idle();
        self.psw = self.pull();
    }
    fn pushRegister(self: *Smp, source: Register) void {
        _ = self.read(self.pc);
        self.push(self.getRegister(source));
        self.idle();
    }
    fn pushPsw(self: *Smp) void {
        _ = self.read(self.pc);
        self.push(self.psw);
        self.idle();
    }

    fn returnInterrupt(self: *Smp) void {
        _ = self.read(self.pc);
        self.idle();
        self.psw = self.pull();
        self.pc = @as(u16, self.pull()) | (@as(u16, self.pull()) << 8);
    }

    fn returnSubroutine(self: *Smp) void {
        _ = self.read(self.pc);
        self.idle();
        self.pc = @as(u16, self.pull()) | (@as(u16, self.pull()) << 8);
    }

    fn stopInstruction(self: *Smp, wait: bool) void {
        if (wait) self.waiting = true else self.stopped = true;
        self.lowPowerCycles();
    }

    fn testSetBitsAbsolute(self: *Smp, set: bool) void {
        const address = self.absoluteAddress();
        const value = self.read(address);
        const difference = self.a -% value;
        self.setNz(difference);
        _ = self.read(address);
        self.write(address, if (set) value | self.a else value & ~self.a);
    }

    fn transfer(self: *Smp, source: Register, target: Register) void {
        _ = self.read(self.pc);
        const value = self.getRegister(source);
        self.setRegister(target, value);
        if (target != .sp) self.setNz(value);
    }

    fn execute(self: *Smp, opcode: u8) void {
        switch (opcode) {
            0x00 => self.noOperation(),
            0x01 => self.callTable(0),
            0x02 => self.directBitSet(0, true),
            0x03 => self.branchBit(0, true),
            0x04 => self.directRead(.or_, .a),
            0x05 => self.absoluteRead(.or_, .a),
            0x06 => self.indirectXRead(.or_),
            0x07 => self.indexedIndirectRead(.or_, .x),
            0x08 => self.immediateRead(.or_, .a),
            0x09 => self.directDirectModify(.or_),
            0x0a => self.absoluteBitModify(0),
            0x0b => self.directModify(.asl),
            0x0c => self.absoluteModify(.asl),
            0x0d => self.pushPsw(),
            0x0e => self.testSetBitsAbsolute(true),
            0x0f => self.breakInstruction(),
            0x10 => self.branch(!self.flag(n_mask)),
            0x11 => self.callTable(1),
            0x12 => self.directBitSet(0, false),
            0x13 => self.branchBit(0, false),
            0x14 => self.directIndexedRead(.or_, .a, .x),
            0x15 => self.absoluteIndexedRead(.or_, .x),
            0x16 => self.absoluteIndexedRead(.or_, .y),
            0x17 => self.indirectIndexedRead(.or_, .y),
            0x18 => self.directImmediateModify(.or_),
            0x19 => self.indirectXWriteIndirectY(.or_),
            0x1a => self.directModifyWord(false),
            0x1b => self.directIndexedModify(.asl, .x),
            0x1c => self.impliedModify(.asl, .a),
            0x1d => self.impliedModify(.dec, .x),
            0x1e => self.absoluteRead(.cmp, .x),
            0x1f => self.jumpIndirectX(),
            0x20 => self.setStatusFlag(p_mask, false),
            0x21 => self.callTable(2),
            0x22 => self.directBitSet(1, true),
            0x23 => self.branchBit(1, true),
            0x24 => self.directRead(.and_, .a),
            0x25 => self.absoluteRead(.and_, .a),
            0x26 => self.indirectXRead(.and_),
            0x27 => self.indexedIndirectRead(.and_, .x),
            0x28 => self.immediateRead(.and_, .a),
            0x29 => self.directDirectModify(.and_),
            0x2a => self.absoluteBitModify(1),
            0x2b => self.directModify(.rol),
            0x2c => self.absoluteModify(.rol),
            0x2d => self.pushRegister(.a),
            0x2e => self.branchNotDirect(),
            0x2f => self.branch(true),
            0x30 => self.branch(self.flag(n_mask)),
            0x31 => self.callTable(3),
            0x32 => self.directBitSet(1, false),
            0x33 => self.branchBit(1, false),
            0x34 => self.directIndexedRead(.and_, .a, .x),
            0x35 => self.absoluteIndexedRead(.and_, .x),
            0x36 => self.absoluteIndexedRead(.and_, .y),
            0x37 => self.indirectIndexedRead(.and_, .y),
            0x38 => self.directImmediateModify(.and_),
            0x39 => self.indirectXWriteIndirectY(.and_),
            0x3a => self.directModifyWord(true),
            0x3b => self.directIndexedModify(.rol, .x),
            0x3c => self.impliedModify(.rol, .a),
            0x3d => self.impliedModify(.inc, .x),
            0x3e => self.directRead(.cmp, .x),
            0x3f => self.callAbsolute(),
            0x40 => self.setStatusFlag(p_mask, true),
            0x41 => self.callTable(4),
            0x42 => self.directBitSet(2, true),
            0x43 => self.branchBit(2, true),
            0x44 => self.directRead(.eor, .a),
            0x45 => self.absoluteRead(.eor, .a),
            0x46 => self.indirectXRead(.eor),
            0x47 => self.indexedIndirectRead(.eor, .x),
            0x48 => self.immediateRead(.eor, .a),
            0x49 => self.directDirectModify(.eor),
            0x4a => self.absoluteBitModify(2),
            0x4b => self.directModify(.lsr),
            0x4c => self.absoluteModify(.lsr),
            0x4d => self.pushRegister(.x),
            0x4e => self.testSetBitsAbsolute(false),
            0x4f => self.callPage(),
            0x50 => self.branch(!self.flag(v_mask)),
            0x51 => self.callTable(5),
            0x52 => self.directBitSet(2, false),
            0x53 => self.branchBit(2, false),
            0x54 => self.directIndexedRead(.eor, .a, .x),
            0x55 => self.absoluteIndexedRead(.eor, .x),
            0x56 => self.absoluteIndexedRead(.eor, .y),
            0x57 => self.indirectIndexedRead(.eor, .y),
            0x58 => self.directImmediateModify(.eor),
            0x59 => self.indirectXWriteIndirectY(.eor),
            0x5a => self.directCompareWord(),
            0x5b => self.directIndexedModify(.lsr, .x),
            0x5c => self.impliedModify(.lsr, .a),
            0x5d => self.transfer(.a, .x),
            0x5e => self.absoluteRead(.cmp, .y),
            0x5f => self.jumpAbsolute(),
            0x60 => self.setStatusFlag(c_mask, false),
            0x61 => self.callTable(6),
            0x62 => self.directBitSet(3, true),
            0x63 => self.branchBit(3, true),
            0x64 => self.directRead(.cmp, .a),
            0x65 => self.absoluteRead(.cmp, .a),
            0x66 => self.indirectXRead(.cmp),
            0x67 => self.indexedIndirectRead(.cmp, .x),
            0x68 => self.immediateRead(.cmp, .a),
            0x69 => self.directDirectCompare(.cmp),
            0x6a => self.absoluteBitModify(3),
            0x6b => self.directModify(.ror),
            0x6c => self.absoluteModify(.ror),
            0x6d => self.pushRegister(.y),
            0x6e => self.branchNotDirectDecrement(),
            0x6f => self.returnSubroutine(),
            0x70 => self.branch(self.flag(v_mask)),
            0x71 => self.callTable(7),
            0x72 => self.directBitSet(3, false),
            0x73 => self.branchBit(3, false),
            0x74 => self.directIndexedRead(.cmp, .a, .x),
            0x75 => self.absoluteIndexedRead(.cmp, .x),
            0x76 => self.absoluteIndexedRead(.cmp, .y),
            0x77 => self.indirectIndexedRead(.cmp, .y),
            0x78 => self.directImmediateCompare(.cmp),
            0x79 => self.indirectXCompareIndirectY(.cmp),
            0x7a => self.directReadWord(.add),
            0x7b => self.directIndexedModify(.ror, .x),
            0x7c => self.impliedModify(.ror, .a),
            0x7d => self.transfer(.x, .a),
            0x7e => self.directRead(.cmp, .y),
            0x7f => self.returnInterrupt(),
            0x80 => self.setStatusFlag(c_mask, true),
            0x81 => self.callTable(8),
            0x82 => self.directBitSet(4, true),
            0x83 => self.branchBit(4, true),
            0x84 => self.directRead(.adc, .a),
            0x85 => self.absoluteRead(.adc, .a),
            0x86 => self.indirectXRead(.adc),
            0x87 => self.indexedIndirectRead(.adc, .x),
            0x88 => self.immediateRead(.adc, .a),
            0x89 => self.directDirectModify(.adc),
            0x8a => self.absoluteBitModify(4),
            0x8b => self.directModify(.dec),
            0x8c => self.absoluteModify(.dec),
            0x8d => self.immediateRead(.ld, .y),
            0x8e => self.pullPsw(),
            0x8f => self.directImmediateWrite(),
            0x90 => self.branch(!self.flag(c_mask)),
            0x91 => self.callTable(9),
            0x92 => self.directBitSet(4, false),
            0x93 => self.branchBit(4, false),
            0x94 => self.directIndexedRead(.adc, .a, .x),
            0x95 => self.absoluteIndexedRead(.adc, .x),
            0x96 => self.absoluteIndexedRead(.adc, .y),
            0x97 => self.indirectIndexedRead(.adc, .y),
            0x98 => self.directImmediateModify(.adc),
            0x99 => self.indirectXWriteIndirectY(.adc),
            0x9a => self.directReadWord(.subtract),
            0x9b => self.directIndexedModify(.dec, .x),
            0x9c => self.impliedModify(.dec, .a),
            0x9d => self.transfer(.sp, .x),
            0x9e => self.divide(),
            0x9f => self.exchangeNibble(),
            0xa0 => self.setStatusFlag(i_mask, true),
            0xa1 => self.callTable(10),
            0xa2 => self.directBitSet(5, true),
            0xa3 => self.branchBit(5, true),
            0xa4 => self.directRead(.sbc, .a),
            0xa5 => self.absoluteRead(.sbc, .a),
            0xa6 => self.indirectXRead(.sbc),
            0xa7 => self.indexedIndirectRead(.sbc, .x),
            0xa8 => self.immediateRead(.sbc, .a),
            0xa9 => self.directDirectModify(.sbc),
            0xaa => self.absoluteBitModify(5),
            0xab => self.directModify(.inc),
            0xac => self.absoluteModify(.inc),
            0xad => self.immediateRead(.cmp, .y),
            0xae => self.pullRegister(.a),
            0xaf => self.indirectXIncrementWrite(.a),
            0xb0 => self.branch(self.flag(c_mask)),
            0xb1 => self.callTable(11),
            0xb2 => self.directBitSet(5, false),
            0xb3 => self.branchBit(5, false),
            0xb4 => self.directIndexedRead(.sbc, .a, .x),
            0xb5 => self.absoluteIndexedRead(.sbc, .x),
            0xb6 => self.absoluteIndexedRead(.sbc, .y),
            0xb7 => self.indirectIndexedRead(.sbc, .y),
            0xb8 => self.directImmediateModify(.sbc),
            0xb9 => self.indirectXWriteIndirectY(.sbc),
            0xba => self.directReadWord(.load),
            0xbb => self.directIndexedModify(.inc, .x),
            0xbc => self.impliedModify(.inc, .a),
            0xbd => self.transfer(.x, .sp),
            0xbe => self.decimalAdjustSubtract(),
            0xbf => self.indirectXIncrementRead(.a),
            0xc0 => self.setStatusFlag(i_mask, false),
            0xc1 => self.callTable(12),
            0xc2 => self.directBitSet(6, true),
            0xc3 => self.branchBit(6, true),
            0xc4 => self.directWrite(.a),
            0xc5 => self.absoluteWrite(.a),
            0xc6 => self.indirectXWrite(.a),
            0xc7 => self.indexedIndirectWrite(.a, .x),
            0xc8 => self.immediateRead(.cmp, .x),
            0xc9 => self.absoluteWrite(.x),
            0xca => self.absoluteBitModify(6),
            0xcb => self.directWrite(.y),
            0xcc => self.absoluteWrite(.y),
            0xcd => self.immediateRead(.ld, .x),
            0xce => self.pullRegister(.x),
            0xcf => self.multiply(),
            0xd0 => self.branch(!self.flag(z_mask)),
            0xd1 => self.callTable(13),
            0xd2 => self.directBitSet(6, false),
            0xd3 => self.branchBit(6, false),
            0xd4 => self.directIndexedWrite(.a, .x),
            0xd5 => self.absoluteIndexedWrite(.x),
            0xd6 => self.absoluteIndexedWrite(.y),
            0xd7 => self.indirectIndexedWrite(.a, .y),
            0xd8 => self.directWrite(.x),
            0xd9 => self.directIndexedWrite(.x, .y),
            0xda => self.directWriteWord(),
            0xdb => self.directIndexedWrite(.y, .x),
            0xdc => self.impliedModify(.dec, .y),
            0xdd => self.transfer(.y, .a),
            0xde => self.branchNotDirectIndexed(.x),
            0xdf => self.decimalAdjustAdd(),
            0xe0 => self.overflowClear(),
            0xe1 => self.callTable(14),
            0xe2 => self.directBitSet(7, true),
            0xe3 => self.branchBit(7, true),
            0xe4 => self.directRead(.ld, .a),
            0xe5 => self.absoluteRead(.ld, .a),
            0xe6 => self.indirectXRead(.ld),
            0xe7 => self.indexedIndirectRead(.ld, .x),
            0xe8 => self.immediateRead(.ld, .a),
            0xe9 => self.absoluteRead(.ld, .x),
            0xea => self.absoluteBitModify(7),
            0xeb => self.directRead(.ld, .y),
            0xec => self.absoluteRead(.ld, .y),
            0xed => self.complementCarry(),
            0xee => self.pullRegister(.y),
            0xef => self.stopInstruction(true),
            0xf0 => self.branch(self.flag(z_mask)),
            0xf1 => self.callTable(15),
            0xf2 => self.directBitSet(7, false),
            0xf3 => self.branchBit(7, false),
            0xf4 => self.directIndexedRead(.ld, .a, .x),
            0xf5 => self.absoluteIndexedRead(.ld, .x),
            0xf6 => self.absoluteIndexedRead(.ld, .y),
            0xf7 => self.indirectIndexedRead(.ld, .y),
            0xf8 => self.directRead(.ld, .x),
            0xf9 => self.directIndexedRead(.ld, .x, .y),
            0xfa => self.directDirectWrite(),
            0xfb => self.directIndexedRead(.ld, .y, .x),
            0xfc => self.impliedModify(.inc, .y),
            0xfd => self.transfer(.a, .y),
            0xfe => self.branchNotYDecrement(),
            0xff => self.stopInstruction(false),
        }
    }
};

test "oscillator accumulation is partition invariant" {
    var once = Smp{};
    var split = Smp{};
    const master_hz: u64 = 21_477_272;
    _ = once.advanceOscillator(master_hz, 10_000_003);
    var left: u64 = 10_000_003;
    while (left != 0) {
        const span = @min(left, 997);
        _ = split.advanceOscillator(master_hz, span);
        left -= span;
    }
    try std.testing.expectEqual(once.oscillator_ticks, split.oscillator_ticks);
    try std.testing.expectEqual(once.oscillator_phase, split.oscillator_phase);
}
