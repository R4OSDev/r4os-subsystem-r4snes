const cpu_mod = @import("cpu.zig");

pub const access_master_cycles: u8 = 6;
pub const internal_ram_bytes: usize = 2 * 1024;
pub const maximum_bwram_bytes: usize = 256 * 1024;
pub const maximum_rom_bytes: usize = 8 * 1024 * 1024;

const address_mask: u32 = 0x00ff_ffff;
const result_mask: u64 = (@as(u64, 1) << 40) - 1;

pub const Region = enum { ntsc, pal };

pub const RunState = enum {
    executed,
    reset,
    waiting,
    stopped,
    held,
    budget,
    fault,
};

pub const RunResult = struct {
    state: RunState,
    instructions: usize,
    master_cycles: u64,
    fault: ?cpu_mod.CpuError = null,
};

pub const DirtyRange = struct {
    first: usize,
    end: usize,
};

pub const WriteResult = struct {
    handled: bool = false,
    changed: bool = false,
    first: usize = 0,
    end: usize = 0,
};

const Resource = enum { none, rom, bwram, iram, io };

const MemoryAccess = struct {
    value: u8,
    clocks: u8,
    resource: Resource,
};

const PortAccess = struct {
    value: u8,
    master_cycles: u8,
};

pub const Device = struct {
    cpu: cpu_mod.Cpu = .{},
    iram: [internal_ram_bytes]u8 = .{0} ** internal_ram_bytes,
    region: Region = .ntsc,
    master_cycles: u64 = 0,
    timer_phase: u1 = 0,
    sa1_open_bus: u8 = 0,
    cpu_open_bus: u8 = 0,

    reset_hold: bool = true,
    ready_hold: bool = false,
    sa1_irq_request: bool = false,
    sa1_nmi_request: bool = false,
    sa1_irq_enable: bool = false,
    timer_irq_enable: bool = false,
    dma_irq_enable: bool = false,
    sa1_nmi_enable: bool = false,
    sa1_irq_flag: bool = false,
    timer_irq_flag: bool = false,
    dma_irq_flag: bool = false,
    sa1_nmi_flag: bool = false,
    nmi_delivered: bool = false,
    cpu_irq_enable: bool = false,
    chdma_irq_enable: bool = false,
    cpu_irq_flag: bool = false,
    chdma_irq_flag: bool = false,
    cpu_irq_vector_switch: bool = false,
    cpu_nmi_vector_switch: bool = false,
    cpu_message: u4 = 0,
    sa1_message: u4 = 0,

    reset_vector: u16 = 0,
    nmi_vector: u16 = 0,
    irq_vector: u16 = 0,
    cpu_nmi_vector: u16 = 0,
    cpu_irq_vector: u16 = 0,

    timer_linear: bool = false,
    timer_h_enable: bool = false,
    timer_v_enable: bool = false,
    timer_h_compare: u16 = 0,
    timer_v_compare: u16 = 0,
    timer_h_counter: u16 = 0,
    timer_v_counter: u16 = 0,
    timer_h_latch: u16 = 0,
    timer_v_latch: u16 = 0,

    rom_banks: [4]u8 = .{ 0, 1, 2, 3 },
    rom_bank_mode: [4]bool = .{ false, false, false, false },
    cpu_bwram_map: u5 = 0,
    sa1_bwram_map: u7 = 0,
    sa1_bwram_bitmap_window: bool = false,
    cpu_bwram_write_enable: bool = false,
    sa1_bwram_write_enable: bool = false,
    bwram_protection: u4 = 0x0f,
    cpu_iram_write_pages: u8 = 0,
    sa1_iram_write_pages: u8 = 0,
    bitmap_two_bpp: bool = false,

    dma_enable: bool = false,
    dma_priority: bool = false,
    character_dma_enable: bool = false,
    character_dma_type1: bool = false,
    dma_destination_bwram: bool = false,
    dma_source: u2 = 0,
    character_end: bool = false,
    character_size: u3 = 0,
    character_bpp_code: u2 = 0,
    dma_source_address: u32 = 0,
    dma_destination_address: u32 = 0,
    dma_count: u16 = 0,
    dma_running: bool = false,
    bitmap_registers: [16]u8 = .{0} ** 16,
    character_line: u4 = 0,
    character_dma_active: bool = false,

    arithmetic_divide: bool = false,
    arithmetic_accumulate: bool = false,
    arithmetic_a: u16 = 0,
    arithmetic_b: u16 = 0,
    arithmetic_result: u64 = 0,
    arithmetic_overflow: bool = false,

    variable_auto_increment: bool = false,
    variable_length: u5 = 16,
    variable_address: u32 = 0,
    variable_bit: u3 = 0,

    pending_cpu_resource: Resource = .none,
    cpu_bus_accesses: u64 = 0,
    sa1_bus_accesses: u64 = 0,
    bus_conflicts: u64 = 0,
    dma_bytes: u64 = 0,
    character_conversions: u64 = 0,
    dirty: bool = false,
    dirty_first: usize = 0,
    dirty_end: usize = 0,

    pub fn power(self: *Device, region: Region, rom_bytes: usize, bwram_bytes: usize) !void {
        try validateGeometry(rom_bytes, bwram_bytes);
        self.* = .{ .region = region };
    }

    pub fn cpuIrqPending(self: *const Device) bool {
        return (self.cpu_irq_enable and self.cpu_irq_flag) or
            (self.chdma_irq_enable and self.chdma_irq_flag);
    }

    pub fn readCpu(self: *Device, rom: []const u8, bwram: []const u8, raw_address: u32, open_bus: u8) ?u8 {
        const address = raw_address & address_mask;
        self.cpu_open_bus = open_bus;

        if (cpuVectorByte(self, address)) |value| return self.observeCpuRead(value, .rom);
        if (ioOffset(address)) |offset| return self.observeCpuRead(self.readIoCpu(offset, open_bus), .io);
        if (cpuIramIndex(address)) |index| return self.observeCpuRead(self.iram[index], .iram);
        if (self.cpuBwramIndex(address, bwram.len)) |index| {
            const value = if (self.character_dma_active)
                self.characterType1Read(bwram, index)
            else
                readMirrored(bwram, index, open_bus);
            return self.observeCpuRead(value, .bwram);
        }
        if (self.romIndex(address, rom.len)) |index| return self.observeCpuRead(rom[index], .rom);
        return null;
    }

    pub fn writeCpu(self: *Device, rom: []const u8, bwram: []u8, raw_address: u32, value: u8) WriteResult {
        const address = raw_address & address_mask;
        self.cpu_open_bus = value;

        if (ioOffset(address)) |offset| {
            self.observeCpuResource(.io);
            self.writeIoCpu(rom, bwram, offset, value);
            return self.writeResult(true);
        }
        if (cpuIramIndex(address)) |index| {
            self.observeCpuResource(.iram);
            const page: u3 = @truncate(index >> 8);
            if ((self.cpu_iram_write_pages & (@as(u8, 1) << page)) != 0) self.iram[index] = value;
            return .{ .handled = true };
        }
        if (self.cpuBwramIndex(address, bwram.len)) |index| {
            self.observeCpuResource(.bwram);
            self.writeBwram(bwram, index, value);
            return self.writeResult(true);
        }
        if (self.romIndex(address, rom.len) != null) {
            self.observeCpuResource(.rom);
            return .{ .handled = true };
        }
        return .{};
    }

    pub fn readCoprocessor(self: *Device, rom: []const u8, bwram: []u8, address: u32) u8 {
        const access = self.readSa1(rom, bwram, address & address_mask);
        self.advanceMaster(access.clocks + self.consumeContention(access.resource));
        self.sa1_open_bus = access.value;
        self.sa1_bus_accesses +%= 1;
        return access.value;
    }

    pub fn writeCoprocessor(self: *Device, rom: []const u8, bwram: []u8, address: u32, value: u8) void {
        const access = self.writeSa1(rom, bwram, address & address_mask, value);
        self.advanceMaster(access.clocks + self.consumeContention(access.resource));
        self.sa1_open_bus = value;
        self.sa1_bus_accesses +%= 1;
    }

    pub fn runSlice(self: *Device, rom: []const u8, bwram: []u8, maximum_instructions: usize) RunResult {
        const start = self.master_cycles;
        if (maximum_instructions == 0) return .{ .state = .budget, .instructions = 0, .master_cycles = 0 };
        var state: RunState = .budget;
        var instructions: usize = 0;
        while (instructions < maximum_instructions) : (instructions += 1) {
            if (self.reset_hold or self.ready_hold) {
                self.advanceMaster(2);
                state = .held;
                instructions += 1;
                break;
            }
            if (self.dma_running) {
                self.runDmaByte(rom, bwram);
                state = .executed;
                continue;
            }
            self.updateInterruptLines();
            var port = CpuPort{ .device = self, .rom = rom, .bwram = bwram };
            const result = self.cpu.step(&port) catch |fault| {
                return .{ .state = .fault, .instructions = instructions, .master_cycles = self.master_cycles -% start, .fault = fault };
            };
            state = switch (result.state) {
                .executed, .interrupt, .awakened => .executed,
                .reset => .reset,
                .waiting => .waiting,
                .stopped => .stopped,
            };
            if (state == .waiting or state == .stopped) {
                instructions += 1;
                break;
            }
        }
        return .{ .state = state, .instructions = instructions, .master_cycles = self.master_cycles -% start };
    }

    pub fn runUntilMasterClock(self: *Device, rom: []const u8, bwram: []u8, target: u64, maximum_instructions: usize) RunResult {
        const start = self.master_cycles;
        var instructions: usize = 0;
        var state: RunState = .budget;
        while (self.master_cycles < target and instructions < maximum_instructions) : (instructions += 1) {
            if (self.reset_hold or self.ready_hold) {
                const remaining = target - self.master_cycles;
                self.advanceMaster(@intCast(@min(remaining, @as(u64, 0xfffe))));
                state = .held;
                continue;
            }
            if (self.dma_running) {
                self.runDmaByte(rom, bwram);
                state = .executed;
                continue;
            }
            self.updateInterruptLines();
            var port = CpuPort{ .device = self, .rom = rom, .bwram = bwram };
            const result = self.cpu.step(&port) catch |fault| {
                return .{ .state = .fault, .instructions = instructions, .master_cycles = self.master_cycles -% start, .fault = fault };
            };
            state = switch (result.state) {
                .executed, .interrupt, .awakened => .executed,
                .reset => .reset,
                .waiting => .waiting,
                .stopped => .stopped,
            };
        }
        return .{ .state = state, .instructions = instructions, .master_cycles = self.master_cycles -% start };
    }

    pub fn takeDirtyRange(self: *Device) ?DirtyRange {
        if (!self.dirty) return null;
        const range = DirtyRange{ .first = self.dirty_first, .end = self.dirty_end };
        self.dirty = false;
        self.dirty_first = 0;
        self.dirty_end = 0;
        return range;
    }

    pub fn stateDigest(self: *const Device, bwram: []const u8) u64 {
        var digest: u64 = 0xcbf29ce484222325;
        digestWord(&digest, self.cpu.a);
        digestWord(&digest, self.cpu.x);
        digestWord(&digest, self.cpu.y);
        digestWord(&digest, self.cpu.s);
        digestWord(&digest, self.cpu.d);
        digestByte(&digest, self.cpu.db);
        digestByte(&digest, self.cpu.pb);
        digestWord(&digest, self.cpu.pc);
        digestByte(&digest, self.cpu.p.byte());
        digestByte(&digest, @intFromBool(self.cpu.emulation));
        digestWord(&digest, self.reset_vector);
        digestWord(&digest, self.nmi_vector);
        digestWord(&digest, self.irq_vector);
        digestWord(&digest, self.timer_h_counter);
        digestWord(&digest, self.timer_v_counter);
        digestByte(&digest, @truncate(self.arithmetic_result));
        digestByte(&digest, @truncate(self.arithmetic_result >> 8));
        digestByte(&digest, @truncate(self.arithmetic_result >> 16));
        digestByte(&digest, @truncate(self.arithmetic_result >> 24));
        digestByte(&digest, @truncate(self.arithmetic_result >> 32));
        for (self.iram) |value| digestByte(&digest, value);
        for (bwram) |value| digestByte(&digest, value);
        return digest;
    }

    fn observeCpuRead(self: *Device, value: u8, resource: Resource) u8 {
        self.cpu_open_bus = value;
        self.observeCpuResource(resource);
        return value;
    }

    fn observeCpuResource(self: *Device, resource: Resource) void {
        self.pending_cpu_resource = resource;
        self.cpu_bus_accesses +%= 1;
    }

    fn consumeContention(self: *Device, resource: Resource) u8 {
        const conflict = resource != .none and self.pending_cpu_resource == resource;
        self.pending_cpu_resource = .none;
        if (!conflict) return 0;
        self.bus_conflicts +%= 1;
        return switch (resource) {
            .bwram => 4,
            .rom, .iram => 2,
            else => 0,
        };
    }

    fn readSa1(self: *Device, rom: []const u8, bwram: []u8, address: u32) MemoryAccess {
        if (sa1VectorByte(self, address)) |value| return .{ .value = value, .clocks = 2, .resource = .rom };
        if (ioOffset(address)) |offset| return .{ .value = self.readIoSa1(rom, bwram, offset), .clocks = 2, .resource = .io };
        if (sa1IramIndex(address)) |index| return .{ .value = self.iram[index], .clocks = 2, .resource = .iram };
        if (self.sa1BwramAccess(address, bwram.len)) |mapped| {
            const value = if (mapped.bitmap)
                self.readBitmap(bwram, mapped.index)
            else
                readMirrored(bwram, mapped.index, self.sa1_open_bus);
            return .{ .value = value, .clocks = 4, .resource = .bwram };
        }
        if (self.romIndex(address, rom.len)) |index| return .{ .value = rom[index], .clocks = 2, .resource = .rom };
        return .{ .value = self.sa1_open_bus, .clocks = 2, .resource = .none };
    }

    fn writeSa1(self: *Device, rom: []const u8, bwram: []u8, address: u32, value: u8) MemoryAccess {
        if (ioOffset(address)) |offset| {
            self.writeIoSa1(rom, bwram, offset, value);
            return .{ .value = value, .clocks = 2, .resource = .io };
        }
        if (sa1IramIndex(address)) |index| {
            const page: u3 = @truncate(index >> 8);
            if ((self.sa1_iram_write_pages & (@as(u8, 1) << page)) != 0) self.iram[index] = value;
            return .{ .value = value, .clocks = 2, .resource = .iram };
        }
        if (self.sa1BwramAccess(address, bwram.len)) |mapped| {
            if (mapped.bitmap) self.writeBitmap(bwram, mapped.index, value) else self.writeBwram(bwram, mapped.index, value);
            return .{ .value = value, .clocks = 4, .resource = .bwram };
        }
        if (self.romIndex(address, rom.len) != null) return .{ .value = value, .clocks = 2, .resource = .rom };
        return .{ .value = value, .clocks = 2, .resource = .none };
    }

    fn readIoCpu(self: *Device, offset: u16, open_bus: u8) u8 {
        return switch (offset) {
            0x2300 => (open_bus & 0x00) | @as(u8, self.cpu_message) |
                (@as(u8, @intFromBool(self.cpu_nmi_vector_switch)) << 4) |
                (@as(u8, @intFromBool(self.chdma_irq_flag)) << 5) |
                (@as(u8, @intFromBool(self.cpu_irq_vector_switch)) << 6) |
                (@as(u8, @intFromBool(self.cpu_irq_flag)) << 7),
            else => open_bus,
        };
    }

    fn readIoSa1(self: *Device, rom: []const u8, bwram: []const u8, offset: u16) u8 {
        return switch (offset) {
            0x2301 => @as(u8, self.sa1_message) |
                (@as(u8, @intFromBool(self.sa1_nmi_flag)) << 4) |
                (@as(u8, @intFromBool(self.dma_irq_flag)) << 5) |
                (@as(u8, @intFromBool(self.timer_irq_flag)) << 6) |
                (@as(u8, @intFromBool(self.sa1_irq_flag)) << 7),
            0x2302 => blk: {
                self.timer_h_latch = self.timer_h_counter >> 2;
                self.timer_v_latch = self.timer_v_counter;
                break :blk @truncate(self.timer_h_latch);
            },
            0x2303 => @truncate(self.timer_h_latch >> 8),
            0x2304 => @truncate(self.timer_v_latch),
            0x2305 => @truncate(self.timer_v_latch >> 8),
            0x2306...0x230a => @truncate(self.arithmetic_result >> @intCast((offset - 0x2306) * 8)),
            0x230b => @as(u8, @intFromBool(self.arithmetic_overflow)) << 7,
            0x230c => @truncate(self.variableWindow(rom, bwram)),
            0x230d => blk: {
                const result: u8 = @truncate(self.variableWindow(rom, bwram) >> 8);
                if (self.variable_auto_increment) self.advanceVariable();
                break :blk result;
            },
            else => 0xff,
        };
    }

    fn writeIoCpu(self: *Device, rom: []const u8, bwram: []u8, offset: u16, value: u8) void {
        switch (offset) {
            0x2200 => {
                const old_reset = self.reset_hold;
                self.sa1_message = @truncate(value);
                self.sa1_nmi_request = (value & 0x10) != 0;
                self.reset_hold = (value & 0x20) != 0;
                self.ready_hold = (value & 0x40) != 0;
                self.sa1_irq_request = (value & 0x80) != 0;
                if (old_reset and !self.reset_hold) {
                    self.cpu.requestReset();
                    self.sa1_iram_write_pages = 0;
                }
                if (self.sa1_irq_request) self.sa1_irq_flag = true;
                if (self.sa1_nmi_request) {
                    self.sa1_nmi_flag = true;
                    self.nmi_delivered = false;
                }
            },
            0x2201 => {
                self.chdma_irq_enable = (value & 0x20) != 0;
                self.cpu_irq_enable = (value & 0x80) != 0;
            },
            0x2202 => {
                if ((value & 0x20) != 0) self.chdma_irq_flag = false;
                if ((value & 0x80) != 0) self.cpu_irq_flag = false;
            },
            0x2203 => setByte16(&self.reset_vector, false, value),
            0x2204 => setByte16(&self.reset_vector, true, value),
            0x2205 => setByte16(&self.nmi_vector, false, value),
            0x2206 => setByte16(&self.nmi_vector, true, value),
            0x2207 => setByte16(&self.irq_vector, false, value),
            0x2208 => setByte16(&self.irq_vector, true, value),
            0x2220...0x2223 => {
                const index: usize = offset - 0x2220;
                self.rom_banks[index] = value & 7;
                self.rom_bank_mode[index] = (value & 0x80) != 0;
            },
            0x2224 => self.cpu_bwram_map = @truncate(value),
            0x2226 => self.cpu_bwram_write_enable = (value & 0x80) != 0,
            0x2228 => self.bwram_protection = @truncate(value),
            0x2229 => self.cpu_iram_write_pages = value,
            0x2231...0x2237 => self.writeIoShared(rom, bwram, offset, value),
            else => {},
        }
    }

    fn writeIoSa1(self: *Device, rom: []const u8, bwram: []u8, offset: u16, value: u8) void {
        switch (offset) {
            0x2209 => {
                self.cpu_message = @truncate(value);
                self.cpu_nmi_vector_switch = (value & 0x10) != 0;
                self.cpu_irq_vector_switch = (value & 0x40) != 0;
                if ((value & 0x80) != 0) self.cpu_irq_flag = true;
            },
            0x220a => {
                self.sa1_nmi_enable = (value & 0x10) != 0;
                self.dma_irq_enable = (value & 0x20) != 0;
                self.timer_irq_enable = (value & 0x40) != 0;
                self.sa1_irq_enable = (value & 0x80) != 0;
            },
            0x220b => {
                if ((value & 0x10) != 0) {
                    self.sa1_nmi_flag = false;
                    self.nmi_delivered = false;
                }
                if ((value & 0x20) != 0) self.dma_irq_flag = false;
                if ((value & 0x40) != 0) self.timer_irq_flag = false;
                if ((value & 0x80) != 0) self.sa1_irq_flag = false;
            },
            0x220c => setByte16(&self.cpu_nmi_vector, false, value),
            0x220d => setByte16(&self.cpu_nmi_vector, true, value),
            0x220e => setByte16(&self.cpu_irq_vector, false, value),
            0x220f => setByte16(&self.cpu_irq_vector, true, value),
            0x2210 => {
                self.timer_h_enable = (value & 1) != 0;
                self.timer_v_enable = (value & 2) != 0;
                self.timer_linear = (value & 0x80) != 0;
            },
            0x2211 => {
                self.timer_h_counter = 0;
                self.timer_v_counter = 0;
            },
            0x2212 => setByte16(&self.timer_h_compare, false, value),
            0x2213 => setByte16(&self.timer_h_compare, true, value),
            0x2214 => setByte16(&self.timer_v_compare, false, value),
            0x2215 => setByte16(&self.timer_v_compare, true, value),
            0x2225 => {
                self.sa1_bwram_map = @truncate(value);
                self.sa1_bwram_bitmap_window = (value & 0x80) != 0;
            },
            0x2227 => self.sa1_bwram_write_enable = (value & 0x80) != 0,
            0x222a => self.sa1_iram_write_pages = value,
            0x2230 => {
                self.dma_source = @truncate(value);
                self.dma_destination_bwram = (value & 0x04) != 0;
                self.character_dma_type1 = (value & 0x10) != 0;
                self.character_dma_enable = (value & 0x20) != 0;
                self.dma_priority = (value & 0x40) != 0;
                self.dma_enable = (value & 0x80) != 0;
                if (!self.dma_enable) {
                    self.character_line = 0;
                    self.dma_running = false;
                }
            },
            0x2231...0x2237 => self.writeIoShared(rom, bwram, offset, value),
            0x2238 => setByte16(&self.dma_count, false, value),
            0x2239 => setByte16(&self.dma_count, true, value),
            0x223f => self.bitmap_two_bpp = (value & 0x80) != 0,
            0x2240...0x224f => {
                const index: usize = offset - 0x2240;
                self.bitmap_registers[index] = value;
                if ((index == 7 or index == 15) and self.dma_enable and self.character_dma_enable and !self.character_dma_type1) {
                    self.characterType2(bwram);
                }
            },
            0x2250 => {
                self.arithmetic_divide = (value & 1) != 0;
                self.arithmetic_accumulate = (value & 2) != 0;
                if (self.arithmetic_accumulate) {
                    self.arithmetic_result = 0;
                    self.arithmetic_overflow = false;
                }
            },
            0x2251 => setByte16(&self.arithmetic_a, false, value),
            0x2252 => setByte16(&self.arithmetic_a, true, value),
            0x2253 => setByte16(&self.arithmetic_b, false, value),
            0x2254 => {
                setByte16(&self.arithmetic_b, true, value);
                self.calculateArithmetic();
            },
            0x2258 => {
                self.variable_length = @intCast(value & 0x0f);
                if (self.variable_length == 0) self.variable_length = 16;
                self.variable_auto_increment = (value & 0x80) != 0;
                if (!self.variable_auto_increment) self.advanceVariable();
            },
            0x2259 => setByte24(&self.variable_address, 0, value),
            0x225a => setByte24(&self.variable_address, 1, value),
            0x225b => {
                setByte24(&self.variable_address, 2, value);
                self.variable_bit = 0;
            },
            else => {},
        }
    }

    fn writeIoShared(self: *Device, _: []const u8, _: []u8, offset: u16, value: u8) void {
        switch (offset) {
            0x2231 => {
                self.character_bpp_code = @min(@as(u2, @truncate(value)), 2);
                self.character_size = @min(@as(u3, @truncate(value >> 2)), 5);
                self.character_end = (value & 0x80) != 0;
                if (self.character_end) self.character_dma_active = false;
            },
            0x2232 => setByte24(&self.dma_source_address, 0, value),
            0x2233 => setByte24(&self.dma_source_address, 1, value),
            0x2234 => setByte24(&self.dma_source_address, 2, value),
            0x2235 => setByte24(&self.dma_destination_address, 0, value),
            0x2236 => {
                setByte24(&self.dma_destination_address, 1, value);
                if (self.dma_enable and !self.character_dma_enable and !self.dma_destination_bwram) self.beginDma();
                if (self.dma_enable and self.character_dma_enable and self.character_dma_type1) self.beginCharacterType1();
            },
            0x2237 => {
                setByte24(&self.dma_destination_address, 2, value);
                if (self.dma_enable and !self.character_dma_enable and self.dma_destination_bwram) self.beginDma();
            },
            else => {},
        }
    }

    fn updateInterruptLines(self: *Device) void {
        if (self.sa1_nmi_enable and self.sa1_nmi_flag and !self.nmi_delivered) {
            self.cpu.requestNmi();
            self.nmi_delivered = true;
        }
        self.cpu.setIrqLine(
            (self.sa1_irq_enable and self.sa1_irq_flag) or
                (self.timer_irq_enable and self.timer_irq_flag) or
                (self.dma_irq_enable and self.dma_irq_flag),
        );
    }

    fn advanceMaster(self: *Device, raw_clocks: u16) void {
        self.master_cycles +%= raw_clocks;
        var clocks: u17 = @as(u17, raw_clocks) + self.timer_phase;
        self.timer_phase = @truncate(clocks & 1);
        while (clocks >= 2) : (clocks -= 2) {
            if (self.timer_linear) {
                self.timer_h_counter +%= 2;
                self.timer_v_counter +%= self.timer_h_counter >> 11;
                self.timer_h_counter &= 0x07ff;
                self.timer_v_counter &= 0x01ff;
            } else {
                self.timer_h_counter += 2;
                if (self.timer_h_counter >= 1364) {
                    self.timer_h_counter = 0;
                    self.timer_v_counter += 1;
                    const scanlines: u16 = if (self.region == .pal) 312 else 262;
                    if (self.timer_v_counter >= scanlines) self.timer_v_counter = 0;
                }
            }
            const h_match = self.timer_h_counter == self.timer_h_compare *% 4;
            const v_match = self.timer_v_counter == self.timer_v_compare;
            const trigger = if (self.timer_h_enable and self.timer_v_enable)
                h_match and v_match
            else if (self.timer_h_enable)
                h_match
            else if (self.timer_v_enable)
                v_match and self.timer_h_counter == 0
            else
                false;
            if (trigger) self.timer_irq_flag = true;
        }
    }

    fn beginDma(self: *Device) void {
        self.dma_running = true;
    }

    fn runDmaByte(self: *Device, rom: []const u8, bwram: []u8) void {
        if (self.dma_count == 0) {
            self.dma_running = false;
            self.dma_irq_flag = true;
            return;
        }

        const source = self.dma_source_address & address_mask;
        const destination = self.dma_destination_address & address_mask;
        const valid = (self.dma_source == 0) or
            (self.dma_source == 1 and !self.dma_destination_bwram) or
            (self.dma_source == 2 and self.dma_destination_bwram);
        if (valid) {
            const value = switch (self.dma_source) {
                0 => if (self.romIndex(source, rom.len)) |index| rom[index] else self.sa1_open_bus,
                1 => readMirrored(bwram, source, self.sa1_open_bus),
                2 => self.iram[source & (internal_ram_bytes - 1)],
                3 => unreachable,
            };
            if (self.dma_destination_bwram) {
                self.storeBwram(bwram, destination, value);
            } else {
                self.iram[destination & (internal_ram_bytes - 1)] = value;
            }
            self.dma_bytes +%= 1;

            var clocks: u16 = if (self.dma_destination_bwram or self.dma_source == 1) 4 else 2;
            const conflict = self.pending_cpu_resource;
            const penalty: u16 = if (self.dma_source == 0 and !self.dma_destination_bwram)
                if (conflict == .iram) 4 else if (conflict == .rom) 2 else 0
            else if (self.dma_source == 0 and self.dma_destination_bwram)
                if (conflict == .bwram) 4 else 0
            else if (conflict == .bwram)
                4
            else if (conflict == .iram)
                2
            else
                0;
            if (penalty != 0) self.bus_conflicts +%= 1;
            clocks += penalty;
            self.advanceMaster(clocks);
        }
        self.pending_cpu_resource = .none;
        self.dma_source_address = (self.dma_source_address +% 1) & address_mask;
        self.dma_destination_address = (self.dma_destination_address +% 1) & address_mask;
        self.dma_count -%= 1;
        if (self.dma_count == 0) {
            self.dma_running = false;
            self.dma_irq_flag = true;
        }
    }

    fn beginCharacterType1(self: *Device) void {
        self.character_dma_active = true;
        self.chdma_irq_flag = true;
    }

    fn characterType1Read(self: *Device, bwram: []const u8, raw_address: usize) u8 {
        const bpp: usize = @as(usize, 2) << @intCast(2 - self.character_bpp_code);
        const character_bytes: usize = @as(usize, 1) << @intCast(@as(u3, 6) - @as(u3, self.character_bpp_code));
        const offset = raw_address -% @as(usize, @intCast(self.dma_source_address));
        if ((offset & (character_bytes - 1)) == 0) {
            const tiles_per_row: usize = @as(usize, 1) << self.character_size;
            const bytes_per_line: usize = (8 * tiles_per_row) >> self.character_bpp_code;
            const tile = (offset % @max(bwram.len, 1)) / character_bytes;
            const tile_y = tile >> self.character_size;
            const tile_x = tile & (tiles_per_row - 1);
            var source = @as(usize, @intCast(self.dma_source_address)) + tile_y * 8 * bytes_per_line + tile_x * bpp;
            for (0..8) |y| {
                var row_bits: u64 = 0;
                for (0..bpp) |byte| row_bits |= @as(u64, readMirrored(bwram, source + byte, 0)) << @intCast(byte * 8);
                source += bytes_per_line;
                var output: [8]u8 = .{0} ** 8;
                for (0..8) |x| {
                    for (0..bpp) |plane| {
                        output[plane] |= @as(u8, @truncate(row_bits & 1)) << @intCast(7 - x);
                        row_bits >>= 1;
                    }
                }
                for (0..bpp) |plane| {
                    const destination = (@as(usize, @intCast(self.dma_destination_address)) + y * 2 +
                        ((plane & 6) << 3) + (plane & 1)) & (internal_ram_bytes - 1);
                    self.iram[destination] = output[plane];
                }
            }
            self.character_conversions +%= 1;
        }
        return self.iram[(@as(usize, @intCast(self.dma_destination_address)) + (offset & (character_bytes - 1))) & (internal_ram_bytes - 1)];
    }

    fn characterType2(self: *Device, bwram: []u8) void {
        _ = bwram;
        const register_base: usize = if ((self.character_line & 1) == 0) 0 else 8;
        const bpp: usize = @as(usize, 2) << @intCast(2 - self.character_bpp_code);
        var destination = @as(usize, @intCast(self.dma_destination_address)) & (internal_ram_bytes - 1);
        destination &= ~((@as(usize, 1) << @intCast(@as(u3, 7) - @as(u3, self.character_bpp_code))) - 1);
        destination += @as(usize, self.character_line & 8) * bpp;
        destination += @as(usize, self.character_line & 7) * 2;
        for (0..bpp) |plane| {
            var output: u8 = 0;
            for (0..8) |bit| output |= ((self.bitmap_registers[register_base + bit] >> @intCast(plane)) & 1) << @intCast(7 - bit);
            self.iram[(destination + ((plane & 6) << 3) + (plane & 1)) & (internal_ram_bytes - 1)] = output;
        }
        self.character_line +%= 1;
        self.character_conversions +%= 1;
    }

    fn calculateArithmetic(self: *Device) void {
        if (self.arithmetic_accumulate) {
            const left: i16 = @bitCast(self.arithmetic_a);
            const right: i16 = @bitCast(self.arithmetic_b);
            const product = @as(i64, left) * @as(i64, right);
            const current = signExtend40(self.arithmetic_result);
            const sum = current + product;
            self.arithmetic_overflow = sum < -(@as(i64, 1) << 39) or sum > ((@as(i64, 1) << 39) - 1);
            self.arithmetic_result = @as(u64, @bitCast(sum)) & result_mask;
            self.arithmetic_b = 0;
            return;
        }
        if (!self.arithmetic_divide) {
            const left: i16 = @bitCast(self.arithmetic_a);
            const right: i16 = @bitCast(self.arithmetic_b);
            const product: i32 = @as(i32, left) * @as(i32, right);
            self.arithmetic_result = @as(u32, @bitCast(product));
            self.arithmetic_b = 0;
            return;
        }
        if (self.arithmetic_b == 0) {
            self.arithmetic_result = 0;
        } else {
            const dividend: i16 = @bitCast(self.arithmetic_a);
            const dividend32: i32 = dividend;
            const divisor: i32 = self.arithmetic_b;
            const remainder: i32 = @mod(dividend32, divisor);
            const quotient: i32 = @divExact(dividend32 - remainder, divisor);
            self.arithmetic_result = (@as(u64, @intCast(remainder)) << 16) | @as(u16, @bitCast(@as(i16, @intCast(quotient))));
        }
        self.arithmetic_a = 0;
        self.arithmetic_b = 0;
    }

    fn variableWindow(self: *Device, rom: []const u8, bwram: []const u8) u16 {
        var data: u32 = 0;
        for (0..3) |index| data |= @as(u32, self.readVariableByte(rom, bwram, self.variable_address +% @as(u32, @intCast(index)))) << @intCast(index * 8);
        return @truncate(data >> self.variable_bit);
    }

    fn readVariableByte(self: *Device, rom: []const u8, bwram: []const u8, address: u32) u8 {
        if (sa1IramIndex(address)) |index| return self.iram[index];
        if (self.cpuBwramIndex(address, bwram.len)) |index| return readMirrored(bwram, index, 0xff);
        if (self.romIndex(address, rom.len)) |index| return rom[index];
        return 0xff;
    }

    fn advanceVariable(self: *Device) void {
        const bits: u8 = @as(u8, self.variable_bit) + @as(u8, self.variable_length);
        self.variable_address = (self.variable_address + (bits >> 3)) & address_mask;
        self.variable_bit = @truncate(bits & 7);
    }

    fn cpuBwramIndex(self: *const Device, address: u32, size: usize) ?usize {
        if (size == 0) return null;
        const bank: u8 = @truncate(address >> 16);
        const offset: u16 = @truncate(address);
        if (isSystemBank(bank) and offset >= 0x6000 and offset < 0x8000) {
            return @as(usize, self.cpu_bwram_map) * 0x2000 + @as(usize, offset & 0x1fff);
        }
        if (bank >= 0x40 and bank <= 0x4f) return (@as(usize, bank - 0x40) << 16) | offset;
        return null;
    }

    const BwAccess = struct { index: usize, bitmap: bool };

    fn sa1BwramAccess(self: *const Device, address: u32, size: usize) ?BwAccess {
        if (size == 0) return null;
        const bank: u8 = @truncate(address >> 16);
        const offset: u16 = @truncate(address);
        if (isSystemBank(bank) and offset >= 0x6000 and offset < 0x8000) {
            const logical = @as(usize, self.sa1_bwram_map) * 0x2000 + @as(usize, offset & 0x1fff);
            return .{ .index = logical, .bitmap = self.sa1_bwram_bitmap_window };
        }
        if (bank >= 0x40 and bank <= 0x5f) return .{ .index = (@as(usize, bank - 0x40) << 16) | offset, .bitmap = false };
        if (bank >= 0x60 and bank <= 0x6f) return .{ .index = (@as(usize, bank - 0x60) << 16) | offset, .bitmap = true };
        return null;
    }

    fn romIndex(self: *const Device, address: u32, size: usize) ?usize {
        if (size == 0) return null;
        const bank: u8 = @truncate(address >> 16);
        const offset: u16 = @truncate(address);
        var logical: usize = undefined;
        var lo_style = false;
        if (isSystemBank(bank) and offset >= 0x8000) {
            logical = (if ((bank & 0x80) != 0) @as(usize, 0x200000) else 0) |
                (@as(usize, bank & 0x3f) << 15) | @as(usize, offset & 0x7fff);
            lo_style = true;
        } else if (bank >= 0xc0) {
            logical = (@as(usize, bank - 0xc0) << 16) | offset;
        } else return null;

        const quadrant = logical >> 20;
        const physical = if (lo_style and !self.rom_bank_mode[quadrant])
            logical
        else
            (@as(usize, self.rom_banks[quadrant] & 7) << 20) | (logical & 0x0fffff);
        return mirrorIndex(physical, size);
    }

    fn readBitmap(self: *const Device, bwram: []const u8, pixel_address: usize) u8 {
        if (!self.bitmap_two_bpp) {
            const pixel_byte = readMirrored(bwram, pixel_address >> 1, self.sa1_open_bus);
            return if ((pixel_address & 1) == 0) pixel_byte & 0x0f else pixel_byte >> 4;
        }
        const pixel_byte = readMirrored(bwram, pixel_address >> 2, self.sa1_open_bus);
        return (pixel_byte >> @intCast((pixel_address & 3) * 2)) & 3;
    }

    fn writeBitmap(self: *Device, bwram: []u8, pixel_address: usize, value: u8) void {
        if (bwram.len == 0) return;
        if (!self.bitmap_two_bpp) {
            const index = mirrorIndex(pixel_address >> 1, bwram.len);
            const prior = bwram[index];
            const next = if ((pixel_address & 1) == 0) (prior & 0xf0) | (value & 0x0f) else (prior & 0x0f) | ((value & 0x0f) << 4);
            self.writeBwram(bwram, index, next);
            return;
        }
        const index = mirrorIndex(pixel_address >> 2, bwram.len);
        const shift: u3 = @intCast((pixel_address & 3) * 2);
        const mask: u8 = @as(u8, 3) << shift;
        self.writeBwram(bwram, index, (bwram[index] & ~mask) | ((value & 3) << shift));
    }

    fn writeBwram(self: *Device, bwram: []u8, raw_index: usize, value: u8) void {
        if (bwram.len == 0) return;
        const protected_end = @as(usize, 0x100) << self.bwram_protection;
        // SA-1 silicon disables the shared BWPA protection when either CPU's
        // write-enable latch is set; Kirby's Dream Land 3 relies on this. The
        // comparison uses the raw 18-bit BW address before physical mirroring.
        if (!self.cpu_bwram_write_enable and !self.sa1_bwram_write_enable and (raw_index & 0x3ffff) < protected_end) return;
        self.storeBwram(bwram, raw_index, value);
    }

    fn storeBwram(self: *Device, bwram: []u8, raw_index: usize, value: u8) void {
        if (bwram.len == 0) return;
        const index = mirrorIndex(raw_index, bwram.len);
        if (bwram[index] == value) return;
        bwram[index] = value;
        self.markDirty(index, index + 1);
    }

    fn markDirty(self: *Device, first: usize, end: usize) void {
        if (!self.dirty) {
            self.dirty = true;
            self.dirty_first = first;
            self.dirty_end = end;
            return;
        }
        self.dirty_first = @min(self.dirty_first, first);
        self.dirty_end = @max(self.dirty_end, end);
    }

    fn writeResult(self: *const Device, handled: bool) WriteResult {
        if (!self.dirty) return .{ .handled = handled };
        return .{ .handled = handled, .changed = true, .first = self.dirty_first, .end = self.dirty_end };
    }
};

const CpuPort = struct {
    device: *Device,
    rom: []const u8,
    bwram: []u8,

    pub fn read(self: *CpuPort, address: u32) PortAccess {
        const before = self.device.master_cycles;
        const value = self.device.readCoprocessor(self.rom, self.bwram, address);
        const elapsed = self.device.master_cycles - before;
        return .{ .value = value, .master_cycles = @intCast(@min(elapsed, @as(u64, 0xff))) };
    }

    pub fn write(self: *CpuPort, address: u32, value: u8) PortAccess {
        const before = self.device.master_cycles;
        self.device.writeCoprocessor(self.rom, self.bwram, address, value);
        const elapsed = self.device.master_cycles - before;
        return .{ .value = value, .master_cycles = @intCast(@min(elapsed, @as(u64, 0xff))) };
    }

    pub fn idle(self: *CpuPort, _: u32) u8 {
        self.device.advanceMaster(2);
        return 2;
    }
};

pub fn validateGeometry(rom_bytes: usize, bwram_bytes: usize) !void {
    if (rom_bytes == 0 or rom_bytes > maximum_rom_bytes) return error.InvalidSa1RomSize;
    if (bwram_bytes > maximum_bwram_bytes) return error.InvalidSa1BwramSize;
    if (bwram_bytes != 0 and !isPowerOfTwo(bwram_bytes)) return error.InvalidSa1BwramSize;
}

fn ioOffset(address: u32) ?u16 {
    const bank: u8 = @truncate(address >> 16);
    const offset: u16 = @truncate(address);
    if (!isSystemBank(bank) or offset < 0x2200 or offset > 0x23ff) return null;
    return offset;
}

fn cpuIramIndex(address: u32) ?usize {
    const bank: u8 = @truncate(address >> 16);
    const offset: u16 = @truncate(address);
    if (!isSystemBank(bank) or offset < 0x3000 or offset >= 0x3800) return null;
    return offset & 0x07ff;
}

fn sa1IramIndex(address: u32) ?usize {
    const bank: u8 = @truncate(address >> 16);
    const offset: u16 = @truncate(address);
    if (!isSystemBank(bank)) return null;
    if (offset < 0x0800) return offset;
    if (offset >= 0x3000 and offset < 0x3800) return offset & 0x07ff;
    return null;
}

fn cpuVectorByte(self: *const Device, address: u32) ?u8 {
    if ((address >> 16) != 0) return null;
    const offset: u16 = @truncate(address);
    if (self.cpu_nmi_vector_switch and (offset == 0xffea or offset == 0xffeb or offset == 0xfffa or offset == 0xfffb)) {
        return if ((offset & 1) == 0) @truncate(self.cpu_nmi_vector) else @truncate(self.cpu_nmi_vector >> 8);
    }
    if (self.cpu_irq_vector_switch and (offset == 0xffee or offset == 0xffef or offset == 0xfffe or offset == 0xffff)) {
        return if ((offset & 1) == 0) @truncate(self.cpu_irq_vector) else @truncate(self.cpu_irq_vector >> 8);
    }
    return null;
}

fn sa1VectorByte(self: *const Device, address: u32) ?u8 {
    if ((address >> 16) != 0) return null;
    const offset: u16 = @truncate(address);
    const vector = switch (offset) {
        0xfffc, 0xfffd => self.reset_vector,
        0xffea, 0xffeb, 0xfffa, 0xfffb => self.nmi_vector,
        0xffee, 0xffef, 0xfffe, 0xffff => self.irq_vector,
        else => return null,
    };
    return if ((offset & 1) == 0) @truncate(vector) else @truncate(vector >> 8);
}

fn isSystemBank(bank: u8) bool {
    return bank <= 0x3f or (bank >= 0x80 and bank <= 0xbf);
}

fn mirrorIndex(logical: usize, physical_size: usize) usize {
    if (physical_size == 0) return 0;
    var address = logical;
    var size = physical_size;
    var base: usize = 0;
    var mask: usize = @as(usize, 1) << (@bitSizeOf(usize) - 2);
    while (address >= size) {
        while ((address & mask) == 0) mask >>= 1;
        address -= mask;
        if (size > mask) {
            size -= mask;
            base += mask;
        }
        mask >>= 1;
    }
    return base + address;
}

fn readMirrored(bytes: []const u8, logical: usize, open_bus: u8) u8 {
    if (bytes.len == 0) return open_bus;
    return bytes[mirrorIndex(logical, bytes.len)];
}

fn setByte16(target: *u16, high: bool, value: u8) void {
    if (high) target.* = (target.* & 0x00ff) | (@as(u16, value) << 8) else target.* = (target.* & 0xff00) | value;
}

fn setByte24(target: *u32, index: u2, value: u8) void {
    const shift: u5 = @intCast(@as(u5, index) * 8);
    const mask = @as(u32, 0xff) << shift;
    target.* = ((target.* & ~mask) | (@as(u32, value) << shift)) & address_mask;
}

fn signExtend40(value: u64) i64 {
    const masked = value & result_mask;
    if ((masked & (@as(u64, 1) << 39)) == 0) return @intCast(masked);
    return @as(i64, @bitCast(masked | ~result_mask));
}

fn isPowerOfTwo(value: usize) bool {
    return value != 0 and (value & (value - 1)) == 0;
}

fn digestByte(digest: *u64, value: u8) void {
    digest.* = (digest.* ^ value) *% 0x100000001b3;
}

fn digestWord(digest: *u64, value: u16) void {
    digestByte(digest, @truncate(value));
    digestByte(digest, @truncate(value >> 8));
}
