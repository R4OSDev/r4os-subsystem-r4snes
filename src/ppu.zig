pub const Ppu = struct {
    v_counter: u16 = 0,
    h_counter: u16 = 0,
    frame: u64 = 0,
    forced_blank: bool = true,
    brightness: u4 = 0,
};
