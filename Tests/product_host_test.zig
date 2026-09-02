const std = @import("std");
const core = @import("core");
const r4os = @import("r4os");

const product = core.product_host;
const runtime_api = r4os.subsystem_runtime;

const FakeTime = struct {
    wall: ?i64 = 1_000,
    monotonic: u64 = 10,

    fn source(self: *FakeTime) product.TimeSource {
        return .{ .context = self, .now_fn = now };
    }

    fn now(context: *anyopaque) product.TimePoint {
        const self: *FakeTime = @ptrCast(@alignCast(context));
        return .{ .wall_seconds = self.wall, .monotonic_ns = self.monotonic };
    }
};

const FakeStore = struct {
    owner: bool = false,
    owner_digest: [core.persistence.digest_bytes]u8 = .{0} ** core.persistence.digest_bytes,
    owner_generation: u64 = 0,
    sram: [128 * 1024]u8 = .{0} ** (128 * 1024),
    sram_len: usize = 0,
    rtc: [core.persistence.rtc_record_bytes]u8 = .{0} ** core.persistence.rtc_record_bytes,
    rtc_present: bool = false,
    fail_writes: bool = false,
    acquire_calls: u32 = 0,
    release_calls: u32 = 0,
    write_calls: u32 = 0,

    fn backend(self: *FakeStore) core.persistence.Backend {
        return .{
            .context = self,
            .acquire_fn = acquire,
            .release_fn = release,
            .read_exact_fn = readExact,
            .write_atomic_fn = writeAtomic,
        };
    }

    fn acquire(context: *anyopaque, digest: *const [core.persistence.digest_bytes]u8, generation: u64) core.persistence.BackendError!void {
        const self: *FakeStore = @ptrCast(@alignCast(context));
        self.acquire_calls += 1;
        if (self.owner) return error.Busy;
        self.owner = true;
        self.owner_digest = digest.*;
        self.owner_generation = generation;
    }

    fn release(context: *anyopaque, digest: *const [core.persistence.digest_bytes]u8, generation: u64) core.persistence.BackendError!void {
        const self: *FakeStore = @ptrCast(@alignCast(context));
        self.release_calls += 1;
        if (!self.owner) return;
        if (generation != self.owner_generation or !std.mem.eql(u8, digest, &self.owner_digest)) return error.Io;
        self.owner = false;
        self.owner_generation = 0;
    }

    fn readExact(
        context: *anyopaque,
        _: *const [core.persistence.digest_bytes]u8,
        kind: core.persistence.FileKind,
        out: []u8,
    ) core.persistence.ReadResult {
        const self: *FakeStore = @ptrCast(@alignCast(context));
        switch (kind) {
            .sram => {
                if (self.sram_len == 0) return .missing;
                if (self.sram_len != out.len) return .wrong_size;
                @memcpy(out, self.sram[0..self.sram_len]);
            },
            .rtc => {
                if (!self.rtc_present) return .missing;
                if (out.len != self.rtc.len) return .wrong_size;
                @memcpy(out, &self.rtc);
            },
        }
        return .ok;
    }

    fn writeAtomic(
        context: *anyopaque,
        digest: *const [core.persistence.digest_bytes]u8,
        kind: core.persistence.FileKind,
        bytes: []const u8,
    ) core.persistence.BackendError!void {
        const self: *FakeStore = @ptrCast(@alignCast(context));
        self.write_calls += 1;
        if (!self.owner or !std.mem.eql(u8, digest, &self.owner_digest)) return error.Busy;
        if (self.fail_writes) return error.Io;
        switch (kind) {
            .sram => {
                if (bytes.len > self.sram.len) return error.Full;
                @memcpy(self.sram[0..bytes.len], bytes);
                self.sram_len = bytes.len;
            },
            .rtc => {
                if (bytes.len != self.rtc.len) return error.Io;
                @memcpy(&self.rtc, bytes);
                self.rtc_present = true;
            },
        }
    }
};

const IdleHost = struct {
    presents: u32 = 0,

    fn driver(self: *IdleHost) runtime_api.HostDriver {
        return .{ .context = self, .poll_fn = poll, .present_fn = present };
    }

    fn poll(_: *anyopaque) runtime_api.HostPollResult {
        return .idle;
    }

    fn present(context: *anyopaque) i32 {
        const self: *IdleHost = @ptrCast(@alignCast(context));
        self.presents += 1;
        return runtime_api.host_present_unchanged;
    }
};

fn makeRuntime() !runtime_api.Runtime {
    return runtime_api.Runtime.init(.{
        .slice_budget = product.slice_budget_master_cycles,
        .max_input_events = 8,
        .max_wait_ticks = 1,
    }, 1_000, 0, null);
}

test "private product guests isolate machine input video audio and bounded runtime state" {
    const allocator = std.testing.allocator;
    var store = FakeStore{};
    var time = FakeTime{};
    var first = product.Guest.init(allocator, store.backend(), time.source(), 1);
    var second = product.Guest.init(allocator, store.backend(), time.source(), 2);
    try first.openOwned(.{ .image = try makeRom(allocator, "R4SNES HOST A", false, 0x11) });
    try second.openOwned(.{ .image = try makeRom(allocator, "R4SNES HOST B", false, 0x22) });
    defer _ = first.close();
    defer _ = second.close();

    try std.testing.expect(first.machine != null and second.machine != null);
    try std.testing.expect(first.machine.? != second.machine.?);
    first.machine.?.bus.wram[0x1234] = 0xa5;
    first.machine.?.ppu.vram[3] = 0x5a;
    first.machine.?.smp.aram[4] = 0xcc;
    try std.testing.expectEqual(@as(u8, 0), second.machine.?.bus.wram[0x1234]);
    try std.testing.expectEqual(@as(u8, 0), second.machine.?.ppu.vram[3]);
    try std.testing.expectEqual(@as(u8, 0), second.machine.?.smp.aram[4]);

    first.focusGained(1);
    try std.testing.expect(first.physicalKey(r4os.abi.physical_key_usage_keypad_6, true, false, 2));
    try std.testing.expect((first.machine.?.controllers.port1.held & (@as(u16, 1) << @intFromEnum(core.controller.Button.a))) != 0);
    try std.testing.expectEqual(@as(u16, 0), second.machine.?.controllers.port1.held);
    first.focusLost(3);
    try std.testing.expectEqual(@as(u16, 0), first.machine.?.controllers.port1.held);
    try std.testing.expect(!first.machine.?.controllers.port2.connected);

    const surface = try first.initialSurface();
    var raster_scratch: [r4os.subsystem_host.tile_max_pixels]u32 = undefined;
    var presenter = try r4os.subsystem_host.Presenter.init(surface, raster_scratch[0..]);
    try first.attachVideo(&presenter);
    const first_video_generation = first.video.binding_generation;
    _ = first.driver().audioFeedback(.{ .state = .degraded, .muted = false });
    try std.testing.expect(!first.machine.?.smp.dsp.capture_enabled);
    _ = first.driver().audioFeedback(.{ .state = .ready, .muted = false });
    try std.testing.expect(first.machine.?.smp.dsp.capture_enabled);

    var first_runtime = try makeRuntime();
    var second_runtime = try makeRuntime();
    var first_host = IdleHost{};
    var second_host = IdleHost{};
    _ = first_runtime.cycle(0, first.driver(), first_host.driver());
    _ = second_runtime.cycle(0, second.driver(), second_host.driver());
    var tick: u64 = 1;
    while (tick <= 40) : (tick += 1) {
        _ = first_runtime.cycle(tick, first.driver(), first_host.driver());
        _ = second_runtime.cycle(tick, second.driver(), second_host.driver());
    }
    try std.testing.expect(first.machine.?.clock.master_cycles != 0 and second.machine.?.clock.master_cycles != 0);
    try std.testing.expect(first.stats.maximum_slice_grant <= product.slice_budget_master_cycles);
    try std.testing.expect(second.stats.maximum_slice_grant <= product.slice_budget_master_cycles);
    try std.testing.expect(first.machine.?.ppu.frame_generation != 0);
    try std.testing.expect(second.machine.?.ppu.frame_generation != 0);

    const first_before_pause = first.machine.?.clock.master_cycles;
    first_runtime.request(.pause, tick, first.driver());
    _ = first_runtime.cycle(tick + 100, first.driver(), first_host.driver());
    try std.testing.expectEqual(first_before_pause, first.machine.?.clock.master_cycles);
    first_runtime.request(.resume_running, tick + 100, first.driver());
    _ = first_runtime.cycle(tick + 101, first.driver(), first_host.driver());

    first.machine.?.bus.wram[1] = 0xee;
    const generation = first.generation;
    first_runtime.request(.reset, tick + 102, first.driver());
    try std.testing.expectEqual(generation + 1, first.generation);
    try std.testing.expectEqual(first_video_generation + 1, first.video.binding_generation);
    try std.testing.expectEqual(@as(u8, 0), first.machine.?.bus.wram[1]);
    try std.testing.expectEqual(@as(usize, 0), first.machine.?.smp.dsp.queuedFrames());
    try std.testing.expectEqual(
        @intFromPtr(&first.machine.?.ppu.published_frame[0]),
        @intFromPtr(presenter.surface.xrgb32Pixels().?.ptr),
    );

    first_runtime.request(.close, tick + 103, first.driver());
    first_runtime.shutdown();
    try std.testing.expectEqual(@as(i32, 0), first.close());
    try std.testing.expect(!first.resourcesOpen());
    try std.testing.expect(second.resourcesOpen());
    const second_cycles = second.machine.?.clock.master_cycles;
    _ = second_runtime.cycle(tick + 104, second.driver(), second_host.driver());
    try std.testing.expect(second.machine.?.clock.master_cycles >= second_cycles);
    try std.testing.expectEqual(@as(i32, 0), first.close());
    try std.testing.expectEqual(@as(u64, 2), first.stats.machine_creates);
    try std.testing.expectEqual(@as(u64, 2), first.stats.machine_destroys);
    second_runtime.shutdown();
}

test "sixty-second host debt is lossless partition-invariant and remains slice bounded" {
    const hz = core.timing.Profile.forRegion(.ntsc).master_hz;
    var one: core.timing.HostBudget = .{};
    var split: core.timing.HostBudget = .{};
    try std.testing.expectEqual(@as(u32, 0), one.budget(0, hz, product.slice_budget_master_cycles));
    try std.testing.expectEqual(@as(u32, 0), split.budget(0, hz, product.slice_budget_master_cycles));
    const end_ns = 60 * std.time.ns_per_s;
    const first = one.budget(end_ns, hz, product.slice_budget_master_cycles);
    try std.testing.expectEqual(product.slice_budget_master_cycles, first);
    one.reconcile(first, first);

    var second: u64 = 1;
    while (second <= 60) : (second += 1) {
        const grant = split.budget(second * std.time.ns_per_s, hz, product.slice_budget_master_cycles);
        try std.testing.expect(grant <= product.slice_budget_master_cycles);
        split.reconcile(grant, grant);
    }
    try std.testing.expectEqual(@as(u64, 60) * hz - product.slice_budget_master_cycles, one.pending_master_cycles);
    try std.testing.expectEqual(@as(u64, 60) * hz - @as(u64, 60) * product.slice_budget_master_cycles, split.pending_master_cycles);

    var drained_one: u64 = first;
    while (one.pending_master_cycles != 0) {
        const grant = one.budget(end_ns, hz, product.slice_budget_master_cycles);
        try std.testing.expect(grant != 0 and grant <= product.slice_budget_master_cycles);
        drained_one += grant;
        one.reconcile(grant, grant);
    }
    var drained_split: u64 = @as(u64, 60) * product.slice_budget_master_cycles;
    while (split.pending_master_cycles != 0) {
        const grant = split.budget(end_ns, hz, product.slice_budget_master_cycles);
        try std.testing.expect(grant != 0 and grant <= product.slice_budget_master_cycles);
        drained_split += grant;
        split.reconcile(grant, grant);
    }
    try std.testing.expectEqual(@as(u64, 60) * hz, drained_one);
    try std.testing.expectEqual(drained_one, drained_split);
}

test "same battery identity is exclusive reset preserves SAV and close failure still unwinds once" {
    const allocator = std.testing.allocator;
    var store = FakeStore{};
    var time = FakeTime{};
    var owner = product.Guest.init(allocator, store.backend(), time.source(), 11);
    try owner.openOwned(.{ .image = try makeRom(allocator, "R4SNES SAVE", true, 0x33) });
    var rejected = product.Guest.init(allocator, store.backend(), time.source(), 12);
    try std.testing.expectError(error.Busy, rejected.openOwned(.{
        .image = try makeRom(allocator, "R4SNES SAVE", true, 0x33),
    }));
    try std.testing.expect(!rejected.resourcesOpen());

    owner.cartridge.?.writeSram(0, 0x73);
    const generation = owner.generation;
    try std.testing.expectEqual(@as(i32, 0), owner.reset());
    try std.testing.expectEqual(generation + 1, owner.generation);
    try std.testing.expectEqual(@as(u8, 0x73), owner.cartridge.?.sram_storage[0]);
    try std.testing.expect(store.owner);
    owner.cartridge.?.writeSram(1, 0x44);
    store.fail_writes = true;
    try std.testing.expectEqual(product.close_error_persistence, owner.close());
    try std.testing.expect(!store.owner);
    try std.testing.expect(!owner.resourcesOpen());
    try std.testing.expectEqual(product.close_error_persistence, owner.close());
    try std.testing.expectEqual(@as(u64, 2), owner.stats.machine_destroys);
    try std.testing.expectEqual(@as(u64, 2), owner.stats.cartridge_destroys);
    try std.testing.expectEqual(@as(u32, 2), store.release_calls);
}

test "invalid cartridge releases its owned source without opening persistence" {
    const allocator = std.testing.allocator;
    var store = FakeStore{};
    var time = FakeTime{};
    var guest = product.Guest.init(allocator, store.backend(), time.source(), 21);
    const invalid = try allocator.alloc(u8, 32 * 1024);
    @memset(invalid, 0xff);
    try std.testing.expectError(error.NoValidHeader, guest.openOwned(.{ .image = invalid }));
    try std.testing.expect(!guest.resourcesOpen());
    try std.testing.expectEqual(@as(u64, 1), guest.stats.source_releases);
    try std.testing.expectEqual(@as(u32, 0), store.acquire_calls);
    try std.testing.expectEqual(@as(i32, 0), guest.close());
}

fn makeRom(allocator: std.mem.Allocator, title: []const u8, battery: bool, variant: u8) ![]u8 {
    const rom = try allocator.alloc(u8, 32 * 1024);
    @memset(rom, 0xea);
    rom[0] = 0x78; // SEI
    rom[1] = 0x80; // BRA -2
    rom[2] = 0xfe;
    rom[3] = variant;
    const header = rom[0x7fc0 .. 0x7fc0 + core.cartridge.header_length];
    @memset(header, 0);
    @memset(header[0..core.cartridge.title_length], ' ');
    const title_len = @min(title.len, core.cartridge.title_length);
    @memcpy(header[0..title_len], title[0..title_len]);
    header[0x15] = 0x20;
    header[0x16] = if (battery) 0x02 else 0x00;
    header[0x17] = 5;
    header[0x18] = if (battery) 1 else 0;
    header[0x19] = 1;
    header[0x1a] = 0x33;
    header[0x3c] = 0x00;
    header[0x3d] = 0x80;
    finalizeChecksum(rom, header);
    return rom;
}

fn finalizeChecksum(rom: []u8, header: []u8) void {
    header[0x1c] = 0;
    header[0x1d] = 0;
    header[0x1e] = 0;
    header[0x1f] = 0;
    var sum: u16 = 0;
    for (rom) |value| sum +%= value;
    const checksum = sum +% 0x01fe;
    const complement = ~checksum;
    header[0x1c] = @truncate(complement);
    header[0x1d] = @truncate(complement >> 8);
    header[0x1e] = @truncate(checksum);
    header[0x1f] = @truncate(checksum >> 8);
}
