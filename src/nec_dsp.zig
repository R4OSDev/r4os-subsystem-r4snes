const std = @import("std");
const board = @import("board.zig");

pub const access_master_cycles: u8 = 8;
pub const frequency_hz: u32 = 7_600_000;
pub const firmware_bytes: usize = 0x2000;
pub const program_bytes: usize = 0x1800;
pub const data_bytes: usize = 0x0800;
pub const program_words: usize = program_bytes / 3;
pub const data_words: usize = data_bytes / 2;
pub const data_ram_words: usize = 0x100;
pub const stack_words: usize = 4;
pub const st_firmware_bytes: usize = 0xd000;
pub const st_program_bytes: usize = 0xc000;
pub const st_data_bytes: usize = 0x1000;
pub const st_program_words: usize = st_program_bytes / 3;
pub const st_data_words: usize = st_data_bytes / 2;
pub const st_data_ram_words: usize = 0x800;
pub const st_data_ram_bytes: usize = st_data_ram_words * 2;
pub const st_stack_words: usize = 16;
pub const st010_frequency_hz: u32 = 11_000_000;
pub const st011_frequency_hz: u32 = 15_000_000;

pub const Revision = enum {
    dsp1,
    dsp1a,
    dsp1b,
    dsp2,
    dsp3,
    dsp4,
    st010,
    st011,

    pub fn chipName(self: Revision) []const u8 {
        return switch (self) {
            .dsp1 => "DSP-1",
            .dsp1a => "DSP-1A",
            .dsp1b => "DSP-1B",
            .dsp2 => "DSP-2",
            .dsp3 => "DSP-3",
            .dsp4 => "DSP-4",
            .st010 => "ST010",
            .st011 => "ST011",
        };
    }

    pub fn fileName(self: Revision) []const u8 {
        return switch (self) {
            .dsp1 => "DSP1.ROM",
            .dsp1a => "DSP1A.ROM",
            .dsp1b => "DSP1B.ROM",
            .dsp2 => "DSP2.ROM",
            .dsp3 => "DSP3.ROM",
            .dsp4 => "DSP4.ROM",
            .st010 => "ST010.ROM",
            .st011 => "ST011.ROM",
        };
    }

    pub fn firmwarePath(self: Revision) []const u8 {
        return switch (self) {
            .dsp1 => firmware_root ++ "DSP1.ROM",
            .dsp1a => firmware_root ++ "DSP1A.ROM",
            .dsp1b => firmware_root ++ "DSP1B.ROM",
            .dsp2 => firmware_root ++ "DSP2.ROM",
            .dsp3 => firmware_root ++ "DSP3.ROM",
            .dsp4 => firmware_root ++ "DSP4.ROM",
            .st010 => firmware_root ++ "ST010.ROM",
            .st011 => firmware_root ++ "ST011.ROM",
        };
    }

    pub fn knownDigest(self: Revision) [32]u8 {
        return switch (self) {
            // DSP-1 and DSP-1A are package revisions with identical code.
            .dsp1, .dsp1a => digestFromHex("91e87d11e1c30d172556bed2211cce2efa94ba595f58c5d264809ef4d363a97b"),
            .dsp1b => digestFromHex("d789cb3c36b05c0b23b6c6f23be7aa37c6e78b6ee9ceac8d2d2aa9d8c4d35fa9"),
            .dsp2 => digestFromHex("03ef4ef26c9f701346708cb5d07847b5203cf1b0818bf2930acd34510ffdd717"),
            .dsp3 => digestFromHex("0971b08f396c32e61989d1067dddf8e4b14649d548b2188f7c541b03d7c69e4e"),
            .dsp4 => digestFromHex("752d03b2d74441e430b7f713001fa241f8bbcfc1a0d890ed4143f174dbe031da"),
            .st010 => digestFromHex("fa9bced838fedea11c6f6ace33d1878024bdd0d02cc9485899d0bdd4015ec24c"),
            .st011 => digestFromHex("8b2b3f3f3e6e29f4d21d8bc736b400bc988b7d2214ebee15643f01c1fee2f364"),
        };
    }

    pub fn isSt01x(self: Revision) bool {
        return self == .st010 or self == .st011;
    }

    pub fn firmwareBytes(self: Revision) usize {
        return if (self.isSt01x()) st_firmware_bytes else firmware_bytes;
    }

    pub fn programBytes(self: Revision) usize {
        return if (self.isSt01x()) st_program_bytes else program_bytes;
    }

    pub fn programWords(self: Revision) usize {
        return if (self.isSt01x()) st_program_words else program_words;
    }

    pub fn dataWords(self: Revision) usize {
        return if (self.isSt01x()) st_data_words else data_words;
    }

    pub fn dataRamWords(self: Revision) usize {
        return if (self.isSt01x()) st_data_ram_words else data_ram_words;
    }

    pub fn stackWords(self: Revision) usize {
        return if (self.isSt01x()) st_stack_words else stack_words;
    }

    pub fn frequencyHz(self: Revision) u32 {
        return switch (self) {
            .st010 => st010_frequency_hz,
            .st011 => st011_frequency_hz,
            else => frequency_hz,
        };
    }
};

pub const firmware_root = "C:\\R4OS\\SUBSYSTEMS\\r4os.snes\\FIRMWARE\\";

pub const FirmwareValidation = enum {
    known_only,
    /// Restricted to checked-in, original owner tests. Product callers must
    /// never select this policy for user-provided firmware.
    allow_open_test,
};

pub const FirmwareSource = enum {
    separate,
    appended,
    open_test,
};

pub const HostMap = enum {
    dsp1_lo_small,
    dsp1_lo_small_ram,
    dsp1_lo_large,
    dsp1_hi,
    dsp2,
    dsp3,
    dsp4,
    st01x,
};

pub const OpcodeClass = enum {
    operation,
    operation_return,
    jump,
    immediate_load,
};

pub const RunState = enum {
    budget_exhausted,
    waiting_host,
    closed,
};

pub const RunResult = struct {
    state: RunState,
    executed: usize,
    total_cycles: u64,
};

pub const Flags = struct {
    overflow0: bool = false,
    overflow1: bool = false,
    zero: bool = false,
    carry: bool = false,
    sign0: bool = false,
    sign1: bool = false,

    pub fn bits(self: Flags) u8 {
        return @as(u8, @intFromBool(self.overflow0)) |
            (@as(u8, @intFromBool(self.overflow1)) << 1) |
            (@as(u8, @intFromBool(self.zero)) << 2) |
            (@as(u8, @intFromBool(self.carry)) << 3) |
            (@as(u8, @intFromBool(self.sign0)) << 4) |
            (@as(u8, @intFromBool(self.sign1)) << 5);
    }
};

const status_p0: u16 = 0x0001;
const status_p1: u16 = 0x0002;
const status_ei: u16 = 0x0080;
const status_sic: u16 = 0x0100;
const status_soc: u16 = 0x0200;
const status_drc: u16 = 0x0400;
const status_dma: u16 = 0x0800;
const status_drs: u16 = 0x1000;
const status_usf0: u16 = 0x2000;
const status_usf1: u16 = 0x4000;
const status_rqm: u16 = 0x8000;
const status_ld_preserve: u16 = 0x907c;

pub const Device = struct {
    allocator: ?std.mem.Allocator = null,
    revision: Revision = .dsp1b,
    host_map: HostMap = .dsp1_lo_small,
    program_rom: []u24 = &.{},
    data_rom: []u16 = &.{},
    data_ram: []u16 = &.{},
    stack: []u16 = &.{},
    firmware_digest: [32]u8 = [_]u8{0} ** 32,
    firmware_source: FirmwareSource = .separate,
    firmware_installed: bool = false,

    pc: u16 = 0,
    rp: u16 = 0,
    dp: u16 = 0,
    sp: u8 = 0,
    serial_input: u16 = 0,
    serial_output: u16 = 0,
    k: u16 = 0,
    l: u16 = 0,
    m: u16 = 0,
    n: u16 = 0,
    a: u16 = 0,
    b: u16 = 0,
    tr: u16 = 0,
    trb: u16 = 0,
    dr: u16 = 0,
    sr: u16 = 0,
    flags_a: Flags = .{},
    flags_b: Flags = .{},
    serial_input_ack: bool = false,
    serial_output_ack: bool = false,
    waiting_host: bool = false,
    closed: bool = false,

    cycles: u64 = 0,
    instructions: u64 = 0,
    host_reads: u64 = 0,
    host_writes: u64 = 0,
    status_writes: u64 = 0,
    reserved_branches: u64 = 0,
    resets: u64 = 0,
    data_ram_dirty: bool = false,
    data_ram_dirty_first: usize = 0,
    data_ram_dirty_end: usize = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        revision: Revision,
        mapping: board.Mapping,
        rom_size: usize,
        sram_size: usize,
        bytes: []const u8,
        validation: FirmwareValidation,
        source: FirmwareSource,
    ) !Device {
        var result = Device{
            .allocator = allocator,
            .revision = revision,
            .host_map = try selectHostMap(revision, mapping, rom_size, sram_size),
            .firmware_source = source,
        };
        result.program_rom = try allocator.alloc(u24, revision.programWords());
        errdefer allocator.free(result.program_rom);
        result.data_rom = try allocator.alloc(u16, revision.dataWords());
        errdefer allocator.free(result.data_rom);
        result.data_ram = try allocator.alloc(u16, revision.dataRamWords());
        errdefer allocator.free(result.data_ram);
        result.stack = try allocator.alloc(u16, revision.stackWords());
        errdefer allocator.free(result.stack);
        @memset(result.program_rom, 0);
        @memset(result.data_rom, 0);
        @memset(result.data_ram, 0);
        @memset(result.stack, 0);
        try result.installFirmware(bytes, validation);
        return result;
    }

    pub fn installFirmware(self: *Device, bytes: []const u8, validation: FirmwareValidation) !void {
        if (bytes.len != self.revision.firmwareBytes()) return error.InvalidNecDspFirmwareSize;
        var actual: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &actual, .{});
        if (validation == .known_only and !std.mem.eql(u8, &actual, &self.revision.knownDigest()))
            return error.InvalidNecDspFirmwareDigest;

        for (0..self.revision.programWords()) |index| {
            const offset = index * 3;
            self.program_rom[index] = @as(u24, bytes[offset]) |
                (@as(u24, bytes[offset + 1]) << 8) |
                (@as(u24, bytes[offset + 2]) << 16);
        }
        for (0..self.revision.dataWords()) |index| {
            const offset = self.revision.programBytes() + index * 2;
            self.data_rom[index] = @as(u16, bytes[offset]) |
                (@as(u16, bytes[offset + 1]) << 8);
        }
        self.firmware_digest = actual;
        self.firmware_installed = true;
        self.power();
    }

    pub fn power(self: *Device) void {
        @memset(self.data_ram, 0);
        self.resetExecutionState();
        self.data_ram_dirty = false;
        self.data_ram_dirty_first = 0;
        self.data_ram_dirty_end = 0;
    }

    fn resetExecutionState(self: *Device) void {
        @memset(self.stack, 0);
        self.pc = 0;
        self.rp = 0;
        self.dp = 0;
        self.sp = 0;
        self.serial_input = 0;
        self.serial_output = 0;
        self.k = 0;
        self.l = 0;
        self.m = 0;
        self.n = 0;
        self.a = 0;
        self.b = 0;
        self.tr = 0;
        self.trb = 0;
        self.dr = 0;
        self.sr = 0;
        self.flags_a = .{};
        self.flags_b = .{};
        self.serial_input_ack = false;
        self.serial_output_ack = false;
        self.waiting_host = false;
        self.closed = false;
        self.cycles = 0;
        self.instructions = 0;
        self.host_reads = 0;
        self.host_writes = 0;
        self.status_writes = 0;
        self.reserved_branches = 0;
        self.resets = 0;
    }

    /// The external reset pin resets the execution state but deliberately
    /// retains the installed ROMs and immutable firmware identity.
    pub fn reset(self: *Device) void {
        const reset_count = self.resets +% 1;
        const source = self.firmware_source;
        const dirty = self.data_ram_dirty;
        const dirty_first = self.data_ram_dirty_first;
        const dirty_end = self.data_ram_dirty_end;
        if (self.revision.isSt01x()) {
            self.resetExecutionState();
            self.data_ram_dirty = dirty;
            self.data_ram_dirty_first = dirty_first;
            self.data_ram_dirty_end = dirty_end;
        } else {
            self.power();
        }
        self.firmware_source = source;
        self.resets = reset_count;
    }

    pub fn close(self: *Device) void {
        if (self.closed) return;
        @memset(self.program_rom, 0);
        @memset(self.data_rom, 0);
        @memset(self.data_ram, 0);
        @memset(self.stack, 0);
        @memset(&self.firmware_digest, 0);
        if (self.allocator) |allocator| {
            allocator.free(self.program_rom);
            allocator.free(self.data_rom);
            allocator.free(self.data_ram);
            allocator.free(self.stack);
        }
        self.program_rom = &.{};
        self.data_rom = &.{};
        self.data_ram = &.{};
        self.stack = &.{};
        self.allocator = null;
        self.firmware_installed = false;
        self.waiting_host = false;
        self.data_ram_dirty = false;
        self.data_ram_dirty_first = 0;
        self.data_ram_dirty_end = 0;
        self.closed = true;
    }

    pub fn runSlice(self: *Device, maximum_instructions: usize) RunResult {
        if (self.closed) return .{ .state = .closed, .executed = 0, .total_cycles = self.cycles };
        if (self.waiting_host and self.rqmConditionStillBlocks())
            return .{ .state = .waiting_host, .executed = 0, .total_cycles = self.cycles };
        self.waiting_host = false;

        var executed: usize = 0;
        while (executed < maximum_instructions) : (executed += 1) {
            self.step();
            if (self.waiting_host) {
                return .{ .state = .waiting_host, .executed = executed + 1, .total_cycles = self.cycles };
            }
        }
        return .{ .state = .budget_exhausted, .executed = executed, .total_cycles = self.cycles };
    }

    pub fn step(self: *Device) void {
        if (self.closed or !self.firmware_installed) return;
        const program_mask = self.programMask();
        const opcode = self.program_rom[self.pc & program_mask];
        self.pc = (self.pc +% 1) & program_mask;
        _ = self.executeOpcode(opcode);
        self.updateMultiplier();
        self.cycles +%= 1;
        self.instructions +%= 1;
    }

    pub fn executeOpcode(self: *Device, raw_opcode: u24) OpcodeClass {
        return switch (raw_opcode >> 22) {
            0 => blk: {
                self.executeOperation(raw_opcode);
                break :blk .operation;
            },
            1 => blk: {
                self.executeOperation(raw_opcode);
                self.sp = (self.sp -% 1) & self.stackMask();
                self.pc = self.stack[self.sp] & self.programMask();
                break :blk .operation_return;
            },
            2 => blk: {
                self.executeJump(raw_opcode);
                break :blk .jump;
            },
            3 => blk: {
                self.loadDestination(@truncate(raw_opcode), @truncate(raw_opcode >> 6));
                break :blk .immediate_load;
            },
            else => unreachable,
        };
    }

    pub fn readCpu(self: *Device, address: u32, _: u8) ?u8 {
        if (self.closed or !self.firmware_installed) return null;
        if (self.stRamByteIndex(address)) |index| {
            self.host_reads +%= 1;
            return self.readRamByte(index);
        }
        const port = self.decodePort(address) orelse return null;
        self.host_reads +%= 1;
        self.waiting_host = false;
        return switch (port) {
            .data => self.readData(),
            .status => self.readStatus(),
        };
    }

    pub fn writeCpu(self: *Device, address: u32, value: u8) bool {
        if (self.closed or !self.firmware_installed) return false;
        if (self.stRamByteIndex(address)) |index| {
            self.host_writes +%= 1;
            self.writeRamByte(index, value);
            return true;
        }
        const port = self.decodePort(address) orelse return false;
        self.host_writes +%= 1;
        self.waiting_host = false;
        switch (port) {
            .data => self.writeData(value),
            .status => self.status_writes +%= 1,
        }
        return true;
    }

    pub fn readStatus(self: *const Device) u8 {
        var visible = self.sr;
        if ((visible & status_drc) != 0) visible &= ~status_drs;
        return @truncate(visible >> 8);
    }

    pub fn requestForMaster(self: *const Device) bool {
        return (self.sr & status_rqm) != 0;
    }

    pub fn busy(self: *const Device) bool {
        return !self.requestForMaster();
    }

    pub fn frequencyHz(self: *const Device) u32 {
        return self.revision.frequencyHz();
    }

    pub fn takeDirtyRange(self: *Device) ?struct { first: usize, end: usize } {
        if (!self.data_ram_dirty) return null;
        const first = self.data_ram_dirty_first;
        const end = self.data_ram_dirty_end;
        self.data_ram_dirty = false;
        self.data_ram_dirty_first = 0;
        self.data_ram_dirty_end = 0;
        return .{ .first = first, .end = end };
    }

    pub fn restorePersistentRam(self: *Device, bytes: []const u8) !void {
        if (!self.revision.isSt01x() or bytes.len != st_data_ram_bytes)
            return error.InvalidNecDspPersistentRamSize;
        for (self.data_ram, 0..) |*word, index| {
            const offset = index * 2;
            word.* = @as(u16, bytes[offset]) | (@as(u16, bytes[offset + 1]) << 8);
        }
        self.data_ram_dirty = false;
        self.data_ram_dirty_first = 0;
        self.data_ram_dirty_end = 0;
    }

    pub fn copyPersistentRamRange(self: *const Device, destination: []u8, first: usize, end: usize) !void {
        if (!self.revision.isSt01x() or destination.len != st_data_ram_bytes or first > end or end > destination.len)
            return error.InvalidNecDspPersistentRamSize;
        var index = first;
        while (index < end) : (index += 1) destination[index] = self.readRamByte(index);
    }

    pub fn stateDigest(self: *const Device) u64 {
        var result: u64 = 0xcbf29ce484222325;
        hashByte(&result, @intFromEnum(self.revision));
        hashByte(&result, @intFromEnum(self.host_map));
        hashByte(&result, @intFromEnum(self.firmware_source));
        hashByte(&result, @intFromBool(self.firmware_installed));
        for (self.firmware_digest) |value| hashByte(&result, value);
        for (self.data_ram) |value| hashWord(&result, value);
        for (self.stack) |value| hashWord(&result, value);
        const words = [_]u16{
            self.pc, self.rp, self.dp,  self.serial_input, self.serial_output,
            self.k,  self.l,  self.m,   self.n,            self.a,
            self.b,  self.tr, self.trb, self.dr,           self.sr,
        };
        for (words) |value| hashWord(&result, value);
        hashByte(&result, self.sp);
        hashByte(&result, self.flags_a.bits());
        hashByte(&result, self.flags_b.bits());
        hashByte(&result, @intFromBool(self.serial_input_ack));
        hashByte(&result, @intFromBool(self.serial_output_ack));
        hashByte(&result, @intFromBool(self.waiting_host));
        hashByte(&result, @intFromBool(self.closed));
        hashQword(&result, self.cycles);
        hashQword(&result, self.instructions);
        hashQword(&result, self.host_reads);
        hashQword(&result, self.host_writes);
        hashQword(&result, self.status_writes);
        hashQword(&result, self.reserved_branches);
        hashQword(&result, self.resets);
        return result;
    }

    fn executeOperation(self: *Device, opcode: u24) void {
        const p_select: u2 = @truncate(opcode >> 20);
        const alu: u4 = @truncate(opcode >> 16);
        const accumulator_select = ((opcode >> 15) & 1) != 0;
        const dp_low: u2 = @truncate(opcode >> 13);
        const dp_high: u4 = @truncate(opcode >> 9);
        const decrement_rp = ((opcode >> 8) & 1) != 0;
        const source: u4 = @truncate(opcode >> 4);
        const destination: u4 = @truncate(opcode);
        const value = self.sourceValue(source);

        if (alu != 0) self.runAlu(alu, p_select, accumulator_select, value);
        self.loadDestination(destination, value);

        if (destination != 4) {
            var next = self.dp;
            switch (dp_low) {
                0 => {},
                1 => next = (next & 0x7f0) | ((next +% 1) & 0x0f),
                2 => next = (next & 0x7f0) | ((next -% 1) & 0x0f),
                3 => next &= 0x7f0,
            }
            self.dp = (next ^ (@as(u16, dp_high) << 4)) & self.dataRamMask();
        }
        if (destination != 5 and decrement_rp) self.rp = (self.rp -% 1) & self.dataRomMask();
    }

    fn sourceValue(self: *Device, source: u4) u16 {
        return switch (source) {
            0 => self.trb,
            1 => self.a,
            2 => self.b,
            3 => self.tr,
            4 => self.dp,
            5 => self.rp,
            6 => self.data_rom[self.rp & self.dataRomMask()],
            7 => @as(u16, 0x8000) - @as(u16, @intFromBool(self.flags_a.sign1)),
            8 => blk: {
                self.sr |= status_rqm;
                break :blk self.dr;
            },
            9 => self.dr,
            10 => self.sr,
            11, 12 => self.serial_input,
            13 => self.k,
            14 => self.l,
            15 => self.data_ram[self.dp & self.dataRamMask()],
        };
    }

    fn loadDestination(self: *Device, destination: u4, value: u16) void {
        switch (destination) {
            0 => {},
            1 => self.a = value,
            2 => self.b = value,
            3 => self.tr = value,
            4 => self.dp = value & self.dataRamMask(),
            5 => self.rp = value & self.dataRomMask(),
            6 => {
                self.dr = value;
                self.sr |= status_rqm;
            },
            7 => self.sr = (self.sr & status_ld_preserve) | (value & ~status_ld_preserve),
            8, 9 => self.serial_output = value,
            10 => self.k = value,
            11 => {
                self.k = value;
                self.l = self.data_rom[self.rp & self.dataRomMask()];
            },
            12 => {
                self.l = value;
                self.k = self.data_ram[(self.dp | 0x40) & self.dataRamMask()];
            },
            13 => self.l = value,
            14 => self.trb = value,
            15 => self.writeRamWord(self.dp & self.dataRamMask(), value),
        }
    }

    fn runAlu(self: *Device, operation: u4, p_select: u2, select_b: bool, source: u16) void {
        var flags = if (select_b) self.flags_b else self.flags_a;
        const other_carry = if (select_b) self.flags_a.carry else self.flags_b.carry;
        const accumulator = if (select_b) self.b else self.a;
        var operand: u16 = switch (p_select) {
            0 => self.data_ram[self.dp & self.dataRamMask()],
            1 => source,
            2 => self.m,
            3 => self.n,
        };
        var result: u16 = switch (operation) {
            1 => accumulator | operand,
            2 => accumulator & operand,
            3 => accumulator ^ operand,
            4 => accumulator -% operand,
            5 => accumulator +% operand,
            6 => accumulator -% operand -% @as(u16, @intFromBool(other_carry)),
            7 => accumulator +% operand +% @as(u16, @intFromBool(other_carry)),
            8 => blk: {
                operand = 1;
                break :blk accumulator -% 1;
            },
            9 => blk: {
                operand = 1;
                break :blk accumulator +% 1;
            },
            10 => ~accumulator,
            11 => (accumulator >> 1) | (accumulator & 0x8000),
            12 => (accumulator << 1) | @as(u16, @intFromBool(other_carry)),
            13 => (accumulator << 2) | 3,
            14 => (accumulator << 4) | 15,
            15 => (accumulator << 8) | (accumulator >> 8),
            else => accumulator,
        };
        result &= 0xffff;
        flags.zero = result == 0;
        flags.sign0 = (result & 0x8000) != 0;
        if (!flags.overflow1) flags.sign1 = flags.sign0;

        switch (operation) {
            1, 2, 3, 10, 13, 14, 15 => {
                flags.overflow0 = false;
                flags.overflow1 = false;
                flags.carry = false;
            },
            4, 5, 6, 7, 8, 9 => {
                const carries = accumulator ^ operand ^ result;
                const overflow = (accumulator ^ result) &
                    (operand ^ (if ((operation & 1) != 0) result else accumulator));
                flags.overflow0 = (overflow & 0x8000) != 0;
                flags.overflow1 = if (flags.overflow0 and flags.overflow1)
                    flags.sign0 == flags.sign1
                else
                    flags.overflow0 or flags.overflow1;
                flags.carry = ((carries ^ overflow) & 0x8000) != 0;
            },
            11 => {
                flags.overflow0 = false;
                flags.overflow1 = false;
                flags.carry = (accumulator & 1) != 0;
            },
            12 => {
                flags.overflow0 = false;
                flags.overflow1 = false;
                flags.carry = (accumulator & 0x8000) != 0;
            },
            else => {},
        }
        if (select_b) {
            self.b = result;
            self.flags_b = flags;
        } else {
            self.a = result;
            self.flags_a = flags;
        }
    }

    fn executeJump(self: *Device, opcode: u24) void {
        const branch: u9 = @truncate(opcode >> 13);
        const next_address: u11 = @truncate(opcode >> 2);
        const bank: u2 = @truncate(opcode);
        const program_mask = self.programMask();
        const target: u16 = ((self.pc & 0x2000) | (@as(u16, bank) << 11) | @as(u16, next_address)) & program_mask;
        var taken: ?bool = null;
        switch (branch) {
            0x000 => self.pc = self.serial_output & program_mask,
            0x080 => taken = !self.flags_a.carry,
            0x082 => taken = self.flags_a.carry,
            0x084 => taken = !self.flags_b.carry,
            0x086 => taken = self.flags_b.carry,
            0x088 => taken = !self.flags_a.zero,
            0x08a => taken = self.flags_a.zero,
            0x08c => taken = !self.flags_b.zero,
            0x08e => taken = self.flags_b.zero,
            0x090 => taken = !self.flags_a.overflow0,
            0x092 => taken = self.flags_a.overflow0,
            0x094 => taken = !self.flags_b.overflow0,
            0x096 => taken = self.flags_b.overflow0,
            0x098 => taken = !self.flags_a.overflow1,
            0x09a => taken = self.flags_a.overflow1,
            0x09c => taken = !self.flags_b.overflow1,
            0x09e => taken = self.flags_b.overflow1,
            0x0a0 => taken = !self.flags_a.sign0,
            0x0a2 => taken = self.flags_a.sign0,
            0x0a4 => taken = !self.flags_b.sign0,
            0x0a6 => taken = self.flags_b.sign0,
            0x0a8 => taken = !self.flags_a.sign1,
            0x0aa => taken = self.flags_a.sign1,
            0x0ac => taken = !self.flags_b.sign1,
            0x0ae => taken = self.flags_b.sign1,
            0x0b0 => taken = (self.dp & 0x0f) == 0,
            0x0b1 => taken = (self.dp & 0x0f) != 0,
            0x0b2 => taken = (self.dp & 0x0f) == 0x0f,
            0x0b3 => taken = (self.dp & 0x0f) != 0x0f,
            0x0b4 => taken = !self.serial_input_ack,
            0x0b6 => taken = self.serial_input_ack,
            0x0b8 => taken = !self.serial_output_ack,
            0x0ba => taken = self.serial_output_ack,
            0x0bc => taken = !self.requestForMaster(),
            0x0be => taken = self.requestForMaster(),
            0x100 => self.pc = target & ~@as(u16, 0x2000),
            0x101 => self.pc = (target | 0x2000) & program_mask,
            0x140, 0x141 => {
                const stack_mask = self.stackMask();
                self.stack[self.sp & stack_mask] = self.pc;
                self.sp = (self.sp +% 1) & stack_mask;
                self.pc = if (branch == 0x140)
                    target & ~@as(u16, 0x2000)
                else
                    (target | 0x2000) & program_mask;
            },
            else => self.reserved_branches +%= 1,
        }
        if (taken) |condition| {
            if (condition) {
                const previous_pc = (self.pc -% 1) & program_mask;
                self.pc = target;
                if ((branch == 0x0bc or branch == 0x0be) and target == previous_pc)
                    self.waiting_host = true;
            }
        }
    }

    fn updateMultiplier(self: *Device) void {
        const signed_k: i16 = @bitCast(self.k);
        const signed_l: i16 = @bitCast(self.l);
        const product: i32 = @as(i32, signed_k) * @as(i32, signed_l);
        self.m = @truncate(@as(u32, @bitCast(product >> 15)));
        self.n = @truncate(@as(u32, @bitCast(product)) << 1);
    }

    fn readData(self: *Device) u8 {
        if ((self.sr & status_drc) == 0) {
            if ((self.sr & status_drs) == 0) {
                self.sr |= status_drs;
                return @truncate(self.dr);
            }
            self.sr &= ~(status_rqm | status_drs);
            return @truncate(self.dr >> 8);
        }
        self.sr &= ~status_rqm;
        return @truncate(self.dr);
    }

    fn writeData(self: *Device, value: u8) void {
        if ((self.sr & status_drc) == 0) {
            if ((self.sr & status_drs) == 0) {
                self.sr |= status_drs;
                self.dr = (self.dr & 0xff00) | value;
                return;
            }
            self.sr &= ~(status_rqm | status_drs);
            self.dr = (self.dr & 0x00ff) | (@as(u16, value) << 8);
            return;
        }
        self.sr &= ~status_rqm;
        self.dr = (self.dr & 0xff00) | value;
    }

    const Port = enum { data, status };

    fn decodePort(self: *const Device, address: u32) ?Port {
        if (address > 0x00ff_ffff) return null;
        const bank: u8 = @truncate(address >> 16);
        const offset: u16 = @truncate(address);
        return switch (self.host_map) {
            .dsp1_lo_small => if (((bank >= 0x30 and bank <= 0x3f) or
                (bank >= 0xb0 and bank <= 0xbf)) and offset >= 0x8000)
                if (offset < 0xc000) .data else .status
            else
                null,
            .dsp1_lo_small_ram => if (((bank >= 0x20 and bank <= 0x3f) or
                (bank >= 0xa0 and bank <= 0xbf)) and offset >= 0x8000)
                if (offset < 0xc000) .data else .status
            else
                null,
            .dsp1_lo_large => if (((bank >= 0x60 and bank <= 0x6f) or
                (bank >= 0xe0 and bank <= 0xef)) and offset < 0x8000)
                if (offset < 0x4000) .data else .status
            else
                null,
            .dsp1_hi => if ((bank <= 0x1f or (bank >= 0x80 and bank <= 0x9f)) and
                offset >= 0x6000 and offset < 0x8000)
                if (offset < 0x7000) .data else .status
            else
                null,
            .dsp2 => if (((bank >= 0x20 and bank <= 0x3f) or
                (bank >= 0xa0 and bank <= 0xbf)) and
                ((offset >= 0x6000 and offset < 0x7000) or offset >= 0x8000))
                if (offset < 0xc000) .data else .status
            else
                null,
            .dsp3 => if (((bank >= 0x20 and bank <= 0x3f) or
                (bank >= 0xa0 and bank <= 0xbf)) and offset >= 0x8000)
                if (offset < 0xc000) .data else .status
            else
                null,
            .dsp4 => if (((bank >= 0x30 and bank <= 0x3f) or
                (bank >= 0xb0 and bank <= 0xbf)) and offset >= 0x8000)
                if (offset < 0xc000) .data else .status
            else
                null,
            .st01x => if (((bank >= 0x60 and bank <= 0x67) or
                (bank >= 0xe0 and bank <= 0xe7)) and offset < 0x4000)
                if ((offset & 1) == 0) .data else .status
            else
                null,
        };
    }

    fn rqmConditionStillBlocks(self: *const Device) bool {
        const opcode = self.program_rom[self.pc & self.programMask()];
        if ((opcode >> 22) != 2) return false;
        const branch: u9 = @truncate(opcode >> 13);
        return (branch == 0x0bc and !self.requestForMaster()) or
            (branch == 0x0be and self.requestForMaster());
    }

    fn programMask(self: *const Device) u16 {
        return @intCast(self.program_rom.len - 1);
    }

    fn dataRomMask(self: *const Device) u16 {
        return @intCast(self.data_rom.len - 1);
    }

    fn dataRamMask(self: *const Device) u16 {
        return @intCast(self.data_ram.len - 1);
    }

    fn stackMask(self: *const Device) u8 {
        return @intCast(self.stack.len - 1);
    }

    fn stRamByteIndex(self: *const Device, address: u32) ?usize {
        if (!self.revision.isSt01x() or address > 0x00ff_ffff) return null;
        const bank: u8 = @truncate(address >> 16);
        const offset: u16 = @truncate(address);
        if (!((bank >= 0x68 and bank <= 0x6f) or (bank >= 0xe8 and bank <= 0xef)) or offset >= 0x8000)
            return null;
        return @as(usize, offset & 0x0fff);
    }

    fn readRamByte(self: *const Device, index: usize) u8 {
        const word = self.data_ram[(index >> 1) & @as(usize, self.dataRamMask())];
        return if ((index & 1) == 0) @truncate(word) else @truncate(word >> 8);
    }

    fn writeRamByte(self: *Device, index: usize, value: u8) void {
        const word_index = (index >> 1) & @as(usize, self.dataRamMask());
        const old = self.data_ram[word_index];
        const next = if ((index & 1) == 0)
            (old & 0xff00) | @as(u16, value)
        else
            (old & 0x00ff) | (@as(u16, value) << 8);
        if (old == next) return;
        self.data_ram[word_index] = next;
        self.markRamDirty(index, index + 1);
    }

    fn writeRamWord(self: *Device, index: usize, value: u16) void {
        const word_index = index & @as(usize, self.dataRamMask());
        if (self.data_ram[word_index] == value) return;
        self.data_ram[word_index] = value;
        self.markRamDirty(word_index * 2, word_index * 2 + 2);
    }

    fn markRamDirty(self: *Device, first: usize, end: usize) void {
        if (!self.revision.isSt01x()) return;
        if (!self.data_ram_dirty) {
            self.data_ram_dirty = true;
            self.data_ram_dirty_first = first;
            self.data_ram_dirty_end = end;
            return;
        }
        self.data_ram_dirty_first = @min(self.data_ram_dirty_first, first);
        self.data_ram_dirty_end = @max(self.data_ram_dirty_end, end);
    }
};

pub fn selectHostMap(revision: Revision, mapping: board.Mapping, rom_size: usize, sram_size: usize) !HostMap {
    return switch (revision) {
        .dsp1, .dsp1a, .dsp1b => switch (mapping) {
            .hi_rom => .dsp1_hi,
            .lo_rom => if (rom_size > 1024 * 1024)
                .dsp1_lo_large
            else if (sram_size != 0)
                .dsp1_lo_small_ram
            else
                .dsp1_lo_small,
            else => error.ContradictoryNecDspBoard,
        },
        .dsp2 => if (mapping == .lo_rom) .dsp2 else error.ContradictoryNecDspBoard,
        .dsp3 => if (mapping == .lo_rom) .dsp3 else error.ContradictoryNecDspBoard,
        .dsp4 => if (mapping == .lo_rom) .dsp4 else error.ContradictoryNecDspBoard,
        .st010, .st011 => if (mapping == .lo_rom and sram_size == st_data_ram_bytes)
            .st01x
        else
            error.ContradictoryNecDspBoard,
    };
}

pub fn validateFirmware(revision: Revision, bytes: []const u8, validation: FirmwareValidation) ![32]u8 {
    if (bytes.len != revision.firmwareBytes()) return error.InvalidNecDspFirmwareSize;
    var actual: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &actual, .{});
    if (validation == .known_only and !std.mem.eql(u8, &actual, &revision.knownDigest()))
        return error.InvalidNecDspFirmwareDigest;
    return actual;
}

fn digestFromHex(comptime source: []const u8) [32]u8 {
    comptime {
        if (source.len != 64) @compileError("SHA-256 text must contain 64 hexadecimal digits");
    }
    var result: [32]u8 = undefined;
    for (0..32) |index| result[index] = (hexNibble(source[index * 2]) << 4) | hexNibble(source[index * 2 + 1]);
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

fn hashByte(result: *u64, value: u8) void {
    result.* = (result.* ^ value) *% 0x100000001b3;
}

fn hashWord(result: *u64, value: u16) void {
    hashByte(result, @truncate(value));
    hashByte(result, @truncate(value >> 8));
}

fn hashQword(result: *u64, value: u64) void {
    var remaining = value;
    for (0..8) |_| {
        hashByte(result, @truncate(remaining));
        remaining >>= 8;
    }
}

comptime {
    _ = status_p0;
    _ = status_p1;
    _ = status_ei;
    _ = status_sic;
    _ = status_soc;
    _ = status_dma;
    _ = status_usf0;
    _ = status_usf1;
}
