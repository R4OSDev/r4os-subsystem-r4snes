const std = @import("std");
const r = @import("r4os");
const t = @import("core").performance_tasks;
const a = r.abi;
const owner = a.ProgramProcessHandle{ .instance_id = 7, .generation = 17 };
const Fake = struct {
    drift: bool = false,
    missing: bool = false,
    generation: u64 = 17,
    begins: usize = 0,
    instant: u64 = 1,
    pub fn now(self: *Fake) ?u64 { defer self.instant += 1; return self.instant; }
    pub fn valid(_: *Fake, _: a.ProgramProcessHandle) bool { return true; }
    pub fn begin(self: *Fake, cursor: *a.ProgramInventoryCursor, summary: *a.ProgramInventorySummary) bool {
        self.begins += 1; cursor.snapshot_generation = 3; summary.task_epoch = 4; summary.task_total = 2; return true;
    }
    pub fn page(self: *Fake, _: *a.ProgramInventoryCursor, items: []a.ProgramTaskSnapshot, info: *a.ProgramInventoryPageInfo) bool {
        items[0] = .{ .task_id = 10, .generation = 100, .owner_instance_id = 7, .instance_generation = self.generation };
        items[1] = .{ .task_id = 20, .generation = 200, .owner_instance_id = 8, .instance_generation = 18 };
        info.snapshot_generation = 3; info.returned = 2; info.status = a.program_inventory_status_complete; return true;
    }
    pub fn performance(self: *Fake, index: u32) ?a.ProgramTaskPerformanceInfo {
        if (self.missing) return null;
        // Performance order deliberately differs from the generation inventory.
        return .{ .id = if (index == 0) 20 else 10, .run_ticks = 30, .switches_in = 40, .blocked_ticks = 50, .max_ready_latency_ticks = 60 };
    }
    pub fn finish(self: *Fake, summary: *a.ProgramInventorySummary) bool { summary.task_epoch = if (self.drift) 5 else 4; summary.task_total = 2; return true; }
};
test "batch task observations reject epoch identity and missing data without zero samples" {
    var live = Fake{};
    const good = t.capture(&live, owner);
    try std.testing.expect(good.view().available and good.count == 1);
    try std.testing.expectEqual(@as(u32, 10), good.entries[0].task_id);
    try std.testing.expectEqual(@as(u64, 100), good.entries[0].task_generation);
    try std.testing.expectEqual(@as(?u64, 1), good.started_ns);
    try std.testing.expectEqual(@as(?u64, 2), good.completed_ns);
    var drift = Fake{ .drift = true };
    const changed = t.capture(&drift, owner);
    try std.testing.expectEqual(t.Reason.epoch_changed, changed.reason);
    try std.testing.expect(changed.view().tasks == null and drift.begins == 3);
    var recycled = Fake{ .generation = 18 };
    try std.testing.expectEqual(t.Reason.task_identity, t.capture(&recycled, owner).reason);
    var absent = Fake{ .missing = true };
    try std.testing.expect(t.capture(&absent, owner).view().tasks == null);
}
test "batch task deltas bind exact generations and keep wait gauges as snapshots" {
    var source = Fake{};
    const before = t.capture(&source, owner);
    var after = before;
    after.entries[0].run_ticks += 7;
    after.entries[0].switches_in += 9;
    after.entries[0].blocked_ticks = 1; // Not cumulative: do not subtract it.
    const delta = t.difference(&before, &after);
    try std.testing.expectEqual(@as(u64, 7), delta.values().?[0].assigned_ticks);
    try std.testing.expectEqual(@as(u64, 9), delta.values().?[0].switches_in);
    after.entries[0].task_generation += 1;
    try std.testing.expectEqual(t.Reason.task_set_changed, t.difference(&before, &after).reason);
    after = before; after.entries[0].run_ticks -= 1;
    try std.testing.expectEqual(t.Reason.counter_regression, t.difference(&before, &after).reason);
    const Counts = struct { frames: u64, backpressure: u64 };
    try std.testing.expect(t.counters(Counts, .{ .frames = 3, .backpressure = 2 }, .{ .frames = 4, .backpressure = 1 }) == null);
}
