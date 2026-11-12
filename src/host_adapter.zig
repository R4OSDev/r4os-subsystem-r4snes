const r4os = @import("r4os");
const controller = @import("controller.zig");
const ppu = @import("ppu.zig");

const video_host = r4os.subsystem_host;
const std = @import("std");

pub fn copyBackend(draw: *const r4os.r4draw.Context) video_host.Backend {
    var backend = video_host.Backend.fromDraw(draw);
    // The shared bridge ends its source loan on synchronous copy return.
    // Retained shared-raster/GPU transports require a different receipt.
    backend.supports_shared_raster = false;
    return backend;
}

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

/// Generation-checked bridge between the private, complete PPU published_frame
/// and the shared window presenter. The bridge never exposes `working_frame`.
pub const VideoAdapter = struct {
    source: ?*ppu.Ppu = null,
    bridge: ?r4os.published_frame.Bridge = null,
    ended: bool = false,

    pub fn bind(
        self: *VideoAdapter,
        source: *ppu.Ppu,
        presenter: *video_host.Presenter,
        generation: u64,
        backend: video_host.Backend,
    ) !void {
        if (self.ended) return error.Closed;
        if (self.bridge == null) {
            var bridge: r4os.published_frame.Bridge = undefined;
            const rc = r4os.published_frame.Bridge.init(backend, presenter.scratch, &bridge);
            if (rc != 0) return error.UnsupportedPresentation;
            self.bridge = bridge;
        }
        const rc = self.bridge.?.bind(generation);
        if (rc == r4os.published_frame.stale_generation) return error.StaleGeneration;
        if (rc != 0) return error.Busy;
        const info = source.frameInfo();
        try presenter.setSurface(try video_host.Surface.initXrgb32(
            source.published_frame[0..], info.width, info.height));
        self.source = source;
        _ = source.takeDamage();
    }

    /// Observation does not consume damage or extend a source loan. The
    /// actual complete-frame loan is acquired and released within presentTo.
    pub fn syncVideo(self: *VideoAdapter, presenter: *video_host.Presenter) bool {
        if (!self.canPresent()) return false;
        const source = self.source orelse return false;
        const info = source.frameInfo();
        if (presenter.surface.width != info.width or presenter.surface.height != info.height)
            presenter.setSurface(video_host.Surface.initXrgb32(source.published_frame[0..], info.width, info.height) catch return false) catch return false;
        return source.damage_pending;
    }

    pub fn invalidate(self: *VideoAdapter) void {
        if (self.bridge) |*bridge| bridge.presenter.invalidateAll();
    }

    pub fn invalidateClient(self: *VideoAdapter, rect: video_host.Rect) void {
        if (self.bridge) |*bridge| bridge.presenter.invalidateClient(rect);
    }

    pub fn presentTo(self: *VideoAdapter, presenter: *video_host.Presenter, width: i32, height: i32, overlay: ?video_host.FrameOverlay) video_host.PresentResult {
        const frame = r4os.published_frame;
        if (!self.canPresent()) return .{ .failure = frame.closed };
        const source = self.source.?;
        const bridge = &self.bridge.?;
        // The initialized reset frame is complete revision1; working pixels
        // remain outside the publication at every native geometry.
        const revision = std.math.add(u64, source.frame_generation, 1) catch return .{ .failure = frame.exhausted };
        const info = source.frameInfo();
        var lease: frame.Lease = .{
            .pixels = .{ .address = @intFromPtr(&source.published_frame), .length = source.published_frame.len * @sizeOf(u32) },
            .binding_generation = bridge.generation,
            .revision = revision,
            .format = frame.format_xrgb32,
            .width = info.width,
            .height = info.height,
            .stride_bytes = info.width * @sizeOf(u32),
            .flags = frame.published,
        };
        if (bridge.revision != 0 and bridge.width == info.width and bridge.height == info.height) {
            lease.damage_kind = frame.damage_none;
            lease.damage_base_revision = bridge.revision;
            if (source.damage_pending and revision != bridge.revision) {
                lease.damage_kind = frame.damage_rect;
                lease.damage = .{
                    .x = source.damage_min_x,
                    .y = source.damage_min_y,
                    .w = @as(u32, source.damage_max_x) - source.damage_min_x + 1,
                    .h = @as(u32, source.damage_max_y) - source.damage_min_y + 1,
                };
            }
        }
        var acquired: frame.Acquisition = undefined;
        const synced = bridge.syncPublished(lease, &acquired);
        if (synced != 0) return .{ .failure = synced };
        // No emulator step, reset or allocation release can occur while the
        // synchronous CPU-copy backend borrows this immutable frame span.
        defer {
            if (bridge.active_ticket == acquired.ticket) {
                const retired = bridge.release(acquired.ticket);
                std.debug.assert(retired == 0);
            } else std.debug.assert(bridge.state == frame.ended and bridge.active_ticket == 0);
        }
        _ = source.takeDamage();
        var result: frame.Presentation = undefined;
        const rc = bridge.presentWithOverlay(acquired.ticket, width, height, &result, overlay);
        if (rc != 0) return .{ .failure = rc };
        // Host's presenter retains only the owned source view for input
        // geometry; all publication and damage state belongs to the Bridge.
        presenter.stats = bridge.presenter.stats;
        const viewport = video_host.Viewport{
            .x = result.viewport.x,
            .y = result.viewport.y,
            .w = result.viewport.width,
            .h = result.viewport.height,
            .guest_w = result.viewport.source_width,
            .guest_h = result.viewport.source_height,
            .integer_scale = result.viewport.integer_scale,
        };
        return switch (result.kind) {
            0 => .unchanged,
            1 => .hidden,
            2 => .{ .presented = .{ .mode = @enumFromInt(result.mode), .viewport = viewport,
                .damage_regions = result.damage_regions, .raster_blocks = result.raster_blocks,
                .sampled_pixels = result.sampled_pixels } },
            else => .{ .failure = result.error_code },
        };
    }

    pub fn pause(self: *VideoAdapter) void {
        if (self.bridge) |*bridge| _ = bridge.pause(true);
    }

    pub fn resumeRunning(self: *VideoAdapter) void {
        if (self.bridge) |*bridge| _ = bridge.pause(false);
    }

    pub fn close(self: *VideoAdapter) void {
        if (self.bridge) |*bridge| {
            const retired = bridge.close();
            std.debug.assert(retired == 0);
        }
        self.source = null;
        self.ended = true;
    }

    pub fn canPresent(self: *const VideoAdapter) bool {
        return self.source != null and !self.ended;
    }
};
