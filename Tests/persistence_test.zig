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
    var result = core.cartridge.Cartridge{
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
        .obc1_device = if (enhancement == .obc1) .{} else null,
        .srtc_device = if (enhancement == .srtc) .{} else null,
        .spc7110_device = if (enhancement == .spc7110_epson_rtc) .{ .has_rtc = true } else null,
        .superfx_device = if (enhancement == .super_fx) core.superfx.Device.init(.gsu2) else null,
        .sa1_device = if (enhancement == .sa1) .{} else null,
    };
    if (result.obc1_device) |*device| try device.power(result.sram_storage);
    if (result.srtc_device) |*device| device.power();
    if (result.spc7110_device) |*device| device.power();
    if (result.superfx_device) |*device| try device.power(.gsu2, result.rom_storage.len, result.sram_storage.len);
    if (result.sa1_device) |*device| try device.power(.ntsc, result.rom_storage.len, result.sram_storage.len);
    return result;
}

test "battery-backed Super FX work RAM uses the canonical hash save and internal GSU writes survive reopen" {
    const allocator = std.testing.allocator;
    var fake = try FakeBackend.init(allocator);
    defer fake.deinit();
    var first = try makeCart(allocator, 64 * 1024, true, .super_fx, 0x5A);
    defer first.deinit();
    var second = try makeCart(allocator, 64 * 1024, true, .super_fx, 0x5A);
    defer second.deinit();

    var session = try core.persistence.Session.open(&first, fake.backend(), 41, 100, 200);
    const device = &first.superfx_device.?;
    device.scmr = 0x08;
    device.r[0] = 0x1234;
    device.r[1] = 0xBEEF;
    device.source_register = 1;
    try device.executeDecoded(first.rom_storage, first.sram_storage, 0x30);
    try device.drain(first.rom_storage, first.sram_storage);
    _ = first.runSuperFxSlice(0);
    try std.testing.expect(first.sram_dirty);
    try std.testing.expectEqual(@as(u8, 0xEF), first.sram_storage[0x1234]);
    try std.testing.expectEqual(@as(u8, 0xBE), first.sram_storage[0x1235]);
    try std.testing.expect(try session.maybeFlush(&first, core.persistence.flush_delay_master_cycles, 100, 200));
    try session.close(&first, 41, 100, 200);
    try std.testing.expectEqual(@as(usize, 64 * 1024), fake.sram_len);

    var reopened = try core.persistence.Session.open(&second, fake.backend(), 42, 100, 200);
    try std.testing.expectEqual(@as(u8, 0xEF), second.sram_storage[0x1234]);
    try std.testing.expectEqual(@as(u8, 0xBE), second.sram_storage[0x1235]);
    try reopened.close(&second, 42, 100, 200);

    var volatile_cart = try makeCart(allocator, 64 * 1024, false, .super_fx, 0x6B);
    defer volatile_cart.deinit();
    var volatile_backend = try FakeBackend.init(allocator);
    defer volatile_backend.deinit();
    var volatile_session = try core.persistence.Session.open(&volatile_cart, volatile_backend.backend(), 43, 100, 200);
    const volatile_device = &volatile_cart.superfx_device.?;
    volatile_device.scmr = 0x08;
    volatile_device.r[0] = 9;
    volatile_device.r[1] = 0x0042;
    volatile_device.source_register = 1;
    try volatile_device.executeDecoded(volatile_cart.rom_storage, volatile_cart.sram_storage, 0x30);
    try volatile_device.drain(volatile_cart.rom_storage, volatile_cart.sram_storage);
    _ = volatile_cart.runSuperFxSlice(0);
    try std.testing.expect(!volatile_cart.sram_dirty);
    try volatile_session.close(&volatile_cart, 43, 100, 200);
    try std.testing.expectEqual(@as(usize, 0), volatile_backend.acquire_calls);
    try std.testing.expectEqual(@as(usize, 0), volatile_backend.write_calls);
}

test "battery-backed SA-1 BW-RAM persists atomically while I-RAM and battery-less BW-RAM stay volatile" {
    const allocator = std.testing.allocator;
    var fake = try FakeBackend.init(allocator);
    defer fake.deinit();
    var first = try makeCart(allocator, 128 * 1024, true, .sa1, 0xA1);
    defer first.deinit();
    var second = try makeCart(allocator, 128 * 1024, true, .sa1, 0xA1);
    defer second.deinit();

    var session = try core.persistence.Session.open(&first, fake.backend(), 51, 100, 200);
    try std.testing.expect(first.writeEnhancement(0x002229, 0x01));
    try std.testing.expect(first.writeEnhancement(0x003000, 0xA6));
    try std.testing.expectEqual(@as(u8, 0xA6), first.sa1_device.?.iram[0]);
    try std.testing.expect(!first.sram_dirty);
    try std.testing.expect(first.writeEnhancement(0x002226, 0x80));
    try std.testing.expect(first.writeEnhancement(0x006123, 0x5C));
    try std.testing.expect(first.sram_dirty);
    try std.testing.expectEqual(@as(u8, 0x5C), first.sram_storage[0x123]);
    try std.testing.expect(try session.maybeFlush(&first, core.persistence.flush_delay_master_cycles, 100, 200));
    try std.testing.expectEqual(@as(usize, 1), fake.write_calls);
    try std.testing.expectEqual(@as(usize, 128 * 1024), fake.sram_len);
    try session.close(&first, 51, 100, 200);

    var reopened = try core.persistence.Session.open(&second, fake.backend(), 52, 100, 200);
    try std.testing.expectEqual(@as(u8, 0x5C), second.sram_storage[0x123]);
    try std.testing.expectEqual(@as(u8, 0), second.sa1_device.?.iram[0]);
    try reopened.close(&second, 52, 100, 200);

    var volatile_cart = try makeCart(allocator, 128 * 1024, false, .sa1, 0xA2);
    defer volatile_cart.deinit();
    var volatile_backend = try FakeBackend.init(allocator);
    defer volatile_backend.deinit();
    var volatile_session = try core.persistence.Session.open(&volatile_cart, volatile_backend.backend(), 53, 100, 200);
    try std.testing.expect(volatile_cart.writeEnhancement(0x002226, 0x80));
    try std.testing.expect(volatile_cart.writeEnhancement(0x006123, 0x7D));
    try std.testing.expectEqual(@as(u8, 0x7D), volatile_cart.sram_storage[0x123]);
    try std.testing.expect(!volatile_cart.sram_dirty);
    try volatile_session.close(&volatile_cart, 53, 100, 200);
    try std.testing.expectEqual(@as(usize, 0), volatile_backend.acquire_calls);
    try std.testing.expectEqual(@as(usize, 0), volatile_backend.write_calls);
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

test "OBC-1 selectors and object bytes restart through exact battery persistence" {
    const allocator = std.testing.allocator;
    var fake = try FakeBackend.init(allocator);
    defer fake.deinit();
    fake.has_sram = true;
    fake.sram_len = core.obc1.ram_bytes;
    @memset(fake.sram[0..fake.sram_len], 0);
    fake.sram[0x1FF5] = 1;
    fake.sram[0x1FF6] = 0x7F;

    var first = try makeCart(allocator, core.obc1.ram_bytes, true, .obc1, 0x71);
    defer first.deinit();
    var session = try core.persistence.Session.open(&first, fake.backend(), 21, 100, 200);
    try std.testing.expectEqual(@as(u16, 0x1800), first.obc1_device.?.base);
    try std.testing.expectEqual(@as(u8, 0x7F), first.obc1_device.?.object);
    try std.testing.expect(first.writeEnhancement(0x007FF0, 0xA5));
    try std.testing.expect(first.writeEnhancement(0x007FF1, 0x5A));
    try session.close(&first, 21, 101, 300);

    var second = try makeCart(allocator, core.obc1.ram_bytes, true, .obc1, 0x71);
    defer second.deinit();
    var reopened = try core.persistence.Session.open(&second, fake.backend(), 22, 101, 300);
    try std.testing.expectEqual(@as(?u8, 0xA5), second.obc1_device.?.read(second.sram_storage, 0x007FF0));
    try std.testing.expectEqual(@as(?u8, 0x5A), second.obc1_device.?.read(second.sram_storage, 0x007FF1));
    try std.testing.expectEqual(@as(u16, 0x1800), second.obc1_device.?.base);
    try reopened.close(&second, 22, 101, 300);
}

test "RTC record round trips chip registers latch halt overflow and checksum" {
    var state = core.persistence.RtcState.init(.epson);
    state.registers = .{ 8, 5, 9, 5, 3, 2, 9, 2, 2, 0, 4, 2, 4, 2, 0, 6 };
    state.latched = state.registers;
    state.halted = true;
    state.overflow = true;
    state.pending_catchup_seconds = 0;
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

test "S-RTC codec rejects checksum-valid calendar latch and halt corruption precisely" {
    var state = core.persistence.RtcState.init(.s_rtc);
    core.srtc.registersFromCalendar(.{
        .second = 0,
        .minute = 0,
        .hour = 0,
        .day = 1,
        .month = 1,
        .year = 0,
        .weekday = core.srtc.calculateWeekday(0, 1, 1),
    }, &state.registers);
    state.latched = state.registers;
    state.halted = false;
    var encoded: [core.persistence.rtc_record_bytes]u8 = undefined;

    var invalid_calendar = state;
    invalid_calendar.registers[8] = 13;
    core.persistence.encodeRtc(.{ .state = invalid_calendar, .wall_anchor_seconds = 1, .monotonic_anchor_ns = 2, .generation = 3 }, &encoded);
    try std.testing.expectError(error.InvalidSrtcCalendar, core.persistence.decodeRtc(encoded[0..]));

    var invalid_latch = state;
    invalid_latch.latched[6] = 0;
    invalid_latch.latched[7] = 0;
    core.persistence.encodeRtc(.{ .state = invalid_latch, .wall_anchor_seconds = 1, .monotonic_anchor_ns = 2, .generation = 3 }, &encoded);
    try std.testing.expectError(error.InvalidSrtcLatch, core.persistence.decodeRtc(encoded[0..]));

    var invalid_halt = state;
    invalid_halt.halted = true;
    core.persistence.encodeRtc(.{ .state = invalid_halt, .wall_anchor_seconds = 1, .monotonic_anchor_ns = 2, .generation = 3 }, &encoded);
    try std.testing.expectError(error.InvalidSrtcHaltState, core.persistence.decodeRtc(encoded[0..]));
}

test "Epson codec rejects checksum-valid calendar weekday latch control and halt corruption precisely" {
    var state = runningEpsonState();
    var encoded: [core.persistence.rtc_record_bytes]u8 = undefined;

    var invalid_calendar = state;
    invalid_calendar.registers[8] = 0;
    invalid_calendar.registers[9] = 0;
    core.persistence.encodeRtc(.{ .state = invalid_calendar, .wall_anchor_seconds = 1, .monotonic_anchor_ns = 2, .generation = 3 }, &encoded);
    try std.testing.expectError(error.InvalidEpsonCalendar, core.persistence.decodeRtc(encoded[0..]));

    var invalid_weekday = state;
    invalid_weekday.registers[12] = 7;
    core.persistence.encodeRtc(.{ .state = invalid_weekday, .wall_anchor_seconds = 1, .monotonic_anchor_ns = 2, .generation = 3 }, &encoded);
    try std.testing.expectError(error.InvalidEpsonWeekday, core.persistence.decodeRtc(encoded[0..]));

    var invalid_latch = state;
    invalid_latch.latched[6] = 0;
    invalid_latch.latched[7] = 0;
    core.persistence.encodeRtc(.{ .state = invalid_latch, .wall_anchor_seconds = 1, .monotonic_anchor_ns = 2, .generation = 3 }, &encoded);
    try std.testing.expectError(error.InvalidEpsonLatch, core.persistence.decodeRtc(encoded[0..]));

    var invalid_control = state;
    invalid_control.registers[14] = 0x10;
    core.persistence.encodeRtc(.{ .state = invalid_control, .wall_anchor_seconds = 1, .monotonic_anchor_ns = 2, .generation = 3 }, &encoded);
    try std.testing.expectError(error.InvalidEpsonControl, core.persistence.decodeRtc(encoded[0..]));

    state.halted = true;
    core.persistence.encodeRtc(.{ .state = state, .wall_anchor_seconds = 1, .monotonic_anchor_ns = 2, .generation = 3 }, &encoded);
    try std.testing.expectError(error.InvalidEpsonHaltState, core.persistence.decodeRtc(encoded[0..]));
}

test "RTC catch-up is forward-only bounded halt-aware and overflow-visible" {
    const backwards = core.persistence.offlineDelta(200, 199);
    try std.testing.expect(backwards.backwards);
    try std.testing.expectEqual(@as(u64, 0), backwards.seconds);
    const bounded = core.persistence.offlineDelta(1, 1 + @as(i64, @intCast(core.persistence.max_offline_seconds)) + 1000);
    try std.testing.expect(bounded.clamped);
    try std.testing.expectEqual(core.persistence.max_offline_seconds, bounded.seconds);

    var running = core.persistence.RtcState.init(.s_rtc);
    running.halted = false;
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
    core.srtc.registersFromCalendar(.{
        .second = 9,
        .minute = 0,
        .hour = 0,
        .day = 1,
        .month = 1,
        .year = 0,
        .weekday = core.srtc.calculateWeekday(0, 1, 1),
    }, &stored.registers);
    stored.latched = stored.registers;
    stored.halted = false;
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
    try std.testing.expectEqual(@as(u64, 0), session.peekRtcState().?.pending_catchup_seconds);
    const advanced = try core.srtc.calendarFromRegisters(&session.peekRtcState().?.registers, true);
    try std.testing.expectEqual(@as(u8, 19), advanced.second);
    try std.testing.expectEqual(@as(u8, 4), advanced.minute);
    try session.close(&cart, 12, 1_250, 3_000);
    const updated = try core.persistence.decodeRtc(fake.rtc[0..]);
    try std.testing.expectEqual(@as(u64, 0), updated.state.pending_catchup_seconds);
    const persisted = try core.srtc.calendarFromRegisters(&updated.state.registers, true);
    try std.testing.expectEqual(advanced, persisted);

    var restarted_cart = try makeCart(allocator, 0, true, .srtc, 0x44);
    defer restarted_cart.deinit();
    var restarted = try core.persistence.Session.open(&restarted_cart, fake.backend(), 14, 1_250, 4_000);
    const restarted_calendar = try core.srtc.calendarFromRegisters(&restarted.peekRtcState().?.registers, true);
    try std.testing.expectEqual(advanced, restarted_calendar);
    try restarted.close(&restarted_cart, 14, 1_250, 4_000);

    var wrong_chip = try makeCart(allocator, 0, true, .spc7110_epson_rtc, 0x44);
    defer wrong_chip.deinit();
    try std.testing.expectError(error.RtcChipMismatch, core.persistence.Session.open(&wrong_chip, fake.backend(), 13, 1_300, 4_000));
    try std.testing.expect(!fake.held);
}

test "Epson RTC session applies offline time once and restarts exact state" {
    const allocator = std.testing.allocator;
    var fake = try FakeBackend.init(allocator);
    defer fake.deinit();
    const stored = runningEpsonState();
    core.persistence.encodeRtc(.{
        .state = stored,
        .wall_anchor_seconds = 1_000,
        .monotonic_anchor_ns = 2_000,
        .generation = 1,
    }, &fake.rtc);
    fake.has_rtc = true;

    var cart = try makeCart(allocator, 8 * 1024, true, .spc7110_epson_rtc, 0x62);
    defer cart.deinit();
    var session = try core.persistence.Session.open(&cart, fake.backend(), 31, 1_002, 3_000);
    const advanced = try core.epson_rtc.calendarFromRegisters(&session.peekRtcState().?.registers);
    try std.testing.expectEqual(@as(u8, 0), advanced.second);
    try std.testing.expectEqual(@as(u8, 0), advanced.minute);
    try std.testing.expectEqual(@as(u8, 0), advanced.hour);
    try std.testing.expectEqual(@as(u8, 1), advanced.day);
    try std.testing.expectEqual(@as(u8, 3), advanced.month);
    try std.testing.expectEqual(@as(u64, 0), session.peekRtcState().?.pending_catchup_seconds);
    try session.close(&cart, 31, 1_002, 3_000);

    const persisted = try core.persistence.decodeRtc(fake.rtc[0..]);
    try std.testing.expectEqualSlices(u8, session.peekRtcState().?.registers[0..], persisted.state.registers[0..]);
    var restarted_cart = try makeCart(allocator, 8 * 1024, true, .spc7110_epson_rtc, 0x62);
    defer restarted_cart.deinit();
    var restarted = try core.persistence.Session.open(&restarted_cart, fake.backend(), 32, 1_002, 4_000);
    const restarted_calendar = try core.epson_rtc.calendarFromRegisters(&restarted.peekRtcState().?.registers);
    try std.testing.expectEqual(advanced, restarted_calendar);
    try restarted.close(&restarted_cart, 32, 1_002, 4_000);

    var backwards_cart = try makeCart(allocator, 8 * 1024, true, .spc7110_epson_rtc, 0x62);
    defer backwards_cart.deinit();
    var backwards = try core.persistence.Session.open(&backwards_cart, fake.backend(), 33, 900, 5_000);
    try std.testing.expect(backwards.offline_adjustment.backwards);
    const backwards_calendar = try core.epson_rtc.calendarFromRegisters(&backwards.peekRtcState().?.registers);
    try std.testing.expectEqual(restarted_calendar, backwards_calendar);
    try backwards.close(&backwards_cart, 33, 900, 5_000);
}

fn runningEpsonState() core.persistence.RtcState {
    var result = core.persistence.RtcState.init(.epson);
    result.registers = .{ 8, 5, 9, 5, 3, 2, 9, 2, 2, 0, 4, 2, 4, 2, 0, 4 };
    result.latched = result.registers;
    result.halted = false;
    return result;
}
