pub const Mapping = enum {
    lo_rom,
    hi_rom,
    ex_lo_rom,
    ex_hi_rom,
};

pub const Region = enum {
    ntsc_j,
    ntsc_u,
    pal,
};

pub const Enhancement = enum {
    none,
    obc1,
    srtc,
    sdd1,
    spc7110_epson_rtc,
    super_fx,
    sa1,
    cx4,
    dsp1_family,
    st010_st011,
    st018,
    msu1,
    adapter_system,
    unknown,
};

pub const Disposition = enum {
    base_implemented,
    planned,
    planned_user_firmware,
    excluded,
    unsupported,
};

pub const Capability = struct {
    enhancement: Enhancement,
    disposition: Disposition,
    planned_version: ?[]const u8,
    firmware_bytes: usize = 0,
};

pub const capability_table = [_]Capability{
    .{ .enhancement = .none, .disposition = .base_implemented, .planned_version = "0.73.3" },
    .{ .enhancement = .obc1, .disposition = .base_implemented, .planned_version = "0.73.12" },
    .{ .enhancement = .srtc, .disposition = .base_implemented, .planned_version = "0.73.12" },
    .{ .enhancement = .sdd1, .disposition = .base_implemented, .planned_version = "0.73.13" },
    .{ .enhancement = .spc7110_epson_rtc, .disposition = .base_implemented, .planned_version = "0.73.13" },
    .{ .enhancement = .super_fx, .disposition = .base_implemented, .planned_version = "0.73.14" },
    .{ .enhancement = .sa1, .disposition = .base_implemented, .planned_version = "0.73.15" },
    .{ .enhancement = .cx4, .disposition = .planned, .planned_version = "0.73.16" },
    .{ .enhancement = .dsp1_family, .disposition = .planned_user_firmware, .planned_version = "0.73.17", .firmware_bytes = 0x2000 },
    .{ .enhancement = .st010_st011, .disposition = .planned_user_firmware, .planned_version = "0.73.18", .firmware_bytes = 0xD000 },
    .{ .enhancement = .st018, .disposition = .planned_user_firmware, .planned_version = "0.73.19", .firmware_bytes = 0x28000 },
    .{ .enhancement = .msu1, .disposition = .excluded, .planned_version = null },
    .{ .enhancement = .adapter_system, .disposition = .excluded, .planned_version = null },
    .{ .enhancement = .unknown, .disposition = .unsupported, .planned_version = null },
};

pub fn capability(enhancement: Enhancement) Capability {
    for (capability_table) |entry| {
        if (entry.enhancement == enhancement) return entry;
    }
    return capability_table[capability_table.len - 1];
}

pub fn enhancementForHeader(rom_type: u8, map_mode: u8) Enhancement {
    const identifier = (@as(u16, rom_type) << 8) | map_mode;
    return switch (identifier) {
        0x5535 => .srtc,
        0xF53A, 0xF93A => .spc7110_epson_rtc,
        0x2530 => .obc1,
        0x3320, 0x3420, 0x3520, 0x3323, 0x3423, 0x3523 => .sa1,
        0x1320,
        0x1420,
        0x1520,
        0x1A20,
        0x1330,
        0x1430,
        0x1530,
        0x1A30,
        => .super_fx,
        0x4332, 0x4532 => .sdd1,
        0xF320 => .cx4,
        0xF530 => .st018,
        0xF630 => .st010_st011,
        else => switch (rom_type) {
            0x00, 0x01, 0x02 => .none,
            0x03, 0x04, 0x05 => .dsp1_family,
            0xE3 => .adapter_system,
            else => .unknown,
        },
    };
}

pub const RevisionFamily = enum {
    obc1,
    srtc,
    sdd1,
    spc7110,
    super_fx,
    sa1,
};

/// Classifies only recognizable but unsupported revisions. It is deliberately
/// narrower than the general enhancement decoder so an unrelated unknown
/// cartridge cannot be mislabeled as a supported chip family.
pub fn unsupportedRevisionFamily(rom_type: u8, map_mode: u8) ?RevisionFamily {
    if ((rom_type & 0xF0) == 0x20 and (rom_type & 0x0F) >= 3 and
        ((map_mode & 0x2F) == 0x20 or (map_mode & 0x2F) == 0x21)) return .obc1;
    if ((rom_type & 0xF0) == 0x50 and (rom_type & 0x0F) >= 3 and
        (map_mode & 0x2F) == 0x25) return .srtc;
    if ((rom_type & 0xF0) == 0x40 and (rom_type & 0x0F) >= 3 and
        (map_mode & 0x2F) == 0x22 and rom_type != 0x43 and rom_type != 0x45) return .sdd1;
    if ((rom_type & 0xF0) == 0xF0 and (rom_type & 0x0F) >= 5 and
        (map_mode & 0x2F) == 0x2A and rom_type != 0xF5 and rom_type != 0xF9) return .spc7110;
    if ((rom_type & 0xF0) == 0x10 and (rom_type & 0x0F) >= 3 and
        ((map_mode & 0x2F) == 0x20) and
        rom_type != 0x13 and rom_type != 0x14 and rom_type != 0x15 and rom_type != 0x1A) return .super_fx;
    if ((rom_type & 0xF0) == 0x30 and (rom_type & 0x0F) >= 3 and
        ((map_mode & 0x2F) == 0x23 or (map_mode & 0x2F) == 0x20) and
        rom_type != 0x33 and rom_type != 0x34 and rom_type != 0x35) return .sa1;
    return null;
}

pub const Board = struct {
    mapping: Mapping,
    region: Region,
    fast_rom: bool,
    capability: Capability,
    sram_bytes: usize,
    battery: bool,

    pub fn readyForExecution(self: Board) bool {
        return self.capability.disposition == .base_implemented;
    }

    pub fn romIndex(self: Board, address: u32, rom_size: usize) ?usize {
        if (self.capability.enhancement == .super_fx) return decodeSuperFxCpuRomIndex(address, rom_size);
        // SA-1 Super MMC registers dynamically select the four ROM quadrants;
        // the cartridge device therefore owns every SA-1 ROM lookup.
        if (self.capability.enhancement == .sa1) return null;
        return decodeRomIndex(self.mapping, address, rom_size);
    }

    pub fn sramIndex(self: Board, address: u32) ?usize {
        if (self.sram_bytes == 0) return null;
        // The GSU owns its non-LoROM 6000-7fff and 70-71/F0-F1 mappings.
        // Cartridge routes those windows through the device before reaching
        // this generic mapper.
        if (self.capability.enhancement == .super_fx or self.capability.enhancement == .sa1) return null;
        const bank: u8 = @truncate(address >> 16);
        const offset: u16 = @truncate(address);
        const logical: usize = switch (self.mapping) {
            .lo_rom, .ex_lo_rom => blk: {
                if (!((bank >= 0x70 and bank <= 0x7D) or bank >= 0xF0) or offset >= 0x8000) return null;
                break :blk (@as(usize, bank & 0x0F) << 15) | @as(usize, offset & 0x7FFF);
            },
            .hi_rom => blk: {
                if (!((bank >= 0x20 and bank <= 0x3F) or (bank >= 0xA0 and bank <= 0xBF)) or
                    offset < 0x6000 or offset >= 0x8000) return null;
                break :blk (@as(usize, bank & 0x1F) << 13) | @as(usize, offset & 0x1FFF);
            },
            .ex_hi_rom => blk: {
                if (!(bank >= 0xA0 and bank <= 0xBF) or offset < 0x6000 or offset >= 0x8000) return null;
                break :blk (@as(usize, bank & 0x1F) << 13) | @as(usize, offset & 0x1FFF);
            },
        };
        return mirrorIndex(logical, self.sram_bytes);
    }
};

pub fn mappingForMode(map_mode: u8) ?Mapping {
    return switch (map_mode & 0x0F) {
        0x0 => .lo_rom,
        0x1 => .hi_rom,
        0x2 => .ex_lo_rom,
        0x5 => .ex_hi_rom,
        else => null,
    };
}

pub fn mappingForHeader(map_mode: u8, enhancement: Enhancement) ?Mapping {
    return switch (enhancement) {
        .sa1, .super_fx, .sdd1, .cx4, .obc1, .dsp1_family, .st010_st011, .st018 => .lo_rom,
        .srtc => .ex_hi_rom,
        .spc7110_epson_rtc => .hi_rom,
        else => mappingForMode(map_mode),
    };
}

pub fn regionForCode(code: u8) ?Region {
    return switch (code) {
        0x00 => .ntsc_j,
        0x01, 0x0D, 0x0F => .ntsc_u,
        0x02...0x0C => .pal,
        else => null,
    };
}

pub fn decodeRomIndex(mapping: Mapping, address: u32, rom_size: usize) ?usize {
    if (rom_size == 0 or address > 0x00FF_FFFF) return null;
    const bank: u8 = @truncate(address >> 16);
    const offset: u16 = @truncate(address);
    if (!romWindow(mapping, bank, offset)) return null;

    const logical: usize = switch (mapping) {
        .lo_rom => (@as(usize, bank & 0x7F) << 15) | @as(usize, offset & 0x7FFF),
        .hi_rom => (@as(usize, bank & 0x3F) << 16) | @as(usize, offset),
        .ex_lo_rom => blk: {
            const quadrant: usize = @as(usize, bank >> 6);
            const base = ([_]usize{ 0x400000, 0x600000, 0x000000, 0x200000 })[quadrant];
            break :blk base + (@as(usize, bank & 0x3F) << 15) + @as(usize, offset & 0x7FFF);
        },
        .ex_hi_rom => blk: {
            const base: usize = if (bank < 0x80) 0x400000 else 0;
            break :blk base + (@as(usize, bank & 0x3F) << 16) + @as(usize, offset);
        },
    };
    return mirrorIndex(logical, rom_size);
}

pub fn decodeSuperFxCpuRomIndex(address: u32, rom_size: usize) ?usize {
    if (rom_size == 0 or address > 0x00FF_FFFF) return null;
    const bank: u8 = @truncate(address >> 16);
    const offset: u16 = @truncate(address);
    if ((bank <= 0x3F or (bank >= 0x80 and bank <= 0xBF)) and offset >= 0x8000) {
        return mirrorIndex((@as(usize, bank & 0x3F) << 15) | @as(usize, offset & 0x7FFF), rom_size);
    }
    if ((bank >= 0x40 and bank <= 0x5F) or (bank >= 0xC0 and bank <= 0xDF)) {
        return mirrorIndex((@as(usize, bank & 0x1F) << 16) | @as(usize, offset), rom_size);
    }
    return null;
}

fn romWindow(mapping: Mapping, bank: u8, offset: u16) bool {
    return switch (mapping) {
        .lo_rom, .ex_lo_rom => offset >= 0x8000 or
            ((bank >= 0x40 and bank <= 0x6F) or (bank >= 0xC0 and bank <= 0xEF)),
        .hi_rom, .ex_hi_rom => offset >= 0x8000 or
            ((bank >= 0x40 and bank <= 0x7D) or bank >= 0xC0),
    };
}

/// SNES disconnected-address mirroring, equivalent to successively folding
/// the highest asserted address line around an arbitrary physical ROM size.
pub fn mirrorIndex(logical: usize, physical_size: usize) usize {
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
