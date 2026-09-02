const std = @import("std");
const armv3 = @import("armv3.zig");

pub const frequency_hz: u32 = 21_440_000;
pub const access_master_cycles: u8 = 8;
pub const firmware_bytes: usize = 0x28000;
pub const program_rom_bytes: usize = 128 * 1024;
pub const data_rom_bytes: usize = 32 * 1024;
pub const work_ram_bytes: usize = 16 * 1024;
pub const reset_delay_cycles: u32 = 65_536;
pub const firmware_root = "C:\\R4OS\\SUBSYSTEMS\\r4os.snes\\FIRMWARE\\";
pub const firmware_file = "ST018.ROM";
pub const firmware_path = firmware_root ++ firmware_file;

pub const FirmwareValidation = enum {
    known_only,
    /// Available only to original owner fixtures. Product launches must use
    /// the hash-bound known image policy.
    allow_open_test,
};

pub const FirmwareSource = enum {
    separate,
    open_test,
};

pub const RunState = enum {
    budget_exhausted,
    reset_hold,
    reset_delay,
    running,
    closed,
};

pub const RunResult = struct {
    state: RunState,
    steps: usize,
    instructions: usize,
    cycles: u64,
    exception: ?armv3.Exception,
};

pub const DirtyRange = struct {
    first: usize,
    end: usize,
};

pub const Device = struct {
    allocator: ?std.mem.Allocator = null,
    program_rom: []u8 = &.{},
    data_rom: []u8 = &.{},
    work_ram: []u8 = &.{},
    firmware_digest: [32]u8 = [_]u8{0} ** 32,
    firmware_source: FirmwareSource = .separate,
    firmware_installed: bool = false,
    cpu: armv3.Cpu = .{},

    cpu_to_arm_data: u8 = 0,
    cpu_to_arm_ready: bool = false,
    arm_to_cpu_data: u8 = 0,
    arm_to_cpu_ready: bool = false,
    signal: bool = false,
    reset_hold: bool = false,
    ready: bool = false,
    reset_delay: u32 = reset_delay_cycles,
    timer: u32 = 0,
    timer_latch: u32 = 0,
    last_prefetch: u32 = 0,

    cycles: u64 = 0,
    host_accesses: u64 = 0,
    host_conflicts: u64 = 0,
    arm_accesses: u64 = 0,
    dirty: bool = false,
    dirty_first: usize = 0,
    dirty_end: usize = 0,
    closed: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        firmware: []const u8,
        validation: FirmwareValidation,
        source: FirmwareSource,
    ) !Device {
        const digest = try validateFirmware(firmware, validation, source);
        const program = try allocator.alloc(u8, program_rom_bytes);
        errdefer allocator.free(program);
        const data = try allocator.alloc(u8, data_rom_bytes);
        errdefer allocator.free(data);
        const ram = try allocator.alloc(u8, work_ram_bytes);
        errdefer allocator.free(ram);
        @memcpy(program, firmware[0..program_rom_bytes]);
        @memcpy(data, firmware[program_rom_bytes..firmware_bytes]);
        @memset(ram, 0);
        var result = Device{
            .allocator = allocator,
            .program_rom = program,
            .data_rom = data,
            .work_ram = ram,
            .firmware_digest = digest,
            .firmware_source = source,
            .firmware_installed = true,
        };
        result.cpu.power();
        return result;
    }

    pub fn close(self: *Device) void {
        if (self.closed) return;
        self.closed = true;
        if (self.allocator) |allocator| {
            if (self.program_rom.len != 0) {
                @memset(self.program_rom, 0);
                allocator.free(self.program_rom);
            }
            if (self.data_rom.len != 0) {
                @memset(self.data_rom, 0);
                allocator.free(self.data_rom);
            }
            if (self.work_ram.len != 0) {
                @memset(self.work_ram, 0);
                allocator.free(self.work_ram);
            }
        }
        self.allocator = null;
        self.program_rom = &.{};
        self.data_rom = &.{};
        self.work_ram = &.{};
        self.firmware_digest = [_]u8{0} ** 32;
        self.firmware_installed = false;
        self.cpu = .{};
        self.cpu_to_arm_ready = false;
        self.arm_to_cpu_ready = false;
        self.signal = false;
        self.ready = false;
        self.timer = 0;
        self.timer_latch = 0;
        self.dirty = false;
        self.dirty_first = 0;
        self.dirty_end = 0;
    }

    /// Hardware reset preserves the 16-KiB data RAM but resets all CPU,
    /// pipeline and bridge state. A rising host reset edge restarts the fixed
    /// 65536-cycle ready delay; clearing the bit releases execution.
    pub fn setReset(self: *Device, asserted: bool) void {
        if (self.closed or self.reset_hold == asserted) return;
        if (asserted) {
            self.cpu.reset();
            self.cpu_to_arm_ready = false;
            self.arm_to_cpu_ready = false;
            self.signal = false;
            self.timer = 0;
            self.timer_latch = 0;
            self.ready = false;
            self.reset_delay = reset_delay_cycles;
        }
        self.reset_hold = asserted;
    }

    pub fn setIrqLine(self: *Device, asserted: bool) void {
        self.cpu.setIrq(asserted);
    }

    pub fn setFiqLine(self: *Device, asserted: bool) void {
        self.cpu.setFiq(asserted);
    }

    pub fn status(self: *const Device) u8 {
        return @as(u8, @intFromBool(self.arm_to_cpu_ready)) |
            (@as(u8, @intFromBool(self.signal)) << 2) |
            (@as(u8, @intFromBool(self.cpu_to_arm_ready)) << 3) |
            (@as(u8, @intFromBool(self.ready and !self.reset_hold)) << 7);
    }

    pub fn readCpu(self: *Device, raw_address: u32, open_bus: u8) ?u8 {
        const port = hostPort(raw_address) orelse return null;
        if (self.closed) return open_bus;
        self.host_accesses +%= 1;
        return switch (port) {
            0 => blk: {
                if (!self.arm_to_cpu_ready) self.host_conflicts +%= 1;
                self.arm_to_cpu_ready = false;
                break :blk self.arm_to_cpu_data;
            },
            2 => blk: {
                self.signal = false;
                break :blk 0;
            },
            4 => self.status(),
            6 => 0,
            else => unreachable,
        };
    }

    pub fn writeCpu(self: *Device, raw_address: u32, value: u8) bool {
        const port = hostPort(raw_address) orelse return false;
        if (self.closed) return true;
        self.host_accesses +%= 1;
        switch (port) {
            2 => {
                if (self.cpu_to_arm_ready) self.host_conflicts +%= 1;
                self.cpu_to_arm_data = value;
                self.cpu_to_arm_ready = true;
            },
            4 => self.setReset((value & 1) != 0),
            else => {},
        }
        return true;
    }

    /// Each step is either one reset-delay cycle or one complete ARM
    /// instruction. This keeps host work bounded and partition-invariant while
    /// the returned cycle count exposes the instruction's exact bus/idles.
    pub fn runSlice(self: *Device, maximum_steps: usize) RunResult {
        if (self.closed) return .{
            .state = .closed,
            .steps = 0,
            .instructions = 0,
            .cycles = 0,
            .exception = null,
        };
        const start_cycles = self.cycles;
        var steps: usize = 0;
        var instructions: usize = 0;
        var last_exception: ?armv3.Exception = null;
        while (steps < maximum_steps) : (steps += 1) {
            if (self.reset_hold) {
                self.tick();
                steps += 1;
                return .{
                    .state = .reset_hold,
                    .steps = steps,
                    .instructions = instructions,
                    .cycles = self.cycles -% start_cycles,
                    .exception = last_exception,
                };
            }
            if (self.reset_delay != 0) {
                self.tick();
                self.reset_delay -= 1;
                if (self.reset_delay == 0) self.ready = true;
                continue;
            }
            const outcome = self.cpu.step(self);
            instructions += @intFromBool(outcome.executed);
            if (outcome.exception) |fault| last_exception = fault;
        }
        return .{
            .state = if (self.reset_delay != 0) .reset_delay else if (maximum_steps == 0) .budget_exhausted else .running,
            .steps = steps,
            .instructions = instructions,
            .cycles = self.cycles -% start_cycles,
            .exception = last_exception,
        };
    }

    pub fn restorePersistentRam(self: *Device, bytes: []const u8) !void {
        if (bytes.len != work_ram_bytes or self.work_ram.len != work_ram_bytes)
            return error.InvalidSt018PersistentRamSize;
        @memcpy(self.work_ram, bytes);
        self.dirty = false;
        self.dirty_first = 0;
        self.dirty_end = 0;
    }

    pub fn copyPersistentRamRange(self: *const Device, destination: []u8, first: usize, end: usize) !void {
        if (destination.len != work_ram_bytes or self.work_ram.len != work_ram_bytes or
            first > end or end > work_ram_bytes)
            return error.InvalidSt018PersistentRamSize;
        @memcpy(destination[first..end], self.work_ram[first..end]);
    }

    pub fn takeDirtyRange(self: *Device) ?DirtyRange {
        if (!self.dirty) return null;
        const result = DirtyRange{ .first = self.dirty_first, .end = self.dirty_end };
        self.dirty = false;
        self.dirty_first = 0;
        self.dirty_end = 0;
        return result;
    }

    pub fn stateDigest(self: *const Device) u64 {
        var hash = self.cpu.stateDigest();
        hash = (hash ^ self.status()) *% 0x0000_0100_0000_01b3;
        hash = (hash ^ self.timer) *% 0x0000_0100_0000_01b3;
        for (self.work_ram) |value| hash = (hash ^ value) *% 0x0000_0100_0000_01b3;
        return hash;
    }

    // ARMv3 bus interface. The CPU core calls these methods generically.
    pub fn readWord(self: *Device, address: u32, prefetch: bool) armv3.ReadResult {
        self.tick();
        const aligned = address & ~@as(u32, 3);
        const value = @as(u32, self.readArmByte(aligned)) |
            (@as(u32, self.readArmByte(aligned +% 1)) << 8) |
            (@as(u32, self.readArmByte(aligned +% 2)) << 16) |
            (@as(u32, self.readArmByte(aligned +% 3)) << 24);
        if (prefetch) self.last_prefetch = value;
        return .{ .value = value };
    }

    pub fn readByte(self: *Device, address: u32, prefetch: bool) armv3.ReadResult {
        self.tick();
        const value = self.readArmByte(address);
        if (prefetch) self.last_prefetch = value;
        return .{ .value = value };
    }

    pub fn writeWord(self: *Device, address: u32, value: u32) bool {
        self.tick();
        const aligned = address & ~@as(u32, 3);
        self.writeArmByte(aligned, @truncate(value));
        self.writeArmByte(aligned +% 1, @truncate(value >> 8));
        self.writeArmByte(aligned +% 2, @truncate(value >> 16));
        self.writeArmByte(aligned +% 3, @truncate(value >> 24));
        return false;
    }

    pub fn writeByte(self: *Device, address: u32, value: u8) bool {
        self.tick();
        self.writeArmByte(address, value);
        return false;
    }

    pub fn idle(self: *Device) void {
        self.tick();
    }

    fn tick(self: *Device) void {
        self.cycles +%= 1;
        self.arm_accesses +%= 1;
        if (self.timer != 0) self.timer -%= 1;
    }

    fn readArmByte(self: *Device, address: u32) u8 {
        return switch (address & 0xe000_0000) {
            0x0000_0000 => self.program_rom[@as(usize, address & 0x1ffff)],
            0x2000_0000, 0x8000_0000, 0xc000_0000 => byteOfWord(self.last_prefetch, address),
            0x4000_0000 => self.readArmIo(address),
            0x6000_0000 => byteOfWord(0x4040_4001, address),
            0xa000_0000 => self.data_rom[@as(usize, address & 0x7fff)],
            0xe000_0000 => self.work_ram[@as(usize, address & 0x3fff)],
            else => 0,
        };
    }

    fn writeArmByte(self: *Device, address: u32, value: u8) void {
        switch (address & 0xe000_0000) {
            0x4000_0000 => self.writeArmIo(address, value),
            0xe000_0000 => {
                const index = @as(usize, address & 0x3fff);
                if (self.work_ram[index] == value) return;
                self.work_ram[index] = value;
                self.markDirty(index, index + 1);
            },
            else => {},
        }
    }

    fn readArmIo(self: *Device, address: u32) u8 {
        return switch (address & 0x3f) {
            0x10 => blk: {
                if (!self.cpu_to_arm_ready) self.host_conflicts +%= 1;
                self.cpu_to_arm_ready = false;
                break :blk self.cpu_to_arm_data;
            },
            0x20 => self.status(),
            else => 0,
        };
    }

    fn writeArmIo(self: *Device, address: u32, value: u8) void {
        switch (address & 0x3f) {
            0x00 => {
                if (self.arm_to_cpu_ready) self.host_conflicts +%= 1;
                self.arm_to_cpu_data = value;
                self.arm_to_cpu_ready = true;
            },
            0x10 => self.signal = true,
            0x20 => self.timer_latch = (self.timer_latch & 0xffff_ff00) | value,
            0x24 => self.timer_latch = (self.timer_latch & 0xffff_00ff) | (@as(u32, value) << 8),
            0x28 => self.timer_latch = (self.timer_latch & 0xff00_ffff) | (@as(u32, value) << 16),
            0x2c => self.timer = self.timer_latch,
            else => {},
        }
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
};

pub fn validateFirmware(bytes: []const u8, validation: FirmwareValidation, source: FirmwareSource) ![32]u8 {
    if (bytes.len != firmware_bytes) return error.InvalidSt018FirmwareSize;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    if (validation == .allow_open_test) {
        if (source != .open_test) return error.InvalidSt018FirmwarePolicy;
        return digest;
    }
    const expected = knownDigest();
    if (!std.mem.eql(u8, &digest, &expected)) return error.InvalidSt018FirmwareDigest;
    return digest;
}

pub fn knownDigest() [32]u8 {
    return digestFromHex("6df209ab5d2524d1839c038be400ae5eb20dafc14a3771a3239cd9e8acd53806");
}

fn hostPort(address: u32) ?u3 {
    if (address > 0x00ff_ffff) return null;
    const bank: u8 = @truncate(address >> 16);
    const offset: u16 = @truncate(address);
    if (!((bank <= 0x3f) or (bank >= 0x80 and bank <= 0xbf))) return null;
    if (offset < 0x3800 or offset > 0x38ff) return null;
    return @truncate(offset & 0x0006);
}

fn byteOfWord(value: u32, address: u32) u8 {
    const amount: u5 = @intCast((address & 3) * 8);
    return @truncate(value >> amount);
}

fn digestFromHex(comptime text: []const u8) [32]u8 {
    if (text.len != 64) @compileError("SHA-256 text must contain 64 hexadecimal characters");
    var result: [32]u8 = undefined;
    for (0..32) |index| result[index] = (hexNibble(text[index * 2]) << 4) | hexNibble(text[index * 2 + 1]);
    return result;
}

fn hexNibble(value: u8) u8 {
    return switch (value) {
        '0'...'9' => value - '0',
        'a'...'f' => value - 'a' + 10,
        'A'...'F' => value - 'A' + 10,
        else => unreachable,
    };
}
