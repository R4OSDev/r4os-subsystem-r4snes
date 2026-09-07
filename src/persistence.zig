const std = @import("std");
const r4os = @import("r4os");
const board = @import("board.zig");
const cartridge = @import("cartridge.zig");
const epson = @import("epson_rtc.zig");
const srtc = @import("srtc.zig");

const shared = r4os.subsystem_persistence;
pub const delta = @import("save_delta.zig");

pub const save_root = "C:\\R4OS\\SUBSYSTEMS\\r4os.snes\\SAVE\\";
pub const firmware_root = "C:\\R4OS\\SUBSYSTEMS\\r4os.snes\\FIRMWARE";
pub const spc700_ipl_path = "C:\\R4OS\\SUBSYSTEMS\\r4os.snes\\FIRMWARE\\SPC700.IPL";
pub const maximum_sram_bytes: usize = 2 * 1024 * 1024;
pub const digest_bytes = shared.digest_bytes;
pub const digest_hex_bytes = shared.digest_hex_bytes;
pub const flush_delay_master_cycles: u64 = 2 * 21_477_272;
pub const max_offline_seconds: u64 = 512 * 24 * 60 * 60;
pub const rtc_record_bytes: usize = 128;
pub const rtc_record_version: u16 = 1;
const rtc_magic = "R4SNRTC1";

pub const FileKind = shared.FileKind;
pub const ReadResult = shared.ReadResult;
pub const BackendError = shared.BackendError;
pub const Backend = shared.Backend;

/// Runtime-visible lifecycle counters retained until the product host binds a
/// concrete Session in the integration milestone.
pub const State = struct {
    dirty: bool = false,
    generation: u64 = 0,
    writer_owned: bool = false,
};

pub const PersistentMemoryKind = enum {
    sram,
    bw_ram,
};

pub fn memoryKind(enhancement: board.Enhancement) PersistentMemoryKind {
    return if (enhancement == .sa1) .bw_ram else .sram;
}

pub const RtcChip = enum(u8) {
    s_rtc = 1,
    epson = 2,

    pub fn forEnhancement(enhancement: board.Enhancement) ?RtcChip {
        return switch (enhancement) {
            .srtc => .s_rtc,
            .spc7110_epson_rtc => .epson,
            else => null,
        };
    }

    pub fn registerCount(self: RtcChip) u8 {
        return switch (self) {
            .s_rtc => 13,
            .epson => 16,
        };
    }
};

pub const OfflineAdjustment = struct {
    seconds: u64 = 0,
    backwards: bool = false,
    clamped: bool = false,
};

/// Raw chip-visible RTC state. Calendar interpretation remains with the
/// enhancement-chip owner; persistence only preserves exact registers and a
/// bounded amount of forward catch-up work.
pub const RtcState = struct {
    chip: RtcChip,
    registers: [16]u8 = .{0} ** 16,
    latched: [16]u8 = .{0} ** 16,
    halted: bool = false,
    overflow: bool = false,
    pending_catchup_seconds: u64 = 0,

    pub fn init(chip: RtcChip) RtcState {
        var result = RtcState{ .chip = chip, .halted = true };
        if (chip == .epson) {
            const device = epson.Device{};
            device.savePersistent(
                &result.registers,
                &result.latched,
                &result.halted,
                &result.overflow,
            );
        }
        return result;
    }

    pub fn queueCatchup(self: *RtcState, adjustment: OfflineAdjustment) void {
        if (self.halted or adjustment.backwards or adjustment.seconds == 0) return;
        const available = max_offline_seconds -| self.pending_catchup_seconds;
        const accepted = @min(available, adjustment.seconds);
        self.pending_catchup_seconds += accepted;
        if (accepted != adjustment.seconds or adjustment.clamped) self.overflow = true;
    }

    pub fn takeCatchup(self: *RtcState) u64 {
        const result = self.pending_catchup_seconds;
        self.pending_catchup_seconds = 0;
        return result;
    }
};

pub const RtcRecord = struct {
    state: RtcState,
    wall_anchor_seconds: i64,
    monotonic_anchor_ns: u64,
    generation: u64,
};

pub const RtcDecodeError = srtc.PersistentError || epson.PersistentError || error{
    WrongSize,
    BadMagic,
    UnsupportedVersion,
    InvalidChip,
    InvalidRegisterCount,
    InvalidFlags,
    InvalidReserved,
    BadChecksum,
    InvalidCatchup,
};

pub const OpenError = BackendError || RtcDecodeError || error{
    InvalidGeneration,
    CorruptSave,
    RtcChipMismatch,
};

pub const FlushError = BackendError || error{
    Closed,
    StaleGeneration,
};

/// Cartridge-owned persistence policy over the shared lease/atomic backend.
/// Battery-less boards never touch the backend. SRAM and SA-1 BW-RAM
/// retain the exact board-sized `.SAV` keyed by normalized ROM hash. Small
/// autosaves use a bounded cumulative `.SDJ`; explicit flush/close checkpoint
/// the current state back to the raw `.SAV` for existing readers.
pub const Session = struct {
    backend: Backend,
    digest: [digest_bytes]u8,
    generation: u64,
    enabled: bool,
    closed: bool = false,
    last_flush_guest_tick: u64 = 0,
    rtc_record: ?RtcRecord = null,
    rtc_dirty: bool = false,
    offline_adjustment: OfflineAdjustment = .{},
    journal: delta.Journal = .{},
    base_present: bool = false,
    checkpoint_pending: bool = false,
    disk_delta_base: ?[32]u8 = null,

    pub fn open(
        cart: *cartridge.Cartridge,
        backend: Backend,
        generation: u64,
        wall_now_seconds: ?i64,
        monotonic_now_ns: u64,
    ) OpenError!Session {
        if (generation == 0) return error.InvalidGeneration;
        var result = Session{
            .backend = backend,
            .digest = cart.identity,
            .generation = generation,
            .enabled = cart.board.battery,
        };
        cart.clearSramDirty();
        if (!result.enabled) return result;

        try backend.acquire(&result.digest, generation);
        errdefer backend.release(&result.digest, generation) catch {};

        if (cart.sram_storage.len != 0) {
            switch (backend.readExact(&result.digest, .sram, cart.sram_storage)) {
                .ok => result.base_present = true,
                .missing => {},
                .wrong_size => return error.CorruptSave,
                .io => return error.Io,
            }
            var base: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(cart.sram_storage, &base, .{});
            switch (backend.readExact(&result.digest, .sram_delta, &result.journal.bytes)) {
                .ok => {
                    if (!delta.validate(&result.journal.bytes)) return error.CorruptSave;
                    result.disk_delta_base = result.journal.base();
                    if (!result.base_present) return error.CorruptSave;
                    if (!result.journal.apply(cart.sram_storage, base)) {
                        result.journal = delta.Journal.init(cart.sram_storage.len, base);
                    }
                },
                .missing => result.journal = delta.Journal.init(cart.sram_storage.len, base),
                .wrong_size => return error.CorruptSave,
                .io => return error.Io,
            }
        }
        if (cart.obc1_device) |*device| device.power(cart.sram_storage) catch return error.CorruptSave;
        cart.restoreNecDspPersistentRam() catch return error.CorruptSave;
        cart.restoreSt018PersistentRam() catch return error.CorruptSave;

        if (rtcChipForCartridge(cart)) |chip| {
            var encoded: [rtc_record_bytes]u8 = undefined;
            switch (backend.readExact(&result.digest, .rtc, encoded[0..])) {
                .ok => {
                    var record = try decodeRtc(encoded[0..]);
                    if (record.state.chip != chip) return error.RtcChipMismatch;
                    result.offline_adjustment = offlineDelta(record.wall_anchor_seconds, wall_now_seconds);
                    record.state.queueCatchup(result.offline_adjustment);
                    if (cart.srtc_device) |*device| {
                        try device.loadPersistent(
                            &record.state.registers,
                            &record.state.latched,
                            record.state.halted,
                            record.state.overflow,
                        );
                        const catchup = record.state.takeCatchup();
                        device.advanceSeconds(catchup);
                        captureSrtc(device, &record.state);
                    }
                    if (cart.spc7110_device) |*device| {
                        if (device.has_rtc) {
                            try device.rtc.loadPersistent(
                                &record.state.registers,
                                &record.state.latched,
                                record.state.halted,
                                record.state.overflow,
                            );
                            const catchup = record.state.takeCatchup();
                            device.advanceRtcSeconds(catchup);
                            captureEpson(&device.rtc, &record.state);
                        }
                    }
                    result.rtc_record = record;
                    result.rtc_dirty = result.offline_adjustment.seconds != 0 or
                        rtcDirty(cart);
                },
                .missing => {
                    result.rtc_record = .{
                        .state = RtcState.init(chip),
                        .wall_anchor_seconds = wall_now_seconds orelse 0,
                        .monotonic_anchor_ns = monotonic_now_ns,
                        .generation = generation,
                    };
                    if (cart.srtc_device) |*device| captureSrtc(device, &result.rtc_record.?.state);
                    if (cart.spc7110_device) |*device| {
                        if (device.has_rtc) captureEpson(&device.rtc, &result.rtc_record.?.state);
                    }
                    result.rtc_dirty = true;
                },
                .wrong_size => return error.WrongSize,
                .io => return error.Io,
            }
        }
        return result;
    }

    pub fn rtcState(self: *Session) ?*RtcState {
        if (self.rtc_record) |*record| {
            self.rtc_dirty = true;
            return &record.state;
        }
        return null;
    }

    pub fn peekRtcState(self: *const Session) ?*const RtcState {
        if (self.rtc_record) |*record| return &record.state;
        return null;
    }

    pub fn maybeFlush(
        self: *Session,
        cart: *cartridge.Cartridge,
        guest_tick: u64,
        wall_now_seconds: ?i64,
        monotonic_now_ns: u64,
    ) FlushError!bool {
        if (self.closed) return error.Closed;
        if (!self.enabled) return false;
        try self.backend.poll();
        if (!cart.sram_dirty and !self.rtc_dirty and !rtcDirty(cart)) return false;
        if (guest_tick -| self.last_flush_guest_tick < flush_delay_master_cycles) return false;
        // The base snapshot may still be in flight. Keep new dirty ranges until
        // it is durable; no delta may reference a merely queued checkpoint.
        if (self.checkpoint_pending and self.backend.pending()) return false;
        self.checkpoint_pending = false;
        if (cart.dirtyRange()) |range| {
            if (self.base_present and cart.sram_storage.len > delta.record_bytes and
                self.journal.capture(cart.sram_storage, range.first, range.end))
            {
                try self.backend.writeAtomic(&self.digest, .sram_delta, &self.journal.bytes);
                self.disk_delta_base = self.journal.base();
                cart.clearSramDirty();
            } else try self.checkpoint(cart);
        }
        try self.flushRtc(cart, wall_now_seconds, monotonic_now_ns);
        self.last_flush_guest_tick = guest_tick;
        return true;
    }

    pub fn flush(
        self: *Session,
        cart: *cartridge.Cartridge,
        wall_now_seconds: ?i64,
        monotonic_now_ns: u64,
    ) FlushError!void {
        if (self.closed) return error.Closed;
        if (!self.enabled) return;
        try self.backend.poll();
        if ((cart.sram_dirty or self.journal.count() != 0) and cart.sram_storage.len != 0) try self.checkpoint(cart);
        try self.flushRtc(cart, wall_now_seconds, monotonic_now_ns);
    }

    fn checkpoint(self: *Session, cart: *cartridge.Cartridge) BackendError!void {
        // Prevent per-kind coalescing from dropping a baseline still referenced
        // by a previously accepted delta, and retain its Last-Good on failure.
        try self.backend.drain();
        var base: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(cart.sram_storage, &base, .{});
        if (self.disk_delta_base) |old_base| {
            if (std.mem.eql(u8, &base, &old_base)) {
                // Returning to an older identical base must not revive a stale
                // delta after a crash between publishing .SAV and closing.
                const empty = delta.Journal.init(cart.sram_storage.len, base);
                try self.backend.writeAtomic(&self.digest, .sram_delta, &empty.bytes);
                try self.backend.drain();
            }
        }
        try self.backend.writeAtomic(&self.digest, .sram, cart.sram_storage);
        self.base_present = true;
        self.checkpoint_pending = true;
        self.journal = delta.Journal.init(cart.sram_storage.len, base);
        cart.clearSramDirty();
    }

    fn flushRtc(self: *Session, cart: *cartridge.Cartridge, wall_now_seconds: ?i64, monotonic_now_ns: u64) FlushError!void {
        if (cart.srtc_device) |*device| {
            if (device.dirty) self.rtc_dirty = true;
            if (self.rtc_record) |*record| captureSrtc(device, &record.state);
        }
        if (cart.spc7110_device) |*device| {
            if (device.has_rtc) {
                if (device.rtc.dirty) self.rtc_dirty = true;
                if (self.rtc_record) |*record| captureEpson(&device.rtc, &record.state);
            }
        }
        if (self.rtc_dirty) {
            if (self.rtc_record) |*record| {
                record.wall_anchor_seconds = wall_now_seconds orelse 0;
                record.monotonic_anchor_ns = monotonic_now_ns;
                record.generation = self.generation;
                var encoded: [rtc_record_bytes]u8 = undefined;
                encodeRtc(record.*, &encoded);
                try self.backend.writeAtomic(&self.digest, .rtc, encoded[0..]);
                self.rtc_dirty = false;
                if (cart.srtc_device) |*device| device.clearDirty();
                if (cart.spc7110_device) |*device| {
                    if (device.has_rtc) device.rtc.clearDirty();
                }
            }
        }
    }

    /// Reset keeps the lease and restores only battery-backed state into an
    /// already powered replacement. Failure leaves the old cartridge intact.
    pub fn restoreForReset(self: *Session, old: *const cartridge.Cartridge, replacement: *cartridge.Cartridge) !void {
        if (!self.enabled) return;
        if (old.sram_storage.len != replacement.sram_storage.len) return error.CorruptSave;
        @memcpy(replacement.sram_storage, old.sram_storage);
        if (replacement.obc1_device) |*device| try device.power(replacement.sram_storage);
        try replacement.restoreNecDspPersistentRam();
        try replacement.restoreSt018PersistentRam();
        if (self.rtc_record) |record| {
            const state = record.state;
            if (replacement.srtc_device) |*device| {
                try device.loadPersistent(&state.registers, &state.latched, state.halted, state.overflow);
            }
            if (replacement.spc7110_device) |*device| {
                if (device.has_rtc) try device.rtc.loadPersistent(&state.registers, &state.latched, state.halted, state.overflow);
            }
        }
        replacement.clearSramDirty();
    }

    /// Close is idempotent, drains the shared asynchronous backend through
    /// release and never retains a lease after a failed final write.
    pub fn close(
        self: *Session,
        cart: *cartridge.Cartridge,
        generation: u64,
        wall_now_seconds: ?i64,
        monotonic_now_ns: u64,
    ) FlushError!void {
        if (self.closed) return;
        if (generation != self.generation) return error.StaleGeneration;
        self.closed = true;
        if (!self.enabled) return;
        var flush_fault: ?FlushError = null;
        self.closed = false;
        self.flush(cart, wall_now_seconds, monotonic_now_ns) catch |fault| {
            flush_fault = fault;
        };
        self.closed = true;
        var release_fault: ?BackendError = null;
        self.backend.release(&self.digest, generation) catch |fault| {
            release_fault = fault;
        };
        if (flush_fault) |fault| return fault;
        if (release_fault) |fault| return fault;
    }
};

pub fn offlineDelta(saved_wall_seconds: i64, now_wall_seconds: ?i64) OfflineAdjustment {
    const now = now_wall_seconds orelse return .{};
    if (saved_wall_seconds <= 0 or now <= 0) return .{};
    if (now < saved_wall_seconds) return .{ .backwards = true };
    const raw: u64 = @intCast(now - saved_wall_seconds);
    if (raw > max_offline_seconds) return .{ .seconds = max_offline_seconds, .clamped = true };
    return .{ .seconds = raw };
}

pub fn digestHex(digest: *const [digest_bytes]u8, out: *[digest_hex_bytes]u8) []const u8 {
    return shared.digestHex(digest, out);
}

pub fn encodeRtc(record: RtcRecord, out: *[rtc_record_bytes]u8) void {
    @memset(out, 0);
    @memcpy(out[0..rtc_magic.len], rtc_magic);
    writeLe(u16, out[8..10], rtc_record_version);
    writeLe(u16, out[10..12], rtc_record_bytes);
    out[12] = @intFromEnum(record.state.chip);
    out[13] = record.state.chip.registerCount();
    out[14] = @as(u8, @intFromBool(record.state.halted)) |
        (@as(u8, @intFromBool(record.state.overflow)) << 1);
    @memcpy(out[16..32], record.state.registers[0..]);
    @memcpy(out[32..48], record.state.latched[0..]);
    writeLe(u64, out[48..56], @bitCast(record.wall_anchor_seconds));
    writeLe(u64, out[56..64], record.monotonic_anchor_ns);
    writeLe(u64, out[64..72], record.generation);
    writeLe(u64, out[72..80], record.state.pending_catchup_seconds);
    std.crypto.hash.sha2.Sha256.hash(out[0..96], out[96..128], .{});
}

pub fn decodeRtc(bytes: []const u8) RtcDecodeError!RtcRecord {
    if (bytes.len != rtc_record_bytes) return error.WrongSize;
    if (!std.mem.eql(u8, bytes[0..rtc_magic.len], rtc_magic)) return error.BadMagic;
    if (readLe(u16, bytes[8..10]) != rtc_record_version) return error.UnsupportedVersion;
    if (readLe(u16, bytes[10..12]) != rtc_record_bytes) return error.WrongSize;
    const chip: RtcChip = switch (bytes[12]) {
        @intFromEnum(RtcChip.s_rtc) => .s_rtc,
        @intFromEnum(RtcChip.epson) => .epson,
        else => return error.InvalidChip,
    };
    if (bytes[13] != chip.registerCount()) return error.InvalidRegisterCount;
    if ((bytes[14] & ~@as(u8, 0x03)) != 0 or bytes[15] != 0) return error.InvalidFlags;
    if (!allZero(bytes[80..96])) return error.InvalidReserved;
    var expected: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes[0..96], &expected, .{});
    if (!std.mem.eql(u8, bytes[96..128], expected[0..])) return error.BadChecksum;
    const pending = readLe(u64, bytes[72..80]);
    if (pending > max_offline_seconds) return error.InvalidCatchup;
    var registers: [16]u8 = undefined;
    var latched: [16]u8 = undefined;
    @memcpy(registers[0..], bytes[16..32]);
    @memcpy(latched[0..], bytes[32..48]);
    const halted = (bytes[14] & 1) != 0;
    if (chip == .s_rtc) {
        if (halted and pending != 0) return error.InvalidSrtcHaltState;
        try srtc.validatePersistent(&registers, &latched, halted);
    } else {
        if (halted and pending != 0) return error.InvalidEpsonHaltState;
        try epson.validatePersistent(&registers, &latched, halted);
    }
    return .{
        .state = .{
            .chip = chip,
            .registers = registers,
            .latched = latched,
            .halted = halted,
            .overflow = (bytes[14] & 2) != 0,
            .pending_catchup_seconds = pending,
        },
        .wall_anchor_seconds = @bitCast(readLe(u64, bytes[48..56])),
        .monotonic_anchor_ns = readLe(u64, bytes[56..64]),
        .generation = readLe(u64, bytes[64..72]),
    };
}

fn rtcChipForCartridge(cart: *const cartridge.Cartridge) ?RtcChip {
    if (cart.srtc_device != null) return .s_rtc;
    if (cart.spc7110_device) |device| {
        if (device.has_rtc) return .epson;
        return null;
    }
    return switch (cart.board.capability.enhancement) {
        .srtc => .s_rtc,
        .spc7110_epson_rtc => .epson,
        else => null,
    };
}

fn rtcDirty(cart: *const cartridge.Cartridge) bool {
    if (cart.srtc_device) |device| return device.dirty;
    if (cart.spc7110_device) |device| return device.has_rtc and device.rtc.dirty;
    return false;
}

fn captureSrtc(device: *const srtc.Device, state: *RtcState) void {
    device.savePersistent(
        &state.registers,
        &state.latched,
        &state.halted,
        &state.overflow,
    );
    state.pending_catchup_seconds = 0;
}

fn captureEpson(device: *const epson.Device, state: *RtcState) void {
    device.savePersistent(
        &state.registers,
        &state.latched,
        &state.halted,
        &state.overflow,
    );
    state.pending_catchup_seconds = 0;
}

fn allZero(bytes: []const u8) bool {
    for (bytes) |byte| if (byte != 0) return false;
    return true;
}

fn writeLe(comptime T: type, out: []u8, value: T) void {
    var index: usize = 0;
    while (index < @sizeOf(T)) : (index += 1) out[index] = @truncate(value >> @intCast(index * 8));
}

fn readLe(comptime T: type, bytes: []const u8) T {
    var value: T = 0;
    for (bytes, 0..) |byte, index| value |= @as(T, byte) << @intCast(index * 8);
    return value;
}
