pub const ntsc_master_hz: u64 = 21_477_272;
pub const pal_master_hz: u64 = 21_281_370;
pub const nominal_audio_hz: u32 = 32_000;
pub const apu_placeholder_hz: u64 = 1_024_000;

// A host turn may never advance more guest time than this.  The bound is
// deliberately independent of the video standard and host wait duration.
pub const maximum_host_slice_master_cycles: u32 = 32_768;
pub const nominal_line_master_cycles: u16 = 1_364;
pub const short_line_master_cycles: u16 = 1_360;
pub const long_line_master_cycles: u16 = 1_368;
pub const hblank_start_master_cycle: u16 = 1_096;
pub const refresh_master_cycles: u8 = 40;

pub const Region = enum {
    ntsc,
    pal,
};

pub const Profile = struct {
    master_hz: u64,
    scanlines: u16,
    vblank_start: u16,

    pub fn forRegion(region: Region) Profile {
        return switch (region) {
            .ntsc => .{ .master_hz = ntsc_master_hz, .scanlines = 262, .vblank_start = 225 },
            .pal => .{ .master_hz = pal_master_hz, .scanlines = 312, .vblank_start = 240 },
        };
    }
};

pub const Clock = struct {
    region: Region = .ntsc,
    master_cycles: u64 = 0,
    h_counter: u16 = 0,
    v_counter: u16 = 0,
    frame: u64 = 0,
    field: bool = false,
    interlace: bool = false,
    paused: bool = false,
    refresh_position: u16 = 538,
    refresh_active_remaining: u8 = 0,
    refresh_events: u64 = 0,
    refresh_wait_master_cycles: u64 = 0,
    apu_phase: u64 = 0,
    apu_ticks: u64 = 0,

    pub fn init(region: Region) Clock {
        return .{ .region = region };
    }

    pub fn profile(self: *const Clock) Profile {
        return Profile.forRegion(self.region);
    }

    pub fn lineMasterCycles(self: *const Clock) u16 {
        if (self.region == .ntsc and !self.interlace and self.field and self.v_counter == 240) {
            return short_line_master_cycles;
        }
        if (self.region == .pal and self.interlace and self.field and self.v_counter == 311) {
            return long_line_master_cycles;
        }
        return nominal_line_master_cycles;
    }

    pub fn inHblank(self: *const Clock) bool {
        return self.h_counter <= 2 or self.h_counter >= hblank_start_master_cycle;
    }

    pub fn inVblank(self: *const Clock) bool {
        return self.v_counter >= self.profile().vblank_start;
    }

    pub fn horizontalDot(self: *const Clock) u16 {
        if (self.lineMasterCycles() == short_line_master_cycles) return self.h_counter >> 2;
        var adjusted = self.h_counter;
        if (adjusted > 1_292) adjusted -%= 2;
        if (adjusted > 1_310) adjusted -%= 2;
        return adjusted >> 2;
    }

    /// Advance an externally requested span without allowing a single host
    /// turn to monopolise execution.  The sink observes the same ordered
    /// physical events regardless of how the caller partitions its spans.
    pub fn runSlice(self: *Clock, requested: u64, sink: anytype) u32 {
        if (self.paused or requested == 0) return 0;
        const bounded: u32 = @intCast(@min(requested, maximum_host_slice_master_cycles));
        var elapsed: u32 = 0;
        while (elapsed < bounded) : (elapsed += 1) {
            _ = self.tick(sink, self.refresh_active_remaining != 0);
        }
        return bounded;
    }

    /// Advance one CPU bus cycle.  A refresh event reached during that cycle
    /// steals exactly forty additional master clocks on the same timeline.
    pub fn advanceCpuCycle(self: *Clock, base_master_cycles: u8, sink: anytype) u8 {
        var elapsed: u8 = 0;
        var refresh_due = false;
        while (elapsed < base_master_cycles) : (elapsed += 1) {
            refresh_due = self.tick(sink, false) or refresh_due;
        }
        if (refresh_due) {
            var stolen: u8 = 0;
            while (stolen < refresh_master_cycles) : (stolen += 1) {
                _ = self.tick(sink, true);
            }
            elapsed +%= refresh_master_cycles;
        }
        return elapsed;
    }

    fn tick(self: *Clock, sink: anytype, refresh_wait: bool) bool {
        const refresh_start = !refresh_wait and self.h_counter == self.refresh_position;
        if (refresh_start) {
            self.refresh_events +%= 1;
            self.refresh_active_remaining = refresh_master_cycles;
        }
        if (refresh_wait) {
            self.refresh_wait_master_cycles +%= 1;
            if (self.refresh_active_remaining != 0) self.refresh_active_remaining -= 1;
        }

        // Fixed order at each physical clock: refresh edge, S-CPU consumers,
        // APU phase accumulator, then the beam/canonical master timestamp.
        sink.onMasterTick(self, refresh_start, refresh_wait);
        self.apu_phase += apu_placeholder_hz;
        while (self.apu_phase >= self.profile().master_hz) {
            self.apu_phase -= self.profile().master_hz;
            self.apu_ticks +%= 1;
        }

        self.master_cycles +%= 1;
        self.h_counter += 1;
        if (self.h_counter >= self.lineMasterCycles()) {
            self.h_counter = 0;
            self.v_counter += 1;
            if (self.v_counter >= self.profile().scanlines) {
                self.v_counter = 0;
                self.frame +%= 1;
                self.field = !self.field;
            }
            // Mesen's observed refresh start is 538 minus the new line's
            // master-clock phase.  Keeping this integer also captures the
            // short/long-line alignment without host-time arithmetic.
            self.refresh_position = 538 - @as(u16, @intCast(self.master_cycles & 7));
        }
        return refresh_start;
    }
};
