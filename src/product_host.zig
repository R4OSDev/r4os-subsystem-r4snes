const std = @import("std");
const r4os = @import("r4os");
const cartridge = @import("cartridge.zig");
const host_adapter = @import("host_adapter.zig");
const machine_module = @import("machine.zig");
const nec_dsp = @import("nec_dsp.zig");
const persistence = @import("persistence.zig");
const ppu = @import("ppu.zig");
const runtime_adapter = @import("runtime_adapter.zig");
const sdsp = @import("sdsp.zig");
const smp = @import("smp.zig");
const st018 = @import("st018.zig");
const timing = @import("timing.zig");

const host_api = r4os.subsystem_host;
const runtime_api = r4os.subsystem_runtime;

pub const slice_budget_master_cycles: u32 = timing.maximum_host_slice_master_cycles;
pub const idle_interval_ns: u64 = std.time.ns_per_ms;
pub const close_error_persistence: i32 = -9740;
pub const runtime_error_persistence: i32 = -9741;
pub const runtime_error_machine: i32 = -9742;
pub const runtime_error_closed: i32 = -9743;
pub const reset_error_persistence: i32 = -9744;
pub const reset_error_cartridge: i32 = -9745;
pub const reset_error_machine: i32 = -9746;
pub const reset_error_video: i32 = -9747;

// USB HID keyboard usages. These deliberately do not overlap guest controls.
pub const physical_usage_f5: u32 = 0x3E;
pub const physical_usage_f6: u32 = 0x3F;
pub const physical_usage_f7: u32 = 0x40;
pub const physical_usage_f8: u32 = 0x41;
pub const physical_usage_f9: u32 = 0x42;
pub const physical_usage_f10: u32 = 0x43;

pub const HostAction = enum {
    pause,
    resume_running,
    reset,
    mute,
    unmute,
};

pub fn actionForPhysicalUsage(usage: u32) ?HostAction {
    return switch (usage) {
        physical_usage_f5 => .pause,
        physical_usage_f6 => .resume_running,
        physical_usage_f8 => .reset,
        physical_usage_f9 => .mute,
        physical_usage_f10 => .unmute,
        else => null,
    };
}

pub fn commandForAction(action: HostAction) runtime_api.LifecycleCommand {
    return switch (action) {
        .pause => .pause,
        .resume_running => .resume_running,
        .reset => .reset,
        .mute => .mute,
        .unmute => .unmute,
    };
}

pub const TimePoint = struct {
    wall_seconds: ?i64,
    monotonic_ns: u64,
};

pub const TimeSource = struct {
    context: *anyopaque,
    now_fn: *const fn (*anyopaque) TimePoint,

    pub fn now(self: TimeSource) TimePoint {
        return self.now_fn(self.context);
    }
};

/// Every heap slice is transferred to Guest by `openOwned`, including on an
/// error. Exact IPL is an inline copy so reset never depends on a host file.
pub const OwnedSource = struct {
    image: []u8,
    nec_dsp_revision: ?nec_dsp.Revision = null,
    nec_dsp_firmware: ?[]u8 = null,
    st018_firmware: ?[]u8 = null,
    exact_ipl: ?[smp.exact_ipl_size]u8 = null,
};

pub const GuestState = enum {
    empty,
    running,
    closed,
};

pub const GuestStats = struct {
    slices: u64 = 0,
    maximum_slice_grant: u32 = 0,
    maximum_slice_execution: u64 = 0,
    flushes: u64 = 0,
    resets: u64 = 0,
    close_calls: u64 = 0,
    cartridge_creates: u64 = 0,
    cartridge_destroys: u64 = 0,
    machine_creates: u64 = 0,
    machine_destroys: u64 = 0,
    source_releases: u64 = 0,
    input_events: u64 = 0,
};

pub const CompletionWitness = struct {
    wram_index: usize,
    value: u8,
};

/// Owns every mutable object belonging to one R4SUBSYS1 launch. `openOwned`
/// is called only after this value reached its final address because the
/// runtime source keeps a pointer to the Guest itself.
pub const Guest = struct {
    allocator: std.mem.Allocator,
    backend: persistence.Backend,
    time: TimeSource,
    instance_id: u64,
    generation: u64,
    save_generation: u64,
    state: GuestState = .empty,
    source_image: ?[]u8 = null,
    source_nec_dsp_revision: ?nec_dsp.Revision = null,
    source_nec_dsp_firmware: ?[]u8 = null,
    source_st018_firmware: ?[]u8 = null,
    source_exact_ipl: ?[smp.exact_ipl_size]u8 = null,
    cartridge: ?cartridge.Cartridge = null,
    machine: ?*machine_module.Machine = null,
    save_session: ?persistence.Session = null,
    runtime_guest: runtime_adapter.Adapter = undefined,
    runtime_guest_ready: bool = false,
    video: host_adapter.VideoAdapter = .{},
    presenter: ?*host_api.Presenter = null,
    focused: bool = false,
    last_host_tick: u64 = 0,
    close_result: i32 = 0,
    completion_witness: ?CompletionWitness = null,
    guest_time_limit_ns: ?u64 = null,
    last_effective_guest_ns: u64 = 0,
    stats: GuestStats = .{},

    pub fn init(
        allocator: std.mem.Allocator,
        backend: persistence.Backend,
        time: TimeSource,
        instance_id: u64,
    ) Guest {
        const identity = if (instance_id == 0) 1 else instance_id;
        return .{
            .allocator = allocator,
            .backend = backend,
            .time = time,
            .instance_id = identity,
            .generation = identity,
            .save_generation = identity,
        };
    }

    pub fn openOwned(self: *Guest, source: OwnedSource) !void {
        if (self.state != .empty or self.source_image != null) return error.AlreadyOpen;
        self.source_image = source.image;
        self.source_nec_dsp_revision = source.nec_dsp_revision;
        self.source_nec_dsp_firmware = source.nec_dsp_firmware;
        self.source_st018_firmware = source.st018_firmware;
        self.source_exact_ipl = source.exact_ipl;
        errdefer _ = self.close();

        var parsed = try self.parseCartridge();
        errdefer parsed.deinit();
        const created = try self.allocator.create(machine_module.Machine);
        errdefer self.allocator.destroy(created);
        try machine_module.Machine.powerInPlace(created, self.instance_id, &parsed, self.exactIpl());
        errdefer created.close();
        const point = self.time.now();
        var session = try persistence.Session.open(
            &parsed,
            self.backend,
            self.save_generation,
            point.wall_seconds,
            point.monotonic_ns,
        );
        errdefer session.close(&parsed, self.save_generation, point.wall_seconds, point.monotonic_ns) catch {};

        self.cartridge = parsed;
        self.stats.cartridge_creates +%= 1;
        self.machine = created;
        self.stats.machine_creates +%= 1;
        self.save_session = session;
        self.runtime_guest = runtime_adapter.Adapter.init(&created.smp.dsp, .{
            .context = self,
            .step_fn = stepMachine,
        });
        self.runtime_guest_ready = true;
        self.state = .running;
    }

    pub fn initialSurface(self: *Guest) !host_api.Surface {
        if (self.state != .running) return error.NotRunning;
        const machine = self.machine orelse return error.NotRunning;
        const info = machine.ppu.frameInfo();
        return host_api.Surface.initXrgb32(
            machine.ppu.published_frame[0..],
            info.width,
            info.height,
        );
    }

    pub fn attachVideo(self: *Guest, presenter: *host_api.Presenter) !void {
        if (self.state != .running) return error.NotRunning;
        const machine = self.machine orelse return error.NotRunning;
        try self.video.bind(&machine.ppu, presenter, self.generation);
        self.presenter = presenter;
    }

    pub fn title(self: *const Guest) []const u8 {
        const cart = if (self.cartridge) |*value| value else return "Cartridge";
        const value = std.mem.trimEnd(u8, cart.header.title[0..], " \x00");
        return if (value.len == 0) "Cartridge" else value;
    }

    pub fn setCompletionWitness(self: *Guest, witness: CompletionWitness) !void {
        if (witness.wram_index >= self.busWramLength()) return error.InvalidCompletionWitnessAddress;
        self.completion_witness = witness;
    }

    pub fn setGuestTimeLimit(self: *Guest, guest_nanoseconds: u64) !void {
        if (guest_nanoseconds == 0 or self.state != .running) return error.InvalidGuestTimeLimit;
        self.guest_time_limit_ns = guest_nanoseconds;
        self.last_effective_guest_ns = 0;
    }

    pub fn effectiveGuestNanoseconds(self: *const Guest) u64 {
        return self.last_effective_guest_ns;
    }

    pub fn driver(self: *Guest) runtime_api.GuestDriver {
        return .{
            .context = self,
            .step_fn = step,
            .reset_fn = resetCallback,
            .render_audio_fn = renderAudio,
            .audio_feedback_fn = audioFeedback,
        };
    }

    pub fn focusGained(self: *Guest, tick: u64) void {
        self.last_host_tick = tick;
        self.focused = true;
    }

    pub fn focusLost(self: *Guest, tick: u64) void {
        self.last_host_tick = tick;
        self.focused = false;
        if (self.machine) |machine| _ = host_adapter.applyInput(&machine.controllers, 0, .focus_lost);
    }

    pub fn physicalKey(self: *Guest, usage: u32, down: bool, repeat: bool, tick: u64) bool {
        self.last_host_tick = tick;
        if (self.state != .running or !self.focused) return false;
        const machine = self.machine orelse return false;
        const kind: host_adapter.InputKind = if (!down) .release else if (repeat) .repeat else .press;
        const accepted = host_adapter.applyInput(&machine.controllers, usage, kind);
        if (accepted) self.stats.input_events +%= 1;
        return accepted;
    }

    pub fn pauseVideo(self: *Guest) void {
        self.video.pause();
    }

    pub fn resumeVideo(self: *Guest) void {
        self.video.resumeRunning();
    }

    pub fn syncVideo(self: *Guest, presenter: *host_api.Presenter) bool {
        return self.video.syncVideo(presenter);
    }

    pub fn reset(self: *Guest) i32 {
        if (self.state != .running or !self.runtime_guest_ready) return runtime_error_closed;
        const old_machine = self.machine orelse return runtime_error_closed;
        const old_cart = if (self.cartridge) |*value| value else return runtime_error_closed;

        // Prepare all fallible state while the old machine and writer lease
        // remain usable. The unchanged ROM and persistence identity are shared.
        var replacement_cart = self.parseCartridge() catch return reset_error_cartridge;
        var replacement_cart_owned = true;
        defer if (replacement_cart_owned) replacement_cart.deinit();
        const replacement_machine = self.allocator.create(machine_module.Machine) catch return reset_error_machine;
        var replacement_machine_owned = true;
        defer if (replacement_machine_owned) self.allocator.destroy(replacement_machine);
        machine_module.Machine.powerInPlace(
            replacement_machine,
            self.instance_id,
            &replacement_cart,
            self.exactIpl(),
        ) catch return reset_error_machine;
        var replacement_machine_powered = true;
        defer if (replacement_machine_powered) replacement_machine.close();
        const next_generation = if (self.generation == std.math.maxInt(u64)) 1 else self.generation + 1;
        var replacement_video = self.video;
        var replacement_presenter: host_api.Presenter = undefined;
        if (self.presenter) |presenter| {
            replacement_presenter = presenter.*;
            replacement_video.bind(&replacement_machine.ppu, &replacement_presenter, next_generation) catch return reset_error_video;
        }
        const point = self.time.now();
        if (self.save_session) |*session| {
            session.flush(old_cart, point.wall_seconds, point.monotonic_ns) catch return reset_error_persistence;
            session.restoreForReset(old_cart, &replacement_cart) catch return reset_error_persistence;
        }

        self.runtime_guest.close();
        old_machine.close();
        self.allocator.destroy(old_machine);
        self.stats.machine_destroys +%= 1;
        old_cart.deinit();
        self.stats.cartridge_destroys +%= 1;
        self.cartridge = replacement_cart;
        replacement_cart_owned = false;
        self.stats.cartridge_creates +%= 1;
        self.machine = replacement_machine;
        replacement_machine_powered = false;
        replacement_machine_owned = false;
        self.stats.machine_creates +%= 1;
        if (self.save_session) |*session| session.last_flush_guest_tick = 0;

        self.generation = next_generation;
        self.runtime_guest = runtime_adapter.Adapter.init(&replacement_machine.smp.dsp, .{
            .context = self,
            .step_fn = stepMachine,
        });
        self.runtime_guest_ready = true;
        self.focused = false;
        self.last_effective_guest_ns = 0;
        _ = host_adapter.applyInput(&replacement_machine.controllers, 0, .reset);
        if (self.presenter) |presenter| {
            self.video = replacement_video;
            presenter.* = replacement_presenter;
        }
        self.stats.resets +%= 1;
        return 0;
    }

    /// Runtime shutdown, GUI close and all error unwinds converge on this one
    /// idempotent reverse-order release path.
    pub fn close(self: *Guest) i32 {
        self.stats.close_calls +%= 1;
        if (self.state == .closed) return self.close_result;
        self.state = .closed;
        self.focused = false;

        if (self.runtime_guest_ready) {
            self.runtime_guest.close();
            self.runtime_guest_ready = false;
        }
        self.video.close();
        self.presenter = null;
        if (self.save_session) |*session| {
            if (self.cartridge) |*cart| {
                const point = self.time.now();
                session.close(
                    cart,
                    self.save_generation,
                    point.wall_seconds,
                    point.monotonic_ns,
                ) catch {
                    self.close_result = close_error_persistence;
                };
            }
        }
        self.save_session = null;
        if (self.machine) |machine| {
            machine.close();
            self.allocator.destroy(machine);
            self.stats.machine_destroys +%= 1;
        }
        self.machine = null;
        if (self.cartridge) |*cart| {
            cart.deinit();
            self.stats.cartridge_destroys +%= 1;
        }
        self.cartridge = null;
        self.releaseSources();
        return self.close_result;
    }

    pub fn resourcesOpen(self: *const Guest) bool {
        return self.state == .running or self.machine != null or self.cartridge != null or
            self.source_image != null or self.source_nec_dsp_firmware != null or
            self.source_st018_firmware != null or self.presenter != null;
    }

    fn parseCartridge(self: *Guest) !cartridge.Cartridge {
        return cartridge.Cartridge.borrowWithOptions(self.allocator, self.source_image orelse return error.NoSource, .{
            .nec_dsp_revision = self.source_nec_dsp_revision,
            .nec_dsp_firmware = self.source_nec_dsp_firmware,
            .st018_firmware = self.source_st018_firmware,
        }, if (self.cartridge) |*cart| cart else null);
    }

    fn exactIpl(self: *Guest) ?[]const u8 {
        if (self.source_exact_ipl) |*firmware| return firmware[0..];
        return null;
    }

    fn releaseSources(self: *Guest) void {
        if (self.source_st018_firmware) |firmware| {
            @memset(firmware, 0);
            self.allocator.free(firmware);
            self.stats.source_releases +%= 1;
        }
        self.source_st018_firmware = null;
        if (self.source_nec_dsp_firmware) |firmware| {
            @memset(firmware, 0);
            self.allocator.free(firmware);
            self.stats.source_releases +%= 1;
        }
        self.source_nec_dsp_firmware = null;
        if (self.source_image) |image| {
            @memset(image, 0);
            self.allocator.free(image);
            self.stats.source_releases +%= 1;
        }
        self.source_image = null;
        if (self.source_exact_ipl) |*firmware| @memset(firmware, 0);
        self.source_exact_ipl = null;
        self.source_nec_dsp_revision = null;
    }

    fn stepMachine(context: *anyopaque, budget: u32, guest_now_ns: u64) runtime_api.StepResult {
        const self: *Guest = @ptrCast(@alignCast(context));
        if (self.state != .running) return runtime_api.StepResult.fail(runtime_error_closed);
        const machine = self.machine orelse return runtime_api.StepResult.fail(runtime_error_closed);
        const cart = if (self.cartridge) |*value| value else return runtime_api.StepResult.fail(runtime_error_closed);
        const effective_guest_ns = if (self.guest_time_limit_ns) |limit| @min(guest_now_ns, limit) else guest_now_ns;
        self.last_effective_guest_ns = effective_guest_ns;
        const result = machine.runHostSlice(cart, budget, effective_guest_ns);
        self.stats.slices +%= 1;
        self.stats.maximum_slice_grant = @max(self.stats.maximum_slice_grant, result.granted_master_cycles);
        self.stats.maximum_slice_execution = @max(self.stats.maximum_slice_execution, result.executed_master_cycles);
        if (result.fault != null) return runtime_api.StepResult.fail(runtime_error_machine)
            .withOperations(result.granted_master_cycles);
        if (self.save_session) |*session| {
            if (session.enabled) {
                const point = self.time.now();
                const flushed = session.maybeFlush(
                    cart,
                    machine.clock.master_cycles,
                    point.wall_seconds,
                    point.monotonic_ns,
                ) catch return runtime_api.StepResult.fail(runtime_error_persistence)
                    .withOperations(result.granted_master_cycles);
                if (flushed) self.stats.flushes +%= 1;
            }
        }
        if (self.completion_witness) |witness| {
            if (machine.bus.wram[witness.wram_index] == witness.value and
                machine.host_budget.pending_master_cycles == 0)
            {
                return runtime_api.StepResult.complete(0, result.frame_ready)
                    .withOperations(result.granted_master_cycles);
            }
        }
        if (result.granted_master_cycles == 0) {
            return runtime_api.StepResult.waitUntil(guest_now_ns +| idle_interval_ns, result.frame_ready)
                .withOperations(0);
        }
        return runtime_api.StepResult.progress(result.frame_ready)
            .withOperations(result.granted_master_cycles);
    }

    fn busWramLength(self: *const Guest) usize {
        if (self.machine) |machine| return machine.bus.wram.len;
        return 128 * 1024;
    }

    fn step(context: *anyopaque, budget: u32, guest_now_ns: u64) runtime_api.StepResult {
        const self: *Guest = @ptrCast(@alignCast(context));
        if (self.state != .running or !self.runtime_guest_ready) return runtime_api.StepResult.fail(runtime_error_closed);
        return self.runtime_guest.driver().step(budget, guest_now_ns);
    }

    fn resetCallback(context: *anyopaque) i32 {
        const self: *Guest = @ptrCast(@alignCast(context));
        return self.reset();
    }

    fn renderAudio(context: *anyopaque, out: []u8) i32 {
        const self: *Guest = @ptrCast(@alignCast(context));
        if (self.state != .running or !self.runtime_guest_ready) return runtime_error_closed;
        return self.runtime_guest.driver().renderAudio(out);
    }

    fn audioFeedback(context: *anyopaque, feedback: runtime_api.AudioFeedback) bool {
        const self: *Guest = @ptrCast(@alignCast(context));
        if (self.state != .running or !self.runtime_guest_ready) return false;
        return self.runtime_guest.driver().audioFeedback(feedback);
    }
};

const TitleState = struct {
    lifecycle: runtime_api.LifecycleState = .ready,
    muted: bool = false,
    audio_degraded: bool = false,

    fn eql(left: TitleState, right: TitleState) bool {
        return left.lifecycle == right.lifecycle and left.muted == right.muted and
            left.audio_degraded == right.audio_degraded;
    }
};

pub const FpsDisplay = struct {
    pub const bounds = host_api.Rect{ .x = 8, .y = 8, .w = 104, .h = 24 };
    enabled: bool = false,
    key_held: bool = false,
    anchored: bool = false,
    anchor_tick: u64 = 0,
    anchor_frame: u64 = 0,
    generation: u64 = 0,
    paused: bool = false,
    storage: [24]u8 = undefined,
    text_len: usize = 0,

    pub fn key(self: *FpsDisplay, down: bool, repeated: bool, focused: bool) bool {
        if (!down) {
            self.key_held = false;
            return false;
        }
        if (repeated or self.key_held or !focused) return false;
        self.key_held = true;
        self.enabled = !self.enabled;
        self.anchored = false;
        return true;
    }

    pub fn text(self: *const FpsDisplay) []const u8 {
        return self.storage[0..self.text_len];
    }

    fn setText(self: *FpsDisplay, value: []const u8) bool {
        if (std.mem.eql(u8, self.text(), value)) return false;
        @memcpy(self.storage[0..value.len], value);
        self.text_len = value.len;
        return true;
    }

    /// Count completed emulation frames against real host time, including
    /// frames whose pixels did not change. No clock call is made here.
    pub fn sample(self: *FpsDisplay, tick: u64, hz: u64, frame: u64, generation: u64, paused: bool) bool {
        if (!self.enabled) return false;
        if (!self.anchored or generation != self.generation or paused != self.paused or
            tick < self.anchor_tick or frame < self.anchor_frame)
        {
            self.anchored = true;
            self.anchor_tick = tick;
            self.anchor_frame = frame;
            self.generation = generation;
            self.paused = paused;
            return self.setText(if (paused) "FPS: Pause" else "FPS: --.-");
        }
        const elapsed = tick - self.anchor_tick;
        if (paused or hz == 0 or elapsed < @max(1, hz / 2 + hz % 2)) return false;
        const tenths: u32 = @intCast(@min(99_999, (@as(u128, frame - self.anchor_frame) * hz * 10 + elapsed / 2) / elapsed));
        self.anchor_tick = tick;
        self.anchor_frame = frame;
        var formatted: [24]u8 = undefined;
        const value = std.fmt.bufPrint(&formatted, "FPS: {d}.{d}", .{ tenths / 10, tenths % 10 }) catch unreachable;
        return self.setText(value);
    }

    pub fn commands(self: *const FpsDisplay) [2]r4os.abi.GuiFrameCommand {
        return .{
            .{ .kind = r4os.abi.gui_frame_command_kind_rect, .x = bounds.x, .y = bounds.y, .w = bounds.w, .h = bounds.h, .rgb = 0x101010 },
            .{ .kind = r4os.abi.gui_frame_command_kind_text, .x = bounds.x + 4, .y = bounds.y + 4, .fg = 0xFFFFFF, .bg = 0x101010, .font_id = r4os.abi.gui_font_builtin_id, .text_w = @intCast(self.text_len * r4os.gui.font_w), .text_h = r4os.gui.font_h, .baseline = r4os.gui.font_h - 1, .line_height = r4os.gui.font_h, .resource_bytes = @intCast(self.text_len) },
        };
    }
};

/// Translates ordered window events only. The shared Runtime performs the one
/// bounded guest slice after the input batch; no guest scheduler lives here.
pub const WindowHost = struct {
    sys: r4os.r4sys.Context,
    window: *host_api.Host,
    guest: *Guest,
    runtime: *runtime_api.Runtime,
    activity_sequence: u64 = 0,
    initial_present_pending: bool = true,
    title_state: ?TitleState = null,
    title_storage: [192]u8 = .{0} ** 192,
    fps: FpsDisplay = .{},

    pub fn init(
        sys: r4os.r4sys.Context,
        window: *host_api.Host,
        guest: *Guest,
        runtime: *runtime_api.Runtime,
    ) WindowHost {
        return .{ .sys = sys, .window = window, .guest = guest, .runtime = runtime };
    }

    pub fn driver(self: *WindowHost) runtime_api.HostDriver {
        return .{
            .context = self,
            .poll_fn = poll,
            .present_fn = present,
            .wait_fn = if (self.window.desk.hasFn("desktop_activity_wait")) wait else null,
            .should_close_fn = shouldClose,
        };
    }

    pub fn applyTitle(self: *WindowHost) void {
        const state = TitleState{
            .lifecycle = self.runtime.state,
            .muted = self.runtime.audio.muted,
            .audio_degraded = self.runtime.audio.state == .degraded,
        };
        if (self.title_state) |old| if (old.eql(state)) return;
        self.title_state = state;
        const suffix: []const u8 = if (state.audio_degraded)
            " [Audio nicht verfuegbar]"
        else if (state.lifecycle == .paused and state.muted)
            " [Pause, stumm]"
        else if (state.lifecycle == .paused)
            " [Pause]"
        else if (state.muted)
            " [Stumm]"
        else
            "";
        const title = std.fmt.bufPrintZ(self.title_storage[0..], "R4SNES - {s}{s}", .{
            self.guest.title(),
            suffix,
        }) catch "R4SNES";
        _ = self.window.setTitle(title.ptr);
    }

    fn poll(context: *anyopaque) runtime_api.HostPollResult {
        const self: *WindowHost = @ptrCast(@alignCast(context));
        self.applyTitle();
        if (self.fps.enabled) {
            if (self.guest.machine) |machine| {
                if (self.fps.sample(self.runtime.clock.last_host_tick, self.runtime.clock.monotonic_hz, machine.clock.frame, self.guest.generation, self.runtime.state == .paused)) {
                    self.window.video.invalidateClient(FpsDisplay.bounds);
                    return .present;
                }
            }
        }
        if (self.initial_present_pending) {
            self.initial_present_pending = false;
            return .present;
        }
        const event = self.window.pollInput() orelse return .idle;
        return switch (event) {
            .close => |close| blk: {
                self.guest.focusLost(close.tick);
                break :blk .{ .command = .close };
            },
            .resize => blk: {
                self.window.video.invalidateAll();
                break :blk .present;
            },
            .focus => |focus| blk: {
                if (focus.focused) self.guest.focusGained(focus.tick) else self.guest.focusLost(focus.tick);
                if (!focus.focused) self.fps.key_held = false;
                break :blk if (focus.focused) .present else .handled;
            },
            .physical_key_down => |key| self.physical(key, true),
            .physical_key_up => |key| self.physical(key, false),
            .key_down, .text, .mouse => .ignored,
        };
    }

    fn physical(self: *WindowHost, key: host_api.PhysicalKeyEvent, down: bool) runtime_api.HostPollResult {
        const repeat = (key.flags & r4os.abi.physical_key_flag_repeat) != 0;
        if (key.key == physical_usage_f7) {
            if (!self.fps.key(down, repeat, self.window.input.focused)) return .ignored;
            if (self.fps.enabled) {
                if (self.guest.machine) |machine| {
                    _ = self.fps.sample(self.runtime.clock.last_host_tick, self.runtime.clock.monotonic_hz, machine.clock.frame, self.guest.generation, self.runtime.state == .paused);
                }
            }
            self.window.overlay = if (self.fps.enabled) .{ .context = self, .append_fn = appendFps } else null;
            self.window.video.invalidateClient(FpsDisplay.bounds);
            return .present;
        }
        if (actionForPhysicalUsage(key.key)) |action| {
            if (!down or repeat) return .ignored;
            switch (action) {
                .pause => self.guest.pauseVideo(),
                .resume_running => self.guest.resumeVideo(),
                .reset, .mute, .unmute => {},
            }
            return .{ .command = commandForAction(action) };
        }
        return if (self.guest.physicalKey(key.key, down, repeat, key.tick)) .handled else .ignored;
    }

    fn shouldClose(context: *anyopaque) bool {
        const self: *WindowHost = @ptrCast(@alignCast(context));
        return self.sys.programShouldClose();
    }

    fn wait(context: *anyopaque, timeout_ticks: u64) i32 {
        const self: *WindowHost = @ptrCast(@alignCast(context));
        var sequence = self.activity_sequence;
        const raw = self.window.desk.desktopActivityWait(self.activity_sequence, timeout_ticks, &sequence);
        self.activity_sequence = sequence;
        return raw;
    }

    fn present(context: *anyopaque) i32 {
        const self: *WindowHost = @ptrCast(@alignCast(context));
        _ = self.guest.syncVideo(&self.window.video);
        return switch (self.window.present()) {
            .failure => |raw| raw,
            .hidden => runtime_api.host_present_hidden,
            .unchanged => runtime_api.host_present_unchanged,
            .presented => runtime_api.host_presented,
        };
    }

    fn appendFps(context: *anyopaque) i32 {
        const self: *WindowHost = @ptrCast(@alignCast(context));
        const commands = self.fps.commands();
        return self.window.draw.guiFrameAppend(&commands, self.fps.text());
    }
};

test "host actions are explicit and never overlap twelve guest controls" {
    try std.testing.expectEqual(HostAction.pause, actionForPhysicalUsage(physical_usage_f5).?);
    try std.testing.expectEqual(HostAction.resume_running, actionForPhysicalUsage(physical_usage_f6).?);
    try std.testing.expectEqual(HostAction.reset, actionForPhysicalUsage(physical_usage_f8).?);
    try std.testing.expectEqual(HostAction.mute, actionForPhysicalUsage(physical_usage_f9).?);
    try std.testing.expectEqual(HostAction.unmute, actionForPhysicalUsage(physical_usage_f10).?);
    for (host_adapter.bindings) |binding| try std.testing.expect(actionForPhysicalUsage(binding.usage) == null);
    for (host_adapter.bindings) |binding| try std.testing.expect(binding.usage != physical_usage_f7);
}

test "FPS display defaults off and toggles once per focused physical press" {
    var fps = FpsDisplay{};
    try std.testing.expect(!fps.enabled);
    try std.testing.expect(!fps.sample(500, 1000, 30, 1, false));
    try std.testing.expect(!fps.anchored);
    try std.testing.expect(!fps.key(true, false, false));
    try std.testing.expect(fps.key(true, false, true));
    try std.testing.expect(fps.enabled);
    try std.testing.expect(!fps.key(true, true, true));
    try std.testing.expect(!fps.key(true, false, true));
    try std.testing.expect(!fps.key(false, false, true));
    try std.testing.expect(fps.key(true, false, true));
    try std.testing.expect(!fps.enabled);
}

test "FPS display measures real time and resets pause and cartridge generations" {
    var fps = FpsDisplay{ .enabled = true };
    try std.testing.expect(fps.sample(1000, 1000, 100, 1, false));
    try std.testing.expect(!fps.sample(1499, 1000, 130, 1, false));
    try std.testing.expect(fps.sample(1500, 1000, 130, 1, false));
    try std.testing.expectEqualStrings("FPS: 60.0", fps.text());
    try std.testing.expect(fps.sample(2000, 1000, 132, 1, false));
    try std.testing.expectEqualStrings("FPS: 4.0", fps.text());
    try std.testing.expect(fps.sample(2100, 1000, 138, 1, true));
    try std.testing.expectEqualStrings("FPS: Pause", fps.text());
    try std.testing.expect(!fps.sample(10000, 1000, 138, 1, true));
    try std.testing.expect(fps.sample(10000, 1000, 138, 1, false));
    try std.testing.expect(fps.sample(10500, 1000, 168, 1, false));
    try std.testing.expectEqualStrings("FPS: 60.0", fps.text());
    try std.testing.expect(fps.sample(11000, 1000, 0, 2, false));
    try std.testing.expect(fps.sample(11500, 1000, 25, 2, false));
    try std.testing.expectEqualStrings("FPS: 50.0", fps.text());
    const commands = fps.commands();
    try std.testing.expectEqual(@as(i32, 8), commands[0].x);
    try std.testing.expectEqual(@as(i32, 8), commands[0].y);
    try std.testing.expect(commands[1].text_w + 8 <= commands[0].w);
    try std.testing.expectEqual(fps.text().len, commands[1].resource_bytes);
}
