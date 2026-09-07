// Explicit integrated profile. Uses the same Guest, WindowHost, Runtime and
// AUDSVC sink as runProduct; it does not implement a second guest scheduler.
const std = @import("std");
const r4os = @import("r4os");
const core = @import("core.zig");
const scene = core.performance_scene;
const rt = r4os.subsystem_runtime;
const video = r4os.subsystem_host;
const product = core.product_host;

pub fn run(app: *r4os.App, check_only: bool) i32 {
    execute(app, check_only) catch |fault| {
        const sys = app.system();
        sys.write("R4SNES integrated profile FAILED: ");
        sys.println(@errorName(fault));
        return 98;
    };
    return 0;
}

fn execute(app: *r4os.App, check_only: bool) !void {
    if (app.profile != .desktop) return error.DesktopRequired;
    const allocator = app.allocator() orelse return error.AllocatorMissing;
    const sys = app.system();
    const files = app.files() orelse return error.FilesMissing;
    const desk = app.desktop() orelse return error.DesktopMissing;
    const draw = app.drawing() orelse return error.DrawingMissing;
    const audio = app.audio() orelse return error.AudioMissing;
    if (sys.monotonicNanoseconds() == null) return error.ClockMissing;
    var report: [32768]u8 = undefined;
    var report_len: usize = 0;
    const sample_count = if (check_only) @as(usize, 1) else scene.samples * 2;
    const measured_ns = if (check_only) scene.warmup_ns else scene.duration_ns;
    for (0..sample_count) |run_index| {
        const sample = run_index / 2;
        const instrumented = run_index % 2 == sample % 2;
        const image = try allocator.alloc(u8, scene.image_bytes);
        try scene.build(image);
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(image, &digest, .{});
        var time = TimeSource{ .sys = &sys };
        var store = core.persistence_r4os.AsyncStore.init(files, allocator);
        var guest = product.Guest.init(allocator, store.backend(), .{ .context = &time, .now_fn = TimeSource.now }, sample + 1);
        try guest.openOwned(.{ .image = image });
        defer _ = guest.close();
        try guest.setGuestTimeLimit(scene.warmup_ns + measured_ns);
        var raster_scratch: [video.tile_max_pixels]u32 = undefined;
        var window = try video.Host.init(desk, draw, try guest.initialSurface(), &raster_scratch);
        defer window.video.deinit(video.Backend.fromDraw(&draw));
        window.setInputPolicy(.{ .key_text_mode = .key_and_text, .pointer_mode = .ignored });
        _ = window.setMinimumSize(core.ppu.frame_width, core.ppu.standard_height);
        try guest.attachVideo(&window.video);
        var sink = rt.R4AudioSink.initWithTimeouts(audio, 200 * std.time.ns_per_ms, 500 * std.time.ns_per_ms);
        var queue: [rt.default_quantum_frames * 2 * core.sdsp.sample_bytes]u8 = undefined;
        var scratch: [rt.default_quantum_frames * core.sdsp.sample_bytes]u8 = undefined;
        var probe = Probe{ .sys = &sys, .guest = &guest, .window = &window, .owner = app.raw.instance_id, .sink = sink.sink(), .measured_ns = measured_ns, .instrumented = instrumented };
        time.probe = &probe;
        var runtime = try rt.Runtime.init(.{ .slice_budget = product.slice_budget_master_cycles }, sys.monotonicHz(), sys.ticks(), .{
            .config = .{ .sample_rate = core.sdsp.output_sample_rate, .channels = core.sdsp.channels, .quantum_frames = rt.default_quantum_frames, .target_quanta = 2, .max_catchup_quanta = 16 },
            .queue_storage = &queue,
            .scratch = &scratch,
            .sink = probe.audioSink(),
        });
        var host = product.WindowHost.init(sys, &window, &guest, &runtime);
        probe.host = host.driver();
        probe.base = guest.driver();
        probe.runtime = &runtime;
        probe.profile = .{ .clock = .{ .context = &probe, .read = Probe.readClock } };
        const code = runtime.run(&sys, probe.driver(), probe.hostDriver());
        const end_ns = probe.now();
        guest.machine.?.profile = null;
        const after = probe.snapshot();
        if (code != 0 or !probe.measuring or runtime.audio.state == .degraded or
            guest.machine.?.smp.dsp.stats.frames_dropped != 0 or
            after.generated -| probe.before.generated < (if (check_only) @as(u64, 8) else 100) or
            after.generation <= probe.before.generation or
            after.non_silent -| probe.before.non_silent == 0 or after.audio_failures != 0)
            return error.InvalidMeasuredRun;
        const cpu_ticks = if (probe.cpu_start) |start| if (probe.taskTicks()) |end| end -| start else null else null;
        const record = .{
            .profile = "r4os-window-audsvc-v1",
            .scene = scene.identity,
            .rom_sha256 = std.fmt.bytesToHex(digest, .lower),
            .sample = sample + 1,
            .instrumented = instrumented,
            .qualification_only = check_only,
            .warmup_guest_ns = scene.warmup_ns,
            .measured_guest_ns = measured_ns,
            .wall_ns = end_ns -| probe.started_ns,
            .assigned_runtime_ticks = cpu_ticks,
            .runtime_tick_hz = sys.monotonicHz(),
            .stage_wall_ns = probe.stage_ns,
            .stage_calls = probe.stage_calls,
            .stage_order = "guest-step-including-persistence,pcm-render,video-submit,host-poll,host-wait,audio-service",
            .persistence_time_calls = time.calls,
            .persistence_time_wall_ns = time.elapsed_ns,
            .persistence_time_nested_in_guest_step = true,
            .beam_frames = after.beam -| probe.before.beam,
            .generated_frames = after.generated -| probe.before.generated,
            .submitted_frames = after.submitted -| probe.before.submitted,
            .unchanged_presents = after.unchanged -| probe.before.unchanged,
            .dropped_presents = after.dropped -| probe.before.dropped,
            .generation_start_exclusive = probe.before.generation,
            .generation_end_inclusive = after.generation,
            .actual_presentation_source = "SNES-PRESENT.TXT: successful Desktop display presents, filtered by generation interval",
            .apu_cpu_cycles = after.apu_cycles -| probe.before.apu_cycles,
            .apu_source_hz = core.timing.apu_source_hz,
            .apu_native_frames = after.native -| probe.before.native,
            .audio_accepted_bytes = after.audio_bytes -| probe.before.audio_bytes,
            .audio_service_writes = after.audio_writes -| probe.before.audio_writes,
            .audio_open_operations = after.audio_opens -| probe.before.audio_opens,
            .audio_close_operations = after.audio_closes -| probe.before.audio_closes,
            .audio_empty_cycles = after.audio_empty -| probe.before.audio_empty,
            .audio_suppressed_bytes = after.audio_suppressed -| probe.before.audio_suppressed,
            .runtime_cycles = after.runtime_cycles -| probe.before.runtime_cycles,
            .runtime_waiting_cycles = after.waiting_cycles -| probe.before.waiting_cycles,
            .runtime_zero_progress_waits = after.zero_progress_waits -| probe.before.zero_progress_waits,
            .audio_failures = after.audio_failures,
            .audio_discarded_bytes = after.discarded -| probe.before.discarded,
            .audio_playback_frames = @as(?u64, null), // No per-stream hardware cursor in ABI.
            .sampled_operations = probe.profile.sampled_operations,
            .profile_clock_reads = probe.profile.clock_reads,
            .sampled_exclusive_wall_ns = probe.profile.elapsed_ns,
            .sampled_phase_calls = probe.profile.calls,
            .phase_order = "cpu,ppu,apu,coprocessor",
            .enhancement = "none",
            .phase_time_is_cpu_accounting = false,
        };
        const json = try std.json.Stringify.valueAlloc(allocator, record, .{});
        defer allocator.free(json);
        if (report_len + json.len + 2 > report.len) return error.ReportTooLarge;
        @memcpy(report[report_len..][0..json.len], json);
        report_len += json.len;
        report[report_len] = '\n';
        report_len += 1;
    }
    if (sys.fileWrite("C:\\TEMP\\SNES-PERF.JSONL", report[0..report_len]) != @as(i32, @intCast(report_len))) return error.ReportWriteFailed;
    sys.println(if (check_only) "R4SNES profile qualification: OK" else "R4SNES integrated profile: OK samples=5 variants=timing-on+timing-off scene=r4snes.active-scene.v1");
}

const TimeSource = struct {
    sys: *const r4os.r4sys.Context,
    probe: ?*Probe = null,
    calls: u64 = 0,
    elapsed_ns: u64 = 0,

    fn now(context: *anyopaque) product.TimePoint {
        const self: *TimeSource = @ptrCast(@alignCast(context));
        const measuring = if (self.probe) |p| p.measuring else false;
        const detailed = measuring and self.probe.?.instrumented;
        const started = if (detailed) self.sys.monotonicNanoseconds().? else 0;
        const point = product.TimePoint{
            .wall_seconds = core.persistence_r4os.wallSeconds(self.sys.timeState()),
            .monotonic_ns = self.sys.monotonicNanoseconds() orelse 0,
        };
        if (measuring) {
            self.calls += 1;
            if (detailed) self.elapsed_ns +|= point.monotonic_ns -| started;
        }
        return point;
    }
};

const Snapshot = struct {
    beam: u64,
    generated: u64,
    submitted: u64,
    unchanged: u64,
    dropped: u64,
    generation: u64,
    apu_cycles: u64,
    native: u64,
    non_silent: u64,
    audio_bytes: u64,
    audio_writes: u64,
    audio_opens: u64,
    audio_closes: u64,
    audio_empty: u64,
    audio_suppressed: u64,
    runtime_cycles: u64,
    waiting_cycles: u64,
    zero_progress_waits: u64,
    audio_failures: u64,
    discarded: u64,
};

const Probe = struct {
    sys: *const r4os.r4sys.Context,
    guest: *product.Guest,
    window: *video.Host,
    owner: u64,
    sink: rt.AudioSink,
    measured_ns: u64,
    instrumented: bool,
    base: rt.GuestDriver = undefined,
    host: rt.HostDriver = undefined,
    runtime: *rt.Runtime = undefined,
    profile: core.performance.Profile = undefined,
    measuring: bool = false,
    started_ns: u64 = 0,
    cpu_start: ?u64 = null,
    before: Snapshot = undefined,
    stage_ns: [6]u64 = .{0} ** 6,
    stage_calls: [6]u64 = .{0} ** 6,

    fn now(self: *Probe) u64 {
        return self.sys.monotonicNanoseconds() orelse 0;
    }
    fn readClock(context: *anyopaque) u64 {
        const self: *Probe = @ptrCast(@alignCast(context));
        return self.now();
    }
    fn begin(self: *Probe) u64 {
        return if (self.measuring and self.instrumented) self.now() else 0;
    }
    fn end(self: *Probe, stage: usize, started: u64) void {
        if (!self.measuring) return;
        if (started != 0) self.stage_ns[stage] +|= self.now() -| started;
        self.stage_calls[stage] += 1;
    }
    fn snapshot(self: *Probe) Snapshot {
        const machine = self.guest.machine.?;
        var info: r4os.abi.GuiFrameInfo = .{};
        _ = self.window.draw.guiFrameInfo(null, &info);
        const audio = self.runtime.audio.stats;
        return .{
            .beam = machine.clock.frame,
            .generated = machine.ppu.frame_generation,
            .submitted = self.window.video.stats.published_frames,
            .unchanged = self.runtime.stats.unchanged_presents,
            .dropped = self.runtime.stats.dropped_presents,
            .generation = info.committed_generation,
            .apu_cycles = machine.smp.cycles,
            .native = machine.smp.dsp.stats.native_frames,
            .non_silent = machine.smp.dsp.stats.frames_rendered -| machine.smp.dsp.stats.silence_frames,
            .audio_bytes = audio.submitted_bytes,
            .audio_writes = audio.writes,
            .audio_opens = audio.open_operations,
            .audio_closes = audio.close_operations,
            .audio_empty = audio.silent_cycles,
            .audio_suppressed = audio.suppressed_bytes,
            .runtime_cycles = self.runtime.stats.cycles,
            .waiting_cycles = self.runtime.stats.waiting_cycles,
            .zero_progress_waits = self.runtime.stats.zero_progress_waits,
            .audio_failures = audio.write_failures,
            .discarded = audio.discarded_bytes,
        };
    }
    fn taskTicks(self: *Probe) ?u64 {
        retry: for (0..4) |_| {
            var cursor: r4os.abi.ProgramInventoryCursor = .{};
            var summary: r4os.abi.ProgramInventorySummary = .{};
            if (self.sys.programInventoryBegin(&cursor, &summary) != r4os.abi.program_handle_ok) continue;
            var items: [32]r4os.abi.ProgramTaskSnapshot = undefined;
            var total: u64 = 0;
            var found = false;
            for (0..64) |_| {
                var page: r4os.abi.ProgramInventoryPageInfo = .{};
                if (self.sys.programInventoryTasks(&cursor, &items, &page) != r4os.abi.program_handle_ok or
                    page.status == r4os.abi.program_inventory_status_restart or
                    page.snapshot_generation != cursor.snapshot_generation or page.returned > items.len) continue :retry;
                for (items[0..page.returned]) |item| if (item.owner_instance_id == self.owner) {
                    total +|= item.runtime_ticks;
                    found = true;
                };
                if (page.status == r4os.abi.program_inventory_status_complete) return if (found) total else null;
                if (page.status != r4os.abi.program_inventory_status_more or page.returned == 0) continue :retry;
            }
        }
        return null;
    }
    fn driver(self: *Probe) rt.GuestDriver {
        return .{ .context = self, .step_fn = step, .reset_fn = reset, .render_audio_fn = renderAudio, .audio_feedback_fn = feedback };
    }
    fn hostDriver(self: *Probe) rt.HostDriver {
        return .{ .context = self, .poll_fn = poll, .present_fn = present, .wait_fn = if (self.host.wait_fn != null) wait else null, .should_close_fn = shouldClose };
    }
    fn audioSink(self: *Probe) rt.AudioSink {
        return .{ .context = self, .open_fn = audioOpen, .write_fn = audioWrite, .volume_fn = audioVolume, .close_fn = audioClose };
    }
    fn from(context: *anyopaque) *Probe {
        return @ptrCast(@alignCast(context));
    }
    fn step(context: *anyopaque, budget: u32, guest_ns: u64) rt.StepResult {
        const self = from(context);
        const started = self.begin();
        const result = self.base.step(budget, guest_ns);
        self.end(0, started);
        if (result.status == .failed) return result;
        const machine = self.guest.machine.?;
        const hz = machine.clock.profile().master_hz;
        if (!self.measuring and machine.clock.master_cycles >= @as(u128, scene.warmup_ns) * hz / std.time.ns_per_s) {
            self.before = self.snapshot();
            self.cpu_start = self.taskTicks();
            self.started_ns = self.now();
            self.measuring = true;
            machine.profile = if (self.instrumented) &self.profile else null;
        }
        if (guest_ns >= scene.warmup_ns + self.measured_ns and machine.host_budget.pending_master_cycles == 0 and
            machine.clock.master_cycles >= @as(u128, scene.warmup_ns + self.measured_ns) * hz / std.time.ns_per_s)
            return rt.StepResult.complete(0, result.frame_ready).withOperations(result.operations);
        return result;
    }
    fn reset(_: *anyopaque) i32 {
        return -1;
    } // Fixed scene has no interactive lifecycle input.
    fn renderAudio(context: *anyopaque, bytes: []u8) i32 {
        const self = from(context);
        const started = self.begin();
        const result = self.base.renderAudio(bytes);
        self.end(1, started);
        return result;
    }
    fn feedback(context: *anyopaque, value: rt.AudioFeedback) bool {
        return from(context).base.audioFeedback(value);
    }
    fn poll(context: *anyopaque) rt.HostPollResult {
        const self = from(context);
        const started = self.begin();
        const result = self.host.poll();
        self.end(3, started);
        return result;
    }
    fn present(context: *anyopaque) i32 {
        const self = from(context);
        const started = self.begin();
        const result = self.host.present();
        self.end(2, started);
        return result;
    }
    fn wait(context: *anyopaque, ticks: u64) i32 {
        const self = from(context);
        const started = self.begin();
        const result = self.host.wait(ticks) orelse -1;
        self.end(4, started);
        return result;
    }
    fn shouldClose(context: *anyopaque) bool {
        return from(context).host.shouldClose() orelse false;
    }
    fn audioOpen(context: *anyopaque, config: rt.AudioConfig) i32 {
        const self = from(context);
        const started = self.begin();
        const result = self.sink.open_fn(self.sink.context, config);
        self.end(5, started);
        return result;
    }
    fn audioWrite(context: *anyopaque, bytes: []const u8) i32 {
        const self = from(context);
        const started = self.begin();
        const result = self.sink.write_fn(self.sink.context, bytes);
        self.end(5, started);
        return result;
    }
    fn audioVolume(context: *anyopaque, volume: u32) i32 {
        const self = from(context);
        const started = self.begin();
        const result = self.sink.volume_fn(self.sink.context, volume);
        self.end(5, started);
        return result;
    }
    fn audioClose(context: *anyopaque) i32 {
        const self = from(context);
        const started = self.begin();
        const result = self.sink.close_fn(self.sink.context);
        self.end(5, started);
        return result;
    }
};
