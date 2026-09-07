const std = @import("std");
const core = @import("core");
const scene = core.performance_scene;

const HostClock = struct {
    io: std.Io,
    fn now(context: *anyopaque) u64 {
        const self: *HostClock = @ptrCast(@alignCast(context));
        return @intCast(std.Io.Clock.awake.now(self.io).nanoseconds);
    }
};

const Drain = struct {
    pcm: [core.sdsp.maximum_render_frames * core.sdsp.sample_bytes]u8 = undefined,
    bytes: u64 = 0,
    nonzero_bytes: u64 = 0,
    render_calls: u64 = 0,

    fn until(self: *Drain, machine: *core.machine.Machine, cart: *core.cartridge.Cartridge, guest_ns: u64) !void {
        const cycles = @as(u128, guest_ns) * machine.clock.profile().master_hz / std.time.ns_per_s;
        while (machine.clock.master_cycles < cycles or machine.host_budget.pending_master_cycles != 0) {
            const result = machine.runHostSlice(cart, core.timing.maximum_host_slice_master_cycles, guest_ns);
            if (result.fault) |fault| {
                std.debug.print("R4SNES scene fault={s} pc=0x{x} cycles={d}\n", .{ @tagName(fault), machine.cpu.pc, machine.clock.master_cycles });
                return error.MachineFault;
            }
            while (machine.smp.dsp.queuedFrames() != 0) {
                self.render_calls += 1;
                const count = machine.smp.dsp.renderPcm(&self.pcm);
                if (count <= 0) break;
                self.bytes += @intCast(count);
                for (self.pcm[0..@intCast(count)]) |byte| self.nonzero_bytes += @intFromBool(byte != 0);
            }
            if (result.granted_master_cycles == 0 and machine.host_budget.pending_master_cycles == 0) break;
        }
    }
};

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const image = try init.gpa.alloc(u8, scene.image_bytes);
    defer init.gpa.free(image);
    try scene.build(image);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(image, &digest, .{});
    if (args.len == 3 and std.mem.eql(u8, args[1], "--write-rom")) {
        try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = args[2], .data = image });
        return;
    }
    const check_only = args.len == 2 and std.mem.eql(u8, args[1], "--check-scene");
    if (args.len != 1 and !check_only) return error.BadArguments;
    // Five paired samples; alternate pair order to reduce warm-order bias.
    // Whole-run clocks stay enabled in both variants; detailed phase clocks
    // are attached only to the instrumented one.
    for (0..if (check_only) @as(usize, 1) else scene.samples * 2) |run_index| {
        const sample = run_index / 2;
        const instrumented = run_index % 2 == sample % 2;
        var cart = try core.cartridge.Cartridge.parse(init.gpa, image);
        defer cart.deinit();
        const machine = try init.gpa.create(core.machine.Machine);
        defer init.gpa.destroy(machine);
        try core.machine.Machine.powerInPlace(machine, sample + 1, &cart, null);
        defer machine.close();
        machine.smp.dsp.beginCapture();
        _ = machine.runHostSlice(&cart, core.timing.maximum_host_slice_master_cycles, 0);
        var drain = Drain{};
        try drain.until(machine, &cart, scene.warmup_ns);
        if (machine.ppu.mode != 1 or machine.ppu.main_enable != 0x13 or
            machine.ppu.sub_enable != 0x13 or machine.ppu.frame_generation < 8 or
            machine.bus.wram[8] < 8 or drain.nonzero_bytes == 0 or
            machine.smp.semantic_ipl_state != .running or machine.smp.dsp.stats.frames_dropped != 0)
        {
            std.debug.print("scene check: mode={d} main={d} sub={d} frames={d} motion={d} audio={d} smp={s} drops={d}\n", .{
                machine.ppu.mode,    machine.ppu.main_enable, machine.ppu.sub_enable,                   machine.ppu.frame_generation,
                machine.bus.wram[8], drain.nonzero_bytes,     @tagName(machine.smp.semantic_ipl_state), machine.smp.dsp.stats.frames_dropped,
            });
            return error.InactiveScene;
        }
        if (check_only) {
            std.debug.print("R4SNES scene: OK identity={s} beam_frames={d} generated_frames={d} motion={d} audio_bytes={d} sha256={s}\n", .{
                scene.identity, machine.clock.frame, machine.ppu.frame_generation, machine.bus.wram[8], drain.bytes, std.fmt.bytesToHex(digest, .lower),
            });
            return;
        }
        var clock = HostClock{ .io = init.io };
        var profile = core.performance.Profile{ .clock = .{ .context = &clock, .read = HostClock.now } };
        machine.profile = if (instrumented) &profile else null;
        const beam_before = machine.clock.frame;
        const generated_before = machine.ppu.frame_generation;
        const native_before = machine.smp.dsp.stats.native_frames;
        const smp_before = machine.smp.cycles;
        const bytes_before = drain.bytes;
        const audio_calls_before = drain.render_calls;
        const cpu_start = std.Io.Clock.cpu_thread.now(init.io);
        const started = std.Io.Clock.awake.now(init.io);
        try drain.until(machine, &cart, scene.warmup_ns + scene.duration_ns);
        const ended = std.Io.Clock.awake.now(init.io);
        const cpu_end = std.Io.Clock.cpu_thread.now(init.io);
        machine.profile = null;
        const record = .{
            .profile = "owner-releasefast-v1",
            .scene = scene.identity,
            .rom_sha256 = std.fmt.bytesToHex(digest, .lower),
            .sample = sample + 1,
            .instrumented = instrumented,
            .warmup_guest_ns = scene.warmup_ns,
            .measured_guest_ns = scene.duration_ns,
            .wall_ns = ended.nanoseconds - started.nanoseconds,
            .thread_cpu_ns = cpu_end.nanoseconds - cpu_start.nanoseconds,
            .beam_frames = machine.clock.frame - beam_before,
            .generated_frames = machine.ppu.frame_generation - generated_before,
            .submitted_frames = @as(u64, 0),
            .actually_presented_frames = @as(u64, 0), // Owner harness has no display.
            .apu_cpu_cycles = machine.smp.cycles - smp_before,
            .apu_source_hz = core.timing.apu_source_hz,
            .apu_native_frames = machine.smp.dsp.stats.native_frames - native_before,
            .pcm_bytes = drain.bytes - bytes_before,
            .pcm_render_calls = drain.render_calls - audio_calls_before,
            .dsp_dropped_frames = machine.smp.dsp.stats.frames_dropped,
            .operations = profile.operations,
            .sampled_operations = profile.sampled_operations,
            .profile_clock_reads = profile.clock_reads,
            .sampled_exclusive_wall_ns = profile.elapsed_ns,
            .sampled_phase_calls = profile.calls,
            .phase_order = "cpu,ppu,apu,coprocessor",
            .enhancement = "none",
            .phase_time_is_cpu_accounting = false,
            .maximum_operation_overshoot = machine.maximum_operation_overshoot,
        };
        const json = try std.json.Stringify.valueAlloc(init.gpa, record, .{});
        defer init.gpa.free(json);
        std.debug.print("{s}\n", .{json});
        if (record.generated_frames < 100 or record.apu_native_frames == 0 or record.dsp_dropped_frames != 0) return error.InactiveMeasuredScene;
    }
}
