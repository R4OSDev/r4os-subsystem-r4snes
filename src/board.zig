const coprocessors = @import("coprocessors.zig");

pub const Mapping = enum {
    unknown,
    lo_rom,
    hi_rom,
    ex_hi_rom,
};

pub const Region = enum {
    unknown,
    ntsc,
    pal,
};

pub const Board = struct {
    mapping: Mapping = .unknown,
    region: Region = .unknown,
    fast_rom: bool = false,
    enhancement: coprocessors.Kind = .none,
    sram_bytes: usize = 0,
};
