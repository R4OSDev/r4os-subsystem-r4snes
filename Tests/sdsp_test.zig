const std = @import("std");
const core = @import("core");
const r4os = @import("r4os");

const ascending = [_]u8{ 0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xde, 0xf0 };
const alternating = [_]u8{ 0x7f, 0x81, 0x6e, 0x92, 0x5d, 0xa3, 0x4c, 0xb4 };
const fnv_offset: u64 = 0xcbf29ce484222325;
const fnv_prime: u64 = 0x100000001b3;

const ReferenceMatrix = struct {
    schema: u32,
    cases: []Case,

    const Case = struct {
        name: []const u8,
        native_frames: u64,
        pcm_digest: []const u8,
        endx: u8,
        envx0: u8,
        outx0: u8,
        echo_ram_digest: []const u8,
    };
};

const Probe = struct {
    aram: [65536]u8 = [_]u8{0} ** 65536,
    dsp: core.sdsp.Dsp = .{},

    fn initialize(self: *Probe) void {
        self.dsp.write(0x6c, 0x20);
        self.dsp.write(0x0c, 0x7f);
        self.dsp.write(0x1c, 0x7f);
    }

    fn sample(self: *Probe, number: usize, address: u16, header: u8, data: [8]u8) void {
        const directory = 0x1000 + number * 4;
        self.aram[directory] = @truncate(address);
        self.aram[directory + 1] = @truncate(address >> 8);
        self.aram[directory + 2] = @truncate(address);
        self.aram[directory + 3] = @truncate(address >> 8);
        self.aram[address] = header;
        @memcpy(self.aram[address + 1 .. address + 9], data[0..]);
    }

    fn voice(
        self: *Probe,
        number: usize,
        source: u8,
        pitch: u16,
        adsr0: u8,
        adsr1: u8,
        gain: u8,
        left: i8,
        right: i8,
    ) void {
        const base: u8 = @intCast(number * 0x10);
        self.dsp.write(base + 0x00, @bitCast(left));
        self.dsp.write(base + 0x01, @bitCast(right));
        self.dsp.write(base + 0x02, @truncate(pitch));
        self.dsp.write(base + 0x03, @truncate(pitch >> 8));
        self.dsp.write(base + 0x04, source);
        self.dsp.write(base + 0x05, adsr0);
        self.dsp.write(base + 0x06, adsr1);
        self.dsp.write(base + 0x07, gain);
    }

    fn run(self: *Probe, frames: u64) void {
        self.dsp.runClocks(&self.aram, frames * 32);
    }

    fn echoRamDigest(self: *const Probe) u64 {
        var value: u64 = fnv_offset;
        for (self.aram[0x4000..0x4800]) |byte| value = (value ^ byte) *% fnv_prime;
        return value;
    }
};

test "SNES-SPC digital oracle covers BRR envelopes noise modulation echo and key events" {
    var parsed = try std.json.parseFromSlice(
        ReferenceMatrix,
        std.testing.allocator,
        @embedFile("sdsp_reference_cases.json"),
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();
    try std.testing.expectEqual(@as(u32, 1), parsed.value.schema);
    try std.testing.expectEqual(@as(usize, 9), parsed.value.cases.len);

    for (parsed.value.cases) |case| {
        var probe = Probe{};
        probe.initialize();
        try configureOracleCase(&probe, case.name);
        try std.testing.expectEqual(case.native_frames, probe.dsp.sample_counter);
        try std.testing.expectEqual(try std.fmt.parseInt(u64, case.pcm_digest, 16), probe.dsp.native_digest);
        try std.testing.expectEqual(case.endx, probe.dsp.read(0x7c));
        try std.testing.expectEqual(case.envx0, probe.dsp.read(0x08));
        try std.testing.expectEqual(case.outx0, probe.dsp.read(0x09));
        try std.testing.expectEqual(try std.fmt.parseInt(u64, case.echo_ram_digest, 16), probe.echoRamDigest());
    }
}

test "all eight voices mix and expose independent ENDX ENVX and OUTX readbacks" {
    var probe = Probe{};
    probe.initialize();
    probe.sample(0, 0x2000, 0xc3, ascending);
    for (0..8) |index| {
        probe.voice(index, 0, 0x1000, 0, 0, 0x7f, @intCast(120 - index * 4), @intCast(80 + index * 4));
    }
    probe.dsp.write(0x5d, 0x10);
    probe.dsp.write(0x4c, 0xff);
    probe.run(192);
    try std.testing.expectEqual(@as(u8, 0xff), probe.dsp.read(0x7c));
    for (0..8) |index| {
        try std.testing.expectEqual(@as(u8, 0x7f), probe.dsp.read(@intCast(index * 0x10 + 0x08)));
        try std.testing.expect(probe.dsp.read(@intCast(index * 0x10 + 0x09)) != 0);
    }
    probe.dsp.write(0x7c, 0xff);
    try std.testing.expectEqual(@as(u8, 0), probe.dsp.read(0x7c));
}

test "SPC700 F2 F3 path drives the cycle-clocked DSP register file" {
    var smp = core.smp.Smp{};
    smp.bus_mode = .hardware;
    smp.io.ipl_enabled = false;
    smp.pc = 0x0200;
    smp.aram[0x0200..0x0209].* = .{
        0x8f, 0x0c, 0xf2,
        0x8f, 0x7f, 0xf3,
        0xe4, 0xf3, 0x00,
    };
    try smp.step();
    try smp.step();
    try smp.step();
    for (0..8) |_| try smp.step();
    try std.testing.expectEqual(@as(i8, 127), smp.dsp.main_volume[0]);
    try std.testing.expectEqual(@as(u8, 0x7f), smp.a);
    try std.testing.expect(smp.dsp.sample_counter != 0);
}

test "32 to 48 kHz conversion is partition invariant bounded and caller-buffered" {
    var once = Probe{};
    once.initialize();
    once.sample(0, 0x2000, 0xc3, ascending);
    once.voice(0, 0, 0x1000, 0, 0, 0x7f, 127, 96);
    once.dsp.write(0x5d, 0x10);
    once.dsp.write(0x4c, 1);
    once.dsp.beginCapture();

    var split = Probe{};
    split.initialize();
    split.sample(0, 0x2000, 0xc3, ascending);
    split.voice(0, 0, 0x1000, 0, 0, 0x7f, 127, 96);
    split.dsp.write(0x5d, 0x10);
    split.dsp.write(0x4c, 1);
    split.dsp.beginCapture();

    const total_clocks: u64 = 4096 * 32;
    once.dsp.runClocks(&once.aram, total_clocks);
    var remaining = total_clocks;
    const partitions = [_]u64{ 1, 31, 17, 409, 3, 2048, 97 };
    var partition: usize = 0;
    while (remaining != 0) : (partition += 1) {
        const clocks = @min(remaining, partitions[partition % partitions.len]);
        split.dsp.runClocks(&split.aram, clocks);
        remaining -= clocks;
    }

    try std.testing.expectEqual(@as(u64, 4096), once.dsp.sample_counter);
    try std.testing.expectEqual(@as(u64, 6143), once.dsp.stats.resampled_frames);
    try std.testing.expectEqual(once.dsp.native_digest, split.dsp.native_digest);
    try std.testing.expectEqual(once.dsp.resampled_digest, split.dsp.resampled_digest);
    try std.testing.expectEqual(once.dsp.queuedFrames(), split.dsp.queuedFrames());
    try std.testing.expectEqual(once.dsp.phase, split.dsp.phase);

    var block: [core.sdsp.maximum_render_frames * core.sdsp.sample_bytes]u8 = undefined;
    try std.testing.expectEqual(@as(i32, block.len), once.dsp.renderPcm(block[0..]));
    try std.testing.expectEqual(@as(usize, 6143 - core.sdsp.maximum_render_frames), once.dsp.queuedFrames());
    var oversized: [(core.sdsp.maximum_render_frames + 1) * core.sdsp.sample_bytes]u8 = undefined;
    try std.testing.expectEqual(@as(i32, -1), once.dsp.renderPcm(oversized[0..]));
}

test "PCM queue overflow mute reset and repeated capture teardown are defined" {
    var probe = Probe{};
    probe.initialize();
    probe.dsp.beginCapture();
    probe.run(6000);
    try std.testing.expectEqual(core.sdsp.pcm_capacity_frames, probe.dsp.queuedFrames());
    try std.testing.expectEqual(@as(u64, 8999 - core.sdsp.pcm_capacity_frames), probe.dsp.stats.frames_dropped);
    try std.testing.expectEqual(probe.dsp.stats.resampled_frames, probe.dsp.stats.silence_frames);

    probe.dsp.endCapture();
    probe.dsp.endCapture();
    try std.testing.expectEqual(@as(usize, 0), probe.dsp.queuedFrames());
    probe.dsp.beginCapture();
    probe.dsp.beginCapture();
    try std.testing.expect(probe.dsp.capture_enabled);
    probe.dsp.reset();
    try std.testing.expect(probe.dsp.muted);
    try std.testing.expect(probe.dsp.soft_reset);
    try std.testing.expectEqual(@as(usize, 0), probe.dsp.queuedFrames());
    var empty: [4 * core.sdsp.sample_bytes]u8 = [_]u8{0xa5} ** (4 * core.sdsp.sample_bytes);
    try std.testing.expectEqual(@as(i32, 0), probe.dsp.renderPcm(empty[0..]));
    try std.testing.expectEqual(@as(u64, 4), probe.dsp.stats.underflow_frames);
}

fn configureOracleCase(probe: *Probe, name: []const u8) !void {
    if (std.mem.eql(u8, name, "direct_loop")) {
        probe.sample(0, 0x2000, 0xc3, ascending);
        probe.voice(0, 0, 0x1000, 0, 0, 0x7f, 127, 96);
        probe.dsp.write(0x5d, 0x10);
        probe.dsp.write(0x4c, 1);
        probe.run(192);
    } else if (std.mem.eql(u8, name, "impulse")) {
        probe.sample(0, 0x2000, 0xc1, .{ 0x70, 0, 0, 0, 0, 0, 0, 0 });
        probe.voice(0, 0, 0x1000, 0, 0, 0x7f, 127, 96);
        probe.dsp.write(0x5d, 0x10);
        probe.dsp.write(0x4c, 1);
        probe.run(96);
    } else if (std.mem.eql(u8, name, "adsr")) {
        probe.sample(0, 0x2000, 0xb3, alternating);
        probe.voice(0, 0, 0x1000, 0x8f, 0xe0, 0, 127, -96);
        probe.dsp.write(0x5d, 0x10);
        probe.dsp.write(0x4c, 1);
        probe.run(256);
    } else if (std.mem.eql(u8, name, "gain_modes")) {
        probe.sample(0, 0x2000, 0xc3, ascending);
        probe.voice(0, 0, 0x1000, 0, 0, 0x7f, 127, 127);
        probe.dsp.write(0x5d, 0x10);
        probe.dsp.write(0x4c, 1);
        probe.run(64);
        probe.dsp.write(0x07, 0x9f);
        probe.run(96);
        probe.dsp.write(0x07, 0xbf);
        probe.run(96);
        probe.dsp.write(0x07, 0xdf);
        probe.run(96);
        probe.dsp.write(0x07, 0xff);
        probe.run(96);
    } else if (std.mem.eql(u8, name, "brr_filters")) {
        for (0..4) |index| {
            probe.sample(
                index,
                @intCast(0x2000 + index * 0x100),
                @intCast(0x63 | (index << 2)),
                if (index & 1 != 0) alternating else ascending,
            );
            probe.voice(
                index,
                @intCast(index),
                0x1000,
                0,
                0,
                0x7f,
                @intCast(112 - index * 8),
                @intCast(-80 + @as(i32, @intCast(index * 8))),
            );
        }
        probe.dsp.write(0x5d, 0x10);
        probe.dsp.write(0x4c, 0x0f);
        probe.run(384);
    } else if (std.mem.eql(u8, name, "noise")) {
        probe.sample(0, 0x2000, 0xc3, ascending);
        probe.voice(0, 0, 0x1000, 0, 0, 0x7f, 127, 127);
        probe.dsp.write(0x5d, 0x10);
        probe.dsp.write(0x3d, 1);
        probe.dsp.write(0x6c, 0x3f);
        probe.dsp.write(0x4c, 1);
        probe.run(256);
    } else if (std.mem.eql(u8, name, "pitch_modulation")) {
        probe.sample(0, 0x2000, 0xc3, ascending);
        probe.sample(1, 0x2100, 0xb3, alternating);
        probe.voice(0, 0, 0x0800, 0, 0, 0x7f, 96, 64);
        probe.voice(1, 1, 0x1000, 0, 0, 0x7f, 64, 96);
        probe.dsp.write(0x5d, 0x10);
        probe.dsp.write(0x2d, 2);
        probe.dsp.write(0x4c, 3);
        probe.run(384);
    } else if (std.mem.eql(u8, name, "echo_fir")) {
        probe.sample(0, 0x2000, 0xc3, ascending);
        probe.voice(0, 0, 0x1000, 0, 0, 0x7f, 127, 96);
        probe.dsp.write(0x5d, 0x10);
        probe.dsp.write(0x2c, 0x50);
        probe.dsp.write(0x3c, 0xb0);
        probe.dsp.write(0x0d, 0x40);
        probe.dsp.write(0x0f, 0x7f);
        probe.dsp.write(0x4d, 1);
        probe.dsp.write(0x6d, 0x40);
        probe.dsp.write(0x7d, 1);
        probe.dsp.write(0x6c, 0);
        probe.dsp.write(0x4c, 1);
        probe.run(512);
    } else if (std.mem.eql(u8, name, "keyoff_release")) {
        probe.sample(0, 0x2000, 0xc3, ascending);
        probe.voice(0, 0, 0x1000, 0, 0, 0x7f, 127, 127);
        probe.dsp.write(0x5d, 0x10);
        probe.dsp.write(0x4c, 1);
        probe.run(64);
        probe.dsp.write(0x5c, 1);
        probe.run(128);
    } else {
        return error.UnknownSdspOracleCase;
    }
}

test "runtime adapter feedback isolates mute degradation reset and close" {
    var dsp = core.sdsp.Dsp{};
    var source_state = AdapterSource{ .dsp = &dsp };
    var adapter = core.runtime_adapter.Adapter.init(&dsp, source_state.source());
    const driver = adapter.driver();

    var prefill_aram: [65536]u8 = [_]u8{0} ** 65536;
    var quantum: [r4os.subsystem_runtime.default_quantum_frames * core.sdsp.sample_bytes]u8 = undefined;
    try std.testing.expectEqual(@as(i32, 0), driver.renderAudio(quantum[0..]));
    dsp.runClocks(&prefill_aram, 641 * 32);
    try std.testing.expect(dsp.queuedFrames() >= adapter.audio_prefill_frames);
    try std.testing.expectEqual(@as(i32, quantum.len), driver.renderAudio(quantum[0..]));
    try std.testing.expect(adapter.audio_prefill_released);

    _ = driver.audioFeedback(.{ .state = .degraded, .muted = false, .discarded_bytes = 128 });
    try std.testing.expect(adapter.audio_degraded);
    try std.testing.expect(!adapter.audio_capture_enabled);
    try std.testing.expectEqual(@as(usize, 0), dsp.queuedFrames());
    _ = driver.audioFeedback(.{ .state = .ready, .muted = false });
    try std.testing.expect(adapter.audio_capture_enabled);
    _ = driver.audioFeedback(.{ .state = .active, .muted = true });
    try std.testing.expect(!adapter.audio_capture_enabled);
    _ = driver.audioFeedback(.{ .state = .active, .muted = false });
    try std.testing.expect(adapter.audio_capture_enabled);

    try std.testing.expectEqual(@as(i32, 0), driver.reset());
    try std.testing.expectEqual(@as(u32, 1), source_state.resets);
    adapter.close();
    adapter.close();
    try std.testing.expect(!dsp.capture_enabled);
    try std.testing.expectEqual(core.runtime_adapter.guest_closed, driver.reset());
    try std.testing.expectEqual(core.runtime_adapter.guest_closed, driver.step(1, 0).exit_code);
}

test "subsystem runtime submits bounded S-DSP PCM and backend loss never stops guest time" {
    const runtime_api = r4os.subsystem_runtime;
    var healthy_probe = Probe{};
    healthy_probe.initialize();
    healthy_probe.sample(0, 0x2000, 0xc3, ascending);
    healthy_probe.voice(0, 0, 0x1000, 0, 0, 0x7f, 127, 96);
    healthy_probe.dsp.write(0x5d, 0x10);
    healthy_probe.dsp.write(0x4c, 1);
    var healthy_source = RuntimeSource{
        .probe = &healthy_probe,
        .target_clocks = 4000 * 32,
    };
    var healthy_adapter = core.runtime_adapter.Adapter.init(&healthy_probe.dsp, healthy_source.source());
    var healthy_sink = RuntimeSink{};
    var healthy_host = RuntimeHost{};
    var healthy_queue: [runtime_api.default_quantum_frames * runtime_api.default_target_quanta * core.sdsp.sample_bytes]u8 = undefined;
    var healthy_scratch: [runtime_api.default_quantum_frames * core.sdsp.sample_bytes]u8 = undefined;
    var healthy_runtime = try runtime_api.Runtime.init(.{
        .slice_budget = 3200,
        .max_wait_ticks = 1,
    }, 1000, 0, .{
        .config = .{
            .sample_rate = core.sdsp.output_sample_rate,
            .channels = core.sdsp.channels,
            .quantum_frames = runtime_api.default_quantum_frames,
            .target_quanta = runtime_api.default_target_quanta,
            .max_catchup_quanta = 8,
        },
        .queue_storage = healthy_queue[0..],
        .scratch = healthy_scratch[0..],
        .sink = healthy_sink.sink(),
    });

    var completed = false;
    for (0..200) |cycle| {
        const result = healthy_runtime.cycle(@intCast(cycle * 10), healthy_adapter.driver(), healthy_host.driver());
        switch (result) {
            .wait => {},
            .finished => |finished| {
                try std.testing.expectEqual(runtime_api.LifecycleState.completed, finished.state);
                completed = true;
                break;
            },
        }
    }
    try std.testing.expect(completed);
    try std.testing.expect(healthy_sink.opens != 0);
    try std.testing.expect(healthy_sink.writes != 0);
    try std.testing.expect(healthy_sink.closes != 0);
    try std.testing.expect(healthy_sink.bytes != 0);
    try std.testing.expect(!healthy_sink.all_zero);
    try std.testing.expectEqual(@as(u16, 1), healthy_runtime.audio.stats.maximum_service_operations_per_cycle);
    try std.testing.expect(!healthy_adapter.audio_degraded);
    try std.testing.expectEqual(@as(usize, 0), healthy_probe.dsp.queuedFrames());
    healthy_adapter.close();

    var failed_probe = Probe{};
    failed_probe.initialize();
    failed_probe.sample(0, 0x2000, 0xc3, ascending);
    failed_probe.voice(0, 0, 0x1000, 0, 0, 0x7f, 127, 96);
    failed_probe.dsp.write(0x5d, 0x10);
    failed_probe.dsp.write(0x4c, 1);
    var failed_source = RuntimeSource{
        .probe = &failed_probe,
        .target_clocks = 20_000 * 32,
    };
    var failed_adapter = core.runtime_adapter.Adapter.init(&failed_probe.dsp, failed_source.source());
    var failed_sink = RuntimeSink{ .fail_writes = true };
    var failed_host = RuntimeHost{};
    var failed_queue: [runtime_api.default_quantum_frames * runtime_api.default_target_quanta * core.sdsp.sample_bytes]u8 = undefined;
    var failed_scratch: [runtime_api.default_quantum_frames * core.sdsp.sample_bytes]u8 = undefined;
    var failed_runtime = try runtime_api.Runtime.init(.{
        .slice_budget = 3200,
        .max_wait_ticks = 1,
    }, 1000, 0, .{
        .config = .{
            .sample_rate = core.sdsp.output_sample_rate,
            .channels = core.sdsp.channels,
            .quantum_frames = runtime_api.default_quantum_frames,
            .target_quanta = runtime_api.default_target_quanta,
            .max_catchup_quanta = 8,
        },
        .queue_storage = failed_queue[0..],
        .scratch = failed_scratch[0..],
        .sink = failed_sink.sink(),
    });
    var degraded = false;
    var tick: u64 = 0;
    for (0..80) |_| {
        _ = failed_runtime.cycle(tick, failed_adapter.driver(), failed_host.driver());
        tick += 10;
        if (failed_runtime.audio.state == .degraded and failed_adapter.audio_degraded) {
            degraded = true;
            break;
        }
    }
    try std.testing.expect(degraded);
    const samples_at_failure = failed_probe.dsp.sample_counter;
    for (0..20) |_| {
        _ = failed_runtime.cycle(tick, failed_adapter.driver(), failed_host.driver());
        tick += 10;
    }
    try std.testing.expect(failed_probe.dsp.sample_counter > samples_at_failure);
    try std.testing.expectEqual(runtime_api.LifecycleState.running, failed_runtime.state);
    try std.testing.expect(!failed_adapter.audio_capture_enabled);
    try std.testing.expectEqual(@as(usize, 0), failed_probe.dsp.queuedFrames());
    try std.testing.expect(failed_sink.closes != 0);
    failed_adapter.close();
}

const AdapterSource = struct {
    dsp: *core.sdsp.Dsp,
    resets: u32 = 0,

    fn source(self: *AdapterSource) core.runtime_adapter.StepSource {
        return .{ .context = self, .step_fn = step, .reset_fn = reset };
    }

    fn step(_: *anyopaque, budget: u32, _: u64) r4os.subsystem_runtime.StepResult {
        return r4os.subsystem_runtime.StepResult.progress(false).withOperations(budget);
    }

    fn reset(context: *anyopaque) i32 {
        const self: *AdapterSource = @ptrCast(@alignCast(context));
        self.resets += 1;
        self.dsp.reset();
        return 0;
    }
};

const RuntimeSource = struct {
    probe: *Probe,
    executed_clocks: u64 = 0,
    target_clocks: u64,

    fn source(self: *RuntimeSource) core.runtime_adapter.StepSource {
        return .{ .context = self, .step_fn = step, .reset_fn = reset };
    }

    fn step(context: *anyopaque, budget: u32, _: u64) r4os.subsystem_runtime.StepResult {
        const self: *RuntimeSource = @ptrCast(@alignCast(context));
        const remaining = self.target_clocks -| self.executed_clocks;
        const clocks: u32 = @intCast(@min(remaining, budget));
        self.probe.dsp.runClocks(&self.probe.aram, clocks);
        self.executed_clocks += clocks;
        if (self.executed_clocks == self.target_clocks) {
            return r4os.subsystem_runtime.StepResult.complete(0, false).withOperations(clocks);
        }
        return r4os.subsystem_runtime.StepResult.progress(false).withOperations(clocks);
    }

    fn reset(context: *anyopaque) i32 {
        const self: *RuntimeSource = @ptrCast(@alignCast(context));
        self.executed_clocks = 0;
        self.probe.dsp.reset();
        return 0;
    }
};

const RuntimeHost = struct {
    fn driver(self: *RuntimeHost) r4os.subsystem_runtime.HostDriver {
        return .{ .context = self, .poll_fn = poll, .present_fn = present };
    }

    fn poll(_: *anyopaque) r4os.subsystem_runtime.HostPollResult {
        return .idle;
    }

    fn present(_: *anyopaque) i32 {
        return r4os.subsystem_runtime.host_present_unchanged;
    }
};

const RuntimeSink = struct {
    fail_writes: bool = false,
    opens: u32 = 0,
    writes: u32 = 0,
    closes: u32 = 0,
    bytes: u64 = 0,
    all_zero: bool = true,

    fn sink(self: *RuntimeSink) r4os.subsystem_runtime.AudioSink {
        return .{
            .context = self,
            .open_fn = open,
            .write_fn = write,
            .volume_fn = volume,
            .close_fn = close,
        };
    }

    fn open(context: *anyopaque, config: r4os.subsystem_runtime.AudioConfig) i32 {
        const self: *RuntimeSink = @ptrCast(@alignCast(context));
        self.opens += 1;
        if (config.sample_rate != core.sdsp.output_sample_rate or
            config.channels != core.sdsp.channels or config.quantum_frames > core.sdsp.maximum_render_frames) return -41;
        return 0;
    }

    fn write(context: *anyopaque, data: []const u8) i32 {
        const self: *RuntimeSink = @ptrCast(@alignCast(context));
        if (self.fail_writes) return -77;
        self.writes += 1;
        self.bytes +%= data.len;
        for (data) |byte| self.all_zero = self.all_zero and byte == 0;
        return @intCast(data.len);
    }

    fn volume(_: *anyopaque, _: u32) i32 {
        return 0;
    }

    fn close(context: *anyopaque) i32 {
        const self: *RuntimeSink = @ptrCast(@alignCast(context));
        self.closes += 1;
        return 0;
    }
};
