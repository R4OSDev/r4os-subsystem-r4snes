//! Explicit detail-profile observations, outside the measured wall interval.
//! Identity/epoch failures remain unavailable. Scheduler ticks are not CPU time.
const std = @import("std");
const r = @import("r4os");
const a = r.abi;
pub const capacity = 8;
pub const Reason = enum { none, source_missing, process_identity, inventory, capacity, task_identity, epoch_changed, counter_regression, task_set_changed };
pub const Task = struct {
    task_id: u32,
    task_generation: u64,
    process_generation: u64,
    state: u32,
    flags: u32,
    run_ticks: u64,
    switches_in: u64,
    blocked_since_tick: u64,
    blocked_ticks: u64,
    ready_since_tick: u64,
    last_ready_latency_ticks: u64,
    max_ready_latency_ticks: u64,
    last_wait_ticks: u64,
    max_wait_ticks: u64,
    max_run_without_switch_ticks: u64,
    max_preemption_deferred_ticks: u64,
};
pub const View = struct {
    available: bool,
    unavailable_reason: ?Reason,
    started_ns: ?u64,
    completed_ns: ?u64,
    process: a.ProgramProcessHandle,
    task_epoch: ?u64,
    tasks: ?[]const Task,
};
pub const Snapshot = struct {
    reason: Reason = .inventory,
    started_ns: ?u64 = null,
    completed_ns: ?u64 = null,
    process: a.ProgramProcessHandle = .{},
    task_epoch: ?u64 = null,
    count: usize = 0,
    entries: [capacity]Task = undefined,

    pub fn view(self: *const Snapshot) View {
        const ok = self.reason == .none;
        return .{ .available = ok, .unavailable_reason = if (ok) null else self.reason,
            .started_ns = self.started_ns, .completed_ns = self.completed_ns,
            .process = self.process, .task_epoch = if (ok) self.task_epoch else null,
            .tasks = if (ok) self.entries[0..self.count] else null };
    }
};
fn sameProcess(left: a.ProgramProcessHandle, right: a.ProgramProcessHandle) bool {
    return left.instance_id != 0 and left.generation != 0 and left.reserved == 0 and
        left.instance_id == right.instance_id and left.generation == right.generation and right.reserved == 0;
}
fn row(identity: a.ProgramTaskSnapshot, performance: a.ProgramTaskPerformanceInfo) Task {
    return .{ .task_id = identity.task_id, .task_generation = identity.generation,
        .process_generation = identity.instance_generation, .state = performance.state, .flags = identity.flags,
        .run_ticks = performance.run_ticks, .switches_in = performance.switches_in,
        .blocked_since_tick = performance.blocked_since_tick, .blocked_ticks = performance.blocked_ticks,
        .ready_since_tick = performance.ready_since_tick, .last_ready_latency_ticks = performance.last_ready_latency_ticks,
        .max_ready_latency_ticks = performance.max_ready_latency_ticks, .last_wait_ticks = performance.last_wait_ticks,
        .max_wait_ticks = performance.max_wait_ticks, .max_run_without_switch_ticks = performance.max_run_without_switch_ticks,
        .max_preemption_deferred_ticks = performance.max_preemption_deferred_ticks };
}
pub const Live = struct {
    sys: r.r4sys.Context,
    dev: ?r.r4dev.Context,
    pub fn now(self: *Live) ?u64 { return self.sys.monotonicNanoseconds(); }
    pub fn valid(self: *Live, owner: a.ProgramProcessHandle) bool {
        var info: a.ProgramInstanceInfo = .{};
        return self.sys.programHandleStatus(&owner, &info) == a.program_handle_ok and info.id == owner.instance_id and info.state != @intFromEnum(a.ProgramInstanceState.done);
    }
    pub fn begin(self: *Live, cursor: *a.ProgramInventoryCursor, summary: *a.ProgramInventorySummary) bool {
        return self.dev != null and self.sys.programInventoryBegin(cursor, summary) == a.program_handle_ok;
    }
    pub fn page(self: *Live, cursor: *a.ProgramInventoryCursor, items: []a.ProgramTaskSnapshot, page_info: *a.ProgramInventoryPageInfo) bool {
        return self.sys.programInventoryTasks(cursor, items, page_info) == a.program_handle_ok;
    }
    pub fn performance(self: *Live, index: u32) ?a.ProgramTaskPerformanceInfo { return self.dev.?.performanceTask(index); }
    pub fn finish(self: *Live, summary: *a.ProgramInventorySummary) bool {
        return self.dev.?.executionInventorySummary(summary) == a.program_handle_ok;
    }
};
pub fn capture(source: anytype, owner: a.ProgramProcessHandle) Snapshot {
    const started = source.now();
    var result = captureTasks(source, owner);
    result.started_ns = started;
    result.completed_ns = source.now();
    if (started == null or result.completed_ns == null or result.completed_ns.? < started.?) result.reason = .source_missing;
    return result;
}
fn captureTasks(source: anytype, owner: a.ProgramProcessHandle) Snapshot {
    var result = Snapshot{ .process = owner };
    if (!sameProcess(owner, owner) or !source.valid(owner)) { result.reason = .process_identity; return result; }
    retry: for (0..3) |_| {
        result.count = 0;
        var cursor: a.ProgramInventoryCursor = .{};
        var before: a.ProgramInventorySummary = .{};
        if (!source.begin(&cursor, &before)) { result.reason = .source_missing; continue; }
        if (before.task_total == 0 or before.task_total > 2048) { result.reason = .capacity; return result; }
        var identities: [capacity]a.ProgramTaskSnapshot = undefined;
        var items: [a.program_inventory_page_max]a.ProgramTaskSnapshot = undefined;
        var visited: usize = 0;
        while (true) {
            var page_info: a.ProgramInventoryPageInfo = .{};
            if (!source.page(&cursor, &items, &page_info) or page_info.snapshot_generation != cursor.snapshot_generation or
                page_info.status == a.program_inventory_status_restart or page_info.returned > items.len) { result.reason = .inventory; continue :retry; }
            visited += page_info.returned;
            if (visited > before.task_total) { result.reason = .inventory; continue :retry; }
            for (items[0..page_info.returned]) |identity| {
                if (identity.owner_instance_id != owner.instance_id) continue;
                if (identity.instance_generation != owner.generation or identity.task_id == 0 or identity.generation == 0) { result.reason = .task_identity; continue :retry; }
                if (result.count == capacity) { result.reason = .capacity; return result; }
                for (identities[0..result.count]) |previous| if (previous.task_id == identity.task_id) { result.reason = .task_identity; continue :retry; };
                identities[result.count] = identity;
                result.count += 1;
            }
            if (page_info.status == a.program_inventory_status_complete) break;
            if (page_info.status != a.program_inventory_status_more or page_info.returned == 0) { result.reason = .inventory; continue :retry; }
        }
        if (visited != before.task_total or result.count == 0) { result.reason = .inventory; continue; }
        var found = [_]bool{false} ** capacity;
        for (0..before.task_total) |index| {
            const performance = source.performance(@intCast(index)) orelse { result.reason = .source_missing; continue :retry; };
            for (identities[0..result.count], 0..) |identity, i| {
                if (performance.id != identity.task_id) continue;
                if (found[i]) { result.reason = .task_identity; continue :retry; }
                result.entries[i] = row(identity, performance);
                found[i] = true;
            }
        }
        for (found[0..result.count]) |present| if (!present) { result.reason = .task_identity; continue :retry; };
        var after: a.ProgramInventorySummary = .{};
        if (!source.finish(&after) or after.task_epoch != before.task_epoch or after.task_total != before.task_total) { result.reason = .epoch_changed; continue; }
        if (!source.valid(owner)) { result.reason = .process_identity; return result; }
        result.task_epoch = before.task_epoch;
        result.reason = .none;
        return result;
    }
    return result;
}
pub const Delta = struct { task_id: u32, task_generation: u64, assigned_ticks: u64, switches_in: u64 };
pub const Report = struct {
    contract: []const u8 = "r4snes-batch-tasks-v1",
    scope: []const u8 = "Stable identities; non-atomic scheduling-state observations outside the wall interval. Deltas bracket boundary work. Assigned ticks are not CPU time; blocked_ticks is a current gauge; last/max latencies are lifetime observations.",
    start_guest_clock_paused: bool = true,
    before: View,
    after: View,
    delta_unavailable_reason: ?Reason,
    deltas: ?[]const Delta,
};
pub const Difference = struct {
    reason: Reason = .inventory,
    count: usize = 0,
    entries: [capacity]Delta = undefined,
    pub fn values(self: *const Difference) ?[]const Delta { return if (self.reason == .none) self.entries[0..self.count] else null; }
};
pub fn difference(before: *const Snapshot, after: *const Snapshot) Difference {
    var result = Difference{};
    if (before.reason != .none or after.reason != .none) return result;
    if (!sameProcess(before.process, after.process)) { result.reason = .process_identity; return result; }
    if (before.count != after.count) { result.reason = .task_set_changed; return result; }
    for (before.entries[0..before.count]) |start| {
        const end = for (after.entries[0..after.count]) |value| {
            if (value.task_id == start.task_id and value.task_generation == start.task_generation and value.process_generation == start.process_generation) break value;
        } else { result.reason = .task_set_changed; return result; };
        if (end.run_ticks < start.run_ticks or end.switches_in < start.switches_in) { result.reason = .counter_regression; return result; }
        result.entries[result.count] = .{ .task_id = start.task_id, .task_generation = start.task_generation,
            .assigned_ticks = end.run_ticks - start.run_ticks, .switches_in = end.switches_in - start.switches_in };
        result.count += 1;
    }
    result.reason = .none;
    return result;
}
/// Existing host counters are monotonic during one batch. A regression is
/// unavailable, never silently converted to a measured zero.
pub fn counters(comptime T: type, before: T, after: T) ?T {
    var result: T = undefined;
    inline for (std.meta.fields(T)) |field| {
        if (@field(after, field.name) < @field(before, field.name)) return null;
        @field(result, field.name) = @field(after, field.name) - @field(before, field.name);
    }
    return result;
}
