const std = @import("std");
const core = @import("core");

pub fn power(cart: *const core.cartridge.Cartridge) !*core.machine.Machine {
    const result = try std.testing.allocator.create(core.machine.Machine);
    errdefer std.testing.allocator.destroy(result);
    try core.machine.Machine.powerInPlace(result, 1, cart, null);
    result.cpu = .{ .reset_pending = false, .waiting = true };
    result.clock.h_counter = 1;
    result.host_budget = .{ .paused = false, .last_guest_nanoseconds = 0 };
    return result;
}

pub fn close(machine: *core.machine.Machine) void {
    machine.close();
    std.testing.allocator.destroy(machine);
}

pub fn advance(machine: *core.machine.Machine, cart: *core.cartridge.Cartridge, clocks: u32) !void {
    machine.host_budget.pending_master_cycles += clocks;
    const result = machine.runHostSlice(cart, clocks, 0);
    try std.testing.expectEqual(@as(?core.machine.RunFault, null), result.fault);
    try std.testing.expectEqual(@as(u64, clocks), result.executed_master_cycles);
}
