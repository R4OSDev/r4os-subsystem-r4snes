const board = @import("board.zig");
const epson = @import("epson_rtc.zig");

pub const access_master_cycles: u8 = 6;

pub const Fault = enum(u8) {
    none,
    invalid_decompression_mode,
    missing_data_rom,
};

pub const WriteResult = struct {
    handled: bool = false,
    changed: bool = false,
    first: usize = 0,
    end: usize = 0,
};

const ModelState = struct {
    probability: u8,
    next_mps: u8,
    next_lps: u8,
};

const model = [_]ModelState{
    .{ .probability = 0x5a, .next_mps = 1, .next_lps = 1 },
    .{ .probability = 0x25, .next_mps = 2, .next_lps = 6 },
    .{ .probability = 0x11, .next_mps = 3, .next_lps = 8 },
    .{ .probability = 0x08, .next_mps = 4, .next_lps = 10 },
    .{ .probability = 0x03, .next_mps = 5, .next_lps = 12 },
    .{ .probability = 0x01, .next_mps = 5, .next_lps = 15 },
    .{ .probability = 0x5a, .next_mps = 7, .next_lps = 7 },
    .{ .probability = 0x3f, .next_mps = 8, .next_lps = 19 },
    .{ .probability = 0x2c, .next_mps = 9, .next_lps = 21 },
    .{ .probability = 0x20, .next_mps = 10, .next_lps = 22 },
    .{ .probability = 0x17, .next_mps = 11, .next_lps = 23 },
    .{ .probability = 0x11, .next_mps = 12, .next_lps = 25 },
    .{ .probability = 0x0c, .next_mps = 13, .next_lps = 26 },
    .{ .probability = 0x09, .next_mps = 14, .next_lps = 28 },
    .{ .probability = 0x07, .next_mps = 15, .next_lps = 29 },
    .{ .probability = 0x05, .next_mps = 16, .next_lps = 31 },
    .{ .probability = 0x04, .next_mps = 17, .next_lps = 32 },
    .{ .probability = 0x03, .next_mps = 18, .next_lps = 34 },
    .{ .probability = 0x02, .next_mps = 5, .next_lps = 35 },
    .{ .probability = 0x5a, .next_mps = 20, .next_lps = 20 },
    .{ .probability = 0x48, .next_mps = 21, .next_lps = 39 },
    .{ .probability = 0x3a, .next_mps = 22, .next_lps = 40 },
    .{ .probability = 0x2e, .next_mps = 23, .next_lps = 42 },
    .{ .probability = 0x26, .next_mps = 24, .next_lps = 44 },
    .{ .probability = 0x1f, .next_mps = 25, .next_lps = 45 },
    .{ .probability = 0x19, .next_mps = 26, .next_lps = 46 },
    .{ .probability = 0x15, .next_mps = 27, .next_lps = 25 },
    .{ .probability = 0x11, .next_mps = 28, .next_lps = 26 },
    .{ .probability = 0x0e, .next_mps = 29, .next_lps = 26 },
    .{ .probability = 0x0b, .next_mps = 30, .next_lps = 27 },
    .{ .probability = 0x09, .next_mps = 31, .next_lps = 28 },
    .{ .probability = 0x08, .next_mps = 32, .next_lps = 29 },
    .{ .probability = 0x07, .next_mps = 33, .next_lps = 30 },
    .{ .probability = 0x05, .next_mps = 34, .next_lps = 31 },
    .{ .probability = 0x04, .next_mps = 35, .next_lps = 33 },
    .{ .probability = 0x04, .next_mps = 36, .next_lps = 33 },
    .{ .probability = 0x03, .next_mps = 37, .next_lps = 34 },
    .{ .probability = 0x02, .next_mps = 38, .next_lps = 35 },
    .{ .probability = 0x02, .next_mps = 5, .next_lps = 36 },
    .{ .probability = 0x58, .next_mps = 40, .next_lps = 39 },
    .{ .probability = 0x4d, .next_mps = 41, .next_lps = 47 },
    .{ .probability = 0x43, .next_mps = 42, .next_lps = 48 },
    .{ .probability = 0x3b, .next_mps = 43, .next_lps = 49 },
    .{ .probability = 0x34, .next_mps = 44, .next_lps = 50 },
    .{ .probability = 0x2e, .next_mps = 45, .next_lps = 51 },
    .{ .probability = 0x29, .next_mps = 46, .next_lps = 44 },
    .{ .probability = 0x25, .next_mps = 24, .next_lps = 45 },
    .{ .probability = 0x56, .next_mps = 48, .next_lps = 47 },
    .{ .probability = 0x4f, .next_mps = 49, .next_lps = 47 },
    .{ .probability = 0x47, .next_mps = 50, .next_lps = 48 },
    .{ .probability = 0x41, .next_mps = 51, .next_lps = 49 },
    .{ .probability = 0x3c, .next_mps = 52, .next_lps = 50 },
    .{ .probability = 0x37, .next_mps = 43, .next_lps = 51 },
};

const Context = struct {
    prediction: u8 = 0,
    swap: u8 = 0,
};

/// Arithmetic decompressor shared by the register-driven product path and
/// synthetic oracle tests. It consumes only caller-provided data-ROM bytes.
pub const Decompressor = struct {
    contexts: [5][15]Context = [_][15]Context{[_]Context{.{}} ** 15} ** 5,
    bpp: u8 = 1,
    offset: u32 = 0,
    bits: u8 = 8,
    range: u16 = 0x100,
    input: u16 = 0,
    output: u8 = 0,
    pixels: u64 = 0,
    colormap: u64 = 0xFEDCBA9876543210,
    result: u32 = 0,
    initialized: bool = false,

    pub fn init(self: *Decompressor, data: []const u8, mode: u8, origin: u32) !void {
        if (mode > 2) return error.InvalidMode;
        if (data.len == 0) return error.MissingData;
        self.* = .{};
        self.bpp = @as(u8, 1) << @intCast(mode);
        self.offset = origin;
        self.input = @as(u16, self.nextInput(data)) << 8;
        self.input |= self.nextInput(data);
        self.initialized = true;
    }

    pub fn decode(self: *Decompressor, data: []const u8) u32 {
        if (!self.initialized or data.len == 0) return 0;
        var pixel: u8 = 0;
        while (pixel < 8) : (pixel += 1) {
            var map = self.colormap;
            var difference: u8 = 0;
            if (self.bpp > 1) {
                const a: u8 = @truncate(if (self.bpp == 2) (self.pixels >> 2) & 3 else self.pixels & 15);
                const b: u8 = @truncate(if (self.bpp == 2) (self.pixels >> 14) & 3 else (self.pixels >> 28) & 15);
                const c: u8 = @truncate(if (self.bpp == 2) (self.pixels >> 16) & 3 else (self.pixels >> 32) & 15);
                if (a != b or b != c) {
                    const match = a ^ b ^ c;
                    difference = 4;
                    if ((match ^ c) == 0) difference = 3;
                    if ((match ^ b) == 0) difference = 2;
                    if ((match ^ a) == 0) difference = 1;
                }
                self.colormap = moveToFront(self.colormap, a);
                map = moveToFront(map, c);
                map = moveToFront(map, b);
                map = moveToFront(map, a);
            }

            var plane: u8 = 0;
            while (plane < self.bpp) : (plane += 1) {
                const bit: u32 = if (self.bpp > 1)
                    @as(u32, 1) << @intCast(plane)
                else
                    @as(u32, 1) << @intCast(pixel & 3);
                const history = (bit - 1) & self.output;
                var set: u8 = 0;
                if (self.bpp == 1) set = @intFromBool(pixel >= 4);
                if (self.bpp == 2) set = difference;
                if (plane >= 2 and history <= 1) set = difference;

                const context_index: usize = @intCast(bit + history - 1);
                const context = &self.contexts[set][context_index];
                const state = model[context.prediction];
                const lps_offset: u16 = self.range - state.probability;
                const symbol: u8 = @intFromBool(self.input >= (lps_offset << 8));
                self.output = @truncate((@as(u16, self.output) << 1) | (symbol ^ context.swap));

                if (symbol == 0) {
                    self.range = lps_offset;
                } else {
                    self.range -= lps_offset;
                    self.input -= lps_offset << 8;
                }

                while (self.range <= 0x7F) {
                    context.prediction = if (symbol == 0) state.next_mps else state.next_lps;
                    self.range <<= 1;
                    self.input = @truncate(@as(u32, self.input) << 1);
                    self.bits -= 1;
                    if (self.bits == 0) {
                        self.bits = 8;
                        self.input +%= self.nextInput(data);
                    }
                }
                if (symbol == 1 and state.probability > 0x55) context.swap ^= 1;
            }

            var index: u8 = @truncate(self.output & ((@as(u16, 1) << @intCast(self.bpp)) - 1));
            if (self.bpp == 1) index ^= @truncate((self.pixels >> 15) & 1);
            const mapped: u64 = (map >> @intCast(4 * index)) & 15;
            self.pixels = (self.pixels << @intCast(self.bpp)) | mapped;
        }

        self.result = switch (self.bpp) {
            1 => @truncate(self.pixels),
            2 => deinterleave(self.pixels, 16),
            4 => deinterleave(deinterleave(self.pixels, 32), 32),
            else => 0,
        };
        return self.result;
    }

    fn nextInput(self: *Decompressor, data: []const u8) u8 {
        const index: usize = @intCast(self.offset % @as(u32, @intCast(data.len)));
        self.offset +%= 1;
        return data[index];
    }
};

pub const Device = struct {
    regs: [0x43]u8 = .{0} ** 0x43,
    dcu_mode: u8 = 0,
    dcu_address: u32 = 0,
    dcu_offset: u8 = 0,
    dcu_tile: [32]u8 = .{0} ** 32,
    decompressor: Decompressor = .{},
    rtc: epson.Device = .{},
    has_rtc: bool = true,
    fault: Fault = .none,

    pub fn power(self: *Device) void {
        const rtc = self.rtc;
        const has_rtc = self.has_rtc;
        self.* = .{};
        self.rtc = rtc;
        self.has_rtc = has_rtc;
        if (self.has_rtc) self.rtc.power();
        self.regs[0x32] = 1;
        self.regs[0x33] = 2;
    }

    pub fn reset(self: *Device) void {
        self.power();
    }

    pub fn read(self: *Device, rom: []const u8, sram: []const u8, address: u32, open_bus: u8) ?u8 {
        if (ramAddress(address)) {
            if (sram.len == 0) return 0;
            if ((self.regs[0x30] & 0x80) == 0) return 0;
            const index = board.mirrorIndex(@as(usize, @truncate(address)) & 0x1FFF, sram.len);
            return sram[index];
        }
        if (canonicalPort(address)) |port| {
            if (port >= 0x4840 and !self.has_rtc) return null;
            return self.readPort(rom, port, open_bus);
        }
        if (romAddress(address)) return self.mcuRomRead(rom, address, open_bus);
        return null;
    }

    pub fn write(self: *Device, rom: []const u8, sram: []u8, address: u32, value: u8) WriteResult {
        if (ramAddress(address)) {
            if (sram.len == 0 or (self.regs[0x30] & 0x80) == 0) return .{ .handled = true };
            const index = board.mirrorIndex(@as(usize, @truncate(address)) & 0x1FFF, sram.len);
            if (sram[index] == value) return .{ .handled = true };
            sram[index] = value;
            return .{ .handled = true, .changed = true, .first = index, .end = index + 1 };
        }
        if (canonicalPort(address)) |port| {
            if (port >= 0x4840 and !self.has_rtc) return .{};
            self.writePort(rom, port, value);
            return .{ .handled = true };
        }
        if (romAddress(address)) return .{ .handled = true };
        return .{};
    }

    pub fn advanceRtcSeconds(self: *Device, seconds: u64) void {
        self.rtc.advanceSeconds(seconds);
    }

    fn readPort(self: *Device, rom: []const u8, port: u16, open_bus: u8) u8 {
        if (port >= 0x4840 and port <= 0x4842) return self.rtc.readPort(port, open_bus);
        if (port < 0x4800 or port > 0x483F) return open_bus;
        const index: usize = port - 0x4800;
        return switch (port) {
            0x4800 => blk: {
                var counter = word(self.regs[9], self.regs[10]);
                counter -%= 1;
                splitWord(counter, &self.regs[9], &self.regs[10]);
                break :blk self.dcuRead(rom);
            },
            0x4808 => 0,
            0x4810 => blk: {
                const result = self.regs[0x10];
                self.increment4810(rom);
                break :blk result;
            },
            0x4819 => open_bus,
            0x481A => blk: {
                self.increment481a(rom);
                break :blk 0;
            },
            0x4801...0x4807,
            0x4809...0x480C,
            0x4811...0x4818,
            0x4820...0x482F,
            0x4830...0x4834,
            => self.regs[index],
            else => open_bus,
        };
    }

    fn writePort(self: *Device, rom: []const u8, port: u16, value: u8) void {
        if (port >= 0x4840 and port <= 0x4842) {
            _ = self.rtc.writePort(port, value);
            return;
        }
        if (port < 0x4800 or port > 0x483F) return;
        const index: usize = port - 0x4800;
        switch (port) {
            0x4801, 0x4802, 0x4803 => self.regs[index] = value,
            0x4804 => {
                self.regs[index] = value;
                self.loadDcuAddress(rom);
            },
            0x4805 => self.regs[index] = value,
            0x4806 => {
                self.regs[index] = value;
                self.regs[0x0C] &= 0x7F;
                self.beginDcu(rom);
            },
            0x4807, 0x4809, 0x480A => self.regs[index] = value,
            0x480B => self.regs[index] = value & 3,
            0x4811, 0x4812 => self.regs[index] = value,
            0x4813 => {
                self.regs[index] = value & 0x7F;
                self.fillDataPort(rom);
            },
            0x4814 => {
                self.regs[index] = value;
                self.increment4814(rom);
            },
            0x4815 => {
                self.regs[index] = value;
                if ((self.regs[0x18] & 2) != 0) self.fillDataPort(rom);
                self.increment4815(rom);
            },
            0x4816, 0x4817 => self.regs[index] = value,
            0x4818 => {
                self.regs[index] = value & 0x7F;
                self.fillDataPort(rom);
            },
            0x4820...0x4824, 0x4826 => self.regs[index] = value,
            0x4825 => {
                self.regs[index] = value;
                self.multiply();
            },
            0x4827 => {
                self.regs[index] = value;
                self.divide();
            },
            0x482E => self.regs[index] = value & 1,
            0x4830 => self.regs[index] = value & 0x87,
            0x4831, 0x4832, 0x4833, 0x4834 => self.regs[index] = value & 7,
            else => {},
        }
    }

    fn loadDcuAddress(self: *Device, rom: []const u8) void {
        const table = three(self.regs[1], self.regs[2], self.regs[3]);
        const address = table +% (@as(u32, self.regs[4]) << 2);
        self.dcu_mode = self.dataRomRead(rom, address);
        self.dcu_address = (@as(u32, self.dataRomRead(rom, address +% 1)) << 16) |
            (@as(u32, self.dataRomRead(rom, address +% 2)) << 8) |
            self.dataRomRead(rom, address +% 3);
    }

    fn beginDcu(self: *Device, rom: []const u8) void {
        if (self.dcu_mode > 2) {
            self.fault = .invalid_decompression_mode;
            return;
        }
        const data = dataSlice(rom);
        if (data.len == 0) {
            self.fault = .missing_data_rom;
            return;
        }
        self.decompressor.init(data, self.dcu_mode, self.dcu_address) catch {
            self.fault = .missing_data_rom;
            return;
        };
        _ = self.decompressor.decode(data);
        var seek: u16 = if ((self.regs[0x0B] & 2) != 0) word(self.regs[5], self.regs[6]) else 0;
        while (seek != 0) : (seek -= 1) _ = self.decompressor.decode(data);
        self.regs[0x0C] |= 0x80;
        self.dcu_offset = 0;
        self.fault = .none;
    }

    fn dcuRead(self: *Device, rom: []const u8) u8 {
        if ((self.regs[0x0C] & 0x80) == 0) return 0;
        const data = dataSlice(rom);
        if (data.len == 0) return 0;
        if (self.dcu_offset == 0) {
            var row: usize = 0;
            while (row < 8) : (row += 1) {
                const result = self.decompressor.result;
                switch (self.decompressor.bpp) {
                    1 => self.dcu_tile[row] = @truncate(result),
                    2 => {
                        self.dcu_tile[row * 2] = @truncate(result);
                        self.dcu_tile[row * 2 + 1] = @truncate(result >> 8);
                    },
                    4 => {
                        self.dcu_tile[row * 2] = @truncate(result);
                        self.dcu_tile[row * 2 + 1] = @truncate(result >> 8);
                        self.dcu_tile[row * 2 + 16] = @truncate(result >> 16);
                        self.dcu_tile[row * 2 + 17] = @truncate(result >> 24);
                    },
                    else => {},
                }
                var seek: u8 = if ((self.regs[0x0B] & 1) != 0) self.regs[7] else 1;
                while (seek != 0) : (seek -= 1) _ = self.decompressor.decode(data);
            }
        }
        const result = self.dcu_tile[self.dcu_offset];
        self.dcu_offset +%= 1;
        self.dcu_offset &= self.decompressor.bpp * 8 - 1;
        return result;
    }

    fn dataOffset(self: *const Device) u32 {
        return three(self.regs[0x11], self.regs[0x12], self.regs[0x13]);
    }

    fn dataAdjust(self: *const Device) u16 {
        return word(self.regs[0x14], self.regs[0x15]);
    }

    fn dataStride(self: *const Device) u16 {
        return word(self.regs[0x16], self.regs[0x17]);
    }

    fn setDataOffset(self: *Device, value: u32) void {
        self.regs[0x11] = @truncate(value);
        self.regs[0x12] = @truncate(value >> 8);
        self.regs[0x13] = @truncate(value >> 16);
    }

    fn setDataAdjust(self: *Device, value: u32) void {
        self.regs[0x14] = @truncate(value);
        self.regs[0x15] = @truncate(value >> 8);
    }

    fn fillDataPort(self: *Device, rom: []const u8) void {
        const offset = self.dataOffset();
        var adjust: u32 = if ((self.regs[0x18] & 2) != 0) self.dataAdjust() else 0;
        if ((self.regs[0x18] & 8) != 0) adjust = signExtend16(@truncate(adjust));
        self.regs[0x10] = self.dataRomRead(rom, offset +% adjust);
    }

    fn increment4810(self: *Device, rom: []const u8) void {
        const offset = self.dataOffset();
        var stride: u32 = if ((self.regs[0x18] & 1) != 0) self.dataStride() else 1;
        var adjust: u32 = self.dataAdjust();
        if ((self.regs[0x18] & 4) != 0) stride = signExtend16(@truncate(stride));
        if ((self.regs[0x18] & 8) != 0) adjust = signExtend16(@truncate(adjust));
        if ((self.regs[0x18] & 0x10) == 0) self.setDataOffset(offset +% stride) else self.setDataAdjust(adjust +% stride);
        self.fillDataPort(rom);
    }

    fn increment4814(self: *Device, rom: []const u8) void {
        if ((self.regs[0x18] >> 5) != 1) return;
        var adjust: u32 = self.dataAdjust();
        if ((self.regs[0x18] & 8) != 0) adjust = signExtend16(@truncate(adjust));
        self.setDataOffset(self.dataOffset() +% adjust);
        self.fillDataPort(rom);
    }

    fn increment4815(self: *Device, rom: []const u8) void {
        if ((self.regs[0x18] >> 5) != 2) return;
        var adjust: u32 = self.dataAdjust();
        if ((self.regs[0x18] & 8) != 0) adjust = signExtend16(@truncate(adjust));
        self.setDataOffset(self.dataOffset() +% adjust);
        self.fillDataPort(rom);
    }

    fn increment481a(self: *Device, rom: []const u8) void {
        if ((self.regs[0x18] >> 5) != 3) return;
        var adjust: u32 = self.dataAdjust();
        if ((self.regs[0x18] & 8) != 0) adjust = signExtend16(@truncate(adjust));
        self.setDataOffset(self.dataOffset() +% adjust);
        self.fillDataPort(rom);
    }

    fn multiply(self: *Device) void {
        const left = word(self.regs[0x20], self.regs[0x21]);
        const right = word(self.regs[0x24], self.regs[0x25]);
        const result: u32 = if ((self.regs[0x2E] & 1) != 0) signed: {
            const a: i16 = @bitCast(left);
            const b: i16 = @bitCast(right);
            const product: i32 = @as(i32, a) * @as(i32, b);
            break :signed @bitCast(product);
        } else @as(u32, left) * @as(u32, right);
        splitDword(result, self.regs[0x28..0x2C]);
        self.regs[0x2F] = (self.regs[0x2F] | 1) & 0x7F;
    }

    fn divide(self: *Device) void {
        const dividend = dword(self.regs[0x20..0x24]);
        const divisor = word(self.regs[0x26], self.regs[0x27]);
        var quotient: u32 = 0;
        var remainder: u16 = @truncate(dividend);
        if ((self.regs[0x2E] & 1) != 0) {
            const a: i32 = @bitCast(dividend);
            const b: i16 = @bitCast(divisor);
            if (b != 0) {
                if (a == -2147483648 and b == -1) {
                    quotient = 0x80000000;
                    remainder = 0;
                } else {
                    const q: i32 = @divTrunc(a, b);
                    const r: i16 = @intCast(@rem(a, b));
                    quotient = @bitCast(q);
                    remainder = @bitCast(r);
                }
            }
        } else if (divisor != 0) {
            quotient = dividend / divisor;
            remainder = @truncate(dividend % divisor);
        }
        splitDword(quotient, self.regs[0x28..0x2C]);
        splitWord(remainder, &self.regs[0x2C], &self.regs[0x2D]);
        self.regs[0x2F] &= 0x7F;
    }

    fn mcuRomRead(self: *const Device, rom: []const u8, address: u32, open_bus: u8) u8 {
        if (rom.len == 0) return open_bus;
        const logical = (@as(u32, @as(u8, @truncate(address >> 16)) & 0x3F) << 16) | @as(u16, @truncate(address));
        const segment = logical >> 20;
        const within = logical & 0x0F_FFFF;
        const program = programSlice(rom);
        if (segment == 0 and program.len != 0) return program[board.mirrorIndex(within, program.len)];
        if (segment == 1 and (self.regs[0x34] & 4) != 0 and program.len != 0) {
            return program[board.mirrorIndex(0x100000 + @as(usize, within), program.len)];
        }
        const selected: u8 = switch (segment) {
            0 => self.regs[0x30] & 7,
            1 => self.regs[0x31] & 7,
            2 => self.regs[0x32] & 7,
            3 => self.regs[0x33] & 7,
            else => return open_bus,
        };
        return self.dataRomRead(rom, (@as(u32, selected) << 20) | within);
    }

    fn dataRomRead(self: *const Device, rom: []const u8, address: u32) u8 {
        const data = dataSlice(rom);
        if (data.len == 0) return 0;
        const configured: u32 = @as(u32, 0x100000) << @intCast(self.regs[0x34] & 3);
        if (configured != 0x800000 and (address & 0x400000) != 0) return 0;
        const offset = address & (configured - 1);
        return data[board.mirrorIndex(offset, data.len)];
    }
};

pub fn programRomBytes(total: usize) usize {
    if (total > 0x500000) return @min(total, 0x200000);
    return @min(total, 0x100000);
}

pub fn programSlice(rom: []const u8) []const u8 {
    return rom[0..programRomBytes(rom.len)];
}

pub fn dataSlice(rom: []const u8) []const u8 {
    return rom[programRomBytes(rom.len)..];
}

fn canonicalPort(address: u32) ?u16 {
    const bank: u8 = @truncate(address >> 16);
    const port: u16 = @truncate(address);
    if (bank == 0x50) return 0x4800;
    if (bank == 0x58) return 0x4808;
    if ((bank <= 0x3F or (bank >= 0x80 and bank <= 0xBF)) and port >= 0x4800 and port <= 0x4842) return port;
    return null;
}

fn ramAddress(address: u32) bool {
    const bank: u8 = @truncate(address >> 16);
    const port: u16 = @truncate(address);
    return (bank <= 0x3F or (bank >= 0x80 and bank <= 0xBF)) and port >= 0x6000 and port <= 0x7FFF;
}

fn romAddress(address: u32) bool {
    const bank: u8 = @truncate(address >> 16);
    const port: u16 = @truncate(address);
    return ((bank <= 0x3F or (bank >= 0x80 and bank <= 0xBF)) and port >= 0x8000) or bank >= 0xC0;
}

fn moveToFront(list: u64, nibble: u8) u64 {
    var values: [16]u8 = undefined;
    var found: usize = 0;
    for (0..16) |index| {
        values[index] = @truncate((list >> @intCast(index * 4)) & 15);
        if (values[index] == nibble) found = index;
    }
    var index = found;
    while (index > 0) : (index -= 1) values[index] = values[index - 1];
    values[0] = nibble;
    var result: u64 = 0;
    for (values, 0..) |value, at| result |= @as(u64, value) << @intCast(at * 4);
    return result;
}

fn deinterleave(raw: u64, bits: u8) u32 {
    var data = raw & ((@as(u64, 1) << @intCast(bits)) - 1);
    data = 0x5555555555555555 & ((data << @intCast(bits)) | (data >> 1));
    data = 0x3333333333333333 & (data | (data >> 1));
    data = 0x0F0F0F0F0F0F0F0F & (data | (data >> 2));
    data = 0x00FF00FF00FF00FF & (data | (data >> 4));
    data = 0x0000FFFF0000FFFF & (data | (data >> 8));
    return @truncate(data | (data >> 16));
}

fn signExtend16(value: u16) u32 {
    const signed: i16 = @bitCast(value);
    const wide: i32 = signed;
    return @bitCast(wide);
}

fn word(low: u8, high: u8) u16 {
    return @as(u16, low) | (@as(u16, high) << 8);
}

fn three(low: u8, middle: u8, high: u8) u32 {
    return @as(u32, low) | (@as(u32, middle) << 8) | (@as(u32, high) << 16);
}

fn dword(bytes: []const u8) u32 {
    return @as(u32, bytes[0]) | (@as(u32, bytes[1]) << 8) | (@as(u32, bytes[2]) << 16) | (@as(u32, bytes[3]) << 24);
}

fn splitWord(value: u16, low: *u8, high: *u8) void {
    low.* = @truncate(value);
    high.* = @truncate(value >> 8);
}

fn splitDword(value: u32, bytes: []u8) void {
    bytes[0] = @truncate(value);
    bytes[1] = @truncate(value >> 8);
    bytes[2] = @truncate(value >> 16);
    bytes[3] = @truncate(value >> 24);
}
