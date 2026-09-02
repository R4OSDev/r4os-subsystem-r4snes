const board = @import("board.zig");

pub const access_master_cycles: u8 = 8;

pub const Fault = enum(u8) {
    none,
    invalid_stream,
};

pub const WriteResult = struct {
    handled: bool = false,
    changed: bool = false,
    first: usize = 0,
    end: usize = 0,
};

const DmaDescriptor = struct {
    address: u32 = 0,
    size: u16 = 0,
};

const Evolution = struct {
    code_number: u8,
    next_if_mps: u8,
    next_if_lps: u8,
};

const evolution = [_]Evolution{
    .{ .code_number = 0, .next_if_mps = 25, .next_if_lps = 25 },
    .{ .code_number = 0, .next_if_mps = 2, .next_if_lps = 1 },
    .{ .code_number = 0, .next_if_mps = 3, .next_if_lps = 1 },
    .{ .code_number = 0, .next_if_mps = 4, .next_if_lps = 2 },
    .{ .code_number = 0, .next_if_mps = 5, .next_if_lps = 3 },
    .{ .code_number = 1, .next_if_mps = 6, .next_if_lps = 4 },
    .{ .code_number = 1, .next_if_mps = 7, .next_if_lps = 5 },
    .{ .code_number = 1, .next_if_mps = 8, .next_if_lps = 6 },
    .{ .code_number = 1, .next_if_mps = 9, .next_if_lps = 7 },
    .{ .code_number = 2, .next_if_mps = 10, .next_if_lps = 8 },
    .{ .code_number = 2, .next_if_mps = 11, .next_if_lps = 9 },
    .{ .code_number = 2, .next_if_mps = 12, .next_if_lps = 10 },
    .{ .code_number = 2, .next_if_mps = 13, .next_if_lps = 11 },
    .{ .code_number = 3, .next_if_mps = 14, .next_if_lps = 12 },
    .{ .code_number = 3, .next_if_mps = 15, .next_if_lps = 13 },
    .{ .code_number = 3, .next_if_mps = 16, .next_if_lps = 14 },
    .{ .code_number = 3, .next_if_mps = 17, .next_if_lps = 15 },
    .{ .code_number = 4, .next_if_mps = 18, .next_if_lps = 16 },
    .{ .code_number = 4, .next_if_mps = 19, .next_if_lps = 17 },
    .{ .code_number = 5, .next_if_mps = 20, .next_if_lps = 18 },
    .{ .code_number = 5, .next_if_mps = 21, .next_if_lps = 19 },
    .{ .code_number = 6, .next_if_mps = 22, .next_if_lps = 20 },
    .{ .code_number = 6, .next_if_mps = 23, .next_if_lps = 21 },
    .{ .code_number = 7, .next_if_mps = 24, .next_if_lps = 22 },
    .{ .code_number = 7, .next_if_mps = 24, .next_if_lps = 23 },
    .{ .code_number = 0, .next_if_mps = 26, .next_if_lps = 1 },
    .{ .code_number = 1, .next_if_mps = 27, .next_if_lps = 2 },
    .{ .code_number = 2, .next_if_mps = 28, .next_if_lps = 4 },
    .{ .code_number = 3, .next_if_mps = 29, .next_if_lps = 8 },
    .{ .code_number = 4, .next_if_mps = 30, .next_if_lps = 12 },
    .{ .code_number = 5, .next_if_mps = 31, .next_if_lps = 16 },
    .{ .code_number = 6, .next_if_mps = 32, .next_if_lps = 18 },
    .{ .code_number = 7, .next_if_mps = 24, .next_if_lps = 22 },
};

const run_count = [_]u8{
    0x00, 0x00, 0x01, 0x00, 0x03, 0x01, 0x02, 0x00,
    0x07, 0x03, 0x05, 0x01, 0x06, 0x02, 0x04, 0x00,
    0x0f, 0x07, 0x0b, 0x03, 0x0d, 0x05, 0x09, 0x01,
    0x0e, 0x06, 0x0a, 0x02, 0x0c, 0x04, 0x08, 0x00,
    0x1f, 0x0f, 0x17, 0x07, 0x1b, 0x0b, 0x13, 0x03,
    0x1d, 0x0d, 0x15, 0x05, 0x19, 0x09, 0x11, 0x01,
    0x1e, 0x0e, 0x16, 0x06, 0x1a, 0x0a, 0x12, 0x02,
    0x1c, 0x0c, 0x14, 0x04, 0x18, 0x08, 0x10, 0x00,
    0x3f, 0x1f, 0x2f, 0x0f, 0x37, 0x17, 0x27, 0x07,
    0x3b, 0x1b, 0x2b, 0x0b, 0x33, 0x13, 0x23, 0x03,
    0x3d, 0x1d, 0x2d, 0x0d, 0x35, 0x15, 0x25, 0x05,
    0x39, 0x19, 0x29, 0x09, 0x31, 0x11, 0x21, 0x01,
    0x3e, 0x1e, 0x2e, 0x0e, 0x36, 0x16, 0x26, 0x06,
    0x3a, 0x1a, 0x2a, 0x0a, 0x32, 0x12, 0x22, 0x02,
    0x3c, 0x1c, 0x2c, 0x0c, 0x34, 0x14, 0x24, 0x04,
    0x38, 0x18, 0x28, 0x08, 0x30, 0x10, 0x20, 0x00,
    0x7f, 0x3f, 0x5f, 0x1f, 0x6f, 0x2f, 0x4f, 0x0f,
    0x77, 0x37, 0x57, 0x17, 0x67, 0x27, 0x47, 0x07,
    0x7b, 0x3b, 0x5b, 0x1b, 0x6b, 0x2b, 0x4b, 0x0b,
    0x73, 0x33, 0x53, 0x13, 0x63, 0x23, 0x43, 0x03,
    0x7d, 0x3d, 0x5d, 0x1d, 0x6d, 0x2d, 0x4d, 0x0d,
    0x75, 0x35, 0x55, 0x15, 0x65, 0x25, 0x45, 0x05,
    0x79, 0x39, 0x59, 0x19, 0x69, 0x29, 0x49, 0x09,
    0x71, 0x31, 0x51, 0x11, 0x61, 0x21, 0x41, 0x01,
    0x7e, 0x3e, 0x5e, 0x1e, 0x6e, 0x2e, 0x4e, 0x0e,
    0x76, 0x36, 0x56, 0x16, 0x66, 0x26, 0x46, 0x06,
    0x7a, 0x3a, 0x5a, 0x1a, 0x6a, 0x2a, 0x4a, 0x0a,
    0x72, 0x32, 0x52, 0x12, 0x62, 0x22, 0x42, 0x02,
    0x7c, 0x3c, 0x5c, 0x1c, 0x6c, 0x2c, 0x4c, 0x0c,
    0x74, 0x34, 0x54, 0x14, 0x64, 0x24, 0x44, 0x04,
    0x78, 0x38, 0x58, 0x18, 0x68, 0x28, 0x48, 0x08,
    0x70, 0x30, 0x50, 0x10, 0x60, 0x20, 0x40, 0x00,
};

const Generator = struct {
    mps_count: u8 = 0,
    lps_index: bool = false,
};

const Context = struct {
    status: u8 = 0,
    mps: u8 = 0,
};

/// Streaming S-DD1 decoder. All state lives in the instance, so stopping after
/// any output byte and resuming in a later guest slice is deterministic.
pub const Decompressor = struct {
    offset: u32 = 0,
    bit_count: u8 = 4,
    generators: [8]Generator = [_]Generator{.{}} ** 8,
    contexts: [32]Context = [_]Context{.{}} ** 32,
    bitplanes_info: u8 = 0,
    context_bits_info: u8 = 0,
    bit_number: u8 = 0,
    current_bitplane: u8 = 0,
    previous_bitplane_bits: [8]u16 = .{0} ** 8,
    output_phase: u8 = 1,
    output_first: u8 = 0,
    output_second: u8 = 0,
    initialized: bool = false,

    pub fn init(self: *Decompressor, rom: []const u8, banks: [4]u8, offset: u32) void {
        self.* = .{};
        self.offset = offset;
        const first = mmcRead(rom, banks, offset);
        self.bitplanes_info = first & 0xC0;
        self.context_bits_info = first & 0x30;
        self.current_bitplane = switch (self.bitplanes_info) {
            0x00 => 1,
            0x40 => 7,
            0x80 => 3,
            else => 0,
        };
        self.initialized = true;
    }

    pub fn read(self: *Decompressor, rom: []const u8, banks: [4]u8) u8 {
        if (!self.initialized) return 0;
        switch (self.bitplanes_info) {
            0x00, 0x40, 0x80 => {
                if (self.output_phase == 0) {
                    self.output_phase = 0xFF;
                    return self.output_second;
                }
                self.output_first = 0;
                self.output_second = 0;
                self.output_phase = 0x80;
                while (self.output_phase != 0) : (self.output_phase >>= 1) {
                    if (self.contextBit(rom, banks) != 0) self.output_first |= self.output_phase;
                    if (self.contextBit(rom, banks) != 0) self.output_second |= self.output_phase;
                }
                return self.output_first;
            },
            0xC0 => {
                self.output_first = 0;
                self.output_phase = 1;
                while (self.output_phase != 0) : (self.output_phase <<= 1) {
                    if (self.contextBit(rom, banks) != 0) self.output_first |= self.output_phase;
                }
                return self.output_first;
            },
            else => return 0,
        }
    }

    fn codeWord(self: *Decompressor, rom: []const u8, banks: [4]u8, code_length: u8) u8 {
        var result: u8 = @truncate(@as(u16, mmcRead(rom, banks, self.offset)) << @intCast(self.bit_count));
        self.bit_count +%= 1;
        if ((result & 0x80) != 0) {
            const shift = 9 - self.bit_count;
            if (shift < 8) result |= mmcRead(rom, banks, self.offset +% 1) >> @intCast(shift);
            self.bit_count +%= code_length;
        }
        if ((self.bit_count & 8) != 0) {
            self.offset +%= 1;
            self.bit_count &= 7;
        }
        return result;
    }

    fn generatorBit(self: *Decompressor, rom: []const u8, banks: [4]u8, number: u8, end_of_run: *bool) u8 {
        const generator = &self.generators[number];
        if (generator.mps_count == 0 and !generator.lps_index) {
            const word = self.codeWord(rom, banks, number);
            if ((word & 0x80) != 0) {
                generator.lps_index = true;
                const shift: u3 = @intCast(number ^ 7);
                generator.mps_count = run_count[word >> shift];
            } else {
                generator.mps_count = @as(u8, 1) << @intCast(number);
            }
        }
        const result: u8 = if (generator.mps_count != 0) result: {
            generator.mps_count -= 1;
            break :result 0;
        } else result: {
            generator.lps_index = false;
            break :result 1;
        };
        end_of_run.* = generator.mps_count == 0 and !generator.lps_index;
        return result;
    }

    fn probabilityBit(self: *Decompressor, rom: []const u8, banks: [4]u8, index: u8) u8 {
        const context = &self.contexts[index];
        const current_status = context.status;
        const current_mps = context.mps;
        const state = evolution[current_status];
        var end_of_run = false;
        const bit = self.generatorBit(rom, banks, state.code_number, &end_of_run);
        if (end_of_run) {
            if (bit != 0) {
                if ((current_status & 0xFE) == 0) context.mps ^= 1;
                context.status = state.next_if_lps;
            } else {
                context.status = state.next_if_mps;
            }
        }
        return bit ^ current_mps;
    }

    fn contextBit(self: *Decompressor, rom: []const u8, banks: [4]u8) u8 {
        switch (self.bitplanes_info) {
            0x00 => self.current_bitplane ^= 1,
            0x40 => {
                self.current_bitplane ^= 1;
                if ((self.bit_number & 0x7F) == 0) self.current_bitplane = (self.current_bitplane + 2) & 7;
            },
            0x80 => {
                self.current_bitplane ^= 1;
                if ((self.bit_number & 0x7F) == 0) self.current_bitplane ^= 2;
            },
            0xC0 => self.current_bitplane = self.bit_number & 7,
            else => {},
        }
        const history = &self.previous_bitplane_bits[self.current_bitplane];
        var context: u8 = (self.current_bitplane & 1) << 4;
        context |= switch (self.context_bits_info) {
            0x00 => @truncate(((history.* & 0x01C0) >> 5) | (history.* & 1)),
            0x10 => @truncate(((history.* & 0x0180) >> 5) | (history.* & 1)),
            0x20 => @truncate(((history.* & 0x00C0) >> 5) | (history.* & 1)),
            0x30 => @truncate(((history.* & 0x0180) >> 5) | (history.* & 3)),
            else => 0,
        };
        const result = self.probabilityBit(rom, banks, context);
        history.* = (history.* << 1) | result;
        self.bit_number +%= 1;
        return result;
    }
};

pub const Device = struct {
    hard_enable: u8 = 0,
    soft_enable: u8 = 0,
    banks: [4]u8 = .{ 0, 1, 2, 3 },
    dma: [8]DmaDescriptor = [_]DmaDescriptor{.{}} ** 8,
    dma_ready: bool = false,
    decoder: Decompressor = .{},
    fault: Fault = .none,

    pub fn power(self: *Device) void {
        self.* = .{};
    }

    pub fn reset(self: *Device) void {
        self.power();
    }

    /// DMA controller writes remain owned by the S-CPU. S-DD1 only shadows
    /// source and length so a later fixed-source A-bus read can start exactly
    /// the selected compressed stream.
    pub fn observeDmaWrite(self: *Device, address: u32, value: u8) void {
        const bank: u8 = @truncate(address >> 16);
        const port: u16 = @truncate(address);
        if (!systemBank(bank) or port < 0x4300 or port > 0x437F) return;
        const channel: usize = (port >> 4) & 7;
        switch (port & 0x0F) {
            2 => self.dma[channel].address = (self.dma[channel].address & 0xFFFF00) | value,
            3 => self.dma[channel].address = (self.dma[channel].address & 0xFF00FF) | (@as(u32, value) << 8),
            4 => self.dma[channel].address = (self.dma[channel].address & 0x00FFFF) | (@as(u32, value) << 16),
            5 => self.dma[channel].size = (self.dma[channel].size & 0xFF00) | value,
            6 => self.dma[channel].size = (self.dma[channel].size & 0x00FF) | (@as(u16, value) << 8),
            else => {},
        }
    }

    pub fn read(self: *Device, rom: []const u8, sram: []const u8, address: u32, open_bus: u8) ?u8 {
        if (ramIndex(sram.len, address)) |index| return sram[index];
        const bank: u8 = @truncate(address >> 16);
        const port: u16 = @truncate(address);
        if (systemBank(bank) and port >= 0x4800 and port <= 0x480F) {
            return switch (port & 0x0F) {
                0 => self.hard_enable,
                1 => self.soft_enable,
                4, 5, 6, 7 => self.banks[port & 3],
                else => if (rom.len == 0) open_bus else rom[board.mirrorIndex(port, rom.len)],
            };
        }
        if (bank <= 0x3F or (bank >= 0x80 and bank <= 0xBF)) {
            if (port < 0x8000) return null;
            var logical_bank = bank & 0x3F;
            if (bank <= 0x3F and logical_bank >= 0x20 and (self.banks[1] & 0x80) != 0) logical_bank &= 0x1F;
            if (bank >= 0x80 and logical_bank >= 0x20 and (self.banks[3] & 0x80) != 0) logical_bank &= 0x1F;
            const logical = (@as(usize, logical_bank) << 15) | @as(usize, port & 0x7FFF);
            return rom[board.mirrorIndex(logical, rom.len)];
        }
        if (bank >= 0xC0) {
            const enabled = self.hard_enable & self.soft_enable;
            if (enabled != 0) {
                for (0..8) |channel| {
                    const bit = @as(u8, 1) << @intCast(channel);
                    if ((enabled & bit) == 0 or self.dma[channel].address != address) continue;
                    if (!self.dma_ready) {
                        self.decoder.init(rom, self.banks, address);
                        self.dma_ready = true;
                    }
                    const result = self.decoder.read(rom, self.banks);
                    self.dma[channel].size -%= 1;
                    if (self.dma[channel].size == 0) {
                        self.dma_ready = false;
                        self.soft_enable &= ~bit;
                    }
                    return result;
                }
            }
            return mmcRead(rom, self.banks, address);
        }
        return null;
    }

    pub fn write(self: *Device, sram: []u8, address: u32, value: u8) WriteResult {
        if (ramIndex(sram.len, address)) |index| {
            if (sram[index] == value) return .{ .handled = true };
            sram[index] = value;
            return .{ .handled = true, .changed = true, .first = index, .end = index + 1 };
        }
        const bank: u8 = @truncate(address >> 16);
        const port: u16 = @truncate(address);
        if (systemBank(bank) and port >= 0x4800 and port <= 0x480F) {
            switch (port & 0x0F) {
                0 => self.hard_enable = value,
                1 => self.soft_enable = value,
                4, 5, 6, 7 => self.banks[port & 3] = value & 0x8F,
                else => {},
            }
            return .{ .handled = true };
        }
        if ((bank <= 0x3F or (bank >= 0x80 and bank <= 0xBF)) and port >= 0x8000) return .{ .handled = true };
        if (bank >= 0xC0) return .{ .handled = true };
        return .{};
    }
};

pub fn mmcRead(rom: []const u8, banks: [4]u8, address: u32) u8 {
    if (rom.len == 0) return 0;
    const window: usize = @intCast((address >> 20) & 3);
    const logical = (@as(usize, banks[window] & 0x0F) << 20) | @as(usize, address & 0x0F_FFFF);
    return rom[board.mirrorIndex(logical, rom.len)];
}

fn ramIndex(size: usize, address: u32) ?usize {
    if (size == 0) return null;
    const bank: u8 = @truncate(address >> 16);
    const port: u16 = @truncate(address);
    var logical: usize = undefined;
    if (systemBank(bank) and port >= 0x6000 and port <= 0x7FFF) {
        logical = port & 0x1FFF;
    } else if (bank >= 0x70 and bank <= 0x73) {
        logical = port & 0x7FFF;
    } else {
        return null;
    }
    return board.mirrorIndex(logical, size);
}

fn systemBank(bank: u8) bool {
    return bank <= 0x3F or (bank >= 0x80 and bank <= 0xBF);
}
