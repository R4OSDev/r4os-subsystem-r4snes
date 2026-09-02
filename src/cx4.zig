const std = @import("std");
const board = @import("board.zig");

pub const access_master_cycles: u8 = 8;
pub const data_ram_bytes: usize = 3 * 1024;
pub const program_words: usize = 256;
pub const data_rom_words: usize = 1024;
pub const maximum_rom_bytes: usize = 2 * 1024 * 1024;

const address_mask: u32 = 0x00ff_ffff;
const value_mask: u32 = 0x00ff_ffff;
const sign_bit: u32 = 0x0080_0000;

pub const Fault = enum {
    invalid_dma,
    cache_locked,
};

pub const RunState = enum {
    budget,
    halted,
    locked,
    suspended,
    cache,
    dma,
    running,
};

pub const RunResult = struct {
    state: RunState,
    cycles: u64,
    instructions: u64,
    fault: ?Fault,
};

pub const WriteResult = struct {
    handled: bool = false,
    changed: bool = false,
};

pub const OpcodeClass = enum {
    defined,
    reserved_nop,
};

const Resource = enum {
    none,
    rom,
    save_ram,
    data_ram,
    io,
};

const DmaPhase = enum {
    source,
    target,
};

const Operation = enum {
    none,
    cache_read,
    dma_read,
    dma_write,
};

pub const Device = struct {
    program_ram: [2][program_words]u16 = .{ .{0} ** program_words, .{0} ** program_words },
    data_ram: [data_ram_bytes]u8 = .{0} ** data_ram_bytes,

    pb: u15 = 0,
    pc: u8 = 0,
    negative: bool = false,
    zero: bool = false,
    carry: bool = false,
    overflow: bool = false,
    accumulator: u24 = 0,
    page: u15 = 0,
    multiplier: u48 = 0,
    memory_data: u24 = 0,
    rom_buffer: u24 = 0,
    ram_buffer: u24 = 0,
    memory_address: u24 = 0,
    data_pointer: u24 = 0,
    gpr: [16]u24 = .{0} ** 16,
    stack: [8]u23 = .{0} ** 8,

    locked: bool = false,
    stopped: bool = true,
    irq_disabled: bool = false,
    irq_flag: bool = false,
    irq_line: bool = false,
    single_rom: bool = true,
    rom_wait: u3 = 3,
    ram_wait: u3 = 3,
    vectors: [32]u8 = .{0} ** 32,

    suspend_enabled: bool = false,
    suspend_duration: u8 = 0,

    cache_enabled: bool = false,
    cache_prepared: bool = false,
    cache_page: u1 = 0,
    cache_lock: [2]bool = .{ false, false },
    cache_valid: [2]bool = .{ false, false },
    cache_address: [2]u24 = .{ 0, 0 },
    cache_base: u24 = 0,
    cache_program_bank: u15 = 0,
    cache_program_counter: u8 = 0,
    cache_position: u16 = 0,

    dma_enabled: bool = false,
    dma_source: u24 = 0,
    dma_target: u24 = 0,
    dma_length: u16 = 0,
    dma_position: u16 = 0,
    dma_phase: DmaPhase = .source,
    dma_latch: u8 = 0,

    bus_enabled: bool = false,
    bus_reading: bool = false,
    bus_writing: bool = false,
    bus_pending: u4 = 0,
    bus_address: u24 = 0,

    operation: Operation = .none,
    operation_wait: u8 = 0,
    operation_address: u24 = 0,
    operation_value: u8 = 0,
    stall_cycles: u8 = 0,

    cycle_count: u64 = 0,
    instruction_count: u64 = 0,
    dma_bytes: u64 = 0,
    cache_bytes: u64 = 0,
    bus_conflicts: u64 = 0,
    reserved_opcodes: u64 = 0,
    last_reserved_opcode: u16 = 0,
    last_fault: ?Fault = null,

    pub fn power(self: *Device, rom_bytes: usize, save_ram_bytes: usize) !void {
        try validateGeometry(rom_bytes, save_ram_bytes);
        self.* = .{};
    }

    pub fn readCpu(self: *Device, rom: []const u8, save_ram: []const u8, raw_address: u32, open_bus: u8) ?u8 {
        const address = raw_address & address_mask;
        if (dataRamIndex(address)) |index| return self.data_ram[index];
        if (ioAddress(address)) |io| return self.readIo(io);

        const resource = resourceForAddress(address, rom.len, save_ram.len);
        if (self.resourceBusy(resource)) {
            self.bus_conflicts +%= 1;
            if (resource == .rom) {
                if (cpuVectorIo(address)) |io| return self.readIo(io);
            }
            return open_bus;
        }
        return null;
    }

    pub fn writeCpu(self: *Device, rom: []const u8, save_ram: []u8, raw_address: u32, value: u8) WriteResult {
        const address = raw_address & address_mask;
        if (dataRamIndex(address)) |index| {
            const changed = self.data_ram[index] != value;
            self.data_ram[index] = value;
            return .{ .handled = true, .changed = changed };
        }
        if (ioAddress(address)) |io| {
            self.writeIo(io, value);
            return .{ .handled = true, .changed = true };
        }

        const resource = resourceForAddress(address, rom.len, save_ram.len);
        if (self.resourceBusy(resource)) {
            self.bus_conflicts +%= 1;
            return .{ .handled = true };
        }
        return .{};
    }

    pub fn runSlice(self: *Device, rom: []const u8, save_ram: []u8, maximum_cycles: usize) RunResult {
        const cycles_before = self.cycle_count;
        const instructions_before = self.instruction_count;
        var consumed: usize = 0;
        while (consumed < maximum_cycles) : (consumed += 1) self.tick(rom, save_ram);
        return .{
            .state = if (maximum_cycles == 0) .budget else self.runState(),
            .cycles = self.cycle_count -% cycles_before,
            .instructions = self.instruction_count -% instructions_before,
            .fault = self.last_fault,
        };
    }

    pub fn runUntilCycle(self: *Device, rom: []const u8, save_ram: []u8, target: u64) RunResult {
        const remaining = if (target > self.cycle_count) target - self.cycle_count else 0;
        const bounded: usize = @intCast(@min(remaining, std.math.maxInt(usize)));
        return self.runSlice(rom, save_ram, bounded);
    }

    pub fn irqPending(self: *const Device) bool {
        return self.irq_line;
    }

    pub fn busy(self: *const Device) bool {
        return self.cache_enabled or self.dma_enabled or self.bus_enabled or self.operation != .none;
    }

    pub fn running(self: *const Device) bool {
        return self.busy() or !self.stopped;
    }

    pub fn executeDecoded(self: *Device, opcode: u16) OpcodeClass {
        const operation: u8 = @truncate(opcode >> 8);
        const operand: u8 = @truncate(opcode);
        const group = operation & 0xfc;
        const mode: u2 = @truncate(operation);
        const shift = shiftForCode(mode);
        const source: u7 = @truncate(operand);

        const class: OpcodeClass = switch (group) {
            0x00 => .defined,
            0x04 => .reserved_nop,
            0x08 => blk: {
                self.branch(true, operation, operand);
                break :blk .defined;
            },
            0x0c => blk: {
                self.branch(self.zero, operation, operand);
                break :blk .defined;
            },
            0x10 => blk: {
                self.branch(self.carry, operation, operand);
                break :blk .defined;
            },
            0x14 => blk: {
                self.branch(self.negative, operation, operand);
                break :blk .defined;
            },
            0x18 => blk: {
                self.branch(self.overflow, operation, operand);
                break :blk .defined;
            },
            0x1c => blk: {
                if (self.bus_enabled) self.stall_cycles = @max(self.stall_cycles, self.bus_pending);
                break :blk .defined;
            },
            0x20 => .reserved_nop,
            0x24 => blk: {
                const flag = switch (mode) {
                    0 => self.overflow,
                    1 => self.carry,
                    2 => self.zero,
                    else => self.negative,
                };
                if (flag == ((operand & 1) != 0)) {
                    self.advanceProgramCounter();
                    self.stall_cycles +|= 1;
                }
                break :blk .defined;
            },
            0x28 => blk: {
                self.call(true, operation, operand);
                break :blk .defined;
            },
            0x2c => blk: {
                self.call(self.zero, operation, operand);
                break :blk .defined;
            },
            0x30 => blk: {
                self.call(self.carry, operation, operand);
                break :blk .defined;
            },
            0x34 => blk: {
                self.call(self.negative, operation, operand);
                break :blk .defined;
            },
            0x38 => blk: {
                self.call(self.overflow, operation, operand);
                break :blk .defined;
            },
            0x3c => blk: {
                self.pull();
                self.stall_cycles +|= 2;
                break :blk .defined;
            },
            0x40 => blk: {
                self.memory_address +%= 1;
                break :blk .defined;
            },
            0x44 => .reserved_nop,
            0x48 => blk: {
                _ = self.subtract(self.sourceValue(source), self.shiftedAccumulator(shift));
                break :blk .defined;
            },
            0x4c => blk: {
                _ = self.subtract(operand, self.shiftedAccumulator(shift));
                break :blk .defined;
            },
            0x50 => blk: {
                _ = self.subtract(self.shiftedAccumulator(shift), self.sourceValue(source));
                break :blk .defined;
            },
            0x54 => blk: {
                _ = self.subtract(self.shiftedAccumulator(shift), operand);
                break :blk .defined;
            },
            0x58 => switch (mode) {
                1 => blk: {
                    self.accumulator = @truncate(@as(u32, @bitCast(@as(i32, @as(i8, @bitCast(@as(u8, @truncate(self.accumulator))))))));
                    self.setNz(self.accumulator);
                    break :blk .defined;
                },
                2 => blk: {
                    self.accumulator = @truncate(@as(u32, @bitCast(@as(i32, @as(i16, @bitCast(@as(u16, @truncate(self.accumulator))))))));
                    self.setNz(self.accumulator);
                    break :blk .defined;
                },
                else => .reserved_nop,
            },
            0x5c => .reserved_nop,
            0x60 => blk: {
                switch (mode) {
                    0 => self.accumulator = self.sourceValue(source),
                    1 => self.memory_data = self.sourceValue(source),
                    2 => self.memory_address = self.sourceValue(source),
                    else => self.page = @truncate(self.gpr[operand & 0x0f]),
                }
                break :blk .defined;
            },
            0x64 => blk: {
                switch (mode) {
                    0 => self.accumulator = operand,
                    1 => self.memory_data = operand,
                    2 => self.memory_address = operand,
                    else => self.page = operand,
                }
                break :blk .defined;
            },
            0x68 => if (mode < 3) blk: {
                self.readDataRamByte(mode, @truncate(self.accumulator));
                break :blk .defined;
            } else .reserved_nop,
            0x6c => if (mode < 3) blk: {
                self.readDataRamByte(mode, @truncate(self.data_pointer +% operand));
                break :blk .defined;
            } else .reserved_nop,
            0x70 => blk: {
                self.rom_buffer = dataRomWord(@truncate(self.accumulator));
                break :blk .defined;
            },
            0x74 => blk: {
                const index: u10 = (@as(u10, mode) << 8) | operand;
                self.rom_buffer = dataRomWord(index);
                break :blk .defined;
            },
            0x78 => .reserved_nop,
            0x7c => switch (mode) {
                0 => blk: {
                    self.page = (self.page & 0x7f00) | operand;
                    break :blk .defined;
                },
                1 => blk: {
                    self.page = (self.page & 0x00ff) | (@as(u15, operand & 0x7f) << 8);
                    break :blk .defined;
                },
                else => .reserved_nop,
            },
            0x80 => blk: {
                self.accumulator = self.add(self.shiftedAccumulator(shift), self.sourceValue(source));
                break :blk .defined;
            },
            0x84 => blk: {
                self.accumulator = self.add(self.shiftedAccumulator(shift), operand);
                break :blk .defined;
            },
            0x88 => blk: {
                self.accumulator = self.subtract(self.sourceValue(source), self.shiftedAccumulator(shift));
                break :blk .defined;
            },
            0x8c => blk: {
                self.accumulator = self.subtract(operand, self.shiftedAccumulator(shift));
                break :blk .defined;
            },
            0x90 => blk: {
                self.accumulator = self.subtract(self.shiftedAccumulator(shift), self.sourceValue(source));
                break :blk .defined;
            },
            0x94 => blk: {
                self.accumulator = self.subtract(self.shiftedAccumulator(shift), operand);
                break :blk .defined;
            },
            0x98 => blk: {
                self.multiply(self.sourceValue(source));
                break :blk .defined;
            },
            0x9c => blk: {
                self.multiply(operand);
                break :blk .defined;
            },
            0xa0 => blk: {
                self.accumulator = @truncate((~self.shiftedAccumulator(shift) ^ self.sourceValue(source)) & value_mask);
                self.setNz(self.accumulator);
                break :blk .defined;
            },
            0xa4 => blk: {
                self.accumulator = @truncate((~self.shiftedAccumulator(shift) ^ operand) & value_mask);
                self.setNz(self.accumulator);
                break :blk .defined;
            },
            0xa8 => blk: {
                self.accumulator = self.shiftedAccumulator(shift) ^ self.sourceValue(source);
                self.setNz(self.accumulator);
                break :blk .defined;
            },
            0xac => blk: {
                self.accumulator = self.shiftedAccumulator(shift) ^ operand;
                self.setNz(self.accumulator);
                break :blk .defined;
            },
            0xb0 => blk: {
                self.accumulator = self.shiftedAccumulator(shift) & self.sourceValue(source);
                self.setNz(self.accumulator);
                break :blk .defined;
            },
            0xb4 => blk: {
                self.accumulator = self.shiftedAccumulator(shift) & operand;
                self.setNz(self.accumulator);
                break :blk .defined;
            },
            0xb8 => blk: {
                self.accumulator = self.shiftedAccumulator(shift) | self.sourceValue(source);
                self.setNz(self.accumulator);
                break :blk .defined;
            },
            0xbc => blk: {
                self.accumulator = self.shiftedAccumulator(shift) | operand;
                self.setNz(self.accumulator);
                break :blk .defined;
            },
            0xc0 => blk: {
                self.shiftRight(@truncate(self.sourceValue(source)));
                break :blk .defined;
            },
            0xc4 => blk: {
                self.shiftRight(@truncate(operand));
                break :blk .defined;
            },
            0xc8 => blk: {
                self.shiftArithmetic(@truncate(self.sourceValue(source)));
                break :blk .defined;
            },
            0xcc => blk: {
                self.shiftArithmetic(@truncate(operand));
                break :blk .defined;
            },
            0xd0 => blk: {
                self.rotateRight(@truncate(self.sourceValue(source)));
                break :blk .defined;
            },
            0xd4 => blk: {
                self.rotateRight(@truncate(operand));
                break :blk .defined;
            },
            0xd8 => blk: {
                self.shiftLeft(@truncate(self.sourceValue(source)));
                break :blk .defined;
            },
            0xdc => blk: {
                self.shiftLeft(@truncate(operand));
                break :blk .defined;
            },
            0xe0 => switch (mode) {
                0 => blk: {
                    self.writeRegister(source, self.accumulator);
                    break :blk .defined;
                },
                1 => blk: {
                    self.writeRegister(source, self.memory_data);
                    break :blk .defined;
                },
                else => .reserved_nop,
            },
            0xe4 => .reserved_nop,
            0xe8 => if (mode < 3) blk: {
                self.writeDataRamByte(mode, @truncate(self.accumulator));
                break :blk .defined;
            } else .reserved_nop,
            0xec => if (mode < 3) blk: {
                self.writeDataRamByte(mode, @truncate(self.data_pointer +% operand));
                break :blk .defined;
            } else .reserved_nop,
            0xf0 => blk: {
                const register = operand & 0x0f;
                const temporary = self.accumulator;
                self.accumulator = self.gpr[register];
                self.gpr[register] = temporary;
                break :blk .defined;
            },
            0xf4 => .reserved_nop,
            0xf8 => blk: {
                self.accumulator = 0;
                self.page = 0;
                self.ram_buffer = 0;
                self.data_pointer = 0;
                break :blk .defined;
            },
            0xfc => blk: {
                self.halt();
                break :blk .defined;
            },
            else => unreachable,
        };

        if (class == .reserved_nop) {
            self.reserved_opcodes +%= 1;
            self.last_reserved_opcode = opcode;
        }
        return class;
    }

    pub fn stateDigest(self: *const Device) u64 {
        var digest: u64 = 0xcbf29ce484222325;
        for (self.program_ram) |page_words| for (page_words) |word| digestValue(&digest, word);
        for (self.data_ram) |value| digestByte(&digest, value);
        digestValue(&digest, self.pb);
        digestValue(&digest, self.pc);
        digestBool(&digest, self.negative);
        digestBool(&digest, self.zero);
        digestBool(&digest, self.carry);
        digestBool(&digest, self.overflow);
        digestValue(&digest, self.accumulator);
        digestValue(&digest, self.page);
        digestValue(&digest, self.multiplier);
        digestValue(&digest, self.memory_data);
        digestValue(&digest, self.rom_buffer);
        digestValue(&digest, self.ram_buffer);
        digestValue(&digest, self.memory_address);
        digestValue(&digest, self.data_pointer);
        for (self.gpr) |value| digestValue(&digest, value);
        for (self.stack) |value| digestValue(&digest, value);
        digestBool(&digest, self.locked);
        digestBool(&digest, self.stopped);
        digestBool(&digest, self.irq_disabled);
        digestBool(&digest, self.irq_flag);
        digestBool(&digest, self.irq_line);
        digestBool(&digest, self.single_rom);
        digestValue(&digest, self.rom_wait);
        digestValue(&digest, self.ram_wait);
        for (self.vectors) |value| digestByte(&digest, value);
        digestBool(&digest, self.suspend_enabled);
        digestValue(&digest, self.suspend_duration);
        digestBool(&digest, self.cache_enabled);
        digestBool(&digest, self.cache_prepared);
        digestValue(&digest, self.cache_page);
        for (self.cache_lock) |value| digestBool(&digest, value);
        for (self.cache_valid) |value| digestBool(&digest, value);
        for (self.cache_address) |value| digestValue(&digest, value);
        digestValue(&digest, self.cache_base);
        digestValue(&digest, self.cache_program_bank);
        digestValue(&digest, self.cache_program_counter);
        digestValue(&digest, self.cache_position);
        digestBool(&digest, self.dma_enabled);
        digestValue(&digest, self.dma_source);
        digestValue(&digest, self.dma_target);
        digestValue(&digest, self.dma_length);
        digestValue(&digest, self.dma_position);
        digestByte(&digest, @intFromEnum(self.dma_phase));
        digestByte(&digest, self.dma_latch);
        digestBool(&digest, self.bus_enabled);
        digestBool(&digest, self.bus_reading);
        digestBool(&digest, self.bus_writing);
        digestValue(&digest, self.bus_pending);
        digestValue(&digest, self.bus_address);
        digestByte(&digest, @intFromEnum(self.operation));
        digestValue(&digest, self.operation_wait);
        digestValue(&digest, self.operation_address);
        digestValue(&digest, self.operation_value);
        digestValue(&digest, self.stall_cycles);
        digestValue(&digest, self.cycle_count);
        digestValue(&digest, self.instruction_count);
        digestValue(&digest, self.dma_bytes);
        digestValue(&digest, self.cache_bytes);
        digestValue(&digest, self.bus_conflicts);
        digestValue(&digest, self.reserved_opcodes);
        digestValue(&digest, self.last_reserved_opcode);
        digestByte(&digest, if (self.last_fault) |fault| 1 + @as(u8, @intFromEnum(fault)) else 0);
        return digest;
    }

    fn tick(self: *Device, rom: []const u8, save_ram: []u8) void {
        self.advanceBus(rom, save_ram);
        self.cycle_count +%= 1;

        if (self.stall_cycles != 0) {
            self.stall_cycles -= 1;
            return;
        }
        if (self.locked) return;
        if (self.suspend_enabled) {
            if (self.suspend_duration != 0) {
                self.suspend_duration -= 1;
                if (self.suspend_duration == 0) self.suspend_enabled = false;
            }
            return;
        }
        if (self.cache_enabled) {
            self.tickCache(rom, save_ram);
            return;
        }
        if (self.dma_enabled) {
            self.tickDma(rom, save_ram);
            return;
        }
        if (self.stopped) return;
        if (!self.ensureCache()) {
            if (!self.cache_enabled) self.halt();
            return;
        }

        const opcode = self.program_ram[self.cache_page][self.pc];
        self.advanceProgramCounter();
        _ = self.executeDecoded(opcode);
        self.instruction_count +%= 1;
    }

    fn tickCache(self: *Device, rom: []const u8, save_ram: []u8) void {
        if (self.operation == .cache_read) {
            self.advanceOperation(rom, save_ram);
            return;
        }
        if (!self.cache_prepared) {
            if (!self.prepareCache()) return;
        }
        if (self.cache_position >= program_words * 2) {
            self.cache_enabled = false;
            self.cache_prepared = false;
            return;
        }
        const address: u24 = @truncate(self.cache_address[self.cache_page] +% self.cache_position);
        self.startOperation(.cache_read, address, 0, waitForAddress(address, rom.len, save_ram.len, self.rom_wait, self.ram_wait));
        self.advanceOperation(rom, save_ram);
    }

    fn tickDma(self: *Device, rom: []const u8, save_ram: []u8) void {
        if (self.operation == .dma_read or self.operation == .dma_write) {
            self.advanceOperation(rom, save_ram);
            return;
        }
        if (self.dma_position >= self.dma_length) {
            self.dma_enabled = false;
            self.dma_position = 0;
            self.dma_phase = .source;
            return;
        }

        const source: u24 = self.dma_source +% self.dma_position;
        const target: u24 = self.dma_target +% self.dma_position;
        const source_resource = resourceForAddress(source, rom.len, save_ram.len);
        const target_resource = resourceForAddress(target, rom.len, save_ram.len);
        if (source_resource == .none or target_resource == .none or target_resource == .rom or source_resource == target_resource) {
            self.dma_enabled = false;
            self.dma_position = 0;
            self.locked = true;
            self.stopped = true;
            self.last_fault = .invalid_dma;
            return;
        }

        switch (self.dma_phase) {
            .source => self.startOperation(.dma_read, source, 0, waitForResource(source_resource, self.rom_wait, self.ram_wait)),
            .target => self.startOperation(.dma_write, target, self.dma_latch, waitForResource(target_resource, self.rom_wait, self.ram_wait)),
        }
        self.advanceOperation(rom, save_ram);
    }

    fn startOperation(self: *Device, operation: Operation, address: u24, value: u8, wait_cycles: u8) void {
        self.operation = operation;
        self.operation_address = address;
        self.operation_value = value;
        self.operation_wait = @max(wait_cycles, 1);
    }

    fn advanceOperation(self: *Device, rom: []const u8, save_ram: []u8) void {
        if (self.operation == .none) return;
        self.operation_wait -= 1;
        if (self.operation_wait != 0) return;
        const operation = self.operation;
        self.operation = .none;
        switch (operation) {
            .cache_read => {
                const value = self.readInternal(rom, save_ram, self.operation_address);
                const word = self.cache_position >> 1;
                if ((self.cache_position & 1) == 0) {
                    self.program_ram[self.cache_page][word] = value;
                } else {
                    self.program_ram[self.cache_page][word] |= @as(u16, value) << 8;
                }
                self.cache_position += 1;
                self.cache_bytes +%= 1;
                if (self.cache_position >= program_words * 2) {
                    self.cache_enabled = false;
                    self.cache_prepared = false;
                }
            },
            .dma_read => {
                self.dma_latch = self.readInternal(rom, save_ram, self.operation_address);
                self.dma_phase = .target;
            },
            .dma_write => {
                self.writeInternal(rom, save_ram, self.operation_address, self.operation_value);
                self.dma_position +%= 1;
                self.dma_bytes +%= 1;
                self.dma_phase = .source;
                if (self.dma_position >= self.dma_length) {
                    self.dma_enabled = false;
                    self.dma_position = 0;
                }
            },
            .none => {},
        }
    }

    fn prepareCache(self: *Device) bool {
        const address: u24 = @truncate(self.cache_base +% (@as(u24, self.pb) << 9));
        if (self.cache_valid[self.cache_page] and self.cache_address[self.cache_page] == address) {
            self.cache_enabled = false;
            self.cache_prepared = false;
            return false;
        }

        self.cache_page ^= 1;
        if (self.cache_valid[self.cache_page] and self.cache_address[self.cache_page] == address) {
            self.cache_enabled = false;
            self.cache_prepared = false;
            return false;
        }
        if (self.cache_lock[self.cache_page]) self.cache_page ^= 1;
        if (self.cache_lock[self.cache_page]) {
            self.cache_enabled = false;
            self.cache_prepared = false;
            self.stopped = true;
            self.last_fault = .cache_locked;
            return false;
        }

        self.cache_address[self.cache_page] = address;
        self.cache_valid[self.cache_page] = true;
        self.cache_position = 0;
        self.cache_prepared = true;
        return true;
    }

    fn ensureCache(self: *Device) bool {
        const address: u24 = @truncate(self.cache_base +% (@as(u24, self.pb) << 9));
        if (self.cache_valid[self.cache_page] and self.cache_address[self.cache_page] == address) return true;
        self.cache_enabled = true;
        self.cache_prepared = false;
        return false;
    }

    fn advanceProgramCounter(self: *Device) void {
        self.pc +%= 1;
        if (self.pc != 0) return;
        if (self.cache_page == 1) {
            self.halt();
            return;
        }
        self.cache_page = 1;
        if (self.cache_lock[1]) {
            self.halt();
            return;
        }
        self.pb = self.page;
        if (!self.ensureCache() and !self.cache_enabled) self.halt();
    }

    fn advanceBus(self: *Device, rom: []const u8, save_ram: []u8) void {
        if (!self.bus_enabled) return;
        if (self.bus_pending != 0) self.bus_pending -= 1;
        if (self.bus_pending != 0) return;
        self.bus_enabled = false;
        if (self.bus_reading) self.memory_data = self.readInternal(rom, save_ram, self.bus_address);
        if (self.bus_writing) self.writeInternal(rom, save_ram, self.bus_address, @truncate(self.memory_data));
        self.bus_reading = false;
        self.bus_writing = false;
    }

    fn runState(self: *const Device) RunState {
        if (self.locked) return .locked;
        if (self.suspend_enabled) return .suspended;
        if (self.cache_enabled) return .cache;
        if (self.dma_enabled) return .dma;
        if (self.stopped) return .halted;
        return .running;
    }

    fn resourceBusy(self: *const Device, resource: Resource) bool {
        if (resource == .none or resource == .data_ram or resource == .io) return false;
        if (self.cache_enabled and resource == .rom) return true;
        if (self.dma_enabled and self.operation == .none) {
            const address = if (self.dma_phase == .source)
                self.dma_source +% self.dma_position
            else
                self.dma_target +% self.dma_position;
            if (resourceForAddress(address, maximum_rom_bytes, 256 * 1024) == resource) return true;
        }
        if (self.operation != .none and resourceForOperation(self) == resource) return true;
        if (self.bus_enabled and resourceForAddress(self.bus_address, maximum_rom_bytes, 256 * 1024) == resource) return true;
        return false;
    }

    fn readInternal(self: *Device, rom: []const u8, save_ram: []const u8, raw_address: u32) u8 {
        const address = raw_address & address_mask;
        if (board.decodeCx4RomIndex(address, rom.len)) |index| return rom[index];
        if (board.decodeCx4SramIndex(address, save_ram.len)) |index| return save_ram[index];
        if (dataRamIndex(address)) |index| return self.data_ram[index];
        if (ioAddress(address)) |io| return self.readIo(io);
        return 0;
    }

    fn writeInternal(self: *Device, rom: []const u8, save_ram: []u8, raw_address: u32, value: u8) void {
        const address = raw_address & address_mask;
        if (board.decodeCx4RomIndex(address, rom.len) != null) return;
        if (board.decodeCx4SramIndex(address, save_ram.len)) |index| {
            save_ram[index] = value;
            return;
        }
        if (dataRamIndex(address)) |index| {
            self.data_ram[index] = value;
            return;
        }
        if (ioAddress(address)) |io| self.writeIo(io, value);
    }

    fn readIo(self: *Device, address: u16) u8 {
        if (address >= 0x7f60 and address <= 0x7f7f) return self.vectors[address & 0x1f];
        if ((address >= 0x7f80 and address <= 0x7faf) or (address >= 0x7fc0 and address <= 0x7fef)) {
            const relative = address & 0x3f;
            const value = self.gpr[relative / 3];
            return @truncate(value >> @intCast((relative % 3) * 8));
        }
        if (address >= 0x7f53 and address <= 0x7f5f) {
            return @as(u8, @intFromBool(self.suspend_enabled)) |
                (@as(u8, @intFromBool(self.irq_flag)) << 1) |
                (@as(u8, @intFromBool(self.running())) << 6) |
                (@as(u8, @intFromBool(self.busy())) << 7);
        }
        return switch (address) {
            0x7f40 => @truncate(self.dma_source),
            0x7f41 => @truncate(self.dma_source >> 8),
            0x7f42 => @truncate(self.dma_source >> 16),
            0x7f43 => @truncate(self.dma_length),
            0x7f44 => @truncate(self.dma_length >> 8),
            0x7f45 => @truncate(self.dma_target),
            0x7f46 => @truncate(self.dma_target >> 8),
            0x7f47 => @truncate(self.dma_target >> 16),
            0x7f48 => self.cache_page,
            0x7f49 => @truncate(self.cache_base),
            0x7f4a => @truncate(self.cache_base >> 8),
            0x7f4b => @truncate(self.cache_base >> 16),
            0x7f4c => @as(u8, @intFromBool(self.cache_lock[0])) | (@as(u8, @intFromBool(self.cache_lock[1])) << 1),
            0x7f4d => @truncate(self.cache_program_bank),
            0x7f4e => @truncate(self.cache_program_bank >> 8),
            0x7f4f => self.cache_program_counter,
            0x7f50 => @as(u8, self.ram_wait) | (@as(u8, self.rom_wait) << 4),
            0x7f51 => @intFromBool(self.irq_disabled),
            0x7f52 => @intFromBool(self.single_rom),
            else => 0,
        };
    }

    fn writeIo(self: *Device, address: u16, value: u8) void {
        if (address >= 0x7f60 and address <= 0x7f7f) {
            self.vectors[address & 0x1f] = value;
            return;
        }
        if ((address >= 0x7f80 and address <= 0x7faf) or (address >= 0x7fc0 and address <= 0x7fef)) {
            const relative = address & 0x3f;
            const register = relative / 3;
            const shift: u5 = @intCast((relative % 3) * 8);
            const mask: u24 = ~(@as(u24, 0xff) << shift);
            self.gpr[register] = (self.gpr[register] & mask) | (@as(u24, value) << shift);
            return;
        }
        if (address >= 0x7f55 and address <= 0x7f5c) {
            self.suspend_enabled = true;
            self.suspend_duration = @intCast((address - 0x7f55) * 32);
            return;
        }
        switch (address) {
            0x7f40 => self.dma_source = (self.dma_source & 0xffff00) | value,
            0x7f41 => self.dma_source = (self.dma_source & 0xff00ff) | (@as(u24, value) << 8),
            0x7f42 => self.dma_source = (self.dma_source & 0x00ffff) | (@as(u24, value) << 16),
            0x7f43 => self.dma_length = (self.dma_length & 0xff00) | value,
            0x7f44 => self.dma_length = (self.dma_length & 0x00ff) | (@as(u16, value) << 8),
            0x7f45 => self.dma_target = (self.dma_target & 0xffff00) | value,
            0x7f46 => self.dma_target = (self.dma_target & 0xff00ff) | (@as(u24, value) << 8),
            0x7f47 => {
                self.dma_target = (self.dma_target & 0x00ffff) | (@as(u24, value) << 16);
                if (self.stopped) {
                    self.dma_enabled = true;
                    self.dma_position = 0;
                    self.dma_phase = .source;
                    self.last_fault = null;
                }
            },
            0x7f48 => {
                self.cache_page = @truncate(value);
                if (self.stopped) {
                    self.cache_enabled = true;
                    self.cache_prepared = false;
                    self.cache_position = 0;
                    self.last_fault = null;
                }
            },
            0x7f49 => self.cache_base = (self.cache_base & 0xffff00) | value,
            0x7f4a => self.cache_base = (self.cache_base & 0xff00ff) | (@as(u24, value) << 8),
            0x7f4b => self.cache_base = (self.cache_base & 0x00ffff) | (@as(u24, value) << 16),
            0x7f4c => {
                self.cache_lock[0] = (value & 1) != 0;
                self.cache_lock[1] = (value & 2) != 0;
            },
            0x7f4d => self.cache_program_bank = (self.cache_program_bank & 0x7f00) | value,
            0x7f4e => self.cache_program_bank = (self.cache_program_bank & 0x00ff) | (@as(u15, value & 0x7f) << 8),
            0x7f4f => {
                self.cache_program_counter = value;
                if (self.stopped) {
                    self.stopped = false;
                    self.pb = self.cache_program_bank;
                    self.pc = value;
                    self.last_fault = null;
                }
            },
            0x7f50 => {
                self.ram_wait = @truncate(value);
                self.rom_wait = @truncate(value >> 4);
            },
            0x7f51 => {
                self.irq_disabled = (value & 1) != 0;
                if (self.irq_disabled) self.irq_line = false;
            },
            0x7f52 => self.single_rom = (value & 1) != 0,
            0x7f53 => {
                self.locked = false;
                self.stopped = true;
                self.last_fault = null;
            },
            0x7f5d => self.suspend_enabled = false,
            0x7f5e => self.irq_flag = false,
            else => {},
        }
    }

    fn sourceValue(self: *Device, register: u7) u24 {
        return switch (register) {
            0x00 => self.accumulator,
            0x01 => @truncate(self.multiplier >> 24),
            0x02 => @truncate(self.multiplier),
            0x03 => self.memory_data,
            0x08 => self.rom_buffer,
            0x0c => self.ram_buffer,
            0x13 => self.memory_address,
            0x1c => self.data_pointer,
            0x20 => self.pc,
            0x28 => self.page,
            0x2e => blk: {
                self.scheduleBus(true, false, 1 + @as(u4, self.rom_wait));
                break :blk 0;
            },
            0x2f => blk: {
                self.scheduleBus(true, false, 1 + @as(u4, self.ram_wait));
                break :blk 0;
            },
            0x50 => 0x000000,
            0x51 => 0xffffff,
            0x52 => 0x00ff00,
            0x53 => 0xff0000,
            0x54 => 0x00ffff,
            0x55 => 0xffff00,
            0x56 => 0x800000,
            0x57 => 0x7fffff,
            0x58 => 0x008000,
            0x59 => 0x007fff,
            0x5a => 0xff7fff,
            0x5b => 0xffff7f,
            0x5c => 0x010000,
            0x5d => 0xfeffff,
            0x5e => 0x000100,
            0x5f => 0x00feff,
            0x60...0x6f => self.gpr[register & 0x0f],
            0x70...0x7f => self.gpr[register & 0x0f],
            else => 0,
        };
    }

    fn writeRegister(self: *Device, register: u7, value: u24) void {
        switch (register) {
            0x01 => self.multiplier = (self.multiplier & 0x000000ffffff) | (@as(u48, value) << 24),
            0x02 => self.multiplier = (self.multiplier & 0xffffff000000) | value,
            0x03 => self.memory_data = value,
            0x08 => self.rom_buffer = value,
            0x0c => self.ram_buffer = value,
            0x13 => self.memory_address = value,
            0x1c => self.data_pointer = value,
            0x20 => self.pc = @truncate(value),
            0x28 => self.page = @truncate(value),
            0x2e => self.scheduleBus(false, true, 1 + @as(u4, self.rom_wait)),
            0x2f => self.scheduleBus(false, true, 1 + @as(u4, self.ram_wait)),
            0x60...0x6f => self.gpr[register & 0x0f] = value,
            0x70...0x7f => self.gpr[register & 0x0f] = value,
            else => {},
        }
    }

    fn scheduleBus(self: *Device, reading: bool, writing: bool, pending: u4) void {
        self.bus_enabled = true;
        self.bus_reading = reading;
        self.bus_writing = writing;
        self.bus_pending = pending;
        self.bus_address = self.memory_address;
    }

    fn branch(self: *Device, take: bool, operation: u8, target: u8) void {
        if (!take) return;
        if ((operation & 2) != 0) self.pb = self.page;
        self.pc = target;
        self.stall_cycles +|= 2;
    }

    fn call(self: *Device, take: bool, operation: u8, target: u8) void {
        if (!take) return;
        self.push();
        if ((operation & 2) != 0) self.pb = self.page;
        self.pc = target;
        self.stall_cycles +|= 2;
    }

    fn push(self: *Device) void {
        var index: usize = self.stack.len - 1;
        while (index != 0) : (index -= 1) self.stack[index] = self.stack[index - 1];
        self.stack[0] = (@as(u23, self.pb) << 8) | self.pc;
    }

    fn pull(self: *Device) void {
        const value = self.stack[0];
        var index: usize = 0;
        while (index + 1 < self.stack.len) : (index += 1) self.stack[index] = self.stack[index + 1];
        self.stack[self.stack.len - 1] = 0;
        self.pb = @truncate(value >> 8);
        self.pc = @truncate(value);
    }

    fn halt(self: *Device) void {
        self.stopped = true;
        if (!self.irq_disabled) {
            self.irq_flag = true;
            self.irq_line = true;
        }
    }

    fn add(self: *Device, raw_left: anytype, raw_right: anytype) u24 {
        const left: u32 = @as(u32, @intCast(raw_left)) & value_mask;
        const right: u32 = @as(u32, @intCast(raw_right)) & value_mask;
        const wide: u64 = @as(u64, left) + right;
        const result: u32 = @truncate(wide & value_mask);
        self.negative = (result & sign_bit) != 0;
        self.zero = result == 0;
        self.carry = wide > value_mask;
        self.overflow = ((~(left ^ right) & (left ^ result) & sign_bit) != 0);
        return @truncate(result);
    }

    fn subtract(self: *Device, raw_left: anytype, raw_right: anytype) u24 {
        const left: u32 = @as(u32, @intCast(raw_left)) & value_mask;
        const right: u32 = @as(u32, @intCast(raw_right)) & value_mask;
        const result: u32 = (left -% right) & value_mask;
        self.negative = (result & sign_bit) != 0;
        self.zero = result == 0;
        self.carry = left >= right;
        self.overflow = ((~(left ^ right) & (left ^ result) & sign_bit) != 0);
        return @truncate(result);
    }

    fn multiply(self: *Device, right: u24) void {
        const product: i64 = @as(i64, signed24(self.accumulator)) * @as(i64, signed24(right));
        self.multiplier = @truncate(@as(u64, @bitCast(product)));
    }

    fn shiftedAccumulator(self: *const Device, shift: u5) u24 {
        return @truncate((@as(u64, self.accumulator) << shift) & value_mask);
    }

    fn shiftRight(self: *Device, raw_shift: u5) void {
        const shift = normalizedShift(raw_shift);
        self.accumulator = if (shift == 0) self.accumulator else if (shift == 24) 0 else self.accumulator >> shift;
        self.setNz(self.accumulator);
    }

    fn shiftArithmetic(self: *Device, raw_shift: u5) void {
        const shift = normalizedShift(raw_shift);
        if (shift != 0) {
            const value = signed24(self.accumulator) >> @intCast(shift);
            self.accumulator = @truncate(@as(u32, @bitCast(value)));
        }
        self.setNz(self.accumulator);
    }

    fn shiftLeft(self: *Device, raw_shift: u5) void {
        const shift = normalizedShift(raw_shift);
        self.accumulator = if (shift == 0) self.accumulator else if (shift == 24) 0 else @truncate(@as(u64, self.accumulator) << shift);
        self.setNz(self.accumulator);
    }

    fn rotateRight(self: *Device, raw_shift: u5) void {
        const shift = normalizedShift(raw_shift);
        if (shift != 0 and shift != 24) {
            const value: u32 = self.accumulator;
            self.accumulator = @truncate((value >> shift) | ((value << @intCast(24 - shift)) & value_mask));
        }
        self.setNz(self.accumulator);
    }

    fn setNz(self: *Device, value: u24) void {
        self.negative = (value & sign_bit) != 0;
        self.zero = value == 0;
    }

    fn readDataRamByte(self: *Device, byte: u2, raw_address: u12) void {
        const address = dataRamMirror(raw_address);
        const shift: u5 = @as(u5, byte) * 8;
        const mask: u24 = ~(@as(u24, 0xff) << shift);
        self.ram_buffer = (self.ram_buffer & mask) | (@as(u24, self.data_ram[address]) << shift);
    }

    fn writeDataRamByte(self: *Device, byte: u2, raw_address: u12) void {
        const address = dataRamMirror(raw_address);
        self.data_ram[address] = @truncate(self.ram_buffer >> (@as(u5, byte) * 8));
    }
};

pub fn validateGeometry(rom_bytes: usize, save_ram_bytes: usize) !void {
    if (rom_bytes < 32 * 1024 or rom_bytes > maximum_rom_bytes or (rom_bytes % (32 * 1024)) != 0)
        return error.InvalidCx4RomGeometry;
    if (save_ram_bytes != 0) return error.InvalidCx4SaveRamGeometry;
}

pub fn dataRomWord(raw_index: u10) u24 {
    const index: usize = raw_index;
    if (index < 256) {
        if (index == 0) return 0xffffff;
        return @intCast(0x800000 / index);
    }
    if (index < 512) {
        const radicand: u64 = @as(u64, index - 256) << 40;
        return @truncate(integerSqrt(radicand));
    }
    if (index < 640) return sineWord(index - 512);
    if (index < 768) return arcsineWord(index - 640);
    if (index < 896) return tangentWord(index - 768);
    return sineWord(index - 768);
}

fn resourceForOperation(self: *const Device) Resource {
    return switch (self.operation) {
        .cache_read => .rom,
        .dma_read, .dma_write => resourceForAddress(self.operation_address, maximum_rom_bytes, 256 * 1024),
        .none => .none,
    };
}

fn resourceForAddress(address: u32, rom_bytes: usize, save_ram_bytes: usize) Resource {
    if (board.decodeCx4RomIndex(address, rom_bytes) != null) return .rom;
    if (board.decodeCx4SramIndex(address, save_ram_bytes) != null) return .save_ram;
    if (dataRamIndex(address) != null) return .data_ram;
    if (ioAddress(address) != null) return .io;
    return .none;
}

fn waitForAddress(address: u32, rom_bytes: usize, save_ram_bytes: usize, rom_wait: u3, ram_wait: u3) u8 {
    return waitForResource(resourceForAddress(address, rom_bytes, save_ram_bytes), rom_wait, ram_wait);
}

fn waitForResource(resource: Resource, rom_wait: u3, ram_wait: u3) u8 {
    return switch (resource) {
        .rom => 1 + @as(u8, rom_wait),
        .save_ram => 1 + @as(u8, ram_wait),
        else => 1,
    };
}

fn dataRamIndex(address: u32) ?usize {
    const bank: u8 = @truncate(address >> 16);
    const offset: u16 = @truncate(address);
    if (!systemBank(bank)) return null;
    if ((offset >= 0x6000 and offset <= 0x6bff) or (offset >= 0x7000 and offset <= 0x7bff))
        return offset & 0x0fff;
    return null;
}

fn ioAddress(address: u32) ?u16 {
    const bank: u8 = @truncate(address >> 16);
    const offset: u16 = @truncate(address);
    if (!systemBank(bank)) return null;
    if ((offset >= 0x6c00 and offset <= 0x6fff) or (offset >= 0x7c00 and offset <= 0x7fff))
        return 0x7c00 | (offset & 0x03ff);
    return null;
}

fn cpuVectorIo(address: u32) ?u16 {
    const bank: u8 = @truncate(address >> 16);
    const offset: u16 = @truncate(address);
    if (systemBank(bank) and offset >= 0xffc0) return 0x7f40 | (offset & 0x3f);
    return null;
}

fn systemBank(bank: u8) bool {
    return bank <= 0x3f or (bank >= 0x80 and bank <= 0xbf);
}

fn dataRamMirror(address: u12) usize {
    return if (address >= 0x0c00) @as(usize, address - 0x0400) else address;
}

fn shiftForCode(code: u2) u5 {
    return switch (code) {
        0 => 0,
        1 => 1,
        2 => 8,
        3 => 16,
    };
}

fn normalizedShift(value: u5) u5 {
    return if (value > 24) 0 else value;
}

fn signed24(value: u24) i32 {
    const extended: u32 = if ((value & sign_bit) != 0) @as(u32, value) | 0xff00_0000 else value;
    return @bitCast(extended);
}

fn integerSqrt(value: u64) u64 {
    var remainder = value;
    var result: u64 = 0;
    var bit: u64 = @as(u64, 1) << 62;
    while (bit > remainder) bit >>= 2;
    while (bit != 0) : (bit >>= 2) {
        if (remainder >= result + bit) {
            remainder -= result + bit;
            result = (result >> 1) + bit;
        } else {
            result >>= 1;
        }
    }
    return result;
}

const fixed_shift = 56;
const fixed_one: i128 = @as(i128, 1) << fixed_shift;
const pi_fixed: i128 = 0x3243f6a8885a300;
const half_pi_fixed: i128 = pi_fixed / 2;

fn fixedMultiply(left: i128, right: i128) i128 {
    return (left * right) >> fixed_shift;
}

fn sineFixed(raw_angle: i128) i128 {
    var angle = raw_angle;
    if (angle > half_pi_fixed) angle = pi_fixed - angle;
    const square = fixedMultiply(angle, angle);
    var term = angle;
    var result = angle;
    var subtract = true;
    var order: i128 = 1;
    while (order < 14) : (order += 1) {
        term = @divTrunc(fixedMultiply(term, square), (2 * order) * (2 * order + 1));
        if (subtract) result -= term else result += term;
        subtract = !subtract;
    }
    return result;
}

fn sineWord(raw_index: usize) u24 {
    const angle = @divTrunc(pi_fixed * @as(i128, @intCast(raw_index)), 256);
    const value = @divTrunc(sineFixed(angle) << 24, fixed_one);
    return @intCast(@min(value, 0xffffff));
}

fn arcsineWord(raw_index: usize) u24 {
    const target = @divTrunc(@as(i128, @intCast(raw_index)) * fixed_one, 128);
    var low: i128 = 0;
    var high: i128 = half_pi_fixed;
    var iteration: usize = 0;
    while (iteration < fixed_shift + 3) : (iteration += 1) {
        const middle = @divTrunc(low + high + 1, 2);
        if (sineFixed(middle) <= target) low = middle else high = middle - 1;
    }
    return @intCast(@divTrunc(low << 24, pi_fixed));
}

fn tangentWord(raw_index: usize) u24 {
    const sine = sineFixed(@divTrunc(pi_fixed * @as(i128, @intCast(raw_index)), 256));
    const cosine = sineFixed(@divTrunc(pi_fixed * @as(i128, @intCast(128 - raw_index)), 256));
    return @intCast(@divTrunc(sine << 16, cosine));
}

fn digestByte(digest: *u64, value: u8) void {
    digest.* = (digest.* ^ value) *% 0x100000001b3;
}

fn digestBool(digest: *u64, value: bool) void {
    digestByte(digest, @intFromBool(value));
}

fn digestValue(digest: *u64, value: anytype) void {
    const T = @TypeOf(value);
    const bytes = (@bitSizeOf(T) + 7) / 8;
    inline for (0..bytes) |index| digestByte(digest, @truncate(value >> @intCast(index * 8)));
}
