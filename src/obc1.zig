pub const ram_bytes: usize = 0x2000;
pub const access_master_cycles: u8 = 8;

pub const WriteResult = struct {
    handled: bool = false,
    changed: bool = false,
    first: usize = 0,
    end: usize = 0,
};

/// Nintendo OBC-1 object-buffer controller. The device owns only its selector
/// registers; its complete 8-KiB address space is the cartridge's battery RAM
/// and therefore participates in the ordinary exact-size save policy.
pub const Device = struct {
    base: u16 = 0x1C00,
    object: u8 = 0,
    attribute_shift: u3 = 0,

    pub fn power(self: *Device, ram: []const u8) !void {
        if (ram.len != ram_bytes) return error.InvalidOBC1RamSize;
        self.base = if ((ram[0x1FF5] & 1) != 0) 0x1800 else 0x1C00;
        self.object = ram[0x1FF6] & 0x7F;
        self.attribute_shift = @truncate((ram[0x1FF6] & 3) << 1);
    }

    pub fn reset(self: *Device, ram: []const u8) !void {
        try self.power(ram);
    }

    pub fn read(self: *const Device, ram: []const u8, address: u32) ?u8 {
        if (ram.len != ram_bytes) return null;
        const logical = mappedIndex(address) orelse return null;
        const target: usize = switch (logical) {
            0x1FF0...0x1FF3 => @as(usize, self.base) + (@as(usize, self.object) << 2) + (logical - 0x1FF0),
            0x1FF4 => @as(usize, self.base) + 0x200 + (@as(usize, self.object) >> 2),
            else => logical,
        };
        return ram[target];
    }

    pub fn write(self: *Device, ram: []u8, address: u32, value: u8) WriteResult {
        if (ram.len != ram_bytes) return .{};
        const logical = mappedIndex(address) orelse return .{};
        var target = logical;
        var stored = value;
        switch (logical) {
            0x1FF0...0x1FF3 => {
                target = @as(usize, self.base) + (@as(usize, self.object) << 2) + (logical - 0x1FF0);
            },
            0x1FF4 => {
                target = @as(usize, self.base) + 0x200 + (@as(usize, self.object) >> 2);
                const shift: u3 = self.attribute_shift;
                const mask: u8 = @as(u8, 3) << shift;
                stored = (ram[target] & ~mask) | ((value & 3) << shift);
            },
            0x1FF5 => {
                self.base = if ((value & 1) != 0) 0x1800 else 0x1C00;
            },
            0x1FF6 => {
                self.object = value & 0x7F;
                self.attribute_shift = @truncate((value & 3) << 1);
            },
            else => {},
        }
        if (ram[target] == stored) return .{ .handled = true };
        ram[target] = stored;
        return .{
            .handled = true,
            .changed = true,
            .first = target,
            .end = target + 1,
        };
    }
};

/// OBC-1 is visible in the ordinary slow cartridge banks and in the two
/// documented 70/71 and F0/F1 mirrors. Every mapping folds to one 13-bit RAM
/// address; no title or ROM-size heuristic participates in the decode.
pub fn mappedIndex(address: u32) ?usize {
    if (address > 0x00FF_FFFF) return null;
    const bank: u8 = @truncate(address >> 16);
    const offset: u16 = @truncate(address);
    const primary = bank <= 0x3F or (bank >= 0x80 and bank <= 0xBF);
    const mirror = bank == 0x70 or bank == 0x71 or bank == 0xF0 or bank == 0xF1;
    if (primary and offset >= 0x6000 and offset <= 0x7FFF) return @as(usize, offset & 0x1FFF);
    if (mirror and ((offset >= 0x6000 and offset <= 0x7FFF) or offset >= 0xE000)) {
        return @as(usize, offset & 0x1FFF);
    }
    return null;
}
