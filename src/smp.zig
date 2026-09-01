const implementation = @import("spc700.zig");

pub const apu_bus_hz = implementation.apu_bus_hz;
pub const aram_size = implementation.aram_size;
pub const exact_ipl_size = implementation.exact_ipl_size;
pub const maximum_trace_cycles = implementation.maximum_trace_cycles;
pub const BusMode = implementation.BusMode;
pub const BusCycleKind = implementation.BusCycleKind;
pub const BusCycle = implementation.BusCycle;
pub const Fault = implementation.Fault;
pub const IplMode = implementation.IplMode;
pub const SemanticIplState = implementation.SemanticIplState;
pub const Timer = implementation.Timer;
pub const Io = implementation.Io;
pub const Smp = implementation.Smp;
