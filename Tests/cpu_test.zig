const std = @import("std");
const core = @import("core");

const Access = struct {
    value: u8,
    master_cycles: u8 = 6,
};

const TestPort = struct {
    memory: []u8,

    pub fn read(self: *TestPort, address: u32) Access {
        return .{ .value = self.memory[address % self.memory.len] };
    }

    pub fn write(self: *TestPort, address: u32, value: u8) Access {
        self.memory[address % self.memory.len] = value;
        return .{ .value = value };
    }

    pub fn idle(_: *TestPort, _: u32) u8 {
        return 6;
    }
};

test "65C816 production core resets and executes width-sensitive arithmetic" {
    var memory = [_]u8{0} ** 65536;
    memory[0xfffc] = 0x00;
    memory[0xfffd] = 0x80;
    memory[0x8000] = 0x18; // CLC
    memory[0x8001] = 0xfb; // XCE -> native
    memory[0x8002] = 0xc2; // REP #$30
    memory[0x8003] = 0x30;
    memory[0x8004] = 0xa9; // LDA #$1234
    memory[0x8005] = 0x34;
    memory[0x8006] = 0x12;
    memory[0x8007] = 0x69; // ADC #$0001
    memory[0x8008] = 0x01;
    memory[0x8009] = 0x00;

    var port = TestPort{ .memory = &memory };
    var cpu = core.cpu.Cpu{};
    try std.testing.expectEqual(core.cpu.StepState.reset, (try cpu.step(&port)).state);
    for (0..5) |_| _ = try cpu.step(&port);
    try std.testing.expectEqual(@as(u16, 0x1236), cpu.a);
    try std.testing.expect(!cpu.p.accumulator_width);
    try std.testing.expect(!cpu.emulation);
}

test "opcode descriptor covers every legal W65C816 byte" {
    try std.testing.expectEqual(@as(usize, 256), core.cpu.opcode_table.len);
    var seen = [_]bool{false} ** 256;
    for (core.cpu.opcode_table, 0..) |_, index| seen[index] = true;
    for (seen) |present| try std.testing.expect(present);
}

test "all legal opcodes instantiate emulation and four native width decoders" {
    const allocator = std.testing.allocator;
    const memory = try allocator.alloc(u8, 1 << 24);
    defer allocator.free(memory);
    @memset(memory, 0);
    var port = TestPort{ .memory = memory };

    const Variant = struct { emulation: bool, m: bool, x: bool };
    const variants = [_]Variant{
        .{ .emulation = true, .m = false, .x = false }, // deliberately inconsistent; step normalizes it
        .{ .emulation = false, .m = false, .x = false },
        .{ .emulation = false, .m = false, .x = true },
        .{ .emulation = false, .m = true, .x = false },
        .{ .emulation = false, .m = true, .x = true },
    };

    for (core.cpu.opcode_table, 0..) |_, byte| {
        for (variants) |variant| {
            @memset(memory[0x7ff0..0x8020], 0);
            @memset(memory[0x0100..0x0300], 0);
            memory[0x8000] = @intCast(byte);
            var cpu = core.cpu.Cpu{
                .reset_pending = false,
                .emulation = variant.emulation,
                .pc = 0x8000,
                .p = .{
                    .index_width = variant.x,
                    .accumulator_width = variant.m,
                },
            };
            const outcome = try cpu.step(&port);
            try std.testing.expect(outcome.has_opcode);
            try std.testing.expectEqual(@as(u8, @intCast(byte)), outcome.opcode);
            try std.testing.expect(outcome.micro_operations != 0);
            if (variant.emulation) {
                try std.testing.expect(cpu.p.index_width);
                try std.testing.expect(cpu.p.accumulator_width);
            }
        }
    }
}

test "absolute word access crosses the data bank and RMW writes high then low" {
    const allocator = std.testing.allocator;
    const memory = try allocator.alloc(u8, 1 << 24);
    defer allocator.free(memory);
    @memset(memory, 0);
    memory[0x8000] = 0xee; // INC $FFFF
    memory[0x8001] = 0xff;
    memory[0x8002] = 0xff;
    memory[0x7e_ffff] = 0xff;
    memory[0x7f_0000] = 0x00;
    var port = TestPort{ .memory = memory };
    var cpu = core.cpu.Cpu{
        .reset_pending = false,
        .emulation = false,
        .pc = 0x8000,
        .db = 0x7e,
        .p = .{ .index_width = false, .accumulator_width = false },
    };

    _ = try cpu.step(&port);
    try std.testing.expectEqual(@as(u8, 0x00), memory[0x7e_ffff]);
    try std.testing.expectEqual(@as(u8, 0x01), memory[0x7f_0000]);
    const trace = cpu.lastTrace();
    try std.testing.expectEqual(core.cpu.MicroOperationKind.write, trace[trace.len - 2].kind);
    try std.testing.expectEqual(@as(u32, 0x7f_0000), trace[trace.len - 2].address);
    try std.testing.expectEqual(@as(u32, 0x7e_ffff), trace[trace.len - 1].address);
}

test "emulation indexed-indirect quirk and direct-page penalties are explicit cycles" {
    var memory = [_]u8{0} ** 65536;
    memory[0x8000] = 0xa1; // LDA ($F7,X)
    memory[0x8001] = 0xf7;
    memory[0x02ff] = 0x34;
    memory[0x0200] = 0x12;
    memory[0x1234] = 0xab;
    var port = TestPort{ .memory = &memory };
    var cpu = core.cpu.Cpu{
        .reset_pending = false,
        .emulation = true,
        .pc = 0x8000,
        .x = 0x00ee,
        .d = 0x011a,
    };

    _ = try cpu.step(&port);
    try std.testing.expectEqual(@as(u8, 0xab), @as(u8, @truncate(cpu.a)));
    const trace = cpu.lastTrace();
    try std.testing.expectEqual(@as(usize, 7), trace.len);
    try std.testing.expectEqual(core.cpu.MicroOperationKind.idle, trace[2].kind); // D.low penalty
    try std.testing.expectEqual(core.cpu.MicroOperationKind.idle, trace[3].kind); // indexed direct page
    try std.testing.expectEqual(@as(u32, 0x02ff), trace[4].address);
    try std.testing.expectEqual(@as(u32, 0x0200), trace[5].address);
    try std.testing.expectEqual(@as(u32, 0x1234), trace[6].address);
}

test "decimal ADC and SBC are deterministic in 8 and 16 bit modes" {
    var memory = [_]u8{0} ** 65536;
    memory[0x8000] = 0x69; // ADC #$0001
    memory[0x8001] = 0x01;
    memory[0x8002] = 0x00;
    memory[0x8003] = 0xe9; // SBC #$0001
    memory[0x8004] = 0x01;
    memory[0x8005] = 0x00;
    var port = TestPort{ .memory = &memory };
    var cpu = core.cpu.Cpu{
        .reset_pending = false,
        .emulation = false,
        .pc = 0x8000,
        .a = 0x9999,
        .p = .{ .decimal = true, .index_width = false, .accumulator_width = false },
    };
    _ = try cpu.step(&port);
    try std.testing.expectEqual(@as(u16, 0x0000), cpu.a);
    try std.testing.expect(cpu.p.carry);
    _ = try cpu.step(&port);
    try std.testing.expectEqual(@as(u16, 0x9999), cpu.a);
    try std.testing.expect(!cpu.p.carry);

    memory[0x8010] = 0x69;
    memory[0x8011] = 0x01;
    cpu.pc = 0x8010;
    cpu.a = 0x1299;
    cpu.p.accumulator_width = true;
    cpu.p.carry = false;
    _ = try cpu.step(&port);
    try std.testing.expectEqual(@as(u16, 0x1200), cpu.a);
    try std.testing.expect(cpu.p.carry);
}

test "block move repeats one byte per bounded instruction step" {
    const allocator = std.testing.allocator;
    const memory = try allocator.alloc(u8, 1 << 24);
    defer allocator.free(memory);
    @memset(memory, 0);
    memory[0x8000] = 0x54; // MVN destination, source
    memory[0x8001] = 0x7e;
    memory[0x8002] = 0x7f;
    memory[0x7f_1000] = 0xaa;
    memory[0x7f_1001] = 0xbb;
    var port = TestPort{ .memory = memory };
    var cpu = core.cpu.Cpu{
        .reset_pending = false,
        .emulation = false,
        .pc = 0x8000,
        .a = 1,
        .x = 0x1000,
        .y = 0x2000,
        .p = .{ .index_width = false, .accumulator_width = false },
    };

    _ = try cpu.step(&port);
    try std.testing.expectEqual(@as(u8, 0xaa), memory[0x7e_2000]);
    try std.testing.expectEqual(@as(u16, 0x8000), cpu.pc);
    try std.testing.expectEqual(@as(u16, 0), cpu.a);
    _ = try cpu.step(&port);
    try std.testing.expectEqual(@as(u8, 0xbb), memory[0x7e_2001]);
    try std.testing.expectEqual(@as(u16, 0x8003), cpu.pc);
    try std.testing.expectEqual(@as(u16, 0xffff), cpu.a);
}

test "native NMI stack vector and delayed IRQ transition are bus-visible" {
    var memory = [_]u8{0} ** 65536;
    memory[0xffea] = 0x00;
    memory[0xffeb] = 0x90;
    var port = TestPort{ .memory = &memory };
    var cpu = core.cpu.Cpu{
        .reset_pending = false,
        .emulation = false,
        .pb = 0x12,
        .pc = 0x3456,
        .s = 0x01ff,
        .p = .{ .index_width = false, .accumulator_width = false },
    };
    cpu.requestNmi();
    const nmi = try cpu.step(&port);
    try std.testing.expectEqual(core.cpu.StepState.interrupt, nmi.state);
    try std.testing.expectEqual(@as(u8, 0), cpu.pb);
    try std.testing.expectEqual(@as(u16, 0x9000), cpu.pc);
    try std.testing.expectEqual(@as(u16, 0x01fb), cpu.s);
    try std.testing.expectEqual(@as(u8, 0x12), memory[0x01ff]);
    try std.testing.expectEqual(@as(u8, 0x34), memory[0x01fe]);
    try std.testing.expectEqual(@as(u8, 0x56), memory[0x01fd]);
    try std.testing.expectEqual(core.cpu.MicroOperationKind.vector_read, cpu.lastTrace()[cpu.lastTrace().len - 1].kind);

    memory[0x8000] = 0x58; // CLI
    memory[0xfffe] = 0x34;
    memory[0xffff] = 0x12;
    cpu = core.cpu.Cpu{ .reset_pending = false, .pc = 0x8000 };
    cpu.setIrqLine(true);
    const cli = try cpu.step(&port);
    try std.testing.expect(cli.has_opcode);
    try std.testing.expectEqual(@as(u8, 0x58), cli.opcode);
    try std.testing.expect(!cpu.p.irq_disable);
    try std.testing.expectEqual(core.cpu.MicroOperationKind.read, cpu.lastTrace()[cpu.lastTrace().len - 1].kind);
    try std.testing.expectEqual(core.cpu.StepState.interrupt, (try cpu.step(&port)).state);
    try std.testing.expectEqual(@as(u16, 0x1234), cpu.pc);
}

test "WAI wakes on masked IRQ while STP only leaves through reset" {
    var memory = [_]u8{0} ** 65536;
    memory[0x8000] = 0xcb; // WAI
    memory[0x8001] = 0xea; // NOP
    memory[0x8010] = 0xdb; // STP
    memory[0xfffc] = 0x00;
    memory[0xfffd] = 0x90;
    var port = TestPort{ .memory = &memory };
    var cpu = core.cpu.Cpu{ .reset_pending = false, .pc = 0x8000 };

    _ = try cpu.step(&port);
    try std.testing.expect(cpu.waiting);
    try std.testing.expectEqual(core.cpu.StepState.waiting, (try cpu.step(&port)).state);
    cpu.setIrqLine(true);
    try std.testing.expectEqual(core.cpu.StepState.awakened, (try cpu.step(&port)).state);
    try std.testing.expect(!cpu.waiting);
    cpu.setIrqLine(false);
    try std.testing.expectEqual(@as(u8, 0xea), (try cpu.step(&port)).opcode);

    cpu.pc = 0x8010;
    _ = try cpu.step(&port);
    cpu.requestNmi();
    try std.testing.expectEqual(core.cpu.StepState.stopped, (try cpu.step(&port)).state);
    cpu.requestReset();
    try std.testing.expectEqual(core.cpu.StepState.reset, (try cpu.step(&port)).state);
    try std.testing.expectEqual(@as(u16, 0x9000), cpu.pc);
    try std.testing.expect(!cpu.stopped);
}

test "ABORT restarts the supplied instruction address and uses its native vector" {
    var memory = [_]u8{0} ** 65536;
    memory[0xffe8] = 0xcd;
    memory[0xffe9] = 0xab;
    var port = TestPort{ .memory = &memory };
    var cpu = core.cpu.Cpu{
        .reset_pending = false,
        .emulation = false,
        .pb = 0x20,
        .pc = 0x4000,
        .s = 0x0200,
        .p = .{ .index_width = false, .accumulator_width = false },
    };
    cpu.requestAbort(0x12_3456);
    _ = try cpu.step(&port);
    try std.testing.expectEqual(@as(u16, 0xabcd), cpu.pc);
    try std.testing.expectEqual(@as(u8, 0x12), memory[0x0200]);
    try std.testing.expectEqual(@as(u8, 0x34), memory[0x01ff]);
    try std.testing.expectEqual(@as(u8, 0x56), memory[0x01fe]);
}

test "equal CPU instances produce equal traces and first divergence is diagnosable" {
    var first_memory = [_]u8{0} ** 65536;
    var second_memory = [_]u8{0} ** 65536;
    first_memory[0x8000] = 0xad; // LDA $1234
    first_memory[0x8001] = 0x34;
    first_memory[0x8002] = 0x12;
    first_memory[0x1234] = 0x5a;
    second_memory = first_memory;
    var first_port = TestPort{ .memory = &first_memory };
    var second_port = TestPort{ .memory = &second_memory };
    var first = core.cpu.Cpu{ .reset_pending = false, .pc = 0x8000 };
    var second = core.cpu.Cpu{ .reset_pending = false, .pc = 0x8000 };

    _ = try first.step(&first_port);
    _ = try second.step(&second_port);
    try std.testing.expectEqual(@as(?usize, null), firstTraceDifference(first.lastTrace(), second.lastTrace()));
    try std.testing.expectEqual(first.a, second.a);

    second_memory[0x1234] = 0xa5;
    first.pc = 0x8000;
    second.pc = 0x8000;
    _ = try first.step(&first_port);
    _ = try second.step(&second_port);
    try std.testing.expectEqual(@as(?usize, 3), firstTraceDifference(first.lastTrace(), second.lastTrace()));
    try std.testing.expectEqual(@as(u8, 0x5a), @as(u8, @truncate(first.a)));
    try std.testing.expectEqual(@as(u8, 0xa5), @as(u8, @truncate(second.a)));
}

fn firstTraceDifference(left: []const core.cpu.MicroOperation, right: []const core.cpu.MicroOperation) ?usize {
    const common = @min(left.len, right.len);
    for (0..common) |index| {
        const a = left[index];
        const b = right[index];
        if (a.kind != b.kind or a.address != b.address or a.value != b.value or a.master_cycles != b.master_cycles) return index;
    }
    return if (left.len == right.len) null else common;
}
