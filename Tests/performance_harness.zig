const std = @import("std");
const core = @import("core");

const guest_nanoseconds: u64 = 5 * std.time.ns_per_s;

pub fn main(init: std.process.Init) !void {
    const clock_ns = try profileClock(init.io);
    const scpu_ns = try profileScpu(init.io);
    const ppu_ns = try profilePpu(init.gpa, init.io);
    const allocator = init.gpa;
    const image = try allocator.alloc(u8, core.fixture_rom.imageBytes(.rom_only));
    defer allocator.free(image);
    try core.fixture_rom.build(image, .rom_only);

    var cart = try core.cartridge.Cartridge.parse(allocator, image);
    defer cart.deinit();
    var machine = try core.machine.Machine.power(1, &cart, null);
    defer machine.close();

    _ = machine.runHostSlice(&cart, core.timing.maximum_host_slice_master_cycles, 0);
    const started = std.Io.Clock.awake.now(init.io);
    var slices: u64 = 0;
    while (machine.clock.master_cycles < 5 * core.timing.ntsc_master_hz or
        machine.host_budget.pending_master_cycles != 0)
    {
        const result = machine.runHostSlice(
            &cart,
            core.timing.maximum_host_slice_master_cycles,
            guest_nanoseconds,
        );
        if (result.fault) |fault| {
            std.debug.print("R4SNES performance: fault={s}\n", .{@tagName(fault)});
            return error.MachineFault;
        }
        if (result.granted_master_cycles == 0 and machine.host_budget.pending_master_cycles == 0) break;
        slices += 1;
    }
    const ended = std.Io.Clock.awake.now(init.io);
    const elapsed_ns: u64 = @intCast(ended.nanoseconds - started.nanoseconds);
    const cycles_per_second: u64 = if (elapsed_ns == 0)
        0
    else
        @intCast((@as(u128, machine.clock.master_cycles) * std.time.ns_per_s) / elapsed_ns);
    std.debug.print(
        "R4SNES performance: guest_ns={d} master_cycles={d} wall_ns={d} cycles_per_second={d} slices={d} beam_frames={d} ppu_frames={d} cpu_instructions={d} cpu_cycles={d} pc=0x{x:0>4} counter={d} cgram={d},{d} smp_cycles={d} smp_ticks={d} clock_ns={d} scpu_ns={d} ppu_ns={d}\n",
        .{ guest_nanoseconds, machine.clock.master_cycles, elapsed_ns, cycles_per_second, slices, machine.clock.frame, machine.ppu.frame_generation, machine.cpu.instructions, machine.cpu.master_cycles, machine.cpu.pc, machine.bus.wram[4], machine.ppu.cgram[0], machine.ppu.cgram[1], machine.smp.cycles, machine.smp.oscillator_ticks, clock_ns, scpu_ns, ppu_ns },
    );
}

const NullSink = struct {
    pub fn onMasterTick(_: *NullSink, _: *const core.timing.Clock, _: bool, _: bool) void {}
};

fn profileClock(io: std.Io) !u64 {
    var clock = core.timing.Clock{};
    var sink = NullSink{};
    const started = std.Io.Clock.awake.now(io);
    drainClock(&clock, &sink);
    return elapsed(started, std.Io.Clock.awake.now(io));
}

const ScpuSink = struct {
    scpu: *core.scpu.Scpu,
    ports: *core.controller.Ports,
    cpu: *core.cpu.Cpu,

    pub fn onMasterTick(self: *ScpuSink, clock: *const core.timing.Clock, refresh_start: bool, refresh_wait: bool) void {
        self.scpu.onMasterTick(clock, self.ports, self.cpu, refresh_start, refresh_wait);
    }
};

fn profileScpu(io: std.Io) !u64 {
    var clock = core.timing.Clock{};
    var scpu = core.scpu.Scpu{};
    var ports = core.controller.Ports{};
    var cpu = core.cpu.Cpu{};
    var sink = ScpuSink{ .scpu = &scpu, .ports = &ports, .cpu = &cpu };
    const started = std.Io.Clock.awake.now(io);
    drainClock(&clock, &sink);
    return elapsed(started, std.Io.Clock.awake.now(io));
}

const PpuSink = struct {
    ppu: *core.ppu.Ppu,

    pub fn onMasterTick(self: *PpuSink, clock: *const core.timing.Clock, _: bool, _: bool) void {
        self.ppu.onMasterTick(clock);
    }
};

fn profilePpu(allocator: std.mem.Allocator, io: std.Io) !u64 {
    const video = try allocator.create(core.ppu.Ppu);
    defer allocator.destroy(video);
    video.* = .{};
    var clock = core.timing.Clock{};
    var sink = PpuSink{ .ppu = video };
    const started = std.Io.Clock.awake.now(io);
    drainClock(&clock, &sink);
    return elapsed(started, std.Io.Clock.awake.now(io));
}

fn drainClock(clock: *core.timing.Clock, sink: anytype) void {
    var remaining = core.timing.ntsc_master_hz;
    while (remaining != 0) {
        const advanced = clock.runSlice(remaining, sink);
        remaining -= advanced;
    }
}

fn elapsed(started: std.Io.Timestamp, ended: std.Io.Timestamp) !u64 {
    const delta = ended.nanoseconds - started.nanoseconds;
    if (delta <= 0) return error.ProfileClockUnavailable;
    return @intCast(delta);
}
