pub const Smp = struct {
    a: u8 = 0,
    x: u8 = 0,
    y: u8 = 0,
    sp: u8 = 0xEF,
    pc: u16 = 0,
    psw: u8 = 0,
    cycles: u64 = 0,
    stopped: bool = false,
};
