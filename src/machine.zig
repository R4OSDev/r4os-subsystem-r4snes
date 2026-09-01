const board = @import("board.zig");
const bus = @import("bus.zig");
const controller = @import("controller.zig");
const coprocessors = @import("coprocessors.zig");
const cpu = @import("cpu.zig");
const persistence = @import("persistence.zig");
const ppu = @import("ppu.zig");
const sdsp = @import("sdsp.zig");
const smp = @import("smp.zig");
const timing = @import("timing.zig");

pub const Machine = struct {
    instance_id: u64,
    board: board.Board = .{},
    bus: bus.Bus = .{},
    cpu: cpu.Cpu = .{},
    ppu: ppu.Ppu = .{},
    smp: smp.Smp = .{},
    dsp: sdsp.Dsp = .{},
    controllers: controller.Ports = .{},
    coprocessors: coprocessors.Registry = .{},
    persistence: persistence.State = .{},
    clock: timing.Clock = .{},
    closed: bool = false,

    pub fn init(instance_id: u64) Machine {
        return .{ .instance_id = instance_id };
    }

    pub fn foundationReady(self: *const Machine) bool {
        return self.instance_id != 0 and self.controllers.port1.connected and
            !self.controllers.port2.connected and self.coprocessors.implemented() and
            !self.closed;
    }

    pub fn close(self: *Machine) void {
        self.closed = true;
        self.controllers.port1.held = 0;
        self.controllers.port1.latched = 0;
    }
};
