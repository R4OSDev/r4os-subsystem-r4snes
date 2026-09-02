const std = @import("std");

pub const access_master_cycles: u8 = 6;
pub const cache_bytes: usize = 512;
pub const cache_lines: usize = 32;
pub const minimum_ram_bytes: usize = 32 * 1024;
pub const default_ram_bytes: usize = 64 * 1024;
pub const maximum_ram_bytes: usize = 128 * 1024;
pub const gsu1_maximum_rom_bytes: usize = 1024 * 1024;
pub const gsu2_maximum_rom_bytes: usize = 2 * 1024 * 1024;
pub const default_revision: Revision = .gsu2;

const flag_z: u16 = 1 << 1;
const flag_cy: u16 = 1 << 2;
const flag_s: u16 = 1 << 3;
const flag_ov: u16 = 1 << 4;
const flag_g: u16 = 1 << 5;
const flag_r: u16 = 1 << 6;
const flag_alt1: u16 = 1 << 8;
const flag_alt2: u16 = 1 << 9;
const flag_il: u16 = 1 << 10;
const flag_ih: u16 = 1 << 11;
const flag_b: u16 = 1 << 12;
const flag_irq: u16 = 1 << 15;
const visible_status_mask: u16 = 0x9F7E;

pub const Revision = enum {
    gsu1,
    gsu2,

    pub fn versionCode(self: Revision) u8 {
        return switch (self) {
            .gsu1 => 0x03,
            .gsu2 => 0x04,
        };
    }

    pub fn maximumRomBytes(self: Revision) usize {
        return switch (self) {
            .gsu1 => gsu1_maximum_rom_bytes,
            .gsu2 => gsu2_maximum_rom_bytes,
        };
    }
};

pub const Fault = enum {
    none,
    rom_bus_unavailable,
    ram_bus_unavailable,
    invalid_rom_geometry,
    invalid_ram_geometry,
};

pub const RunState = enum {
    running,
    stopped,
    waiting_rom,
    waiting_ram,
    fault,
};

pub const RunResult = struct {
    state: RunState,
    instructions: usize,
    clocks: u64,
    fault: Fault,
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

const ExecutionError = error{
    RomBusUnavailable,
    RamBusUnavailable,
};

const PixelCache = struct {
    x_base: u8 = 0,
    y: u8 = 0,
    valid: u8 = 0,
    pixels: [8]u8 = .{0} ** 8,
};

/// General GSU-1/GSU-2 execution owner. The core contains no title database
/// and sees only the cartridge ROM, the declared 64/128-KiB GSU RAM and the
/// documented CPU-side register/bus operations.
pub const Device = struct {
    revision: Revision = .gsu2,
    r: [16]u16 = .{0} ** 16,
    r_modified: [16]bool = .{false} ** 16,
    sfr: u16 = 0,
    register_latch: u8 = 0,
    pbr: u8 = 0,
    rombr: u8 = 0,
    rambr: u1 = 0,
    cbr: u16 = 0,
    scbr: u8 = 0,
    scmr: u8 = 0,
    colr: u8 = 0,
    por: u8 = 0,
    bramr: bool = false,
    cfgr: u8 = 0,
    clsr: bool = false,

    pipeline: u8 = 0x01,
    ram_address: u16 = 0,
    source_register: u4 = 0,
    destination_register: u4 = 0,

    rom_delay: u8 = 0,
    rom_data: u8 = 0,
    ram_delay: u8 = 0,
    ram_write_address: u16 = 0,
    ram_write_data: u8 = 0,

    cache: [cache_bytes]u8 = .{0} ** cache_bytes,
    cache_valid: [cache_lines]bool = .{false} ** cache_lines,
    pixel_cache: [2]PixelCache = .{ .{}, .{} },

    cycles: u64 = 0,
    instructions: u64 = 0,
    irq_line: bool = false,
    waiting_rom: bool = false,
    waiting_ram: bool = false,
    fault: Fault = .none,
    dirty: bool = false,
    dirty_first: usize = 0,
    dirty_end: usize = 0,

    pub fn init(revision: Revision) Device {
        return .{ .revision = revision };
    }

    pub fn power(self: *Device, revision: Revision, rom_bytes: usize, ram_bytes: usize) !void {
        try validateGeometry(revision, rom_bytes, ram_bytes);
        self.* = .{ .revision = revision };
    }

    pub fn reset(self: *Device, rom_bytes: usize, ram_bytes: usize) !void {
        const revision = self.revision;
        try self.power(revision, rom_bytes, ram_bytes);
    }

    pub fn running(self: *const Device) bool {
        return self.flag(flag_g);
    }

    pub fn irqPending(self: *const Device) bool {
        return self.flag(flag_irq);
    }

    pub fn screenMode(self: *const Device) u2 {
        return @truncate(self.scmr & 0x03);
    }

    pub fn screenHeightMode(self: *const Device) u2 {
        return @truncate(((self.scmr & 0x20) >> 4) | ((self.scmr & 0x04) >> 2));
    }

    pub fn bitsPerPixel(self: *const Device) u4 {
        return switch (self.screenMode()) {
            0 => 2,
            1, 2 => 4,
            3 => 8,
        };
    }

    pub fn gsuOwnsRom(self: *const Device) bool {
        return self.running() and (self.scmr & 0x10) != 0;
    }

    pub fn gsuOwnsRam(self: *const Device) bool {
        return self.running() and (self.scmr & 0x08) != 0;
    }

    pub fn readCpu(self: *Device, rom: []const u8, ram: []const u8, address: u32, open_bus: u8) ?u8 {
        if (cpuIoOffset(address)) |offset| return self.readIo(offset);
        if (cpuRamIndex(address, ram.len)) |index| {
            if (self.gsuOwnsRam()) return open_bus;
            return ram[index];
        }
        if (cpuRomIndex(address, rom.len)) |index| {
            if (self.gsuOwnsRom()) return cpuRomBusVector(@truncate(address));
            return rom[index];
        }
        return null;
    }

    pub fn writeCpu(self: *Device, ram: []u8, address: u32, value: u8) WriteResult {
        if (cpuIoOffset(address)) |offset| {
            self.writeIo(offset, value);
            return .{ .handled = true };
        }
        if (cpuRamIndex(address, ram.len)) |index| {
            if (self.gsuOwnsRam()) return .{ .handled = true };
            if (ram[index] == value) return .{ .handled = true };
            ram[index] = value;
            self.markDirty(index);
            return .{ .handled = true, .changed = true, .first = index, .end = index + 1 };
        }
        return .{};
    }

    pub fn takeDirtyRange(self: *Device) ?DirtyRange {
        if (!self.dirty) return null;
        const result = DirtyRange{ .first = self.dirty_first, .end = self.dirty_end };
        self.dirty = false;
        self.dirty_first = 0;
        self.dirty_end = 0;
        return result;
    }

    pub fn runSlice(self: *Device, rom: []const u8, ram: []u8, maximum_instructions: usize) RunResult {
        const start_clocks = self.cycles;
        var executed: usize = 0;
        self.fault = .none;
        self.waiting_rom = false;
        self.waiting_ram = false;

        while (executed < maximum_instructions and self.running()) {
            self.executeOne(rom, ram) catch |err| {
                switch (err) {
                    error.RomBusUnavailable => {
                        self.waiting_rom = true;
                        self.fault = .rom_bus_unavailable;
                    },
                    error.RamBusUnavailable => {
                        self.waiting_ram = true;
                        self.fault = .ram_bus_unavailable;
                    },
                }
                break;
            };
            executed += 1;
        }

        const state: RunState = if (self.waiting_rom)
            .waiting_rom
        else if (self.waiting_ram)
            .waiting_ram
        else if (self.fault != .none)
            .fault
        else if (!self.running())
            .stopped
        else
            .running;
        return .{
            .state = state,
            .instructions = executed,
            .clocks = self.cycles -% start_clocks,
            .fault = self.fault,
        };
    }

    pub fn drain(self: *Device, rom: []const u8, ram: []u8) !void {
        try self.syncRomBuffer(rom, ram);
        try self.syncRamBuffer(rom, ram);
        try self.flushPixelCache(rom, ram, 1);
        try self.flushPixelCache(rom, ram, 0);
        try self.syncRamBuffer(rom, ram);
    }

    /// Executes one already-decoded opcode through the productive dispatcher.
    /// This is useful for exhaustive ISA qualification without manufacturing a
    /// different cartridge image for every prefix combination.
    pub fn executeDecoded(self: *Device, rom: []const u8, ram: []u8, opcode: u8) !void {
        try self.dispatch(rom, ram, opcode);
        try self.finishInstruction(rom, ram);
    }

    pub fn stateDigest(self: *const Device) u64 {
        var digest: u64 = 0xCBF29CE484222325;
        for (self.r, self.r_modified) |value, modified| {
            digestByte(&digest, @truncate(value));
            digestByte(&digest, @truncate(value >> 8));
            digestByte(&digest, @intFromBool(modified));
        }
        const words = [_]u16{ self.sfr, self.cbr, self.ram_address, self.ram_write_address };
        for (words) |value| {
            digestByte(&digest, @truncate(value));
            digestByte(&digest, @truncate(value >> 8));
        }
        const bytes = [_]u8{
            self.pbr,                       self.rombr,                self.rambr,                  self.scbr,                   self.scmr,           self.colr,                self.por,
            self.cfgr,                      @intFromBool(self.clsr),   self.pipeline,               self.rom_delay,              self.rom_data,       self.ram_delay,           self.ram_write_data,
            self.source_register,           self.destination_register, @intFromBool(self.irq_line), @intFromEnum(self.revision), self.register_latch, @intFromBool(self.bramr), @intFromBool(self.waiting_rom),
            @intFromBool(self.waiting_ram), @intFromEnum(self.fault),  @intFromBool(self.dirty),
        };
        for (bytes) |value| digestByte(&digest, value);
        digestInteger(&digest, self.cycles);
        digestInteger(&digest, self.instructions);
        digestInteger(&digest, self.dirty_first);
        digestInteger(&digest, self.dirty_end);
        for (self.cache_valid) |value| digestByte(&digest, @intFromBool(value));
        for (self.cache) |value| digestByte(&digest, value);
        for (self.pixel_cache) |entry| {
            digestByte(&digest, entry.x_base);
            digestByte(&digest, entry.y);
            digestByte(&digest, entry.valid);
            for (entry.pixels) |value| digestByte(&digest, value);
        }
        return digest;
    }

    fn readIo(self: *Device, offset: u16) u8 {
        if (self.running() and offset != 0x3030 and offset != 0x3031 and offset != 0x303B) return 0;
        if (offset >= 0x3100 and offset <= 0x32FF) {
            const relative: u16 = offset - 0x3100;
            const index: usize = @intCast((self.cbr +% relative) & 0x01FF);
            return self.cache[index];
        }
        if (offset >= 0x3000 and offset <= 0x301F) {
            const register: usize = @intCast((offset >> 1) & 0x0F);
            return if ((offset & 1) == 0) @truncate(self.r[register]) else @truncate(self.r[register] >> 8);
        }
        return switch (offset) {
            0x3030 => @truncate(self.sfr & visible_status_mask),
            0x3031 => blk: {
                const value: u8 = @truncate((self.sfr & visible_status_mask) >> 8);
                self.setFlag(flag_irq, false);
                self.irq_line = false;
                break :blk value;
            },
            0x3034 => self.pbr,
            0x3036 => self.rombr,
            0x303B => self.revision.versionCode(),
            0x303C => self.rambr,
            0x303E => @truncate(self.cbr),
            0x303F => @truncate(self.cbr >> 8),
            else => 0,
        };
    }

    fn writeIo(self: *Device, offset: u16, value: u8) void {
        if (self.running() and offset != 0x3030 and offset != 0x303A) return;
        if (offset >= 0x3100 and offset <= 0x32FF) {
            const relative: u16 = offset - 0x3100;
            const physical: u16 = (self.cbr +% relative) & 0x01FF;
            const index: usize = @intCast(physical);
            self.cache[index] = value;
            if ((physical & 0x0F) == 0x0F) self.cache_valid[index >> 4] = true;
            return;
        }
        if (offset >= 0x3000 and offset <= 0x301F) {
            const register: u4 = @truncate((offset >> 1) & 0x0F);
            if ((offset & 1) == 0) {
                self.register_latch = value;
            } else {
                self.r[register] = (@as(u16, value) << 8) | self.register_latch;
                self.r_modified[register] = false;
                if (register == 14) self.startRomBuffer();
                if (register == 15) self.setFlag(flag_g, true);
            }
            return;
        }
        switch (offset) {
            0x3030 => {
                const was_running = self.running();
                self.sfr = (self.sfr & 0xFF00) | (@as(u16, value) & 0x007E);
                if (was_running and !self.running()) {
                    self.cbr = 0;
                    self.flushCache();
                }
            },
            0x3031 => self.sfr = ((@as(u16, value) << 8) | (self.sfr & 0x00FF)) & visible_status_mask,
            0x3033 => self.bramr = (value & 1) != 0,
            0x3034 => {
                self.pbr = value & 0x7F;
                self.flushCache();
            },
            0x3037 => self.cfgr = value & 0xA0,
            0x3038 => self.scbr = value,
            0x3039 => self.clsr = (value & 1) != 0,
            0x303A => {
                self.scmr = value & 0x3F;
                if ((self.scmr & 0x10) != 0) self.waiting_rom = false;
                if ((self.scmr & 0x08) != 0) self.waiting_ram = false;
            },
            else => {},
        }
    }

    fn executeOne(self: *Device, rom: []const u8, ram: []u8) ExecutionError!void {
        const opcode = try self.peekPipeline(rom, ram);
        try self.dispatch(rom, ram, opcode);
        try self.finishInstruction(rom, ram);
        self.instructions +%= 1;
    }

    fn finishInstruction(self: *Device, rom: []const u8, ram: []u8) ExecutionError!void {
        if (self.r_modified[14]) {
            self.r_modified[14] = false;
            self.startRomBuffer();
        }
        if (self.r_modified[15]) {
            self.r_modified[15] = false;
        } else {
            self.r[15] +%= 1;
        }
        // One stopped GSU clock is sufficient to keep already queued memory
        // operations moving without tying them to host wall time.
        if (!self.running() and (self.rom_delay != 0 or self.ram_delay != 0)) {
            try self.advanceClocks(rom, ram, 1);
        }
    }

    fn dispatch(self: *Device, rom: []const u8, ram: []u8, opcode: u8) ExecutionError!void {
        switch (opcode) {
            0x00 => self.instructionStop(),
            0x01 => self.resetPrefixes(),
            0x02 => self.instructionCache(),
            0x03 => self.instructionLsr(),
            0x04 => self.instructionRol(),
            0x05 => try self.instructionBranch(rom, ram, true),
            0x06 => try self.instructionBranch(rom, ram, self.flag(flag_s) == self.flag(flag_ov)),
            0x07 => try self.instructionBranch(rom, ram, self.flag(flag_s) != self.flag(flag_ov)),
            0x08 => try self.instructionBranch(rom, ram, !self.flag(flag_z)),
            0x09 => try self.instructionBranch(rom, ram, self.flag(flag_z)),
            0x0A => try self.instructionBranch(rom, ram, !self.flag(flag_s)),
            0x0B => try self.instructionBranch(rom, ram, self.flag(flag_s)),
            0x0C => try self.instructionBranch(rom, ram, !self.flag(flag_cy)),
            0x0D => try self.instructionBranch(rom, ram, self.flag(flag_cy)),
            0x0E => try self.instructionBranch(rom, ram, !self.flag(flag_ov)),
            0x0F => try self.instructionBranch(rom, ram, self.flag(flag_ov)),
            0x10...0x1F => self.instructionToMove(@truncate(opcode)),
            0x20...0x2F => self.instructionWith(@truncate(opcode)),
            0x30...0x3B => try self.instructionStore(rom, ram, @truncate(opcode)),
            0x3C => self.instructionLoop(),
            0x3D => self.instructionAlt1(),
            0x3E => self.instructionAlt2(),
            0x3F => self.instructionAlt3(),
            0x40...0x4B => try self.instructionLoad(rom, ram, @truncate(opcode)),
            0x4C => try self.instructionPlotRpix(rom, ram),
            0x4D => self.instructionSwap(),
            0x4E => self.instructionColorCmode(),
            0x4F => self.instructionNot(),
            0x50...0x5F => self.instructionAddAdc(@truncate(opcode)),
            0x60...0x6F => self.instructionSubSbcCmp(@truncate(opcode)),
            0x70 => self.instructionMerge(),
            0x71...0x7F => self.instructionAndBic(@truncate(opcode)),
            0x80...0x8F => try self.instructionMultUmult(rom, ram, @truncate(opcode)),
            0x90 => try self.instructionSbk(rom, ram),
            0x91...0x94 => self.instructionLink(opcode - 0x90),
            0x95 => self.instructionSex(),
            0x96 => self.instructionAsrDiv2(),
            0x97 => self.instructionRor(),
            0x98...0x9D => self.instructionJmpLjmp(@truncate(opcode)),
            0x9E => self.instructionLob(),
            0x9F => try self.instructionFmultLmult(rom, ram),
            0xA0...0xAF => try self.instructionIbtLmsSms(rom, ram, @truncate(opcode)),
            0xB0...0xBF => self.instructionFromMoves(@truncate(opcode)),
            0xC0 => self.instructionHib(),
            0xC1...0xCF => self.instructionOrXor(@truncate(opcode)),
            0xD0...0xDE => self.instructionInc(@truncate(opcode)),
            0xDF => try self.instructionGetcRambRomb(rom, ram),
            0xE0...0xEE => self.instructionDec(@truncate(opcode)),
            0xEF => try self.instructionGetb(rom, ram),
            0xF0...0xFF => try self.instructionIwtLmSm(rom, ram, @truncate(opcode)),
        }
    }

    fn instructionStop(self: *Device) void {
        if ((self.cfgr & 0x80) == 0) {
            self.setFlag(flag_irq, true);
            self.irq_line = true;
        }
        self.setFlag(flag_g, false);
        self.pipeline = 0x01;
        self.resetPrefixes();
    }

    fn instructionCache(self: *Device) void {
        const base = self.r[15] & 0xFFF0;
        if (self.cbr != base) {
            self.cbr = base;
            self.flushCache();
        }
        self.resetPrefixes();
    }

    fn instructionLsr(self: *Device) void {
        const source = self.sourceValue();
        self.setFlag(flag_cy, (source & 1) != 0);
        const result = source >> 1;
        self.writeDestination(result);
        self.setSignZero(result);
        self.resetPrefixes();
    }

    fn instructionRol(self: *Device) void {
        const source = self.sourceValue();
        const result = (source << 1) | @intFromBool(self.flag(flag_cy));
        self.setFlag(flag_cy, (source & 0x8000) != 0);
        self.writeDestination(result);
        self.setSignZero(result);
        self.resetPrefixes();
    }

    fn instructionBranch(self: *Device, rom: []const u8, ram: []u8, take: bool) ExecutionError!void {
        const raw = try self.pipe(rom, ram);
        if (take) {
            const signed: i8 = @bitCast(raw);
            const wide: i16 = signed;
            self.writeRegister(15, self.r[15] +% @as(u16, @bitCast(wide)));
        }
    }

    fn instructionToMove(self: *Device, register: u4) void {
        if (!self.flag(flag_b)) {
            self.destination_register = register;
        } else {
            self.writeRegister(register, self.sourceValue());
            self.resetPrefixes();
        }
    }

    fn instructionWith(self: *Device, register: u4) void {
        self.source_register = register;
        self.destination_register = register;
        self.setFlag(flag_b, true);
    }

    fn instructionStore(self: *Device, rom: []const u8, ram: []u8, register: u4) ExecutionError!void {
        self.ram_address = self.r[register];
        try self.writeRamBuffer(rom, ram, self.ram_address, @truncate(self.sourceValue()));
        if (!self.flag(flag_alt1)) try self.writeRamBuffer(rom, ram, self.ram_address ^ 1, @truncate(self.sourceValue() >> 8));
        self.resetPrefixes();
    }

    fn instructionLoop(self: *Device) void {
        self.r[12] -%= 1;
        self.setSignZero(self.r[12]);
        if (!self.flag(flag_z)) self.writeRegister(15, self.r[13]);
        self.resetPrefixes();
    }

    fn instructionAlt1(self: *Device) void {
        self.setFlag(flag_b, false);
        self.setFlag(flag_alt1, true);
    }

    fn instructionAlt2(self: *Device) void {
        self.setFlag(flag_b, false);
        self.setFlag(flag_alt2, true);
    }

    fn instructionAlt3(self: *Device) void {
        self.setFlag(flag_b, false);
        self.setFlag(flag_alt1, true);
        self.setFlag(flag_alt2, true);
    }

    fn instructionLoad(self: *Device, rom: []const u8, ram: []u8, register: u4) ExecutionError!void {
        self.ram_address = self.r[register];
        var value: u16 = try self.readRamBuffer(rom, ram, self.ram_address);
        if (!self.flag(flag_alt1)) value |= @as(u16, try self.readRamBuffer(rom, ram, self.ram_address ^ 1)) << 8;
        self.writeDestination(value);
        self.resetPrefixes();
    }

    fn instructionPlotRpix(self: *Device, rom: []const u8, ram: []u8) ExecutionError!void {
        if (!self.flag(flag_alt1)) {
            try self.plot(rom, ram, @truncate(self.r[1]), @truncate(self.r[2]));
            self.r[1] +%= 1;
        } else {
            const value = try self.readPixel(rom, ram, @truncate(self.r[1]), @truncate(self.r[2]));
            self.writeDestination(value);
            self.setFlag(flag_s, false);
            self.setFlag(flag_z, value == 0);
        }
        self.resetPrefixes();
    }

    fn instructionSwap(self: *Device) void {
        const source = self.sourceValue();
        const result = (source >> 8) | (source << 8);
        self.writeDestination(result);
        self.setSignZero(result);
        self.resetPrefixes();
    }

    fn instructionColorCmode(self: *Device) void {
        if (!self.flag(flag_alt1)) self.colr = self.color(@truncate(self.sourceValue())) else self.por = @truncate(self.sourceValue() & 0x1F);
        self.resetPrefixes();
    }

    fn instructionNot(self: *Device) void {
        const result = ~self.sourceValue();
        self.writeDestination(result);
        self.setSignZero(result);
        self.resetPrefixes();
    }

    fn instructionAddAdc(self: *Device, register: u4) void {
        const operand: u16 = if (self.flag(flag_alt2)) register else self.r[register];
        const source = self.sourceValue();
        const carry: u32 = if (self.flag(flag_alt1) and self.flag(flag_cy)) 1 else 0;
        const result: u32 = @as(u32, source) + operand + carry;
        const narrowed: u16 = @truncate(result);
        self.setFlag(flag_ov, ((~(source ^ operand) & (operand ^ narrowed) & 0x8000) != 0));
        self.setFlag(flag_cy, result >= 0x10000);
        self.setSignZero(narrowed);
        self.writeDestination(narrowed);
        self.resetPrefixes();
    }

    fn instructionSubSbcCmp(self: *Device, register: u4) void {
        const alt1 = self.flag(flag_alt1);
        const alt2 = self.flag(flag_alt2);
        const operand: u16 = if (!alt2 or alt1) self.r[register] else register;
        const source = self.sourceValue();
        const borrow: i32 = if (!alt2 and alt1 and !self.flag(flag_cy)) 1 else 0;
        const result: i32 = @as(i32, source) - @as(i32, operand) - borrow;
        const narrowed: u16 = @truncate(@as(u32, @bitCast(result)));
        self.setFlag(flag_ov, ((source ^ operand) & (source ^ narrowed) & 0x8000) != 0);
        self.setFlag(flag_cy, result >= 0);
        self.setSignZero(narrowed);
        if (!alt2 or !alt1) self.writeDestination(narrowed);
        self.resetPrefixes();
    }

    fn instructionMerge(self: *Device) void {
        const result = (self.r[7] & 0xFF00) | (self.r[8] >> 8);
        self.writeDestination(result);
        self.setFlag(flag_ov, (result & 0xC0C0) != 0);
        self.setFlag(flag_s, (result & 0x8080) != 0);
        self.setFlag(flag_cy, (result & 0xE0E0) != 0);
        self.setFlag(flag_z, (result & 0xF0F0) != 0);
        self.resetPrefixes();
    }

    fn instructionAndBic(self: *Device, register: u4) void {
        const operand: u16 = if (self.flag(flag_alt2)) register else self.r[register];
        const result = self.sourceValue() & (if (self.flag(flag_alt1)) ~operand else operand);
        self.writeDestination(result);
        self.setSignZero(result);
        self.resetPrefixes();
    }

    fn instructionMultUmult(self: *Device, rom: []const u8, ram: []u8, register: u4) ExecutionError!void {
        const operand: u16 = if (self.flag(flag_alt2)) register else self.r[register];
        const result: u16 = if (self.flag(flag_alt1)) blk: {
            const left: u8 = @truncate(self.sourceValue());
            const right: u8 = @truncate(operand);
            break :blk @as(u16, left) * @as(u16, right);
        } else blk: {
            const left: i8 = @bitCast(@as(u8, @truncate(self.sourceValue())));
            const right: i8 = @bitCast(@as(u8, @truncate(operand)));
            const product: i16 = @as(i16, left) * @as(i16, right);
            break :blk @bitCast(product);
        };
        self.writeDestination(result);
        self.setSignZero(result);
        self.resetPrefixes();
        if ((self.cfgr & 0x20) == 0) try self.advanceClocks(rom, ram, if (self.clsr) 1 else 2);
    }

    fn instructionSbk(self: *Device, rom: []const u8, ram: []u8) ExecutionError!void {
        try self.writeRamBuffer(rom, ram, self.ram_address, @truncate(self.sourceValue()));
        try self.writeRamBuffer(rom, ram, self.ram_address ^ 1, @truncate(self.sourceValue() >> 8));
        self.resetPrefixes();
    }

    fn instructionLink(self: *Device, amount: u8) void {
        self.r[11] = self.r[15] +% amount;
        self.resetPrefixes();
    }

    fn instructionSex(self: *Device) void {
        const low: i8 = @bitCast(@as(u8, @truncate(self.sourceValue())));
        const result: u16 = @bitCast(@as(i16, low));
        self.writeDestination(result);
        self.setSignZero(result);
        self.resetPrefixes();
    }

    fn instructionAsrDiv2(self: *Device) void {
        const source = self.sourceValue();
        self.setFlag(flag_cy, (source & 1) != 0);
        const signed: i16 = @bitCast(source);
        var result: u16 = @bitCast(signed >> 1);
        if (self.flag(flag_alt1) and source == 0xFFFF) result +%= 1;
        self.writeDestination(result);
        self.setSignZero(result);
        self.resetPrefixes();
    }

    fn instructionRor(self: *Device) void {
        const source = self.sourceValue();
        const result = (source >> 1) | (@as(u16, @intFromBool(self.flag(flag_cy))) << 15);
        self.setFlag(flag_cy, (source & 1) != 0);
        self.writeDestination(result);
        self.setSignZero(result);
        self.resetPrefixes();
    }

    fn instructionJmpLjmp(self: *Device, register: u4) void {
        if (!self.flag(flag_alt1)) {
            self.writeRegister(15, self.r[register]);
        } else {
            self.pbr = @truncate(self.r[register] & 0x7F);
            self.writeRegister(15, self.sourceValue());
            self.cbr = self.r[15] & 0xFFF0;
            self.flushCache();
        }
        self.resetPrefixes();
    }

    fn instructionLob(self: *Device) void {
        const result: u16 = self.sourceValue() & 0x00FF;
        self.writeDestination(result);
        self.setFlag(flag_s, (result & 0x80) != 0);
        self.setFlag(flag_z, result == 0);
        self.resetPrefixes();
    }

    fn instructionFmultLmult(self: *Device, rom: []const u8, ram: []u8) ExecutionError!void {
        const left: i16 = @bitCast(self.sourceValue());
        const right: i16 = @bitCast(self.r[6]);
        const product: i32 = @as(i32, left) * @as(i32, right);
        const bits: u32 = @bitCast(product);
        if (self.flag(flag_alt1)) self.r[4] = @truncate(bits);
        const result: u16 = @truncate(bits >> 16);
        self.writeDestination(result);
        self.setFlag(flag_s, (result & 0x8000) != 0);
        self.setFlag(flag_cy, (bits & 0x8000) != 0);
        self.setFlag(flag_z, result == 0);
        self.resetPrefixes();
        const base: u8 = if ((self.cfgr & 0x20) != 0) 3 else 7;
        try self.advanceClocks(rom, ram, base * (if (self.clsr) @as(u8, 1) else 2));
    }

    fn instructionIbtLmsSms(self: *Device, rom: []const u8, ram: []u8, register: u4) ExecutionError!void {
        if (self.flag(flag_alt1)) {
            self.ram_address = @as(u16, try self.pipe(rom, ram)) << 1;
            const low = try self.readRamBuffer(rom, ram, self.ram_address);
            const high = try self.readRamBuffer(rom, ram, self.ram_address ^ 1);
            self.writeRegister(register, (@as(u16, high) << 8) | low);
        } else if (self.flag(flag_alt2)) {
            self.ram_address = @as(u16, try self.pipe(rom, ram)) << 1;
            try self.writeRamBuffer(rom, ram, self.ram_address, @truncate(self.r[register]));
            try self.writeRamBuffer(rom, ram, self.ram_address ^ 1, @truncate(self.r[register] >> 8));
        } else {
            const immediate: i8 = @bitCast(try self.pipe(rom, ram));
            self.writeRegister(register, @bitCast(@as(i16, immediate)));
        }
        self.resetPrefixes();
    }

    fn instructionFromMoves(self: *Device, register: u4) void {
        if (!self.flag(flag_b)) {
            self.source_register = register;
        } else {
            const result = self.r[register];
            self.writeDestination(result);
            self.setFlag(flag_ov, (result & 0x80) != 0);
            self.setFlag(flag_s, (result & 0x8000) != 0);
            self.setFlag(flag_z, result == 0);
            self.resetPrefixes();
        }
    }

    fn instructionHib(self: *Device) void {
        const result: u16 = self.sourceValue() >> 8;
        self.writeDestination(result);
        self.setFlag(flag_s, (result & 0x80) != 0);
        self.setFlag(flag_z, result == 0);
        self.resetPrefixes();
    }

    fn instructionOrXor(self: *Device, register: u4) void {
        const operand: u16 = if (self.flag(flag_alt2)) register else self.r[register];
        const result = if (self.flag(flag_alt1)) self.sourceValue() ^ operand else self.sourceValue() | operand;
        self.writeDestination(result);
        self.setSignZero(result);
        self.resetPrefixes();
    }

    fn instructionInc(self: *Device, register: u4) void {
        self.writeRegister(register, self.r[register] +% 1);
        self.setSignZero(self.r[register]);
        self.resetPrefixes();
    }

    fn instructionGetcRambRomb(self: *Device, rom: []const u8, ram: []u8) ExecutionError!void {
        if (!self.flag(flag_alt2)) {
            self.colr = self.color(try self.readRomBuffer(rom, ram));
        } else if (!self.flag(flag_alt1)) {
            try self.syncRamBuffer(rom, ram);
            self.rambr = @truncate(self.sourceValue());
        } else {
            try self.syncRomBuffer(rom, ram);
            self.rombr = @truncate(self.sourceValue() & 0x7F);
        }
        self.resetPrefixes();
    }

    fn instructionDec(self: *Device, register: u4) void {
        self.writeRegister(register, self.r[register] -% 1);
        self.setSignZero(self.r[register]);
        self.resetPrefixes();
    }

    fn instructionGetb(self: *Device, rom: []const u8, ram: []u8) ExecutionError!void {
        const value = try self.readRomBuffer(rom, ram);
        const result: u16 = switch ((@as(u2, @intFromBool(self.flag(flag_alt2))) << 1) |
            @as(u2, @intFromBool(self.flag(flag_alt1)))) {
            0 => value,
            1 => (@as(u16, value) << 8) | (self.sourceValue() & 0x00FF),
            2 => (self.sourceValue() & 0xFF00) | value,
            3 => blk: {
                const signed: i8 = @bitCast(value);
                break :blk @bitCast(@as(i16, signed));
            },
        };
        self.writeDestination(result);
        self.resetPrefixes();
    }

    fn instructionIwtLmSm(self: *Device, rom: []const u8, ram: []u8, register: u4) ExecutionError!void {
        if (self.flag(flag_alt1)) {
            const low_address = try self.pipe(rom, ram);
            const high_address = try self.pipe(rom, ram);
            self.ram_address = @as(u16, low_address) | (@as(u16, high_address) << 8);
            const low = try self.readRamBuffer(rom, ram, self.ram_address);
            const high = try self.readRamBuffer(rom, ram, self.ram_address ^ 1);
            self.writeRegister(register, (@as(u16, high) << 8) | low);
        } else if (self.flag(flag_alt2)) {
            const low_address = try self.pipe(rom, ram);
            const high_address = try self.pipe(rom, ram);
            self.ram_address = @as(u16, low_address) | (@as(u16, high_address) << 8);
            try self.writeRamBuffer(rom, ram, self.ram_address, @truncate(self.r[register]));
            try self.writeRamBuffer(rom, ram, self.ram_address ^ 1, @truncate(self.r[register] >> 8));
        } else {
            const low = try self.pipe(rom, ram);
            const high = try self.pipe(rom, ram);
            self.writeRegister(register, (@as(u16, high) << 8) | low);
        }
        self.resetPrefixes();
    }

    fn peekPipeline(self: *Device, rom: []const u8, ram: []u8) ExecutionError!u8 {
        const result = self.pipeline;
        self.pipeline = try self.readOpcode(rom, ram, self.r[15]);
        self.r_modified[15] = false;
        return result;
    }

    fn pipe(self: *Device, rom: []const u8, ram: []u8) ExecutionError!u8 {
        const result = self.pipeline;
        self.r[15] +%= 1;
        self.pipeline = try self.readOpcode(rom, ram, self.r[15]);
        self.r_modified[15] = false;
        return result;
    }

    fn readOpcode(self: *Device, rom: []const u8, ram: []u8, address: u16) ExecutionError!u8 {
        const offset = address -% self.cbr;
        if (offset < cache_bytes) {
            const line: usize = @intCast(offset >> 4);
            if (!self.cache_valid[line]) {
                const destination: u16 = offset & 0x01F0;
                if (self.pbr <= 0x5F) try self.requireRomBus() else try self.requireRamBus();
                var source_address: u16 = (self.cbr +% destination) & 0xFFF0;
                var index: usize = @intCast(destination);
                var count: u8 = 0;
                while (count < 16) : (count += 1) {
                    try self.advanceClocks(rom, ram, self.memoryClocks());
                    self.cache[index] = try self.readInternal(rom, ram, (@as(u32, self.pbr) << 16) | source_address);
                    source_address +%= 1;
                    index += 1;
                }
                self.cache_valid[line] = true;
            } else {
                try self.advanceClocks(rom, ram, self.cacheClocks());
            }
            return self.cache[@intCast(offset)];
        }

        if (self.pbr <= 0x5F) {
            try self.syncRomBuffer(rom, ram);
            try self.requireRomBus();
        } else {
            try self.syncRamBuffer(rom, ram);
            try self.requireRamBus();
        }
        try self.advanceClocks(rom, ram, self.memoryClocks());
        return self.readInternal(rom, ram, (@as(u32, self.pbr) << 16) | address);
    }

    fn advanceClocks(self: *Device, rom: []const u8, ram: []u8, clocks: u8) ExecutionError!void {
        self.cycles +%= clocks;
        if (self.rom_delay != 0) {
            const elapsed = @min(clocks, self.rom_delay);
            self.rom_delay -= elapsed;
            if (self.rom_delay == 0) {
                if ((self.scmr & 0x10) == 0) {
                    self.rom_delay = 1;
                    return error.RomBusUnavailable;
                }
                self.rom_data = try self.readInternal(rom, ram, (@as(u32, self.rombr) << 16) | self.r[14]);
                self.setFlag(flag_r, false);
            }
        }
        if (self.ram_delay != 0) {
            const elapsed = @min(clocks, self.ram_delay);
            self.ram_delay -= elapsed;
            if (self.ram_delay == 0) {
                if ((self.scmr & 0x08) == 0) {
                    self.ram_delay = 1;
                    return error.RamBusUnavailable;
                }
                try self.writeInternalRam(ram, self.rambr, self.ram_write_address, self.ram_write_data);
            }
        }
    }

    fn syncRomBuffer(self: *Device, rom: []const u8, ram: []u8) ExecutionError!void {
        if (self.rom_delay != 0) try self.advanceClocks(rom, ram, self.rom_delay);
    }

    fn readRomBuffer(self: *Device, rom: []const u8, ram: []u8) ExecutionError!u8 {
        try self.syncRomBuffer(rom, ram);
        return self.rom_data;
    }

    fn startRomBuffer(self: *Device) void {
        self.setFlag(flag_r, true);
        self.rom_delay = self.memoryClocks();
    }

    fn syncRamBuffer(self: *Device, rom: []const u8, ram: []u8) ExecutionError!void {
        if (self.ram_delay != 0) try self.advanceClocks(rom, ram, self.ram_delay);
    }

    fn readRamBuffer(self: *Device, rom: []const u8, ram: []u8, address: u16) ExecutionError!u8 {
        try self.syncRamBuffer(rom, ram);
        try self.requireRamBus();
        return ram[ramIndex(self.rambr, address, ram.len)];
    }

    fn writeRamBuffer(self: *Device, rom: []const u8, ram: []u8, address: u16, value: u8) ExecutionError!void {
        try self.syncRamBuffer(rom, ram);
        self.ram_delay = self.memoryClocks();
        self.ram_write_address = address;
        self.ram_write_data = value;
    }

    fn readInternal(self: *Device, rom: []const u8, ram: []const u8, address: u32) ExecutionError!u8 {
        if (gsuRomIndex(address, rom.len)) |index| {
            try self.requireRomBus();
            return rom[index];
        }
        if (gsuRamIndex(address, ram.len)) |index| {
            try self.requireRamBus();
            return ram[index];
        }
        return 0;
    }

    fn writeInternalRam(self: *Device, ram: []u8, bank: u1, address: u16, value: u8) ExecutionError!void {
        try self.requireRamBus();
        const index = ramIndex(bank, address, ram.len);
        if (ram[index] == value) return;
        ram[index] = value;
        self.markDirty(index);
    }

    fn plot(self: *Device, rom: []const u8, ram: []u8, x: u8, y: u8) ExecutionError!void {
        if ((self.por & 0x01) == 0 and self.transparentColor()) return;

        var color_value = self.colr;
        if ((self.por & 0x02) != 0 and self.bitsPerPixel() != 8) {
            if (((x ^ y) & 1) != 0) color_value >>= 4;
            color_value &= 0x0F;
        }

        const x_base = x & 0xF8;
        if (self.pixel_cache[0].valid != 0 and
            (self.pixel_cache[0].x_base != x_base or self.pixel_cache[0].y != y))
        {
            try self.flushPixelCache(rom, ram, 1);
            self.pixel_cache[1] = self.pixel_cache[0];
            self.pixel_cache[0] = .{ .x_base = x_base, .y = y };
        } else if (self.pixel_cache[0].valid == 0) {
            self.pixel_cache[0].x_base = x_base;
            self.pixel_cache[0].y = y;
        }

        const bit: u3 = @truncate((x & 7) ^ 7);
        self.pixel_cache[0].pixels[bit] = color_value;
        self.pixel_cache[0].valid |= @as(u8, 1) << bit;
        if (self.pixel_cache[0].valid == 0xFF) {
            try self.flushPixelCache(rom, ram, 1);
            self.pixel_cache[1] = self.pixel_cache[0];
            self.pixel_cache[0] = .{};
        }
    }

    pub fn readPixel(self: *Device, rom: []const u8, ram: []u8, x_raw: u8, y: u8) ExecutionError!u8 {
        try self.flushPixelCache(rom, ram, 1);
        try self.flushPixelCache(rom, ram, 0);
        try self.syncRamBuffer(rom, ram);

        const address = self.tileAddress(x_raw, y);
        const x: u3 = @truncate((x_raw & 7) ^ 7);
        var result: u8 = 0;
        var plane: u4 = 0;
        while (plane < self.bitsPerPixel()) : (plane += 1) {
            const byte = (@as(u32, plane >> 1) << 4) + (plane & 1);
            try self.advanceClocks(rom, ram, self.memoryClocks());
            const value = try self.readInternal(rom, ram, address + byte);
            result |= ((value >> x) & 1) << @truncate(plane);
        }
        return result;
    }

    fn flushPixelCache(self: *Device, rom: []const u8, ram: []u8, cache_index: usize) ExecutionError!void {
        const entry = self.pixel_cache[cache_index];
        if (entry.valid == 0) return;
        const address = self.tileAddress(entry.x_base, entry.y);
        var plane: u4 = 0;
        while (plane < self.bitsPerPixel()) : (plane += 1) {
            var value: u8 = 0;
            for (entry.pixels, 0..) |pixel, bit| {
                value |= ((pixel >> @truncate(plane)) & 1) << @intCast(bit);
            }
            const byte = (@as(u32, plane >> 1) << 4) + (plane & 1);
            if (entry.valid != 0xFF) {
                try self.advanceClocks(rom, ram, self.memoryClocks());
                value = (value & entry.valid) | ((try self.readInternal(rom, ram, address + byte)) & ~entry.valid);
            }
            try self.advanceClocks(rom, ram, self.memoryClocks());
            const absolute = address + byte;
            const index = gsuRamIndex(absolute, ram.len) orelse return error.RamBusUnavailable;
            try self.requireRamBus();
            if (ram[index] != value) {
                ram[index] = value;
                self.markDirty(index);
            }
        }
        self.pixel_cache[cache_index].valid = 0;
    }

    fn tileAddress(self: *const Device, x: u8, y: u8) u32 {
        const mode: u2 = if ((self.por & 0x10) != 0) 3 else self.screenHeightMode();
        const tile: u32 = switch (mode) {
            0 => (@as(u32, x & 0xF8) << 1) + ((y & 0xF8) >> 3),
            1 => (@as(u32, x & 0xF8) << 1) + (@as(u32, x & 0xF8) >> 1) + ((y & 0xF8) >> 3),
            2 => (@as(u32, x & 0xF8) << 1) + @as(u32, x & 0xF8) + ((y & 0xF8) >> 3),
            3 => (@as(u32, y & 0x80) << 2) + (@as(u32, x & 0x80) << 1) +
                (@as(u32, y & 0x78) << 1) + ((x & 0x78) >> 3),
        };
        return 0x700000 + (@as(u32, self.scbr) << 10) + tile * (@as(u32, self.bitsPerPixel()) << 3) +
            (@as(u32, y & 7) << 1);
    }

    fn transparentColor(self: *const Device) bool {
        const color_value = if ((self.por & 0x08) != 0) self.colr & 0x0F else self.colr;
        return switch (self.bitsPerPixel()) {
            2 => (color_value & 0x03) == 0,
            4 => (color_value & 0x0F) == 0,
            8 => color_value == 0,
            else => unreachable,
        };
    }

    fn color(self: *const Device, source_value: u8) u8 {
        if ((self.por & 0x04) != 0) return (self.colr & 0xF0) | (source_value >> 4);
        if ((self.por & 0x08) != 0) return (self.colr & 0xF0) | (source_value & 0x0F);
        return source_value;
    }

    fn sourceValue(self: *const Device) u16 {
        return self.r[self.source_register];
    }

    fn writeDestination(self: *Device, value: u16) void {
        self.writeRegister(self.destination_register, value);
    }

    fn writeRegister(self: *Device, register: u4, value: u16) void {
        self.r[register] = value;
        self.r_modified[register] = true;
    }

    fn flag(self: *const Device, mask: u16) bool {
        return (self.sfr & mask) != 0;
    }

    fn setFlag(self: *Device, mask: u16, value: bool) void {
        if (value) self.sfr |= mask else self.sfr &= ~mask;
    }

    fn setSignZero(self: *Device, value: u16) void {
        self.setFlag(flag_s, (value & 0x8000) != 0);
        self.setFlag(flag_z, value == 0);
    }

    fn resetPrefixes(self: *Device) void {
        self.setFlag(flag_b, false);
        self.setFlag(flag_alt1, false);
        self.setFlag(flag_alt2, false);
        self.source_register = 0;
        self.destination_register = 0;
    }

    fn flushCache(self: *Device) void {
        @memset(self.cache_valid[0..], false);
    }

    fn memoryClocks(self: *const Device) u8 {
        return if (self.clsr) 5 else 6;
    }

    fn cacheClocks(self: *const Device) u8 {
        return if (self.clsr) 1 else 2;
    }

    fn requireRomBus(self: *const Device) ExecutionError!void {
        if ((self.scmr & 0x10) == 0) return error.RomBusUnavailable;
    }

    fn requireRamBus(self: *const Device) ExecutionError!void {
        if ((self.scmr & 0x08) == 0) return error.RamBusUnavailable;
    }

    fn markDirty(self: *Device, index: usize) void {
        if (!self.dirty) {
            self.dirty = true;
            self.dirty_first = index;
            self.dirty_end = index + 1;
            return;
        }
        self.dirty_first = @min(self.dirty_first, index);
        self.dirty_end = @max(self.dirty_end, index + 1);
    }
};

pub fn validateGeometry(revision: Revision, rom_bytes: usize, ram_bytes: usize) !void {
    if (rom_bytes == 0 or rom_bytes > revision.maximumRomBytes()) return error.InvalidSuperFxRomSize;
    if (ram_bytes != minimum_ram_bytes and ram_bytes != default_ram_bytes and ram_bytes != maximum_ram_bytes)
        return error.InvalidSuperFxRamSize;
    if (revision == .gsu1 and ram_bytes == maximum_ram_bytes) return error.InvalidSuperFxRamSize;
}

pub fn workRamBytes(expansion_ram_size_code: u8) usize {
    if (expansion_ram_size_code >= 1 and expansion_ram_size_code <= 7) {
        return @as(usize, 1024) << @intCast(expansion_ram_size_code);
    }
    return default_ram_bytes;
}

fn cpuIoOffset(address: u32) ?u16 {
    if (address > 0xFFFFFF) return null;
    const bank: u8 = @truncate(address >> 16);
    const offset: u16 = @truncate(address);
    if (!systemBank(bank) or offset < 0x3000 or offset > 0x34FF) return null;
    return offset;
}

fn cpuRamIndex(address: u32, ram_bytes: usize) ?usize {
    if (ram_bytes == 0 or address > 0xFFFFFF) return null;
    const bank: u8 = @truncate(address >> 16);
    const offset: u16 = @truncate(address);
    if (systemBank(bank) and offset >= 0x6000 and offset <= 0x7FFF) {
        return mirrorIndex(offset - 0x6000, ram_bytes);
    }
    if ((bank == 0x70 or bank == 0x71 or bank == 0xF0 or bank == 0xF1)) {
        return mirrorIndex((@as(usize, bank & 1) << 16) | offset, ram_bytes);
    }
    return null;
}

fn cpuRomIndex(address: u32, rom_bytes: usize) ?usize {
    if (rom_bytes == 0 or address > 0xFFFFFF) return null;
    const bank: u8 = @truncate(address >> 16);
    const offset: u16 = @truncate(address);
    if ((bank <= 0x3F or (bank >= 0x80 and bank <= 0xBF)) and offset >= 0x8000) {
        return mirrorIndex((@as(usize, bank & 0x3F) << 15) | (offset & 0x7FFF), rom_bytes);
    }
    if ((bank >= 0x40 and bank <= 0x5F) or (bank >= 0xC0 and bank <= 0xDF)) {
        return mirrorIndex((@as(usize, bank & 0x1F) << 16) | offset, rom_bytes);
    }
    return null;
}

fn gsuRomIndex(address: u32, rom_bytes: usize) ?usize {
    if (rom_bytes == 0 or address > 0xFFFFFF) return null;
    const bank: u8 = @truncate(address >> 16);
    const offset: u16 = @truncate(address);
    if (bank <= 0x3F) return mirrorIndex((@as(usize, bank) << 15) | (offset & 0x7FFF), rom_bytes);
    if (bank >= 0x40 and bank <= 0x5F) return mirrorIndex((@as(usize, bank - 0x40) << 16) | offset, rom_bytes);
    return null;
}

fn gsuRamIndex(address: u32, ram_bytes: usize) ?usize {
    if (ram_bytes == 0 or address > 0xFFFFFF) return null;
    const bank: u8 = @truncate(address >> 16);
    if (bank != 0x70 and bank != 0x71) return null;
    return ramIndex(@truncate(bank), @truncate(address), ram_bytes);
}

fn ramIndex(bank: u1, address: u16, ram_bytes: usize) usize {
    return mirrorIndex((@as(usize, bank) << 16) | address, ram_bytes);
}

fn cpuRomBusVector(offset: u16) u8 {
    const vector = [_]u8{
        0x00, 0x01, 0x00, 0x01, 0x04, 0x01, 0x00, 0x01,
        0x00, 0x01, 0x08, 0x01, 0x00, 0x01, 0x0C, 0x01,
    };
    return vector[offset & 0x0F];
}

fn systemBank(bank: u8) bool {
    return bank <= 0x3F or (bank >= 0x80 and bank <= 0xBF);
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

fn digestByte(digest: *u64, value: u8) void {
    digest.* ^= value;
    digest.* *%= 0x100000001B3;
}

fn digestInteger(digest: *u64, value: anytype) void {
    const T = @TypeOf(value);
    const U = std.meta.Int(.unsigned, @bitSizeOf(T));
    const bits: U = @bitCast(value);
    inline for (0..@sizeOf(T)) |index| {
        digestByte(digest, @truncate(bits >> @intCast(index * 8)));
    }
}
