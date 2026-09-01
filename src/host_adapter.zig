const r4os = @import("r4os");
const controller = @import("controller.zig");
const ppu = @import("ppu.zig");

const video_host = r4os.subsystem_host;

pub const Binding = struct {
    usage: u32,
    button: controller.Button,
};

pub const bindings = [_]Binding{
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

pub fn buttonForUsage(usage: u32) ?controller.Button {
    for (bindings) |binding| {
        if (binding.usage == usage) return binding.button;
    }
    return null;
}

pub const InputKind = enum {
    press,
    release,
    repeat,
    focus_lost,
    reset,
};

/// Feed physical keyboard events into the only connected controller.  Repeat
/// is intentionally idempotent; opposing directions remain independently
/// held because the physical SNES pad itself does not arbitrate them.
pub fn applyInput(ports: *controller.Ports, usage: u32, kind: InputKind) bool {
    switch (kind) {
        .focus_lost, .reset => {
            ports.clearInput();
            return true;
        },
        .press, .repeat, .release => {},
    }
    const button = buttonForUsage(usage) orelse return false;
    ports.port1.set(button, kind != .release);
    return true;
}

pub const VideoState = enum {
    unbound,
    running,
    paused,
    closed,
};

/// Generation-safe XRGB32 bridge. The PPU owns and packs complete frames;
/// the shared subsystem host owns scaling, bounded raster tiles and the
/// letterbox viewport. Neither side can observe a partially rendered field.
pub const VideoAdapter = struct {
    source: ?*ppu.Ppu = null,
    binding_generation: u64 = 0,
    observed_revision: u64 = 0,
    state: VideoState = .unbound,

    pub fn bind(self: *VideoAdapter, source: *ppu.Ppu, presenter: *video_host.Presenter, generation: u64) !void {
        if (self.state == .closed) return error.Closed;
        if (generation == 0 or generation <= self.binding_generation) return error.StaleGeneration;
        const info = source.frameInfo();
        try presenter.setSurface(try video_host.Surface.initXrgb32(
            source.published_frame[0..],
            info.width,
            info.height,
        ));
        self.source = source;
        self.binding_generation = generation;
        self.observed_revision = source.frame_generation;
        self.state = .running;
        _ = source.takeDamage();
    }

    pub fn syncVideo(self: *VideoAdapter, presenter: *video_host.Presenter) bool {
        if (!self.canPresent()) return false;
        const source = self.source orelse return false;
        const damage = source.takeDamage() orelse return false;
        if (damage.revision <= self.observed_revision) return false;
        const info = source.frameInfo();
        if (presenter.surface.width != info.width or presenter.surface.height != info.height) {
            presenter.setSurface(video_host.Surface.initXrgb32(
                source.published_frame[0..],
                info.width,
                info.height,
            ) catch return false) catch return false;
        } else {
            presenter.invalidate(.{
                .x = damage.x,
                .y = damage.y,
                .w = damage.width,
                .h = damage.height,
            });
        }
        self.observed_revision = damage.revision;
        return true;
    }

    pub fn pause(self: *VideoAdapter) void {
        if (self.state == .running) self.state = .paused;
    }

    pub fn resumeRunning(self: *VideoAdapter) void {
        if (self.state == .paused) self.state = .running;
    }

    pub fn close(self: *VideoAdapter) void {
        self.source = null;
        self.state = .closed;
    }

    pub fn canPresent(self: *const VideoAdapter) bool {
        return self.source != null and (self.state == .running or self.state == .paused);
    }
};
