const std = @import("std");
const core = @import("core");

test "SPC700 NOP exposes its opcode and dummy read" {
    var smp = core.smp.Smp{};
    smp.bus_mode = .vector_ram;
    smp.pc = 0x4000;
    smp.aram[0x4000] = 0x00;
    smp.aram[0x4001] = 0x5a;
    smp.beginTrace();
    try smp.step();
    const trace = smp.endTrace();
    try std.testing.expectEqual(@as(u16, 0x4001), smp.pc);
    try std.testing.expectEqual(@as(usize, 2), trace.len);
    try std.testing.expectEqual(core.smp.BusCycleKind.read, trace[0].kind);
    try std.testing.expectEqual(@as(?u16, 0x4000), trace[0].address);
    try std.testing.expectEqual(@as(?u8, 0x00), trace[0].value);
    try std.testing.expectEqual(@as(?u16, 0x4001), trace[1].address);
}

test "CPU and SMP ports are separate ordered latches" {
    var smp = core.smp.Smp{};
    smp.cpuWritePort(2, 0x34);
    smp.cpuWritePort(0, 0x12);
    try std.testing.expectEqual(@as(u8, 0x34), smp.io.cpu_to_smp[2]);
    try std.testing.expectEqual(@as(u8, 0x12), smp.io.cpu_to_smp[0]);
    try std.testing.expectEqual(@as(u8, 0), smp.cpuReadPort(0));
    try std.testing.expect(smp.io.cpu_port_epoch[2] < smp.io.cpu_port_epoch[0]);

    smp.bus_mode = .hardware;
    smp.io.ipl_enabled = false;
    smp.pc = 0x0200;
    smp.aram[0x0200] = 0x8f; // MOV dp,#imm
    smp.aram[0x0201] = 0xa5;
    smp.aram[0x0202] = 0xf4;
    try smp.step();
    try std.testing.expectEqual(@as(u8, 0xa5), smp.cpuReadPort(0));
    try std.testing.expectEqual(@as(u8, 0x12), smp.io.cpu_to_smp[0]);
    try std.testing.expect(smp.io.smp_port_epoch[0] > smp.io.cpu_port_epoch[0]);
}

test "three hardware timers use falling divider edges and clear on read" {
    var smp = core.smp.Smp{};
    smp.bus_mode = .vector_ram;
    smp.timers[2].enabled = true;
    smp.timers[2].target = 1;
    smp.io.timers_enabled = true;
    smp.io.timers_disabled = false;
    smp.pc = 0x1000;
    @memset(smp.aram[0x1000..0x1020], 0x00);
    var index: usize = 0;
    while (index < 8) : (index += 1) try smp.step();
    try std.testing.expectEqual(@as(u4, 1), smp.timers[2].output);

    smp.bus_mode = .hardware;
    smp.io.ipl_enabled = false;
    smp.pc = 0x1100;
    smp.aram[0x1100] = 0xe4; // MOV A,dp
    smp.aram[0x1101] = 0xff;
    try smp.step();
    try std.testing.expectEqual(@as(u8, 1), smp.a);
    try std.testing.expectEqual(@as(u4, 0), smp.timers[2].output);
}

test "TEST global timer disable synchronizes an active divider edge" {
    var smp = core.smp.Smp{};
    smp.bus_mode = .hardware;
    smp.io.ipl_enabled = false;
    smp.timers[2].enabled = true;
    smp.timers[2].target = 1;
    smp.timers[2].stage1 = true;
    smp.timers[2].line = true;
    smp.pc = 0x1200;
    smp.aram[0x1200] = 0x8f; // MOV dp,#imm
    smp.aram[0x1201] = 0x01; // TEST.timers_disabled
    smp.aram[0x1202] = 0xf0;
    try smp.step();
    try std.testing.expect(smp.io.timers_disabled);
    try std.testing.expectEqual(@as(u4, 1), smp.timers[2].output);
}

test "semantic IPL uploads without embedding proprietary bytes" {
    var smp = core.smp.Smp{};
    smp.powerSemanticIpl();
    try std.testing.expectEqual(@as(u8, 0xaa), smp.cpuReadPort(0));
    try std.testing.expectEqual(@as(u8, 0xbb), smp.cpuReadPort(1));

    smp.cpuWritePort(2, 0x00);
    smp.cpuWritePort(3, 0x02);
    smp.cpuWritePort(1, 0xcc);
    smp.cpuWritePort(0, 0xcc);
    try std.testing.expectEqual(core.smp.SemanticIplState.receiving, smp.semantic_ipl_state);
    try std.testing.expectEqual(@as(u8, 0xcc), smp.cpuReadPort(0));

    smp.cpuWritePort(1, 0x00); // NOP
    smp.cpuWritePort(0, 0x00);
    smp.cpuWritePort(1, 0xef); // SLEEP
    smp.cpuWritePort(0, 0x01);
    try std.testing.expectEqual(@as(u8, 0x00), smp.aram[0x0200]);
    try std.testing.expectEqual(@as(u8, 0xef), smp.aram[0x0201]);

    smp.cpuWritePort(2, 0x00);
    smp.cpuWritePort(3, 0x02);
    smp.cpuWritePort(1, 0x00);
    smp.cpuWritePort(0, 0x03);
    try std.testing.expectEqual(core.smp.SemanticIplState.launch_ack, smp.semantic_ipl_state);
    try std.testing.expectEqual(@as(u8, 0x03), smp.cpuReadPort(0));
    try std.testing.expectEqual(core.smp.SemanticIplState.running, smp.semantic_ipl_state);
    try std.testing.expectEqual(@as(u32, 2), try smp.runSemanticInstructions(2));
    try std.testing.expect(smp.waiting);
}

test "optional exact IPL validates size and missing firmware fails closed" {
    var smp = core.smp.Smp{};
    try std.testing.expectError(error.InvalidIplSize, smp.installExactIpl(&[_]u8{0} ** 63));
    try std.testing.expectError(error.ExactIplUnavailable, smp.exactIplByte(0xffc0));

    smp.bus_mode = .hardware;
    smp.pc = 0xffc0;
    try std.testing.expectError(error.ExactIplUnavailable, smp.step());

    var firmware: [64]u8 = undefined;
    for (&firmware, 0..) |*byte, index| byte.* = @truncate(index * 3);
    firmware[0] = 0x00;
    firmware[1] = 0x5a;
    firmware[62] = 0xc0;
    firmware[63] = 0xff;
    try smp.installExactIpl(&firmware);
    smp.reset();
    try std.testing.expectEqual(@as(u16, 0xffc0), smp.pc);
    try std.testing.expectEqual(firmware[0], try smp.exactIplByte(0xffc0));
    smp.beginTrace();
    try smp.step();
    const exact_trace = smp.endTrace();
    try std.testing.expectEqual(@as(u16, 0xffc1), smp.pc);
    try std.testing.expectEqual(@as(?u8, 0x00), exact_trace[0].value);
    smp.removeExactIpl();
    try std.testing.expectError(error.ExactIplUnavailable, smp.exactIplByte(0xffc0));
}

test "canonical private IPL location is stable" {
    try std.testing.expectEqualStrings("C:\\R4OS\\SUBSYSTEMS\\r4os.snes\\FIRMWARE", core.persistence.firmware_root);
    try std.testing.expectEqualStrings("C:\\R4OS\\SUBSYSTEMS\\r4os.snes\\FIRMWARE\\SPC700.IPL", core.persistence.spc700_ipl_path);
}

test "SLEEP and STOP retain PC while exposing bounded low-power bus cycles" {
    inline for (.{ @as(u8, 0xef), @as(u8, 0xff) }) |opcode| {
        var smp = core.smp.Smp{};
        smp.bus_mode = .vector_ram;
        smp.pc = 0x3000;
        smp.aram[0x3000] = opcode;
        smp.beginTrace();
        try smp.step();
        const trace = smp.endTrace();
        try std.testing.expectEqual(@as(u16, 0x3001), smp.pc);
        try std.testing.expectEqual(@as(usize, 7), trace.len);
        try std.testing.expect((opcode == 0xef and smp.waiting) or (opcode == 0xff and smp.stopped));
    }
}

test "APU progress and port synchronization are slice and host-wait invariant" {
    const master_hz: u64 = core.timing.ntsc_master_hz;
    var one = core.smp.Smp{};
    var many = core.smp.Smp{};

    _ = one.advanceOscillator(master_hz, 10_000);
    one.cpuWritePort(0, 0x11);
    _ = one.advanceOscillator(master_hz, 20_000);
    one.cpuWritePort(1, 0x22);
    _ = one.advanceOscillator(master_hz, 30_003);

    var elapsed: u64 = 0;
    const boundaries = [_]u64{ 10_000, 30_000, 60_003 };
    const slices = [_]u64{ 1, 17, 509, 4_096, 0, 31 };
    var slice_index: usize = 0;
    for (boundaries, 0..) |boundary, event| {
        while (elapsed < boundary) : (slice_index += 1) {
            const requested = slices[slice_index % slices.len];
            if (requested == 0) {
                try std.testing.expectEqual(@as(u64, 0), many.advanceOscillator(master_hz, 0));
                continue;
            }
            const span = @min(requested, boundary - elapsed);
            _ = many.advanceOscillator(master_hz, span);
            elapsed += span;
        }
        if (event == 0) many.cpuWritePort(0, 0x11);
        if (event == 1) many.cpuWritePort(1, 0x22);
    }

    try std.testing.expectEqual(one.oscillator_ticks, many.oscillator_ticks);
    try std.testing.expectEqual(one.oscillator_phase, many.oscillator_phase);
    try std.testing.expectEqualSlices(u64, one.io.cpu_port_tick[0..], many.io.cpu_port_tick[0..]);
    try std.testing.expectEqualSlices(u64, one.io.cpu_port_epoch[0..], many.io.cpu_port_epoch[0..]);
    try std.testing.expectEqualSlices(u8, one.io.cpu_to_smp[0..], many.io.cpu_to_smp[0..]);
}
