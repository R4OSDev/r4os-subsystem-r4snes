const std = @import("std");
const core = @import("core");

const FakeBackend = struct {
    allocator: std.mem.Allocator,
    sram: []u8,
    sram_len: usize = 0,
    has_sram: bool = false,
    rtc: [core.persistence.rtc_record_bytes]u8 = .{0} ** core.persistence.rtc_record_bytes,
    has_rtc: bool = false,
    held: bool = false,
    acquire_calls: usize = 0,
    release_calls: usize = 0,
    read_calls: usize = 0,
    write_calls: usize = 0,
    poll_calls: usize = 0,
    last_digest: [core.persistence.digest_bytes]u8 = .{0} ** core.persistence.digest_bytes,
    last_generation: u64 = 0,
    fail_poll: bool = false,
    fail_write_after_publish: bool = false,

    fn init(allocator: std.mem.Allocator) !FakeBackend {
        return .{
            .allocator = allocator,
            .sram = try allocator.alloc(u8, core.persistence.maximum_sram_bytes),
        };
    }

    fn deinit(self: *FakeBackend) void {
        self.allocator.free(self.sram);
        self.sram = &.{};
    }

    fn backend(self: *FakeBackend) core.persistence.Backend {
        return .{
            .context = self,
            .acquire_fn = acquire,
            .release_fn = release,
            .read_exact_fn = readExact,
            .write_atomic_fn = writeAtomic,
            .poll_fn = poll,
        };
    }

    fn acquire(context: *anyopaque, digest: *const [core.persistence.digest_bytes]u8, generation: u64) core.persistence.BackendError!void {
        const self: *FakeBackend = @ptrCast(@alignCast(context));
        self.acquire_calls += 1;
        if (self.held) return error.Busy;
        self.held = true;
        self.last_digest = digest.*;
        self.last_generation = generation;
    }

    fn release(context: *anyopaque, digest: *const [core.persistence.digest_bytes]u8, generation: u64) core.persistence.BackendError!void {
        const self: *FakeBackend = @ptrCast(@alignCast(context));
        self.release_calls += 1;
        if (!self.held or generation != self.last_generation or !std.mem.eql(u8, digest, &self.last_digest)) return error.Busy;
        self.held = false;
    }

    fn readExact(
        context: *anyopaque,
        digest: *const [core.persistence.digest_bytes]u8,
        kind: core.persistence.FileKind,
        out: []u8,
    ) core.persistence.ReadResult {
        const self: *FakeBackend = @ptrCast(@alignCast(context));
        self.read_calls += 1;
        self.last_digest = digest.*;
        return switch (kind) {
            .sram => if (!self.has_sram)
                .missing
            else if (out.len != self.sram_len)
                .wrong_size
            else blk: {
                @memcpy(out, self.sram[0..self.sram_len]);
                break :blk .ok;
            },
            .rtc => if (!self.has_rtc)
                .missing
            else if (out.len != self.rtc.len)
                .wrong_size
            else blk: {
                @memcpy(out, self.rtc[0..]);
                break :blk .ok;
            },
        };
    }

    fn writeAtomic(
        context: *anyopaque,
        digest: *const [core.persistence.digest_bytes]u8,
        kind: core.persistence.FileKind,
        bytes: []const u8,
    ) core.persistence.BackendError!void {
        const self: *FakeBackend = @ptrCast(@alignCast(context));
        self.write_calls += 1;
        self.last_digest = digest.*;
        switch (kind) {
            .sram => {
                if (bytes.len > self.sram.len) return error.Full;
                @memcpy(self.sram[0..bytes.len], bytes);
                self.sram_len = bytes.len;
                self.has_sram = true;
            },
            .rtc => {
                if (bytes.len != self.rtc.len) return error.Io;
                @memcpy(self.rtc[0..], bytes);
                self.has_rtc = true;
            },
        }
        if (self.fail_write_after_publish) return error.Io;
    }

    fn poll(context: *anyopaque) core.persistence.BackendError!void {
        const self: *FakeBackend = @ptrCast(@alignCast(context));
        self.poll_calls += 1;
        if (self.fail_poll) return error.Io;
    }
};

fn makeCart(
    allocator: std.mem.Allocator,
    ram_bytes: usize,
    battery: bool,
    enhancement: core.board.Enhancement,
    identity_byte: u8,
) !core.cartridge.Cartridge {
    const rom = try allocator.alloc(u8, core.cartridge.minimum_rom_size);
    errdefer allocator.free(rom);
    @memset(rom, 0);
    const ram = try allocator.alloc(u8, ram_bytes);
    errdefer allocator.free(ram);
    @memset(ram, 0);
    return .{
        .allocator = allocator,
        .rom_storage = rom,
        .sram_storage = ram,
        .identity = .{identity_byte} ** core.persistence.digest_bytes,
        .header = undefined,
        .board = .{
            .mapping = .lo_rom,
            .region = .ntsc_u,
            .fast_rom = false,
            .capability = core.board.capability(enhancement),
            .sram_bytes = ram_bytes,
            .battery = battery,
        },
        .had_copier_header = false,
    };
}

test "normalized hash names only exact canonical SAV and RTC paths" {
    const digest = [_]u8{0xAB} ** core.persistence.digest_bytes;
    var text: [core.persistence.digest_hex_bytes]u8 = undefined;
    const hash = core.persistence.digestHex(&digest, &text);
    var expected_raw: [192]u8 = undefined;

    const sav = try core.persistence_r4os.dataPath(&digest, .sram);
    const expected_sav = try std.fmt.bufPrint(expected_raw[0..], "{s}{s}.SAV", .{ core.persistence.save_root, hash });
    try std.testing.expectEqualStrings(expected_sav, sav.bytes());
    try std.testing.expect(std.mem.indexOf(u8, sav.bytes(), "\\APPDATA\\") == null);

    const rtc = try core.persistence_r4os.dataPath(&digest, .rtc);
    const expected_rtc = try std.fmt.bufPrint(expected_raw[0..], "{s}{s}.RTC", .{ core.persistence.save_root, hash });
    try std.testing.expectEqualStrings(expected_rtc, rtc.bytes());
    try std.testing.expectEqual(core.persistence.PersistentMemoryKind.bw_ram, core.persistence.memoryKind(.sa1));
    try std.testing.expectEqual(core.persistence.PersistentMemoryKind.sram, core.persistence.memoryKind(.none));
}

test "battery-less boards never acquire read write poll or release persistence" {
    const allocator = std.testing.allocator;
    var fake = try FakeBackend.init(allocator);
    defer fake.deinit();
    var cart = try makeCart(allocator, 2048, false, .none, 0x10);
    defer cart.deinit();

    var session = try core.persistence.Session.open(&cart, fake.backend(), 1, 100, 200);
    cart.writeSram(0, 0x5A);
    try std.testing.expect(!try session.maybeFlush(&cart, core.persistence.flush_delay_master_cycles, 101, 300));
    try session.close(&cart, 1, 101, 300);
    try std.testing.expectEqual(@as(usize, 0), fake.acquire_calls);
    try std.testing.expectEqual(@as(usize, 0), fake.read_calls);
    try std.testing.expectEqual(@as(usize, 0), fake.write_calls);
    try std.testing.expectEqual(@as(usize, 0), fake.poll_calls);
    try std.testing.expectEqual(@as(usize, 0), fake.release_calls);
}

test "exact board-sized save lease debounce reopen and second writer fail closed" {
    const allocator = std.testing.allocator;
    var fake = try FakeBackend.init(allocator);
    defer fake.deinit();
    var first = try makeCart(allocator, 2048, true, .none, 0x22);
    defer first.deinit();
    var second = try makeCart(allocator, 2048, true, .none, 0x22);
    defer second.deinit();

    var session = try core.persistence.Session.open(&first, fake.backend(), 7, 100, 200);
    try std.testing.expectError(error.Busy, core.persistence.Session.open(&second, fake.backend(), 8, 100, 200));
    first.writeSram(0, 0xA7);
    first.writeSram(first.sram_storage.len - 1, 0x5C);
    try std.testing.expect(!try session.maybeFlush(&first, core.persistence.flush_delay_master_cycles - 1, 100, 200));
    try std.testing.expect(try session.maybeFlush(&first, core.persistence.flush_delay_master_cycles, 100, 200));
    try std.testing.expectEqual(first.sram_storage.len, fake.sram_len);
    try session.close(&first, 7, 100, 200);
    try std.testing.expect(!fake.held);

    var reopened = try core.persistence.Session.open(&second, fake.backend(), 9, 100, 200);
    try std.testing.expectEqual(@as(u8, 0xA7), second.sram_storage[0]);
    try std.testing.expectEqual(@as(u8, 0x5C), second.sram_storage[second.sram_storage.len - 1]);
    try reopened.close(&second, 9, 100, 200);

    fake.sram_len -= 1;
    var wrong = try makeCart(allocator, 2048, true, .none, 0x22);
    defer wrong.deinit();
    try std.testing.expectError(error.CorruptSave, core.persistence.Session.open(&wrong, fake.backend(), 10, 100, 200));
    try std.testing.expect(!fake.held);
}

test "lost write acknowledgement preserves dirty state and close always releases" {
    const allocator = std.testing.allocator;
    var fake = try FakeBackend.init(allocator);
    defer fake.deinit();
    var cart = try makeCart(allocator, 4096, true, .none, 0x33);
    defer cart.deinit();
    var session = try core.persistence.Session.open(&cart, fake.backend(), 11, 100, 200);
    cart.writeSram(7, 0xD4);
    fake.fail_write_after_publish = true;
    try std.testing.expectError(error.Io, session.close(&cart, 11, 101, 300));
    try std.testing.expect(cart.sram_dirty);
    try std.testing.expect(fake.has_sram);
    try std.testing.expectEqual(@as(u8, 0xD4), fake.sram[7]);
    try std.testing.expect(!fake.held);
    try std.testing.expectEqual(@as(usize, 1), fake.release_calls);
}

test "RTC record round trips chip registers latch halt overflow and checksum" {
    var state = core.persistence.RtcState.init(.epson);
    for (&state.registers, 0..) |*byte, index| byte.* = @truncate(index * 7 + 1);
    for (&state.latched, 0..) |*byte, index| byte.* = @truncate(index * 11 + 3);
    state.halted = true;
    state.overflow = true;
    state.pending_catchup_seconds = 12345;
    const record = core.persistence.RtcRecord{
        .state = state,
        .wall_anchor_seconds = 1_800_000_000,
        .monotonic_anchor_ns = 9_876_543_210,
        .generation = 42,
    };
    var encoded: [core.persistence.rtc_record_bytes]u8 = undefined;
    core.persistence.encodeRtc(record, &encoded);
    const decoded = try core.persistence.decodeRtc(encoded[0..]);
    try std.testing.expectEqual(record.state.chip, decoded.state.chip);
    try std.testing.expectEqualSlices(u8, record.state.registers[0..], decoded.state.registers[0..]);
    try std.testing.expectEqualSlices(u8, record.state.latched[0..], decoded.state.latched[0..]);
    try std.testing.expect(decoded.state.halted and decoded.state.overflow);
    try std.testing.expectEqual(record.state.pending_catchup_seconds, decoded.state.pending_catchup_seconds);
    try std.testing.expectEqual(record.wall_anchor_seconds, decoded.wall_anchor_seconds);
    try std.testing.expectEqual(record.monotonic_anchor_ns, decoded.monotonic_anchor_ns);
    try std.testing.expectEqual(record.generation, decoded.generation);

    encoded[31] ^= 0x80;
    try std.testing.expectError(error.BadChecksum, core.persistence.decodeRtc(encoded[0..]));
    try std.testing.expectError(error.WrongSize, core.persistence.decodeRtc(encoded[0 .. encoded.len - 1]));
}

test "RTC catch-up is forward-only bounded halt-aware and overflow-visible" {
    const backwards = core.persistence.offlineDelta(200, 199);
    try std.testing.expect(backwards.backwards);
    try std.testing.expectEqual(@as(u64, 0), backwards.seconds);
    const bounded = core.persistence.offlineDelta(1, 1 + @as(i64, @intCast(core.persistence.max_offline_seconds)) + 1000);
    try std.testing.expect(bounded.clamped);
    try std.testing.expectEqual(core.persistence.max_offline_seconds, bounded.seconds);

    var running = core.persistence.RtcState.init(.s_rtc);
    running.queueCatchup(.{ .seconds = core.persistence.max_offline_seconds, .clamped = true });
    try std.testing.expectEqual(core.persistence.max_offline_seconds, running.pending_catchup_seconds);
    try std.testing.expect(running.overflow);
    running.queueCatchup(.{ .seconds = 1 });
    try std.testing.expectEqual(core.persistence.max_offline_seconds, running.takeCatchup());
    try std.testing.expectEqual(@as(u64, 0), running.pending_catchup_seconds);

    var halted = core.persistence.RtcState.init(.epson);
    halted.halted = true;
    halted.queueCatchup(.{ .seconds = 500 });
    halted.queueCatchup(backwards);
    try std.testing.expectEqual(@as(u64, 0), halted.pending_catchup_seconds);
}

test "RTC session validates chip identity and queues only forward elapsed time" {
    const allocator = std.testing.allocator;
    var fake = try FakeBackend.init(allocator);
    defer fake.deinit();
    var stored = core.persistence.RtcState.init(.s_rtc);
    stored.registers[0] = 9;
    core.persistence.encodeRtc(.{
        .state = stored,
        .wall_anchor_seconds = 1_000,
        .monotonic_anchor_ns = 2_000,
        .generation = 1,
    }, &fake.rtc);
    fake.has_rtc = true;
    var cart = try makeCart(allocator, 0, true, .srtc, 0x44);
    defer cart.deinit();
    var session = try core.persistence.Session.open(&cart, fake.backend(), 12, 1_250, 3_000);
    try std.testing.expectEqual(@as(u64, 250), session.peekRtcState().?.pending_catchup_seconds);
    try std.testing.expectEqual(@as(u8, 9), session.peekRtcState().?.registers[0]);
    try session.close(&cart, 12, 1_250, 3_000);
    const updated = try core.persistence.decodeRtc(fake.rtc[0..]);
    try std.testing.expectEqual(@as(u64, 250), updated.state.pending_catchup_seconds);

    var wrong_chip = try makeCart(allocator, 0, true, .spc7110_epson_rtc, 0x44);
    defer wrong_chip.deinit();
    try std.testing.expectError(error.RtcChipMismatch, core.persistence.Session.open(&wrong_chip, fake.backend(), 13, 1_300, 4_000));
    try std.testing.expect(!fake.held);
}
