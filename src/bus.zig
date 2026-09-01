pub const address_mask: u32 = 0x00FF_FFFF;

pub const Bus = struct {
    open_bus: u8 = 0,
    last_address: u32 = 0,
    reads: u64 = 0,
    writes: u64 = 0,

    pub fn observeRead(self: *Bus, address: u32, value: u8) u8 {
        self.last_address = address & address_mask;
        self.open_bus = value;
        self.reads +%= 1;
        return value;
    }

    pub fn observeWrite(self: *Bus, address: u32, value: u8) void {
        self.last_address = address & address_mask;
        self.open_bus = value;
        self.writes +%= 1;
    }
};
