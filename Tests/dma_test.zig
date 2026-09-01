const std = @import("std");
const core = @import("core");

const FakePort = struct {
    master: u64 = 0,
    a: [65_536]u8 = [_]u8{0} ** 65_536,
    b: [256]u8 = [_]u8{0} ** 256,

    pub fn masterClock(self: *const FakePort) u64 {
        return self.master;
    }

    pub fn advanceDma(self: *FakePort, clocks: u8) u8 {
        self.master +%= clocks;
        return clocks;
    }

    pub fn readDma(self: *FakePort, address: u32, _: core.dma.Revision) core.dma.ReadResult {
        const valid = core.dma.validAAddress(address);
        const value = if (valid) self.a[@as(u16, @truncate(address))] else 0;
        return .{
            .address = address & 0x00ff_ffff,
            .value = value,
            .valid = valid,
            .master_cycles = self.advanceDma(8),
        };
    }

    pub fn transferByte(
        self: *FakePort,
        channel: *const core.dma.Channel,
        byte_index: u3,
        address_a: u32,
        revision: core.dma.Revision,
    ) core.dma.TransferResult {
        const address_b = channel.bBusAddress(byte_index);
        const valid_a = core.dma.validAAddress(address_a);
        const conflict = address_b == 0x2180 and core.dma.isWorkRamAddress(address_a);
        var value: u8 = 0;
        if (!channel.directionBtoA()) {
            if (valid_a) value = self.a[@as(u16, @truncate(address_a))];
            if (!conflict) self.b[@as(u8, @truncate(address_b))] = value;
        } else {
            value = if (conflict)
                (if (revision == .s_cpu_a) 0 else 0xff)
            else
                self.b[@as(u8, @truncate(address_b))];
            if (valid_a) self.a[@as(u16, @truncate(address_a))] = value;
        }
        return .{
            .a_address = address_a & 0x00ff_ffff,
            .b_address = address_b,
            .value = value,
            .valid = valid_a and !conflict,
            .conflict = conflict,
            .master_cycles = self.advanceDma(8),
        };
    }
};

fn runUntilIdle(controller: *core.dma.Controller, port: *FakePort) !void {
    var steps: usize = 0;
    while (controller.busy() and steps < 100_000) : (steps += 1) {
        const result = controller.step(port);
        try std.testing.expect(result.progressed);
    }
    try std.testing.expect(steps < 100_000);
    try std.testing.expect(controller.cpuMayRun());
}

test "DMA register file preserves all eight channels masks mirrors and open bus" {
    var dma = core.dma.Controller{};
    for (0..8) |channel| {
        const base: u16 = 0x4300 + @as(u16, @intCast(channel)) * 0x10;
        for (0..11) |register| {
            const value: u8 = @truncate(channel * 16 + register);
            try std.testing.expect(dma.writeRegister(base + @as(u16, @intCast(register)), value));
            try std.testing.expectEqual(@as(?u8, value), dma.readRegister(base + @as(u16, @intCast(register)), 0xa5));
        }
        try std.testing.expect(dma.writeRegister(base + 0x0f, 0x5a));
        try std.testing.expectEqual(@as(?u8, 0x5a), dma.readRegister(base + 0x0b, 0));
        try std.testing.expectEqual(@as(?u8, 0xa5), dma.readRegister(base + 0x0c, 0xa5));
    }
    try std.testing.expectEqual(@as(?u8, null), dma.readRegister(0x42ff, 0));
    try std.testing.expect(!dma.writeRegister(0x4380, 0));
}

test "all manual transfer modes emit exact B-bus patterns and clock totals" {
    const expected = [8][8]u8{
        .{ 0, 0, 0, 0, 0, 0, 0, 0 },
        .{ 0, 1, 0, 1, 0, 1, 0, 1 },
        .{ 0, 0, 0, 0, 0, 0, 0, 0 },
        .{ 0, 0, 1, 1, 0, 0, 1, 1 },
        .{ 0, 1, 2, 3, 0, 1, 2, 3 },
        .{ 0, 1, 0, 1, 0, 1, 0, 1 },
        .{ 0, 0, 0, 0, 0, 0, 0, 0 },
        .{ 0, 0, 1, 1, 0, 0, 1, 1 },
    };
    for (0..8) |mode| {
        var dma = core.dma.Controller{};
        var port = FakePort{};
        for (0..8) |index| port.a[0x100 + index] = @intCast(0x80 + index);
        dma.channels[0] = .{
            .control = @intCast(mode),
            .b_address = 0x20,
            .a_address = 0x100,
            .a_bank = 0x40,
            .transfer_size = 8,
        };
        dma.requestManual(1, 6);
        try runUntilIdle(&dma, &port);
        try std.testing.expectEqual(@as(u64, 8), dma.manual_bytes);
        try std.testing.expectEqual(@as(u64, 90), port.master);
        try std.testing.expectEqual(@as(u16, 0x108), dma.channels[0].a_address);
        var transfer: usize = 0;
        for (dma.lastTrace()) |entry| {
            if (entry.kind != .transfer) continue;
            try std.testing.expectEqual(@as(u16, 0x2120) + expected[mode][transfer], entry.b_address);
            try std.testing.expectEqual(@as(u8, @intCast(0x80 + transfer)), entry.value);
            transfer += 1;
        }
        try std.testing.expectEqual(@as(usize, 8), transfer);
    }
}

test "manual DMA honors fixed decrement direction zero size and channel priority" {
    var dma = core.dma.Controller{};
    var port = FakePort{};
    port.a[0x100] = 0x11;
    port.a[0x0ff] = 0x22;
    dma.channels[0] = .{ .control = 0x18, .b_address = 0x10, .a_address = 0x100, .a_bank = 0x40, .transfer_size = 2 };
    dma.requestManual(1, 6);
    try runUntilIdle(&dma, &port);
    try std.testing.expectEqual(@as(u16, 0x100), dma.channels[0].a_address);

    dma = .{};
    port = .{};
    dma.channels[0] = .{ .control = 0x10, .b_address = 0x10, .a_address = 0x100, .a_bank = 0x40, .transfer_size = 2 };
    dma.requestManual(1, 6);
    try runUntilIdle(&dma, &port);
    try std.testing.expectEqual(@as(u16, 0x0fe), dma.channels[0].a_address);

    dma = .{};
    port = .{};
    for ([_]usize{ 0, 2, 7 }) |index| {
        dma.channels[index] = .{ .control = 0, .b_address = @intCast(index), .a_address = @intCast(0x100 + index), .a_bank = 0x40, .transfer_size = 1 };
        port.a[0x100 + index] = @intCast(index + 1);
    }
    dma.requestManual(0x85, 6);
    try runUntilIdle(&dma, &port);
    var order: [3]u8 = undefined;
    var count: usize = 0;
    for (dma.lastTrace()) |entry| {
        if (entry.kind == .transfer) {
            order[count] = entry.channel;
            count += 1;
        }
    }
    try std.testing.expectEqualSlices(u8, &.{ 0, 2, 7 }, order[0..count]);

    dma = .{};
    port = .{};
    dma.channels[0] = .{ .control = 0, .b_address = 0, .a_address = 0, .a_bank = 0x40, .transfer_size = 0 };
    dma.requestManual(1, 6);
    for (0..5) |_| _ = dma.step(&port);
    try std.testing.expectEqual(@as(u16, 0xffff), dma.channels[0].transfer_size);
    try std.testing.expect(dma.channels[0].dma_active);
    dma.abortAll();
    try std.testing.expect(dma.cpuMayRun());
}

test "HDMA direct tables implement repeat skip reload completion and restart" {
    var dma = core.dma.Controller{};
    var port = FakePort{};
    dma.channels[0] = .{ .control = 1, .b_address = 0x10, .a_address = 0x100, .a_bank = 0x40 };
    port.a[0x100] = 0x82;
    port.a[0x101] = 0xaa;
    port.a[0x102] = 0xbb;
    port.a[0x103] = 0xcc;
    port.a[0x104] = 0xdd;
    port.a[0x105] = 0;
    dma.setHdmaEnabled(1);
    dma.beginFrame();
    try runUntilIdle(&dma, &port);
    try std.testing.expectEqual(@as(u8, 0x82), dma.channels[0].line_counter);
    try std.testing.expectEqual(@as(u16, 0x101), dma.channels[0].hdma_table_address);

    dma.beginHblank();
    try runUntilIdle(&dma, &port);
    try std.testing.expectEqual(@as(u8, 0xaa), port.b[0x10]);
    try std.testing.expectEqual(@as(u8, 0xbb), port.b[0x11]);
    try std.testing.expectEqual(@as(u8, 0x81), dma.channels[0].line_counter);
    try std.testing.expect(!dma.channels[0].hdma_completed);

    dma.beginHblank();
    try runUntilIdle(&dma, &port);
    try std.testing.expectEqual(@as(u8, 0xcc), port.b[0x10]);
    try std.testing.expectEqual(@as(u8, 0xdd), port.b[0x11]);
    try std.testing.expect(dma.channels[0].hdma_completed);
    try std.testing.expectEqual(@as(u64, 4), dma.hdma_bytes);

    dma.beginFrame();
    try runUntilIdle(&dma, &port);
    try std.testing.expect(!dma.channels[0].hdma_completed);
    try std.testing.expectEqual(@as(u16, 0x101), dma.channels[0].hdma_table_address);
}

test "HDMA indirect tables and skipped lines retain deterministic byte boundaries" {
    var dma = core.dma.Controller{};
    var port = FakePort{};
    dma.channels[0] = .{ .control = 0x40, .b_address = 0x22, .a_address = 0x200, .a_bank = 0x40, .indirect_bank = 0x41 };
    port.a[0x200] = 0x81;
    port.a[0x201] = 0x00;
    port.a[0x202] = 0x30;
    port.a[0x203] = 0;
    port.a[0x204] = 0;
    port.a[0x3000] = 0x5a;
    dma.setHdmaEnabled(1);
    dma.beginFrame();
    try runUntilIdle(&dma, &port);
    try std.testing.expectEqual(@as(u16, 0x3000), dma.channels[0].transfer_size);
    dma.beginHblank();
    try runUntilIdle(&dma, &port);
    try std.testing.expectEqual(@as(u8, 0x5a), port.b[0x22]);
    try std.testing.expect(dma.channels[0].hdma_completed);

    dma = .{};
    port = .{};
    dma.channels[0] = .{ .control = 0, .b_address = 0x30, .a_address = 0x100, .a_bank = 0x40 };
    port.a[0x100] = 0x02;
    port.a[0x101] = 0x11;
    port.a[0x102] = 0;
    dma.setHdmaEnabled(1);
    dma.beginFrame();
    try runUntilIdle(&dma, &port);
    dma.beginHblank();
    try runUntilIdle(&dma, &port);
    try std.testing.expectEqual(@as(u64, 1), dma.hdma_bytes);
    dma.beginHblank();
    try runUntilIdle(&dma, &port);
    try std.testing.expectEqual(@as(u64, 1), dma.hdma_bytes);
    try std.testing.expect(dma.channels[0].hdma_completed);
}

test "DMA conflict classes are bounded and revision claims remain explicit" {
    try std.testing.expect(!core.dma.validAAddress(0x002100));
    try std.testing.expect(!core.dma.validAAddress(0x004016));
    try std.testing.expect(!core.dma.validAAddress(0x00420b));
    try std.testing.expect(!core.dma.validAAddress(0x00437f));
    try std.testing.expect(core.dma.validAAddress(0x7e2100));
    try std.testing.expect(core.dma.isWorkRamAddress(0x7e0000));
    try std.testing.expect(core.dma.isWorkRamAddress(0x000100));
    try std.testing.expect(!core.dma.isWorkRamAddress(0x400100));

    const channel = core.dma.Channel{ .control = 4, .b_address = 0xff };
    try std.testing.expectEqual(@as(u16, 0x21ff), channel.bBusAddress(0));
    try std.testing.expectEqual(@as(u16, 0x2100), channel.bBusAddress(1));
    try std.testing.expectEqual(core.dma.GlitchDisposition.diagnostic_only, core.dma.glitchDisposition(.s_cpu_a, .hdma_2100_then_manual_dma));
    try std.testing.expectEqual(core.dma.GlitchDisposition.absent, core.dma.glitchDisposition(.s_cpu_b, .hdma_2100_then_manual_dma));
    try std.testing.expectEqual(core.dma.GlitchDisposition.exact, core.dma.glitchDisposition(.s_cpu_b, .b_bus_21ff_wrap));
    try std.testing.expectEqual(core.dma.GlitchDisposition.exact, core.dma.glitchDisposition(.s_cpu_a, .dmap_write_during_transfer));
}

test "live DMAP writes take effect at the next byte and HDMA preempts only on byte boundaries" {
    var dma = core.dma.Controller{};
    var port = FakePort{};
    port.a[0x100] = 0x10;
    port.a[0x101] = 0x11;
    port.a[0x102] = 0x12;
    dma.channels[0] = .{ .control = 0, .b_address = 0x10, .a_address = 0x100, .a_bank = 0x40, .transfer_size = 3 };
    dma.requestManual(1, 6);
    while (dma.manual_bytes == 0) _ = dma.step(&port);
    try std.testing.expect(dma.writeRegister(0x4300, 0x18));
    try std.testing.expect(dma.writeRegister(0x4301, 0x20));
    try runUntilIdle(&dma, &port);
    try std.testing.expectEqual(@as(u16, 0x101), dma.channels[0].a_address);
    try std.testing.expectEqual(@as(u8, 0x11), port.b[0x20]);

    dma = .{};
    port = .{};
    dma.channels[1] = .{ .control = 0, .b_address = 0x30, .a_address = 0x300, .a_bank = 0x40 };
    port.a[0x300] = 0x81;
    port.a[0x301] = 0xa5;
    port.a[0x302] = 0;
    dma.setHdmaEnabled(0x02);
    dma.beginFrame();
    try runUntilIdle(&dma, &port);
    dma.clearTrace();
    dma.channels[0] = .{ .control = 0, .b_address = 0x10, .a_address = 0x100, .a_bank = 0x40, .transfer_size = 3 };
    dma.requestManual(1, 6);
    while (dma.manual_bytes == 0) _ = dma.step(&port);
    dma.beginHblank();
    try runUntilIdle(&dma, &port);
    try std.testing.expectEqual(@as(u64, 3), dma.manual_bytes);
    try std.testing.expectEqual(@as(u64, 1), dma.hdma_bytes);
    try std.testing.expectEqual(@as(u8, 0xa5), port.b[0x30]);
    var first_manual: ?usize = null;
    var hdma: ?usize = null;
    var last_manual: ?usize = null;
    for (dma.lastTrace(), 0..) |entry, index| {
        if (entry.kind != .transfer) continue;
        if (entry.phase == .manual_byte) {
            if (first_manual == null) first_manual = index else last_manual = index;
        }
        if (entry.phase == .hdma_run_transfer) hdma = index;
    }
    try std.testing.expect(first_manual.? < hdma.? and hdma.? < last_manual.?);
}

test "DMA state and traces remain identical across arbitrary service partitions" {
    var one = core.dma.Controller{};
    var many = core.dma.Controller{};
    var first_port = FakePort{};
    var second_port = FakePort{};
    for (0..64) |index| {
        first_port.a[0x400 + index] = @truncate(index * 3);
        second_port.a[0x400 + index] = @truncate(index * 3);
    }
    for ([_]usize{ 0, 3, 7 }) |channel| {
        const state = core.dma.Channel{
            .control = @intCast(channel & 7),
            .b_address = @intCast(0x40 + channel * 4),
            .a_address = @intCast(0x400 + channel * 8),
            .a_bank = 0x40,
            .transfer_size = 8,
        };
        one.channels[channel] = state;
        many.channels[channel] = state;
    }
    one.requestManual(0x89, 8);
    many.requestManual(0x89, 8);
    try runUntilIdle(&one, &first_port);
    const groups = [_]usize{ 1, 5, 2, 11 };
    var group: usize = 0;
    while (many.busy()) : (group += 1) {
        for (0..groups[group % groups.len]) |_| {
            if (!many.busy()) break;
            _ = many.step(&second_port);
        }
    }
    try std.testing.expectEqual(first_port.master, second_port.master);
    try std.testing.expectEqual(one.manual_bytes, many.manual_bytes);
    try std.testing.expectEqual(one.dma_clock_counter, many.dma_clock_counter);
    try std.testing.expectEqual(one.trace_len, many.trace_len);
    for (one.lastTrace(), many.lastTrace()) |a, b| {
        try std.testing.expectEqual(a.kind, b.kind);
        try std.testing.expectEqual(a.phase, b.phase);
        try std.testing.expectEqual(a.channel, b.channel);
        try std.testing.expectEqual(a.a_address, b.a_address);
        try std.testing.expectEqual(a.b_address, b.b_address);
        try std.testing.expectEqual(a.value, b.value);
        try std.testing.expectEqual(a.master_cycles, b.master_cycles);
    }
}
