// Optional sampled wall-time attribution for explicit performance runs.
// A sampled operation contains CPU/PPU, then APU, then coprocessor work.
// PPU time is subtracted from its enclosing CPU span, never added twice.
// These are elapsed call spans, not CPU scheduler accounting.
pub const Phase = enum { cpu_bus, dma, ppu, smp, dsp, coprocessor };
pub const phase_count = 6;
pub const phase_order = "cpu_bus,dma,ppu,smp,dsp,coprocessor";
pub const sample_interval = 1024;

pub const Clock = struct {
    context: *anyopaque,
    read: *const fn (*anyopaque) u64,
};

// Outside the measured batch. This is observed clock-call cost, not a claim
// about the physical timer's resolution or emulator CPU consumption.
pub fn calibrate(clock: Clock) u64 {
    var minimum: u64 = ~@as(u64, 0);
    for (0..64) |_| {
        const begin = clock.read(clock.context);
        const end = clock.read(clock.context);
        if (end >= begin) minimum = @min(minimum, end - begin);
    }
    return minimum;
}

pub const Profile = struct {
    clock: Clock,
    operations: u64 = 0,
    sampled_operations: u64 = 0,
    clock_reads: u64 = 0,
    clock_regressions: u64 = 0,
    last_clock: ?u64 = null,
    cpu_operations: u64 = 0,
    dma_operations: u64 = 0,
    master_cycles: u64 = 0,
    elapsed_ns: [phase_count]u64 = .{0} ** phase_count,
    calls: [phase_count]u64 = .{0} ** phase_count,

    pub fn operation(self: *Profile) ?*Profile {
        self.operations +|= 1;
        if (self.operations % sample_interval != 1) return null;
        self.sampled_operations +|= 1;
        return self;
    }

    pub fn now(self: *Profile) u64 {
        self.clock_reads +|= 1;
        const value = self.clock.read(self.clock.context);
        if (self.last_clock) |last| if (value < last) {
            self.clock_regressions +|= 1;
        };
        self.last_clock = value;
        return value;
    }

    pub fn add(self: *Profile, phase: Phase, ns: u64) void {
        self.elapsed_ns[@intFromEnum(phase)] +|= ns;
        self.calls[@intFromEnum(phase)] +|= 1;
    }

    pub fn elapsed(self: *const Profile, phase: Phase) u64 {
        return self.elapsed_ns[@intFromEnum(phase)];
    }
};
