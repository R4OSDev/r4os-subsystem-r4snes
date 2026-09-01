pub const Status = packed struct(u8) {
    carry: bool = false,
    zero: bool = false,
    irq_disable: bool = true,
    decimal: bool = false,
    index_width: bool = true,
    accumulator_width: bool = true,
    overflow: bool = false,
    negative: bool = false,
};

pub const Cpu = struct {
    a: u16 = 0,
    x: u16 = 0,
    y: u16 = 0,
    s: u16 = 0x01FF,
    d: u16 = 0,
    db: u8 = 0,
    pb: u8 = 0,
    pc: u16 = 0,
    p: Status = .{},
    emulation: bool = true,
    stopped: bool = false,
    waiting: bool = false,
    master_cycles: u64 = 0,
};
