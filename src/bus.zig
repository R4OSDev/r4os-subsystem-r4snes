const cartridge = @import("cartridge.zig");

pub const address_mask: u32 = 0x00FF_FFFF;
pub const wram_size: usize = 128 * 1024;

pub const AccessClass = enum {
    wram,
    mmio,
    cartridge_rom,
    cartridge_ram,
    open_bus,
};

pub const Latch = enum {
    cpu,
    ppu,
    none,
};

pub const MmioRead = struct {
    handled: bool = false,
    value: u8 = 0,
    latch: Latch = .cpu,
};

pub const Access = struct {
    value: u8,
    master_cycles: u8,
    class: AccessClass,
};

pub const Bus = struct {
    wram: [wram_size]u8 = [_]u8{0} ** wram_size,
    cpu_open_bus: u8 = 0,
    ppu_open_bus: u8 = 0,
    fast_rom_enabled: bool = false,
    last_address: u32 = 0,
    reads: u64 = 0,
    writes: u64 = 0,

    pub fn read(self: *Bus, cart: *const cartridge.Cartridge, mmio: anytype, raw_address: u32) Access {
        const address = raw_address & address_mask;
        self.last_address = address;
        self.reads +%= 1;

        if (wramIndex(address)) |index| {
            return self.completeRead(self.wram[index], 8, .wram, .cpu);
        }
        if (isMmioWindow(address)) {
            const reply: MmioRead = mmio.read(address, self.cpu_open_bus, self.ppu_open_bus);
            if (reply.handled) return self.completeRead(reply.value, mmioCycles(address), .mmio, reply.latch);
        }
        if (cart.board.sramIndex(address)) |index| {
            return self.completeRead(cart.readSram(index), 8, .cartridge_ram, .cpu);
        }
        if (cart.board.romIndex(address, cart.rom().len)) |index| {
            return self.completeRead(cart.readRom(index), self.romCycles(cart, address), .cartridge_rom, .cpu);
        }
        return .{ .value = self.cpu_open_bus, .master_cycles = 8, .class = .open_bus };
    }

    pub fn write(self: *Bus, cart: *cartridge.Cartridge, mmio: anytype, raw_address: u32, value: u8) Access {
        const address = raw_address & address_mask;
        self.last_address = address;
        self.writes +%= 1;
        self.cpu_open_bus = value;

        if (wramIndex(address)) |index| {
            self.wram[index] = value;
            return .{ .value = value, .master_cycles = 8, .class = .wram };
        }
        if (isMmioWindow(address) and mmio.write(address, value, self.cpu_open_bus, self.ppu_open_bus)) {
            return .{ .value = value, .master_cycles = mmioCycles(address), .class = .mmio };
        }
        if (cart.board.sramIndex(address)) |index| {
            cart.writeSram(index, value);
            return .{ .value = value, .master_cycles = 8, .class = .cartridge_ram };
        }
        if (cart.board.romIndex(address, cart.rom().len) != null) {
            return .{ .value = value, .master_cycles = self.romCycles(cart, address), .class = .cartridge_rom };
        }
        return .{ .value = value, .master_cycles = 8, .class = .open_bus };
    }

    fn completeRead(self: *Bus, value: u8, cycles: u8, class: AccessClass, latch: Latch) Access {
        switch (latch) {
            .cpu => self.cpu_open_bus = value,
            .ppu => self.ppu_open_bus = value,
            .none => {},
        }
        return .{ .value = value, .master_cycles = cycles, .class = class };
    }

    fn romCycles(self: *const Bus, cart: *const cartridge.Cartridge, address: u32) u8 {
        const bank: u8 = @truncate(address >> 16);
        return if (self.fast_rom_enabled and cart.board.fast_rom and bank >= 0x80) 6 else 8;
    }
};

// Compile-time adapter used by the CPU core. It keeps the CPU independent of
// cartridge mapping and MMIO ownership while ensuring production execution
// still goes through this 24-bit bus for every externally visible cycle.
pub fn CpuPort(comptime Mmio: type) type {
    return struct {
        bus: *Bus,
        cartridge: *cartridge.Cartridge,
        mmio: Mmio,

        const Self = @This();

        pub fn read(self: *Self, address: u32) Access {
            return self.bus.read(self.cartridge, self.mmio, address);
        }

        pub fn write(self: *Self, address: u32, value: u8) Access {
            return self.bus.write(self.cartridge, self.mmio, address, value);
        }

        pub fn idle(_: *Self, _: u32) u8 {
            // Internal 5A22 cycles are refined by the timing/MMIO stage. The
            // CPU nevertheless emits a distinct idle micro-operation now.
            return 6;
        }
    };
}

pub const NullMmio = struct {
    pub fn read(_: NullMmio, _: u32, _: u8, _: u8) MmioRead {
        return .{};
    }

    pub fn write(_: NullMmio, _: u32, _: u8, _: u8, _: u8) bool {
        return false;
    }
};

fn wramIndex(address: u32) ?usize {
    const bank: u8 = @truncate(address >> 16);
    const offset: u16 = @truncate(address);
    if (bank == 0x7E or bank == 0x7F) {
        return (@as(usize, bank - 0x7E) << 16) | @as(usize, offset);
    }
    if (isSystemBank(bank) and offset < 0x2000) return @as(usize, offset);
    return null;
}

fn isMmioWindow(address: u32) bool {
    const bank: u8 = @truncate(address >> 16);
    const offset: u16 = @truncate(address);
    return isSystemBank(bank) and offset >= 0x2000 and offset < 0x6000;
}

fn isSystemBank(bank: u8) bool {
    return bank <= 0x3F or (bank >= 0x80 and bank <= 0xBF);
}

fn mmioCycles(address: u32) u8 {
    const offset: u16 = @truncate(address);
    return if (offset >= 0x4000 and offset <= 0x41FF) 12 else 6;
}
