pub const Button = enum(u4) {
    b,
    y,
    select,
    start,
    up,
    down,
    left,
    right,
    a,
    x,
    l,
    r,
};

pub const ControllerPort = struct {
    connected: bool = false,
    held: u16 = 0,
    latched: u16 = 0,
    bit_index: u5 = 0,

    pub fn set(self: *ControllerPort, button: Button, down: bool) void {
        if (!self.connected) return;
        const bit = @as(u16, 1) << @intFromEnum(button);
        if (down) self.held |= bit else self.held &= ~bit;
    }

    pub fn latch(self: *ControllerPort) void {
        self.latched = self.held;
        self.bit_index = 0;
    }

    pub fn serialBit(self: *ControllerPort) u1 {
        if (!self.connected) return 1;
        if (self.bit_index >= 12) return 1;
        const shift: u4 = @intCast(self.bit_index);
        const result: u1 = @intCast((self.latched >> shift) & 1);
        self.bit_index += 1;
        return result;
    }
};

pub const Ports = struct {
    port1: ControllerPort = .{ .connected = true },
    port2: ControllerPort = .{},
};
