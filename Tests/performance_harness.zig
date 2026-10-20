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
    capture: []u8,
    capture_len: usize = 0,
    bytes: u64 = 0,
    nonzero_bytes: u64 = 0,
    render_calls: u64 = 0,

    fn until(self: *Drain, machine: *core.machine.Machine, cart: *core.cartridge.Cartridge, guest_ns: u64) !void {
        const cycles = @as(u128, guest_ns) * machine.clock.profile().master_hz / std.time.ns_per_s;
        while (machine.clock.master_cycles < cycles or machine.host_budget.pending_master_cycles != 0) {
            const result = machine.runHostSlice(cart, core.timing.maximum_host_slice_master_cycles, guest_ns);
            if (result.fault != null) return error.MachineFault;
            while (machine.smp.dsp.queuedFrames() != 0) {
                self.render_calls += 1;
                const count = machine.smp.dsp.renderPcm(&self.pcm);
                if (count <= 0) return error.PcmStalled;
                const size: usize = @intCast(count);
                if (size > self.capture.len - self.capture_len) return error.CaptureOverflow;
                @memcpy(self.capture[self.capture_len..][0..size], self.pcm[0..size]);
                self.capture_len += size;
                self.bytes += size;
                for (self.pcm[0..size]) |byte| self.nonzero_bytes += @intFromBool(byte != 0);
            }
            if (result.granted_master_cycles == 0 and machine.host_budget.pending_master_cycles == 0) break;
        }
    }
};

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const write_rom = args.len == 3 and std.mem.eql(u8, args[1], "--write-rom");
    const options = if (write_rom) core.performance_options.Options{} else try core.performance_options.host(args[1..]);
    const image = try init.gpa.alloc(u8, scene.image_bytes);
    defer init.gpa.free(image);
    try scene.buildForRegion(image, options.region);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(image, &digest, .{});
    if (write_rom) {
        try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = args[2], .data = image });
        return;
    }
    for (0..options.count(options.check)) |run_index| {
        const sample = options.sample(run_index);
        const instrumented = options.detailed(run_index);
        var cart = try core.cartridge.Cartridge.parse(init.gpa, image);
        defer cart.deinit();
        const machine = try init.gpa.create(core.machine.Machine);
        defer init.gpa.destroy(machine);
        try core.machine.Machine.powerInPlace(machine, 1, &cart, null);
        defer machine.close();
        const initial = core.performance.stateDigest(machine);
        machine.smp.dsp.beginCapture();
        const capture = try init.gpa.alloc(u8, 700_000);
        defer init.gpa.free(capture);
        var drain = Drain{ .capture = capture };
        var clock = HostClock{ .io = init.io };
        var profile = core.performance.Profile{ .clock = .{ .context = &clock, .read = HostClock.now } };
        const pair_ns = core.performance.calibrate(profile.clock);
        _ = machine.runHostSlice(&cart, core.timing.maximum_host_slice_master_cycles, 0);
        const warm_start = HostClock.now(&clock);
        try drain.until(machine, &cart, scene.warmup_ns);
        const warm_end = HostClock.now(&clock);
        if (machine.ppu.mode != 1 or machine.ppu.main_enable != 0x13 or
            machine.ppu.sub_enable != 0x13 or machine.ppu.frame_generation < 8 or
            machine.bus.wram[8] < 8 or drain.nonzero_bytes == 0 or
            machine.smp.semantic_ipl_state != .running or machine.smp.dsp.stats.frames_dropped != 0)
            return error.InactiveScene;
        if (options.check) {
            std.debug.print("R4SNES scene: OK identity={s} region={s} sha256={s}\n", .{
                scene.identity, @tagName(options.region), std.fmt.bytesToHex(digest, .lower),
            });
            return;
        }
        const warmup = .{
            .wall_ns = warm_end - warm_start,
            .guest_ns = scene.warmup_ns,
            .master_cycles = machine.clock.master_cycles,
            .generated_frames = machine.ppu.frame_generation,
            .apu_native_frames = machine.smp.dsp.stats.native_frames,
            .pcm_bytes = drain.bytes,
        };
        const start_master = machine.clock.master_cycles;
        const beam_before = machine.clock.frame;
        const generated_before = machine.ppu.frame_generation;
        const native_before = machine.smp.dsp.stats.native_frames;
        const smp_before = machine.smp.cycles;
        const bytes_before = drain.bytes;
        const audio_calls_before = drain.render_calls;
        machine.profile = if (instrumented) &profile else null;
        const cpu_start = std.Io.Clock.cpu_thread.now(init.io);
        const started = HostClock.now(&clock);
        try drain.until(machine, &cart, scene.warmup_ns + scene.duration_ns);
        const ended = HostClock.now(&clock);
        const cpu_end = std.Io.Clock.cpu_thread.now(init.io);
        machine.profile = null;
        var pcm_digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(capture[0..drain.capture_len], &pcm_digest, .{});
        const record = .{
            .profile = "owner-releasefast-v2",
            .scene = scene.identity,
            .region = @tagName(options.region),
            .rom_sha256 = std.fmt.bytesToHex(digest, .lower),
            .initial_state_sha256 = std.fmt.bytesToHex(initial, .lower),
            .state_sha256 = std.fmt.bytesToHex(core.performance.stateDigest(machine), .lower),
            .frame_sha256 = std.fmt.bytesToHex(core.performance.frameDigest(machine), .lower),
            .pcm_sha256 = std.fmt.bytesToHex(pcm_digest, .lower),
            .sample = sample,
            .instrumented = instrumented,
            .qualification_only = false,
            .warmup = warmup,
            .warmup_guest_ns = scene.warmup_ns,
            .measured_guest_ns = scene.duration_ns,
            .work_start_master = start_master,
            .work_end_master = machine.clock.master_cycles,
            .master_hz = machine.clock.profile().master_hz,
            .wall_ns = ended - started,
            .thread_cpu_ns = cpu_end.nanoseconds - cpu_start.nanoseconds,
            .clock_source = "std.Io.Clock.awake",
            .clock_resolution_ns = @as(?u64, null),
            .clock_generation = @as(?u64, null),
            .clock_pair_min_ns = pair_ns,
            .beam_frames = machine.clock.frame - beam_before,
            .generated_frames = machine.ppu.frame_generation - generated_before,
            .submitted_frames = @as(?u64, null),
            .actually_presented_frames = @as(?u64, null),
            .apu_cpu_cycles = machine.smp.cycles - smp_before,
            .apu_source_hz = core.timing.apu_source_hz,
            .apu_native_frames = machine.smp.dsp.stats.native_frames - native_before,
            .pcm_bytes = drain.bytes - bytes_before,
            .pcm_render_calls = drain.render_calls - audio_calls_before,
            .dsp_dropped_frames = machine.smp.dsp.stats.frames_dropped,
            .audio_playback_frames = @as(?u64, null),
            .operations = profile.operations,
            .cpu_operations = profile.cpu_operations,
            .dma_operations = profile.dma_operations,
            .observed_master_cycles = profile.master_cycles,
            .profile_clock_regressions = profile.clock_regressions,
            .sampled_operations = profile.sampled_operations,
            .profile_clock_reads = profile.clock_reads,
            .sample_interval = core.performance.sample_interval,
            .sampled_exclusive_wall_ns = profile.elapsed_ns,
            .sampled_phase_calls = profile.calls,
            .phase_order = core.performance.phase_order,
            .enhancement = "none",
            .phase_time_is_cpu_accounting = false,
            .maximum_operation_overshoot = machine.maximum_operation_overshoot,
            .pending_master_cycles = machine.host_budget.pending_master_cycles,
            .cleanup_verified = true,
        };
        if (record.generated_frames < 100 or record.apu_native_frames == 0 or
            record.dsp_dropped_frames != 0 or record.profile_clock_regressions != 0 or
            record.pending_master_cycles != 0 or record.wall_ns == 0) return error.InvalidMeasuredScene;
        machine.close();
        const json = try std.json.Stringify.valueAlloc(init.gpa, record, .{});
        defer init.gpa.free(json);
        std.debug.print("{s}\n", .{json});
    }
}
