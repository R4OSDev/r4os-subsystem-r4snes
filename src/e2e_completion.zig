const std = @import("std");
const r4os = @import("r4os");
const fixture_rom = @import("fixture_rom.zig");
const persistence = @import("persistence.zig");
const persistence_r4os = @import("persistence_r4os.zig");
const product_host = @import("product_host.zig");
const sdsp = @import("sdsp.zig");

/// Diagnostic values must be copied before Guest.close frees their owners.
/// This snapshot owns no resources and makes no persistence decisions.
pub const Snapshot = struct {
    runtime_stats: r4os.subsystem_runtime.RuntimeStats,
    audio_stats: r4os.subsystem_runtime.AudioStats,
    guest_ns: u64,
    guest_cycles: u64,
    master_hz: u64,
    drift_cycles: u64,
    pending_cycles: u64,
    ppu_frames: u64,
    dsp_stats: sdsp.AudioStats,
    dsp_queued_frames: usize,
    maximum_step_gap_ns: u64,
    controller_witness: u16,
    completion_seen: bool,
    battery: bool,
    rtc: bool,
    save_bytes: usize,
    identity: [persistence.digest_bytes]u8,
    guest_stats: product_host.GuestStats,
    published_frames: u64,

    pub fn capture(
        active: bool,
        guest: *const product_host.Guest,
        runtime: *const r4os.subsystem_runtime.Runtime,
        window: *const r4os.subsystem_host.Host,
    ) ?Snapshot {
        if (!active) return null;
        const guest_ns = guest.effectiveGuestNanoseconds();
        const machine = guest.machine.?;
        const guest_cycles = machine.clock.master_cycles;
        const master_hz = machine.clock.profile().master_hz;
        const expected_cycles: u64 = @intCast((@as(u128, guest_ns) * master_hz) / std.time.ns_per_s);
        return .{
            .runtime_stats = runtime.stats,
            .audio_stats = runtime.audio.stats,
            .guest_ns = guest_ns,
            .guest_cycles = guest_cycles,
            .master_hz = master_hz,
            .drift_cycles = if (guest_cycles >= expected_cycles) guest_cycles - expected_cycles else expected_cycles - guest_cycles,
            .pending_cycles = machine.host_budget.pending_master_cycles,
            .ppu_frames = machine.clock.frame,
            .dsp_stats = machine.smp.dsp.stats,
            .dsp_queued_frames = machine.smp.dsp.queuedFrames(),
            .maximum_step_gap_ns = guest.runtime_guest.maximum_step_gap_ns,
            .controller_witness = @as(u16, machine.bus.wram[fixture_rom.controller_low_wram_index]) |
                (@as(u16, machine.bus.wram[fixture_rom.controller_high_wram_index]) << 8),
            .completion_seen = machine.bus.wram[fixture_rom.completion_wram_index] == fixture_rom.completion_witness_value,
            .battery = guest.cartridge.?.board.battery,
            .rtc = guest.save_session.?.rtc_record != null,
            .save_bytes = guest.cartridge.?.sram_storage.len,
            .identity = guest.cartridge.?.identity,
            .guest_stats = guest.stats,
            .published_frames = window.video.stats.published_frames,
        };
    }

    /// Additional report evidence after the real close, never a save receipt.
    pub fn persistenceFilesPresent(self: *const Snapshot, files: *const r4os.Files) bool {
        if (self.save_bytes != 0) {
            const path = persistence_r4os.dataPath(&self.identity, .sram) catch return false;
            const info = switch (files.info(path.asZ())) {
                .value => |value| value,
                .missing, .failure => return false,
            };
            if (info.is_dir != 0 or info.size != self.save_bytes) return false;
        }
        if (self.rtc) {
            const path = persistence_r4os.dataPath(&self.identity, .rtc) catch return false;
            const info = switch (files.info(path.asZ())) {
                .value => |value| value,
                .missing, .failure => return false,
            };
            if (info.is_dir != 0 or info.size != persistence.rtc_record_bytes) return false;
        }
        return true;
    }
};
