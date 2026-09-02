const r4os = @import("r4os");
const sdsp = @import("sdsp.zig");

const runtime = r4os.subsystem_runtime;

pub const reset_not_available: i32 = -9731;
pub const guest_closed: i32 = -9732;
pub const audio_frame_bytes: u64 = sdsp.sample_bytes;

/// Execution remains owned by the SNES machine. The adapter composes that
/// bounded stepper with the common runtime without introducing a host clock
/// or audio backend into CPU, PPU, S-SMP, or S-DSP.
pub const StepSource = struct {
    context: *anyopaque,
    step_fn: *const fn (*anyopaque, u32, u64) runtime.StepResult,
    reset_fn: ?*const fn (*anyopaque) i32 = null,

    pub fn step(self: StepSource, budget: u32, guest_now_ns: u64) runtime.StepResult {
        return self.step_fn(self.context, budget, guest_now_ns);
    }

    pub fn reset(self: StepSource) i32 {
        return if (self.reset_fn) |callback| callback(self.context) else reset_not_available;
    }
};

pub const Adapter = struct {
    dsp: *sdsp.Dsp,
    source: StepSource,
    audio_capture_enabled: bool = true,
    audio_degraded: bool = false,
    audio_prefill_frames: usize = runtime.default_quantum_frames * runtime.default_target_quanta,
    audio_prefill_released: bool = false,
    audio_render_calls: u64 = 0,
    audio_feedback_calls: u64 = 0,
    last_step_guest_ns: u64 = 0,
    maximum_step_gap_ns: u64 = 0,
    transport_pending_bytes: u64 = 0,
    source_finished: bool = false,
    source_exit_code: i32 = 0,
    closed: bool = false,

    pub fn init(dsp: *sdsp.Dsp, source: StepSource) Adapter {
        dsp.beginCapture();
        return .{ .dsp = dsp, .source = source };
    }

    pub fn driver(self: *Adapter) runtime.GuestDriver {
        return .{
            .context = self,
            .step_fn = step,
            .reset_fn = reset,
            .render_audio_fn = renderAudio,
            .audio_feedback_fn = audioFeedback,
        };
    }

    pub fn close(self: *Adapter) void {
        if (self.closed) return;
        self.closed = true;
        self.dsp.endCapture();
        self.transport_pending_bytes = 0;
        self.audio_prefill_released = false;
    }
};

fn step(context: *anyopaque, budget: u32, guest_now_ns: u64) runtime.StepResult {
    const self: *Adapter = @ptrCast(@alignCast(context));
    if (self.closed) return runtime.StepResult.fail(guest_closed);
    if (self.last_step_guest_ns != 0) {
        self.maximum_step_gap_ns = @max(self.maximum_step_gap_ns, guest_now_ns -| self.last_step_guest_ns);
    }
    self.last_step_guest_ns = guest_now_ns;
    if (!self.source_finished) {
        const result = self.source.step(budget, guest_now_ns);
        switch (result.status) {
            .failed => return result,
            .completed => {
                self.source_finished = true;
                self.source_exit_code = result.exit_code;
                if (self.dsp.queuedFrames() == 0 and self.transport_pending_bytes == 0) return result;
                return runtime.StepResult.progress(result.frame_ready).withOperations(result.operations);
            },
            .progress, .waiting => return result,
        }
    }
    if (self.dsp.queuedFrames() == 0 and self.transport_pending_bytes == 0) {
        return runtime.StepResult.complete(self.source_exit_code, false);
    }
    return runtime.StepResult.progress(false);
}

fn reset(context: *anyopaque) i32 {
    const self: *Adapter = @ptrCast(@alignCast(context));
    if (self.closed) return guest_closed;
    const result = self.source.reset();
    if (result != 0) return result;
    self.dsp.beginCapture();
    self.audio_capture_enabled = true;
    self.audio_degraded = false;
    self.audio_prefill_released = false;
    self.transport_pending_bytes = 0;
    self.source_finished = false;
    self.source_exit_code = 0;
    self.last_step_guest_ns = 0;
    return 0;
}

fn renderAudio(context: *anyopaque, out: []u8) i32 {
    const self: *Adapter = @ptrCast(@alignCast(context));
    self.audio_render_calls +%= 1;
    if (self.closed) return guest_closed;
    if (!self.audio_capture_enabled) {
        @memset(out, 0);
        return @intCast(out.len);
    }
    const requested_frames = out.len / sdsp.sample_bytes;
    if (!self.audio_prefill_released and !self.source_finished) {
        if (self.dsp.queuedFrames() < self.audio_prefill_frames) return 0;
        self.audio_prefill_released = true;
    }
    if (!self.source_finished and self.dsp.queuedFrames() < requested_frames) return 0;
    const rendered_before = self.dsp.stats.frames_rendered;
    const result = self.dsp.renderPcm(out);
    if (result >= 0) {
        const source_frames = self.dsp.stats.frames_rendered -| rendered_before;
        self.transport_pending_bytes +|= source_frames * audio_frame_bytes;
    }
    return result;
}

fn audioFeedback(context: *anyopaque, feedback: runtime.AudioFeedback) bool {
    const self: *Adapter = @ptrCast(@alignCast(context));
    self.audio_feedback_calls +%= 1;
    const resolved = feedback.accepted_bytes +| feedback.suppressed_bytes +| feedback.discarded_bytes;
    self.transport_pending_bytes -|= resolved;
    const unavailable = feedback.muted or switch (feedback.state) {
        .disabled, .degraded, .closed => true,
        .ready, .active => false,
    };
    self.audio_degraded = feedback.state == .degraded or feedback.state == .disabled;
    if (unavailable and self.audio_capture_enabled) {
        self.dsp.endCapture();
        self.audio_capture_enabled = false;
        self.audio_prefill_released = false;
        self.transport_pending_bytes = 0;
    } else if (!unavailable and !self.audio_capture_enabled and !self.closed) {
        self.dsp.beginCapture();
        self.audio_capture_enabled = true;
        self.audio_prefill_released = false;
    }
    return false;
}
