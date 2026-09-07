// Optional sampled wall-time attribution for explicit performance runs.
// A sampled operation contains CPU/PPU, then APU, then coprocessor work.
// PPU time is subtracted from its enclosing CPU span, never added twice.
// These are elapsed call spans, not CPU scheduler accounting.
pub const Phase = enum { cpu, ppu, apu, coprocessor };
pub const phase_count = 4;
pub const sample_interval = 1024;

pub const Clock = struct {
    context: *anyopaque,
    read: *const fn (*anyopaque) u64,
};

pub const Profile = struct {
    clock: Clock,
    operations: u64 = 0,
    sampled_operations: u64 = 0,
    clock_reads: u64 = 0,
    elapsed_ns: [phase_count]u64 = .{0} ** phase_count,
    calls: [phase_count]u64 = .{0} ** phase_count,

    pub fn operation(self: *Profile) ?*Profile {
        self.operations += 1;
        if (self.operations % sample_interval != 1) return null;
        self.sampled_operations += 1;
        return self;
    }

    pub fn now(self: *Profile) u64 {
        self.clock_reads += 1;
        return self.clock.read(self.clock.context);
    }

    pub fn add(self: *Profile, phase: Phase, ns: u64) void {
        self.elapsed_ns[@intFromEnum(phase)] +|= ns;
        self.calls[@intFromEnum(phase)] += 1;
    }

    pub fn elapsed(self: *const Profile, phase: Phase) u64 {
        return self.elapsed_ns[@intFromEnum(phase)];
    }
};
