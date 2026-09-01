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

    pub fn clear(self: *ControllerPort) void {
        self.held = 0;
        self.latched = 0;
        self.bit_index = 0;
    }

    pub fn serialBit(self: *ControllerPort) u1 {
        if (!self.connected) return 1;
        const result: u1 = if (self.bit_index < 12)
            @intCast((self.latched >> @as(u4, @intCast(self.bit_index))) & 1)
        else if (self.bit_index < 16)
            0
        else
            1;
        if (self.bit_index == 31) return result;
        self.bit_index += 1;
        return result;
    }

    pub fn firstBit(self: *const ControllerPort) u1 {
        if (!self.connected) return 1;
        return @intCast(self.held & 1);
    }
};

pub const Ports = struct {
    port1: ControllerPort = .{ .connected = true },
    port2: ControllerPort = .{},
    strobe: bool = false,

    pub fn writeStrobe(self: *Ports, high: bool) void {
        self.strobe = high;
        if (high) self.latch();
    }

    pub fn latch(self: *Ports) void {
        self.port1.latch();
        self.port2.latch();
    }

    pub fn readPort1(self: *Ports) u1 {
        if (self.strobe) return self.port1.firstBit();
        return self.port1.serialBit();
    }

    pub fn readPort2(self: *Ports) u1 {
        if (self.strobe) return self.port2.firstBit();
        return self.port2.serialBit();
    }

    pub fn clearInput(self: *Ports) void {
        self.port1.clear();
        self.port2.clear();
        self.strobe = false;
    }
};
