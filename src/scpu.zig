const bus_mod = @import("bus.zig");
const cartridge_mod = @import("cartridge.zig");
const controller_mod = @import("controller.zig");
const cpu_mod = @import("cpu.zig");
const dma_mod = @import("dma.zig");
const timing = @import("timing.zig");

pub const MathOperation = enum {
    none,
    multiply,
    divide,
};

pub const Scpu = struct {
    wram_address: u32 = 0,
    nmi_enabled: bool = false,
    h_irq_enabled: bool = false,
    v_irq_enabled: bool = false,
    auto_joy_enabled: bool = false,
    pio: u8 = 0xff,
    htime: u16 = 0x1ff,
    vtime: u16 = 0x1ff,
    nmi_flag: bool = false,
    irq_flag: bool = false,
    irq_match: bool = false,
    last_vblank: bool = false,
    wrmpya: u8 = 0xff,
    wrmpyb: u8 = 0xff,
    wrdiva: u16 = 0xffff,
    wrdivb: u8 = 0xff,
    rddiv: u16 = 0,
    rdmpy: u16 = 0,
    math_operation: MathOperation = .none,
    math_counter: u5 = 0,
    math_shift: u32 = 0,
    joy: [4]u16 = [_]u16{0} ** 4,
    auto_joy_counter: u6 = 33,
    auto_joy_sample1: u2 = 0,
    auto_joy_sample2: u2 = 0,
    cpu_latch: bool = false,
    auto_joy_latch: bool = false,
    latched_h: u16 = 0,
    latched_v: u16 = 0,
    h_latch_high: bool = false,
    v_latch_high: bool = false,
    counters_latched: bool = false,
    dma_enable: u8 = 0,
    hdma_enable: u8 = 0,
    dma: dma_mod.Controller = .{},
    interrupt_polls: u64 = 0,
    event_digest: u64 = 0xcbf29ce484222325,

    pub fn reset(self: *Scpu, bus: *bus_mod.Bus, ports: *controller_mod.Ports, cpu: *cpu_mod.Cpu) void {
        self.* = .{};
        bus.fast_rom_enabled = false;
        ports.clearInput();
        ports.port1.connected = true;
        ports.port2.connected = false;
        cpu.setIrqLine(false);
        cpu.requestReset();
    }

    pub fn read(
        self: *Scpu,
        bus: *bus_mod.Bus,
        clock: *timing.Clock,
        ports: *controller_mod.Ports,
        cpu: *cpu_mod.Cpu,
        address: u32,
        cpu_open_bus: u8,
        ppu_open_bus: u8,
    ) bus_mod.MmioRead {
        const offset: u16 = @truncate(address);
        if (self.dma.readRegister(offset, cpu_open_bus)) |value| return internal(value);
        switch (offset) {
            0x2137 => {
                self.latchCounters(clock);
                return .{ .handled = true, .value = ppu_open_bus, .latch = .ppu };
            },
            0x213c => return .{ .handled = true, .value = self.readLatchedCounter(self.latched_h, &self.h_latch_high, ppu_open_bus), .latch = .ppu },
            0x213d => return .{ .handled = true, .value = self.readLatchedCounter(self.latched_v, &self.v_latch_high, ppu_open_bus), .latch = .ppu },
            0x2180 => {
                const value = bus.wram[@as(usize, @intCast(self.wram_address & 0x1ffff))];
                self.wram_address = (self.wram_address + 1) & 0x1ffff;
                return .{ .handled = true, .value = value };
            },
            0x4016 => {
                const value = (cpu_open_bus & 0xfc) | @as(u8, ports.readPort1());
                return .{ .handled = true, .value = value, .latch = .none };
            },
            0x4017 => {
                const value = (cpu_open_bus & 0xe0) | 0x1c | @as(u8, ports.readPort2());
                return .{ .handled = true, .value = value, .latch = .none };
            },
            0x4210 => {
                const value = (cpu_open_bus & 0x70) | 0x02 | (if (self.nmi_flag) @as(u8, 0x80) else 0);
                self.nmi_flag = false;
                return internal(value);
            },
            0x4211 => {
                const value = (cpu_open_bus & 0x7f) | (if (self.irq_flag) @as(u8, 0x80) else 0);
                self.irq_flag = false;
                cpu.setIrqLine(false);
                return internal(value);
            },
            0x4212 => {
                const active = self.auto_joy_enabled and self.auto_joy_counter < 33;
                const value = (cpu_open_bus & 0x3e) |
                    (if (active) @as(u8, 0x01) else 0) |
                    (if (clock.inHblank()) @as(u8, 0x40) else 0) |
                    (if (clock.inVblank()) @as(u8, 0x80) else 0);
                return internal(value);
            },
            0x4213 => return internal(self.pio),
            0x4214 => return internal(@truncate(self.rddiv)),
            0x4215 => return internal(@truncate(self.rddiv >> 8)),
            0x4216 => return internal(@truncate(self.rdmpy)),
            0x4217 => return internal(@truncate(self.rdmpy >> 8)),
            0x4218...0x421f => {
                const register = offset - 0x4218;
                const word = self.joy[register >> 1];
                const value: u8 = if ((register & 1) == 0) @truncate(word) else @truncate(word >> 8);
                return internal(value);
            },
            else => return .{},
        }
    }

    pub fn write(
        self: *Scpu,
        bus: *bus_mod.Bus,
        clock: *timing.Clock,
        ports: *controller_mod.Ports,
        cpu: *cpu_mod.Cpu,
        address: u32,
        value: u8,
    ) bool {
        const offset: u16 = @truncate(address);
        if (self.dma.writeRegister(offset, value)) {
            self.mixEvent((@as(u64, offset) << 8) | value);
            return true;
        }
        switch (offset) {
            0x2180 => {
                bus.wram[@as(usize, @intCast(self.wram_address & 0x1ffff))] = value;
                self.wram_address = (self.wram_address + 1) & 0x1ffff;
            },
            0x2181 => self.wram_address = (self.wram_address & 0x1ff00) | value,
            0x2182 => self.wram_address = (self.wram_address & 0x100ff) | (@as(u32, value) << 8),
            0x2183 => self.wram_address = (self.wram_address & 0x0ffff) | (@as(u32, value & 1) << 16),
            0x4016 => {
                self.cpu_latch = (value & 1) != 0;
                self.updateControllerLatch(ports);
            },
            0x4200 => {
                const was_nmi_enabled = self.nmi_enabled;
                self.auto_joy_enabled = (value & 0x01) != 0;
                self.h_irq_enabled = (value & 0x10) != 0;
                self.v_irq_enabled = (value & 0x20) != 0;
                self.nmi_enabled = (value & 0x80) != 0;
                if (!was_nmi_enabled and self.nmi_enabled and clock.inVblank()) cpu.requestNmi();
                if (!self.h_irq_enabled and !self.v_irq_enabled) {
                    self.irq_flag = false;
                    self.irq_match = false;
                    cpu.setIrqLine(false);
                }
                if (!self.auto_joy_enabled and self.auto_joy_counter >= 2) {
                    self.auto_joy_counter = 33;
                    self.auto_joy_latch = false;
                    self.updateControllerLatch(ports);
                }
            },
            0x4201 => {
                if ((self.pio & 0x80) != 0 and (value & 0x80) == 0) self.latchCounters(clock);
                self.pio = value;
            },
            0x4202 => self.wrmpya = value,
            0x4203 => self.startMultiply(value),
            0x4204 => self.wrdiva = (self.wrdiva & 0xff00) | value,
            0x4205 => self.wrdiva = (self.wrdiva & 0x00ff) | (@as(u16, value) << 8),
            0x4206 => self.startDivide(value),
            0x4207 => self.htime = (self.htime & 0x100) | value,
            0x4208 => self.htime = (self.htime & 0x0ff) | (@as(u16, value & 1) << 8),
            0x4209 => self.vtime = (self.vtime & 0x100) | value,
            0x420a => self.vtime = (self.vtime & 0x0ff) | (@as(u16, value & 1) << 8),
            0x420b => {
                self.dma_enable = value;
                self.dma.requestManual(value, 6);
            },
            0x420c => {
                self.hdma_enable = value;
                self.dma.setHdmaEnabled(value);
            },
            0x420d => bus.fast_rom_enabled = (value & 1) != 0,
            else => return false,
        }
        self.mixEvent((@as(u64, offset) << 8) | value);
        return true;
    }

    pub fn aluEdge(self: *Scpu) void {
        switch (self.math_operation) {
            .none => {},
            .multiply => {
                if ((self.rddiv & 1) != 0) self.rdmpy +%= @truncate(self.math_shift);
                self.rddiv >>= 1;
                self.math_shift = (self.math_shift << 1) & 0xffff;
                self.math_counter -= 1;
                if (self.math_counter == 0) self.math_operation = .none;
            },
            .divide => {
                self.rddiv = @truncate(@as(u32, self.rddiv) << 1);
                self.math_shift >>= 1;
                if (@as(u32, self.rdmpy) >= self.math_shift) {
                    self.rdmpy -%= @truncate(self.math_shift);
                    self.rddiv |= 1;
                }
                self.math_counter -= 1;
                if (self.math_counter == 0) self.math_operation = .none;
            },
        }
    }

    pub fn onMasterTick(
        self: *Scpu,
        clock: *const timing.Clock,
        ports: *controller_mod.Ports,
        cpu: *cpu_mod.Cpu,
        refresh_start: bool,
        refresh_wait: bool,
    ) void {
        if (refresh_start) self.mixEvent(0x52454652455348);
        if (refresh_wait and clock.refresh_active_remaining % 8 == 0) self.aluEdge();

        const vblank = clock.inVblank();
        if (vblank and !self.last_vblank) {
            self.nmi_flag = true;
            if (self.nmi_enabled) cpu.requestNmi();
            self.mixEvent(0x4e4d49);
        } else if (!vblank and self.last_vblank) {
            self.nmi_flag = false;
            self.auto_joy_counter = 33;
        }
        self.last_vblank = vblank;

        if ((clock.master_cycles & 3) == 0) self.pollInterrupts(clock, cpu);
        if ((clock.master_cycles & 127) == 0) self.joypadEdge(clock, ports);
        if (clock.v_counter == 0 and clock.h_counter == 12) self.dma.beginFrame();
        if (clock.v_counter < clock.profile().vblank_start and clock.h_counter == 1_104) self.dma.beginHblank();
    }

    pub fn cpuMayRun(self: *const Scpu) bool {
        return self.dma.cpuMayRun();
    }

    fn pollInterrupts(self: *Scpu, clock: *const timing.Clock, cpu: *cpu_mod.Cpu) void {
        self.interrupt_polls +%= 1;
        const enabled = self.h_irq_enabled or self.v_irq_enabled;
        const h_target: u16 = (self.htime + 1) << 2;
        const h_match = !self.h_irq_enabled or clock.h_counter == h_target;
        const v_match = !self.v_irq_enabled or clock.v_counter == self.vtime;
        const match = enabled and h_match and v_match and (clock.v_counter != 0 or clock.h_counter != 0);
        if (match and !self.irq_match) {
            self.irq_flag = true;
            cpu.setIrqLine(true);
            self.mixEvent(0x495251);
        }
        self.irq_match = match;
    }

    fn joypadEdge(self: *Scpu, clock: *const timing.Clock, ports: *controller_mod.Ports) void {
        if (clock.v_counter == clock.profile().vblank_start and
            (clock.master_cycles & 255) == 0 and
            clock.h_counter >= 130 and clock.h_counter <= 384)
        {
            self.auto_joy_counter = 0;
        } else {
            if (self.auto_joy_counter >= 33) return;
            self.auto_joy_counter += 1;
        }

        if (self.auto_joy_counter == 0) {
            self.auto_joy_latch = self.auto_joy_enabled;
            self.updateControllerLatch(ports);
            if (self.auto_joy_enabled) self.joy = [_]u16{0} ** 4;
        }
        if (self.auto_joy_counter == 1) {
            self.auto_joy_latch = false;
            self.updateControllerLatch(ports);
        }
        if (self.auto_joy_counter != 1 and !self.auto_joy_enabled) {
            self.auto_joy_counter = 33;
            return;
        }
        if (self.auto_joy_counter >= 2) {
            if ((self.auto_joy_counter & 1) == 0) {
                self.auto_joy_sample1 = @as(u2, ports.readPort1());
                self.auto_joy_sample2 = @as(u2, ports.readPort2());
            } else {
                self.joy[0] = (self.joy[0] << 1) | @as(u16, self.auto_joy_sample1 & 1);
                self.joy[1] = (self.joy[1] << 1) | @as(u16, self.auto_joy_sample2 & 1);
                self.joy[2] = (self.joy[2] << 1) | @as(u16, self.auto_joy_sample1 >> 1);
                self.joy[3] = (self.joy[3] << 1) | @as(u16, self.auto_joy_sample2 >> 1);
            }
        }
    }

    fn updateControllerLatch(self: *Scpu, ports: *controller_mod.Ports) void {
        ports.writeStrobe(self.cpu_latch or self.auto_joy_latch);
    }

    fn startMultiply(self: *Scpu, value: u8) void {
        self.rdmpy = 0;
        if (self.math_operation != .none) return;
        self.wrmpyb = value;
        self.rddiv = (@as(u16, value) << 8) | self.wrmpya;
        self.math_operation = .multiply;
        self.math_counter = 8;
        self.math_shift = value;
    }

    fn startDivide(self: *Scpu, value: u8) void {
        self.rdmpy = self.wrdiva;
        if (self.math_operation != .none) return;
        self.wrdivb = value;
        self.rddiv = 0;
        self.math_operation = .divide;
        self.math_counter = 16;
        self.math_shift = @as(u32, value) << 16;
    }

    fn latchCounters(self: *Scpu, clock: *const timing.Clock) void {
        self.latched_h = clock.horizontalDot();
        self.latched_v = clock.v_counter;
        self.h_latch_high = false;
        self.v_latch_high = false;
        self.counters_latched = true;
    }

    fn readLatchedCounter(_: *Scpu, value: u16, high: *bool, open_bus: u8) u8 {
        const result: u8 = if (!high.*)
            @truncate(value)
        else
            (open_bus & 0xfe) | @as(u8, @truncate(value >> 8));
        high.* = !high.*;
        return result;
    }

    fn mixEvent(self: *Scpu, value: u64) void {
        self.event_digest = (self.event_digest ^ value) *% 0x100000001b3;
    }
};

fn internal(value: u8) bus_mod.MmioRead {
    return .{ .handled = true, .value = value, .latch = .none };
}

pub fn MmioWithDevice(comptime Device: type) type {
    return struct {
        scpu: *Scpu,
        bus: *bus_mod.Bus,
        clock: *timing.Clock,
        ports: *controller_mod.Ports,
        cpu: *cpu_mod.Cpu,
        device: Device,

        const Self = @This();

        pub fn read(self: *Self, address: u32, cpu_open_bus: u8, ppu_open_bus: u8) bus_mod.MmioRead {
            const reply = self.scpu.read(self.bus, self.clock, self.ports, self.cpu, address, cpu_open_bus, ppu_open_bus);
            if (reply.handled) return reply;
            return self.device.read(address, cpu_open_bus, ppu_open_bus);
        }

        pub fn write(self: *Self, address: u32, value: u8, cpu_open_bus: u8, ppu_open_bus: u8) bool {
            if (self.scpu.write(self.bus, self.clock, self.ports, self.cpu, address, value)) return true;
            return self.device.write(address, value, cpu_open_bus, ppu_open_bus);
        }
    };
}

pub const Mmio = MmioWithDevice(bus_mod.NullMmio);

fn EventSink(comptime Device: type) type {
    return struct {
        scpu: *Scpu,
        ports: *controller_mod.Ports,
        cpu: *cpu_mod.Cpu,
        device: Device,

        const Self = @This();

        pub fn onMasterTick(self: *Self, clock: *const timing.Clock, refresh_start: bool, refresh_wait: bool) void {
            self.scpu.onMasterTick(clock, self.ports, self.cpu, refresh_start, refresh_wait);
            if (comptime deviceObservesMasterClock(Device)) self.device.onMasterTick(clock);
        }
    };
}

fn deviceObservesMasterClock(comptime Device: type) bool {
    const Owner = switch (@typeInfo(Device)) {
        .pointer => |pointer| pointer.child,
        else => Device,
    };
    return @hasDecl(Owner, "onMasterTick");
}

pub fn TimedPortWithDevice(comptime Device: type) type {
    return struct {
        bus: *bus_mod.Bus,
        cartridge: *cartridge_mod.Cartridge,
        scpu: *Scpu,
        clock: *timing.Clock,
        controllers: *controller_mod.Ports,
        cpu: *cpu_mod.Cpu,
        device: Device,

        const Self = @This();
        const DeviceMmio = MmioWithDevice(Device);

        pub fn read(self: *Self, address: u32) bus_mod.Access {
            var adapter = self.makeMmio();
            var access = self.bus.read(self.cartridge, &adapter, address);
            var events = self.makeSink();
            access.master_cycles = self.clock.advanceCpuCycle(access.master_cycles, &events);
            self.scpu.aluEdge();
            return access;
        }

        pub fn write(self: *Self, address: u32, value: u8) bus_mod.Access {
            self.scpu.aluEdge();
            var adapter = self.makeMmio();
            var access = self.bus.write(self.cartridge, &adapter, address, value);
            var events = self.makeSink();
            access.master_cycles = self.clock.advanceCpuCycle(access.master_cycles, &events);
            return access;
        }

        pub fn idle(self: *Self, _: u32) u8 {
            var events = self.makeSink();
            const elapsed = self.clock.advanceCpuCycle(6, &events);
            self.scpu.aluEdge();
            return elapsed;
        }

        pub fn cpuReady(self: *const Self) bool {
            return self.scpu.cpuMayRun();
        }

        pub fn serviceDmaStep(self: *Self) dma_mod.StepResult {
            var dma_port = DmaBusPort(Device){
                .bus = self.bus,
                .cartridge = self.cartridge,
                .scpu = self.scpu,
                .clock = self.clock,
                .controllers = self.controllers,
                .cpu = self.cpu,
                .device = self.device,
            };
            return self.scpu.dma.step(&dma_port);
        }

        fn makeMmio(self: *Self) DeviceMmio {
            return .{
                .scpu = self.scpu,
                .bus = self.bus,
                .clock = self.clock,
                .ports = self.controllers,
                .cpu = self.cpu,
                .device = self.device,
            };
        }

        fn makeSink(self: *Self) EventSink(Device) {
            return .{ .scpu = self.scpu, .ports = self.controllers, .cpu = self.cpu, .device = self.device };
        }
    };
}

pub const TimedPort = TimedPortWithDevice(bus_mod.NullMmio);

pub fn DmaBusPort(comptime Device: type) type {
    return struct {
        bus: *bus_mod.Bus,
        cartridge: *cartridge_mod.Cartridge,
        scpu: *Scpu,
        clock: *timing.Clock,
        controllers: *controller_mod.Ports,
        cpu: *cpu_mod.Cpu,
        device: Device,

        const Self = @This();
        const DeviceMmio = MmioWithDevice(Device);

        pub fn masterClock(self: *const Self) u64 {
            return self.clock.master_cycles;
        }

        pub fn advanceDma(self: *Self, clocks: u8) u8 {
            var events = EventSink(Device){ .scpu = self.scpu, .ports = self.controllers, .cpu = self.cpu, .device = self.device };
            return self.clock.advanceCpuCycle(clocks, &events);
        }

        pub fn readDma(self: *Self, address: u32, _: dma_mod.Revision) dma_mod.ReadResult {
            const valid = dma_mod.validAAddress(address);
            const value = if (valid) self.readBus(address) else invalid: {
                self.bus.cpu_open_bus = 0;
                break :invalid 0;
            };
            const elapsed = self.advanceDma(8);
            return .{ .address = address & bus_mod.address_mask, .value = value, .valid = valid, .master_cycles = elapsed };
        }

        pub fn transferByte(
            self: *Self,
            channel: *const dma_mod.Channel,
            byte_index: u3,
            address_a: u32,
            revision: dma_mod.Revision,
        ) dma_mod.TransferResult {
            const canonical_a = address_a & bus_mod.address_mask;
            const address_b = channel.bBusAddress(byte_index);
            const valid_a = dma_mod.validAAddress(canonical_a);
            const wram_conflict = address_b == 0x2180 and dma_mod.isWorkRamAddress(canonical_a);
            var value: u8 = 0;
            const valid = valid_a and !wram_conflict;

            if (!channel.directionBtoA()) {
                if (valid_a) {
                    value = self.readBus(canonical_a);
                } else {
                    self.bus.cpu_open_bus = 0;
                }
                if (!wram_conflict) self.writeBus(address_b, value);
            } else {
                if (wram_conflict) {
                    value = if (revision == .s_cpu_a) 0 else 0xff;
                    self.bus.cpu_open_bus = value;
                } else {
                    value = self.readBus(address_b);
                }
                if (valid_a) self.writeBus(canonical_a, value);
            }

            const elapsed = self.advanceDma(8);
            return .{
                .a_address = canonical_a,
                .b_address = address_b,
                .value = value,
                .valid = valid,
                .conflict = wram_conflict,
                .master_cycles = elapsed,
            };
        }

        fn readBus(self: *Self, address: u32) u8 {
            var adapter = self.makeMmio();
            return self.bus.read(self.cartridge, &adapter, address).value;
        }

        fn writeBus(self: *Self, address: u32, value: u8) void {
            var adapter = self.makeMmio();
            _ = self.bus.write(self.cartridge, &adapter, address, value);
        }

        fn makeMmio(self: *Self) DeviceMmio {
            return .{
                .scpu = self.scpu,
                .bus = self.bus,
                .clock = self.clock,
                .ports = self.controllers,
                .cpu = self.cpu,
                .device = self.device,
            };
        }
    };
}
