const std = @import("std");
const core = @import("core");
const r4os = @import("r4os");

const host = r4os.subsystem_host;

const FakeBackend = struct {
    full_begins: u32 = 0,
    damage_begins: u32 = 0,
    commits: u32 = 0,
    rasters: u32 = 0,
    invalid_raster: bool = false,

    fn backend(self: *FakeBackend) host.Backend {
        return .{
            .context = self,
            .begin_full_fn = beginFull,
            .begin_damage_fn = beginDamage,
            .clear_fn = clear,
            .raster_fn = raster,
            .indexed8_fn = indexed8,
            .commit_full_fn = commit,
            .commit_damage_fn = commit,
            .cancel_fn = cancel,
        };
    }

    fn state(context: *anyopaque) *FakeBackend {
        return @ptrCast(@alignCast(context));
    }

    fn beginFull(context: *anyopaque) i32 {
        state(context).full_begins += 1;
        return 0;
    }

    fn beginDamage(context: *anyopaque, _: []const r4os.abi.DisplayDamageRect) i32 {
        state(context).damage_begins += 1;
        return 0;
    }

    fn clear(_: *anyopaque, _: u32) i32 {
        return 0;
    }

    fn raster(context: *anyopaque, _: i32, _: i32, width: u32, height: u32, _: u32, pixels: []const u32) i32 {
        const self = state(context);
        self.rasters += 1;
        if (width == 0 or height == 0 or width > host.tile_max_width or height > host.tile_max_height or
            pixels.len != @as(usize, width) * height)
        {
            self.invalid_raster = true;
        }
        return 0;
    }

    fn indexed8(_: *anyopaque, _: host.IndexedBatch) i32 {
        return -1;
    }

    fn commit(context: *anyopaque) i32 {
        state(context).commits += 1;
        return 0;
    }

    fn cancel(_: *anyopaque) i32 {
        return 0;
    }
};

test "SNES video bridge preserves native geometry complete generations and bounded raster blocks" {
    var display: core.ppu.Ppu = .{};
    _ = display.renderCompleteFrame();
    var placeholder = [_]u32{0};
    var scratch: [host.tile_max_pixels]u32 = undefined;
    var presenter = try host.Presenter.init(try host.Surface.initXrgb32(placeholder[0..], 1, 1), scratch[0..]);
    var adapter: core.host_adapter.VideoAdapter = .{};
    try adapter.bind(&display, &presenter, 1);
    try std.testing.expectEqual(@as(u32, 256), presenter.surface.width);
    try std.testing.expectEqual(@as(u32, 224), presenter.surface.height);
    try std.testing.expectEqual(host.PixelFormat.xrgb32, presenter.surface.format());
    try std.testing.expectEqual(@intFromPtr(&display.published_frame[0]), @intFromPtr(presenter.surface.xrgb32Pixels().?.ptr));
    try std.testing.expect(@intFromPtr(&display.working_frame[0]) != @intFromPtr(presenter.surface.xrgb32Pixels().?.ptr));

    var backend: FakeBackend = .{};
    const first = presenter.presentTo(backend.backend(), 512, 448);
    switch (first) {
        .presented => |info| try std.testing.expectEqual(host.PresentMode.full, info.mode),
        else => return error.UnexpectedPresentResult,
    }
    try std.testing.expect(!backend.invalid_raster);
    try std.testing.expect(!adapter.syncVideo(&presenter));
    try std.testing.expect(presenter.presentTo(backend.backend(), 512, 448) == .unchanged);

    display.published_frame[12 * 256 + 23] = 0xffff0000;
    display.frame_generation += 1;
    display.damage_pending = true;
    display.damage_min_x = 23;
    display.damage_max_x = 23;
    display.damage_min_y = 12;
    display.damage_max_y = 12;
    try std.testing.expect(adapter.syncVideo(&presenter));
    const damaged = presenter.presentTo(backend.backend(), 512, 448);
    switch (damaged) {
        .presented => |info| try std.testing.expectEqual(host.PresentMode.damage, info.mode),
        else => return error.UnexpectedPresentResult,
    }
    try std.testing.expect(!backend.invalid_raster);

    display.mode = 5;
    display.interlace = true;
    display.overscan = true;
    _ = display.renderCompleteFrame();
    try std.testing.expect(adapter.syncVideo(&presenter));
    try std.testing.expectEqual(@as(u32, 512), presenter.surface.width);
    try std.testing.expectEqual(@as(u32, 478), presenter.surface.height);
    const geometry = presenter.presentTo(backend.backend(), 900, 700);
    switch (geometry) {
        .presented => |info| {
            try std.testing.expectEqual(host.PresentMode.full, info.mode);
            try std.testing.expect(info.viewport.mapClientPoint(0, 350) == null);
        },
        else => return error.UnexpectedPresentResult,
    }
    try std.testing.expect(!backend.invalid_raster);
}

test "SNES video pause reset rebind and close reject partial or stale generations" {
    var first_display: core.ppu.Ppu = .{};
    var second_display: core.ppu.Ppu = .{};
    _ = first_display.renderCompleteFrame();
    _ = second_display.renderCompleteFrame();
    var scratch: [host.tile_max_pixels]u32 = undefined;
    var presenter = try host.Presenter.init(
        try host.Surface.initXrgb32(first_display.published_frame[0..], 256, 224),
        scratch[0..],
    );
    var adapter: core.host_adapter.VideoAdapter = .{};
    try adapter.bind(&first_display, &presenter, 1);

    adapter.pause();
    first_display.forced_blank = false;
    first_display.brightness = 15;
    first_display.cgram[0] = 0;
    first_display.cgram[1] = 0x7c;
    _ = first_display.renderCompleteFrame();
    try std.testing.expect(adapter.syncVideo(&presenter));
    adapter.resumeRunning();

    try adapter.bind(&second_display, &presenter, 2);
    try std.testing.expectEqual(@intFromPtr(&second_display.published_frame[0]), @intFromPtr(presenter.surface.xrgb32Pixels().?.ptr));
    try std.testing.expectError(error.StaleGeneration, adapter.bind(&first_display, &presenter, 1));
    adapter.close();
    adapter.close();
    try std.testing.expect(!adapter.canPresent());
    try std.testing.expect(!adapter.syncVideo(&presenter));
    try std.testing.expectError(error.Closed, adapter.bind(&first_display, &presenter, 3));
}
