const std = @import("std");
const r4os = @import("r4os");
const core = @import("core");

const Harness = struct {
    bus: core.bus.Bus = .{},
    clock: core.timing.Clock = .{},
    ports: core.controller.Ports = .{},
    cpu: core.cpu.Cpu = .{},
    scpu: core.scpu.Scpu = .{},

    fn write(self: *Harness, address: u32, value: u8) void {
        tryWrite(self.scpu.write(&self.bus, &self.clock, &self.ports, &self.cpu, address, value));
    }

    fn read(self: *Harness, address: u32, open_bus: u8) core.bus.MmioRead {
        return self.scpu.read(&self.bus, &self.clock, &self.ports, &self.cpu, address, open_bus, self.bus.ppu_open_bus);
    }

    fn advance(self: *Harness, clocks: u64) void {
        var remaining = clocks;
        var sink = Sink{ .harness = self };
        while (remaining != 0) {
            const elapsed = self.clock.runSlice(remaining, &sink);
            std.debug.assert(elapsed != 0);
            remaining -= elapsed;
        }
    }
};

const Sink = struct {
    harness: *Harness,

    pub fn onMasterTick(self: *Sink, clock: *const core.timing.Clock, refresh_start: bool, refresh_wait: bool) void {
        self.harness.scpu.onMasterTick(clock, &self.harness.ports, &self.harness.cpu, refresh_start, refresh_wait);
    }
};

fn tryWrite(ok: bool) void {
    std.debug.assert(ok);
}

test "integer NTSC and PAL clocks remain bounded partition invariant and pause cleanly" {
    try std.testing.expectEqual(@as(u32, 32_768), core.timing.maximum_host_slice_master_cycles);
    try std.testing.expectEqual(@as(u64, 21_477_272), core.timing.Profile.forRegion(.ntsc).master_hz);
    try std.testing.expectEqual(@as(u16, 262), core.timing.Profile.forRegion(.ntsc).scanlines);
    try std.testing.expectEqual(@as(u16, 312), core.timing.Profile.forRegion(.pal).scanlines);

    var one = Harness{};
    var many = Harness{};
    one.ports.port1.set(.b, true);
    many.ports.port1.set(.b, true);
    one.advance(700_000);
    var remaining: u64 = 700_000;
    const partitions = [_]u64{ 1, 7, 113, 4_096, 31_337 };
    var part: usize = 0;
    while (remaining != 0) : (part += 1) {
        const count = @min(remaining, partitions[part % partitions.len]);
        many.advance(count);
        remaining -= count;
    }
    try expectSystemDigestEqual(&one, &many);

    one.clock.paused = true;
    var sink = Sink{ .harness = &one };
    const before = one.clock.master_cycles;
    try std.testing.expectEqual(@as(u32, 0), one.clock.runSlice(50_000, &sink));
    try std.testing.expectEqual(before, one.clock.master_cycles);

    var ntsc = Harness{};
    ntsc.advance(@as(u64, 1_364) * 262);
    try std.testing.expectEqual(@as(u64, 1), ntsc.clock.frame);
    var pal = Harness{ .clock = core.timing.Clock.init(.pal) };
    pal.advance(@as(u64, 1_364) * 312);
    try std.testing.expectEqual(@as(u64, 1), pal.clock.frame);
    try std.testing.expect(ntsc.clock.apu_ticks != 0 and pal.clock.apu_ticks != 0);
}

test "5A22 WRAM ports MEMSEL counters masks and open bus follow their owners" {
    var h = Harness{};
    h.write(0x2181, 0xfe);
    h.write(0x2182, 0xff);
    h.write(0x2183, 1);
    h.write(0x2180, 0xa5);
    try std.testing.expectEqual(@as(u8, 0xa5), h.bus.wram[0x1fffe]);
    try std.testing.expectEqual(@as(u32, 0x1ffff), h.scpu.wram_address);
    h.bus.wram[0x1ffff] = 0x3c;
    try std.testing.expectEqual(@as(u8, 0x3c), h.read(0x2180, 0).value);
    try std.testing.expectEqual(@as(u32, 0), h.scpu.wram_address);

    h.write(0x420d, 1);
    try std.testing.expect(h.bus.fast_rom_enabled);
    h.write(0x420d, 0);
    try std.testing.expect(!h.bus.fast_rom_enabled);

    h.clock.h_counter = 1_300;
    h.clock.v_counter = 123;
    h.write(0x4201, 0x7f);
    try std.testing.expect(h.scpu.counters_latched);
    try std.testing.expectEqual(h.clock.horizontalDot(), h.scpu.latched_h);
    try std.testing.expectEqual(@as(u8, @truncate(h.scpu.latched_h)), h.read(0x213c, 0).value);
    try std.testing.expectEqual(@as(u8, @truncate(h.scpu.latched_h >> 8)), h.read(0x213c, 0).value & 1);

    h.scpu.nmi_flag = true;
    const nmi = h.read(0x4210, 0x7d);
    try std.testing.expectEqual(core.bus.Latch.none, nmi.latch);
    try std.testing.expectEqual(@as(u8, 0xf2), nmi.value);
    try std.testing.expect(!h.scpu.nmi_flag);
    h.clock.h_counter = core.timing.hblank_start_master_cycle;
    h.clock.v_counter = h.clock.profile().vblank_start;
    try std.testing.expectEqual(@as(u8, 0xc0), h.read(0x4212, 0).value & 0xc0);
}

test "5A22 multiplier and divider expose progressive integer results" {
    var h = Harness{};
    h.write(0x4202, 12);
    h.write(0x4203, 13);
    try std.testing.expectEqual(core.scpu.MathOperation.multiply, h.scpu.math_operation);
    for (0..8) |_| h.scpu.aluEdge();
    try std.testing.expectEqual(@as(u16, 156), h.scpu.rdmpy);
    try std.testing.expectEqual(core.scpu.MathOperation.none, h.scpu.math_operation);

    h.write(0x4204, 0xe8);
    h.write(0x4205, 0x03);
    h.write(0x4206, 7);
    for (0..16) |_| h.scpu.aluEdge();
    try std.testing.expectEqual(@as(u16, 142), h.scpu.rddiv);
    try std.testing.expectEqual(@as(u16, 6), h.scpu.rdmpy);

    h.write(0x4206, 0);
    for (0..16) |_| h.scpu.aluEdge();
    try std.testing.expectEqual(@as(u16, 0xffff), h.scpu.rddiv);
    try std.testing.expectEqual(@as(u16, 1_000), h.scpu.rdmpy);
}

test "refresh steals forty clocks and interrupt edges drive the CPU lines" {
    var h = Harness{};
    h.clock.h_counter = 536;
    h.clock.refresh_position = 538;
    var sink = Sink{ .harness = &h };
    try std.testing.expectEqual(@as(u8, 48), h.clock.advanceCpuCycle(8, &sink));
    try std.testing.expectEqual(@as(u64, 1), h.clock.refresh_events);
    try std.testing.expectEqual(@as(u64, 40), h.clock.refresh_wait_master_cycles);

    h.write(0x4207, 1); // target ((1 + 1) * 4) = clock 8
    h.write(0x4208, 0);
    h.write(0x4200, 0x10);
    h.clock.h_counter = 0;
    h.clock.v_counter = 1;
    h.clock.master_cycles = 0;
    h.advance(9);
    try std.testing.expect(h.scpu.irq_flag);
    try std.testing.expect(h.cpu.irq_line);
    try std.testing.expectEqual(@as(u8, 0x80), h.read(0x4211, 0).value);
    try std.testing.expect(!h.cpu.irq_line);

    h.write(0x4200, 0x80);
    h.clock.v_counter = h.clock.profile().vblank_start;
    h.clock.h_counter = 0;
    h.scpu.last_vblank = false;
    h.advance(1);
    try std.testing.expect(h.cpu.nmi_pending);
    try std.testing.expect(h.scpu.nmi_flag);
}

test "keyboard map serial pad and focus policy cover every fixed port-one bit" {
    const expected = [_]struct { usage: u32, button: core.controller.Button }{
        .{ .usage = r4os.abi.physical_key_usage_up, .button = .up },
        .{ .usage = r4os.abi.physical_key_usage_down, .button = .down },
        .{ .usage = r4os.abi.physical_key_usage_left, .button = .left },
        .{ .usage = r4os.abi.physical_key_usage_right, .button = .right },
        .{ .usage = r4os.abi.physical_key_usage_enter, .button = .start },
        .{ .usage = r4os.abi.physical_key_usage_right_control, .button = .select },
        .{ .usage = r4os.abi.physical_key_usage_keypad_8, .button = .x },
        .{ .usage = r4os.abi.physical_key_usage_keypad_6, .button = .a },
        .{ .usage = r4os.abi.physical_key_usage_keypad_2, .button = .b },
        .{ .usage = r4os.abi.physical_key_usage_keypad_4, .button = .y },
        .{ .usage = r4os.abi.physical_key_usage_keypad_7, .button = .l },
        .{ .usage = r4os.abi.physical_key_usage_keypad_9, .button = .r },
    };
    var ports = core.controller.Ports{};
    for (expected) |binding| {
        try std.testing.expectEqual(binding.button, core.host_adapter.buttonForUsage(binding.usage).?);
        try std.testing.expect(core.host_adapter.applyInput(&ports, binding.usage, .press));
        try std.testing.expect(core.host_adapter.applyInput(&ports, binding.usage, .repeat));
        const mask = @as(u16, 1) << @intFromEnum(binding.button);
        try std.testing.expectEqual(mask, ports.port1.held & mask);
        try std.testing.expect(core.host_adapter.applyInput(&ports, binding.usage, .release));
        try std.testing.expectEqual(@as(u16, 0), ports.port1.held & mask);
    }
    _ = core.host_adapter.applyInput(&ports, r4os.abi.physical_key_usage_left, .press);
    _ = core.host_adapter.applyInput(&ports, r4os.abi.physical_key_usage_right, .press);
    try std.testing.expectEqual(@as(u16, 0x00c0), ports.port1.held & 0x00c0);
    _ = core.host_adapter.applyInput(&ports, 0, .focus_lost);
    try std.testing.expectEqual(@as(u16, 0), ports.port1.held);
    try std.testing.expect(!ports.port2.connected);
    ports.port2.set(.b, true);
    try std.testing.expectEqual(@as(u16, 0), ports.port2.held);
}

test "manual and automatic serial reads keep port two disconnected" {
    var h = Harness{};
    h.ports.port1.set(.b, true);
    h.ports.port1.set(.start, true);
    h.write(0x4016, 1);
    try std.testing.expectEqual(@as(u8, 1), h.read(0x4016, 0).value & 1);
    try std.testing.expectEqual(@as(u8, 1), h.read(0x4016, 0).value & 1);
    h.write(0x4016, 0);
    try std.testing.expectEqual(@as(u8, 1), h.read(0x4016, 0).value & 1);
    try std.testing.expectEqual(@as(u8, 0), h.read(0x4016, 0).value & 1);
    try std.testing.expectEqual(@as(u8, 1), h.read(0x4017, 0).value & 1);
    try std.testing.expectEqual(@as(u8, 0x1c), h.read(0x4017, 0).value & 0x1c);

    h.write(0x4200, 0x01);
    h.clock.v_counter = h.clock.profile().vblank_start;
    h.clock.h_counter = 256;
    h.clock.master_cycles = 0;
    h.scpu.last_vblank = true;
    h.advance(1);
    try std.testing.expectEqual(@as(u6, 0), h.scpu.auto_joy_counter);
    h.advance(4_224);
    try std.testing.expectEqual(@as(u6, 33), h.scpu.auto_joy_counter);
    try std.testing.expectEqual(@as(u16, 0x9000), h.scpu.joy[0]);
    try std.testing.expectEqual(@as(u16, 0xffff), h.scpu.joy[1]);
    try std.testing.expectEqual(@as(u8, 0), h.read(0x4212, 0).value & 1);
}

test "production CPU port keeps execution invariant across host grouping" {
    const allocator = std.testing.allocator;
    const image = try makeCpuImage(allocator);
    defer allocator.free(image);
    var first_cart = try core.cartridge.Cartridge.parse(allocator, image);
    defer first_cart.deinit();
    var second_cart = try core.cartridge.Cartridge.parse(allocator, image);
    defer second_cart.deinit();
    var first = Harness{};
    var second = Harness{};
    try runCpu(&first, &first_cart, 300, &.{300});
    try runCpu(&second, &second_cart, 300, &.{ 1, 3, 7, 19 });
    try expectSystemDigestEqual(&first, &second);
    try std.testing.expectEqual(first.cpu.pc, second.cpu.pc);
    try std.testing.expectEqual(first.cpu.instructions, second.cpu.instructions);
    try std.testing.expectEqual(first.cpu.master_cycles, second.cpu.master_cycles);
}

const PpuDmaDevice = struct {
    registers: [256]u8 = [_]u8{0} ** 256,
    writes: u64 = 0,

    pub fn read(self: *PpuDmaDevice, address: u32, _: u8, _: u8) core.bus.MmioRead {
        const offset: u16 = @truncate(address);
        if (offset < 0x2100 or offset > 0x21ff) return .{};
        return .{ .handled = true, .value = self.registers[@as(u8, @truncate(offset))], .latch = .ppu };
    }

    pub fn write(self: *PpuDmaDevice, address: u32, value: u8, _: u8, _: u8) bool {
        const offset: u16 = @truncate(address);
        if (offset < 0x2100 or offset > 0x21ff) return false;
        self.registers[@as(u8, @truncate(offset))] = value;
        self.writes +%= 1;
        return true;
    }
};

test "production DMA bus confines conflicts wrap and refresh while CPU is halted" {
    const allocator = std.testing.allocator;
    const image = try makeCpuImage(allocator);
    defer allocator.free(image);
    var cart = try core.cartridge.Cartridge.parse(allocator, image);
    defer cart.deinit();
    var h = Harness{};
    var device = PpuDmaDevice{};
    var port = core.scpu.TimedPortWithDevice(*PpuDmaDevice){
        .bus = &h.bus,
        .cartridge = &cart,
        .scpu = &h.scpu,
        .clock = &h.clock,
        .controllers = &h.ports,
        .cpu = &h.cpu,
        .device = &device,
    };

    h.bus.wram[0x100] = 0x12;
    h.bus.wram[0x101] = 0x34;
    h.write(0x4300, 4);
    h.write(0x4301, 0xff);
    h.write(0x4302, 0x00);
    h.write(0x4303, 0x01);
    h.write(0x4304, 0x7e);
    h.write(0x4305, 2);
    h.write(0x4306, 0);
    h.clock.master_cycles = 536;
    h.clock.h_counter = 536;
    h.clock.refresh_position = 538;
    h.write(0x420b, 1);
    try std.testing.expect(!port.cpuReady());
    try serviceDma(&port);
    try std.testing.expectEqual(@as(u8, 0x12), device.registers[0xff]);
    try std.testing.expectEqual(@as(u8, 0x34), device.registers[0x00]);
    try std.testing.expectEqual(@as(u64, 1), h.clock.refresh_events);
    try std.testing.expectEqual(@as(u64, 40), h.clock.refresh_wait_master_cycles);
    try std.testing.expect(port.cpuReady());

    h.write(0x4200, 0x80);
    h.clock.v_counter = h.clock.profile().vblank_start - 1;
    h.clock.h_counter = 1_362;
    h.clock.master_cycles = 1_362;
    h.scpu.last_vblank = false;
    h.cpu.nmi_pending = false;
    h.write(0x4300, 0);
    h.write(0x4301, 0x10);
    h.write(0x4302, 0x00);
    h.write(0x4303, 0x01);
    h.write(0x4304, 0x7e);
    h.write(0x4305, 1);
    h.write(0x420b, 1);
    try serviceDma(&port);
    try std.testing.expect(h.cpu.nmi_pending);
    try std.testing.expect(h.scpu.nmi_flag);

    h.scpu.dma.clearTrace();
    h.scpu.wram_address = 0x400;
    h.write(0x4300, 0);
    h.write(0x4301, 0x80);
    h.write(0x4302, 0x00);
    h.write(0x4303, 0x02);
    h.write(0x4304, 0x7e);
    h.write(0x4305, 1);
    h.write(0x420b, 1);
    try serviceDma(&port);
    try std.testing.expectEqual(@as(u32, 0x400), h.scpu.wram_address);
    try std.testing.expectEqual(core.dma.TraceKind.conflict, firstDmaTransfer(&h.scpu.dma).kind);

    h.scpu.dma.clearTrace();
    h.bus.wram[0x200] = 0;
    h.write(0x4300, 0x80);
    h.write(0x4301, 0x80);
    h.write(0x4302, 0x00);
    h.write(0x4303, 0x02);
    h.write(0x4304, 0x7e);
    h.write(0x4305, 1);
    h.write(0x420b, 1);
    try serviceDma(&port);
    try std.testing.expectEqual(@as(u8, 0xff), h.bus.wram[0x200]);
    try std.testing.expectEqual(core.dma.TraceKind.conflict, firstDmaTransfer(&h.scpu.dma).kind);

    h.scpu.dma.clearTrace();
    device.registers[0x10] = 0xa5;
    h.write(0x4300, 0);
    h.write(0x4301, 0x10);
    h.write(0x4302, 0x00);
    h.write(0x4303, 0x43);
    h.write(0x4304, 0x00);
    h.write(0x4305, 1);
    h.write(0x420b, 1);
    try serviceDma(&port);
    try std.testing.expectEqual(@as(u8, 0), device.registers[0x10]);
    try std.testing.expect(!firstDmaTransfer(&h.scpu.dma).valid);
}

test "production timed port advances the PPU on the canonical master timeline" {
    const allocator = std.testing.allocator;
    const image = try makeCpuImage(allocator);
    defer allocator.free(image);
    var cart = try core.cartridge.Cartridge.parse(allocator, image);
    defer cart.deinit();
    var h = Harness{};
    var ppu = core.ppu.Ppu{};
    ppu.forced_blank = false;
    ppu.brightness = 15;
    ppu.cgram[0] = 0x1f;
    h.clock.v_counter = 1;
    h.clock.h_counter = 88;
    var port = core.scpu.TimedPortWithDevice(*core.ppu.Ppu){
        .bus = &h.bus,
        .cartridge = &cart,
        .scpu = &h.scpu,
        .clock = &h.clock,
        .controllers = &h.ports,
        .cpu = &h.cpu,
        .device = &ppu,
    };
    _ = port.idle(0);
    try std.testing.expectEqual(@as(u32, 0xffff0000), ppu.working_frame[0]);
    try std.testing.expectEqual(@as(u16, 93), ppu.h_counter);
    try std.testing.expectEqual(h.clock.v_counter, ppu.v_counter);
}

fn serviceDma(port: anytype) !void {
    var steps: usize = 0;
    while (!port.cpuReady() and steps < 100_000) : (steps += 1) {
        const result = port.serviceDmaStep();
        try std.testing.expect(result.progressed);
    }
    try std.testing.expect(steps < 100_000);
}

fn firstDmaTransfer(controller: *const core.dma.Controller) core.dma.TraceEntry {
    for (controller.lastTrace()) |entry| {
        if (entry.kind == .transfer or entry.kind == .conflict) return entry;
    }
    unreachable;
}

fn runCpu(h: *Harness, cart: *core.cartridge.Cartridge, count: usize, groups: []const usize) !void {
    var port = core.scpu.TimedPort{
        .bus = &h.bus,
        .cartridge = cart,
        .scpu = &h.scpu,
        .clock = &h.clock,
        .controllers = &h.ports,
        .cpu = &h.cpu,
        .device = .{},
    };
    var completed: usize = 0;
    var group_index: usize = 0;
    while (completed < count) : (group_index += 1) {
        const batch = @min(count - completed, groups[group_index % groups.len]);
        for (0..batch) |_| _ = try h.cpu.step(&port);
        completed += batch;
    }
}

fn expectSystemDigestEqual(a: *const Harness, b: *const Harness) !void {
    try std.testing.expectEqual(a.clock.master_cycles, b.clock.master_cycles);
    try std.testing.expectEqual(a.clock.h_counter, b.clock.h_counter);
    try std.testing.expectEqual(a.clock.v_counter, b.clock.v_counter);
    try std.testing.expectEqual(a.clock.frame, b.clock.frame);
    try std.testing.expectEqual(a.clock.refresh_events, b.clock.refresh_events);
    try std.testing.expectEqual(a.clock.apu_phase, b.clock.apu_phase);
    try std.testing.expectEqual(a.clock.apu_ticks, b.clock.apu_ticks);
    try std.testing.expectEqual(a.scpu.event_digest, b.scpu.event_digest);
    try std.testing.expectEqual(a.scpu.auto_joy_counter, b.scpu.auto_joy_counter);
    try std.testing.expectEqualSlices(u16, a.scpu.joy[0..], b.scpu.joy[0..]);
    try std.testing.expectEqual(a.ports.port1.bit_index, b.ports.port1.bit_index);
}

fn makeCpuImage(allocator: std.mem.Allocator) ![]u8 {
    const rom = try allocator.alloc(u8, 32 * 1024);
    @memset(rom, 0xea);
    rom[0] = 0xea; // NOP
    rom[1] = 0x80; // BRA -3
    rom[2] = 0xfd;
    const header = rom[0x7fc0 .. 0x7fc0 + core.cartridge.header_length];
    @memset(header, 0);
    @memset(header[0..core.cartridge.title_length], ' ');
    @memcpy(header[0..17], "R4SNES CLOCK TEST");
    header[0x15] = 0x30;
    header[0x16] = 0x00;
    header[0x17] = 5;
    header[0x19] = 1;
    header[0x1a] = 0x33;
    header[0x3c] = 0x00;
    header[0x3d] = 0x80;
    var sum: u16 = 0;
    for (rom) |value| sum +%= value;
    const checksum = sum +% 0x01fe;
    const complement = ~checksum;
    header[0x1c] = @truncate(complement);
    header[0x1d] = @truncate(complement >> 8);
    header[0x1e] = @truncate(checksum);
    header[0x1f] = @truncate(checksum >> 8);
    return rom;
}
