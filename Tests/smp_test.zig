const std = @import("std");
const core = @import("core");

test "batched timers match single-clock edges including target wrap and partitions" {
    for ([_]u8{ 16, 128 }) |frequency| {
        for ([_]u8{ 0, 1, 17, 255 }) |target| {
            for (0..16) |flags| {
                var one = core.smp.Timer{
                    .frequency = frequency,
                    .stage0 = frequency - 1,
                    .stage1 = flags & 1 != 0,
                    .line = flags & 2 != 0,
                    .enabled = flags & 4 != 0,
                    .target = target,
                    .stage2 = ([_]u8{ 0, 2, 254, 255 })[flags & 3],
                    .output = 15,
                };
                var partitioned = one;
                var reference = one;
                const globally_enabled = flags & 8 != 0;
                for ([_]u32{ 0, 1, 127, 8193, 65535 }) |clocks| {
                    one.advance(clocks, globally_enabled);
                    var remaining = clocks;
                    while (remaining != 0) {
                        const part = @min(remaining, 251);
                        partitioned.advance(part, globally_enabled);
                        remaining -= part;
                    }
                    for (0..clocks) |_| {
                        reference.stage0 += 1;
                        if (reference.stage0 < frequency) continue;
                        reference.stage0 = 0;
                        reference.stage1 = !reference.stage1;
                        const level = reference.stage1 and globally_enabled;
                        const falling = reference.line and !level;
                        reference.line = level;
                        if (!falling or !reference.enabled) continue;
                        reference.stage2 +%= 1;
                        if (reference.stage2 != target) continue;
                        reference.stage2 = 0;
                        reference.output +%= 1;
                    }
                    try std.testing.expectEqualDeep(reference, one);
                    try std.testing.expectEqualDeep(reference, partitioned);
                }
            }
        }
    }
}

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
    smp.serviceSemanticIpl();
    try std.testing.expectEqual(core.smp.SemanticIplState.receiving, smp.semantic_ipl_state);
    try std.testing.expectEqual(@as(u8, 0xcc), smp.cpuReadPort(0));

    smp.cpuWritePort(1, 0x00); // NOP
    smp.cpuWritePort(0, 0x00);
    smp.serviceSemanticIpl();
    smp.cpuWritePort(1, 0xef); // SLEEP
    smp.cpuWritePort(0, 0x01);
    smp.serviceSemanticIpl();
    try std.testing.expectEqual(@as(u8, 0x00), smp.aram[0x0200]);
    try std.testing.expectEqual(@as(u8, 0xef), smp.aram[0x0201]);

    smp.cpuWritePort(2, 0x00);
    smp.cpuWritePort(3, 0x02);
    smp.cpuWritePort(1, 0x00);
    smp.cpuWritePort(0, 0x03);
    smp.serviceSemanticIpl();
    try std.testing.expectEqual(core.smp.SemanticIplState.launch_ack, smp.semantic_ipl_state);
    try std.testing.expectEqual(@as(u8, 0x03), smp.cpuReadPort(0));
    try std.testing.expectEqual(core.smp.SemanticIplState.running, smp.semantic_ipl_state);
    try std.testing.expectEqual(@as(u32, 2), try smp.runSemanticInstructions(2));
    try std.testing.expect(smp.waiting);
}

test "semantic IPL accepts collision-free block and launch command values" {
    var smp = core.smp.Smp{};
    smp.powerSemanticIpl();

    smp.cpuWritePort(2, 0x00);
    smp.cpuWritePort(3, 0x02);
    smp.cpuWritePort(1, 0xcc);
    smp.cpuWritePort(0, 0xcc);
    smp.serviceSemanticIpl();

    smp.cpuWritePort(1, 0x11);
    smp.cpuWritePort(0, 0x00);
    smp.serviceSemanticIpl();
    smp.cpuWritePort(1, 0x22);
    smp.cpuWritePort(0, 0x01);
    smp.serviceSemanticIpl();
    try std.testing.expectEqual(@as(u8, 0x11), smp.aram[0x0200]);
    try std.testing.expectEqual(@as(u8, 0x22), smp.aram[0x0201]);

    // The next command skips the sequential counter value. A non-zero port 1
    // starts a fresh data block and must not itself be copied into ARAM.
    smp.cpuWritePort(2, 0x00);
    smp.cpuWritePort(3, 0x03);
    smp.cpuWritePort(1, 0x23);
    smp.cpuWritePort(0, 0x23);
    smp.serviceSemanticIpl();
    try std.testing.expectEqual(@as(u8, 0x23), smp.cpuReadPort(0));
    try std.testing.expectEqual(@as(u32, 0), smp.semantic_received);

    // Counter zero remains an ordinary data byte even when its payload is
    // zero. A later non-sequential command with port 1 zero launches.
    smp.cpuWritePort(1, 0x00);
    smp.cpuWritePort(0, 0x00);
    smp.serviceSemanticIpl();
    try std.testing.expectEqual(@as(u8, 0x00), smp.aram[0x0300]);
    smp.cpuWritePort(2, 0x00);
    smp.cpuWritePort(3, 0x03);
    smp.cpuWritePort(1, 0x00);
    smp.cpuWritePort(0, 0x22);
    smp.serviceSemanticIpl();
    try std.testing.expectEqual(core.smp.SemanticIplState.launch_ack, smp.semantic_ipl_state);
    try std.testing.expect(smp.io.ipl_enabled);
    try std.testing.expectEqual(@as(u8, 0x22), smp.cpuReadPort(0));
    try std.testing.expectEqual(core.smp.SemanticIplState.running, smp.semantic_ipl_state);
    try std.testing.expectEqual(@as(u16, 0x0300), smp.pc);
}

test "semantic IPL observes both halves of an S-CPU 16-bit port store" {
    var smp = core.smp.Smp{};
    smp.powerSemanticIpl();
    smp.cpuWritePort(2, 0x00);
    smp.cpuWritePort(3, 0x02);
    smp.cpuWritePort(1, 0xcc);
    smp.cpuWritePort(0, 0xcc);
    smp.serviceSemanticIpl();

    // W65C816 STA $2140 in 16-bit accumulator mode writes the counter to
    // port 0 before writing the payload to port 1. Neither half alone may be
    // consumed as a completed semantic-IPL transaction.
    smp.cpuWritePort(0, 0x00);
    try std.testing.expectEqual(@as(u32, 0), smp.semantic_received);
    try std.testing.expectEqual(@as(u8, 0xcc), smp.io.smp_to_cpu[0]);
    smp.cpuWritePort(1, 0x5a);
    try std.testing.expectEqual(@as(u32, 0), smp.semantic_received);

    smp.serviceSemanticIpl();
    try std.testing.expectEqual(@as(u8, 0x5a), smp.aram[0x0200]);
    try std.testing.expectEqual(@as(u8, 0x00), smp.io.smp_to_cpu[0]);
    try std.testing.expectEqual(@as(u32, 1), smp.semantic_received);
    smp.serviceSemanticIpl();
    try std.testing.expectEqual(@as(u32, 1), smp.semantic_received);
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

test "S-SMP source-clock rates preserve TEST waits timers and native DSP rate" {
    for ([_]u8{ 2, 4, 10, 20 }, [_]u8{ 2, 4, 8, 16 }, 0..) |wait, timer_wait, selector| {
        var smp = core.smp.Smp{};
        smp.ipl_mode = .exact; // execute zero/NOP RAM, no semantic idle service
        smp.bus_mode = .vector_ram;
        smp.io.external_wait_states = @intCast(selector);
        smp.io.internal_wait_states = @intCast(selector);
        for (&smp.timers) |*timer| { timer.enabled = true; timer.target = 1; }
        const master_hz = if (selector & 1 == 0) core.timing.ntsc_master_hz else core.timing.pal_master_hz;
        _ = smp.advanceOscillator(master_hz, master_hz);
        try std.testing.expectEqual(@as(u64, 2_048_000), smp.oscillator_ticks);
        var instructions: u64 = 0;
        var timer_edges = [_]u64{0} ** 3;
        while (smp.cycles < smp.oscillator_ticks) {
            const deadline = @min(smp.cycles + 128, smp.oscillator_ticks);
            while (smp.cycles < deadline) : (instructions += 1) try smp.step();
            for (&smp.timers, &timer_edges) |*timer, *edges| {
                edges.* += timer.output;
                timer.output = 0;
            }
        }
        try std.testing.expectEqual(@as(u64, 2_048_000) / (2 * @as(u64, wait)), instructions);
        const timer_clocks = instructions * 2 * timer_wait;
        try std.testing.expectEqualSlices(u64, &.{ timer_clocks / 256, timer_clocks / 256, timer_clocks / 32 }, &timer_edges);
        try std.testing.expectEqual(@as(u64, 32_000), smp.dsp.stats.native_frames);
        std.debug.print("SMPRATE source={d} wait={d} instructions={d} timers={d}/{d}/{d} dsp={d}\n", .{ smp.oscillator_ticks, wait, instructions, timer_edges[0], timer_edges[1], timer_edges[2], smp.dsp.stats.native_frames });
    }
    // A RAM opcode/operand use external waits; the MMIO read uses internal.
    var mixed = core.smp.Smp{};
    mixed.io.ipl_enabled = false;
    mixed.io.internal_wait_states = 1;
    mixed.pc = 0x200;
    mixed.aram[0x200..0x202].* = .{ 0xe4, 0xf4 }; // MOV A,$f4
    try mixed.step();
    try std.testing.expectEqual(@as(u64, 8), mixed.cycles);
    try std.testing.expectEqual(@as(u8, 4), mixed.dsp.phase);
}

test "semantic upload peripheral clocks keep odd remainders across partitions" {
    for (0..4) |selector| {
        var one = core.smp.Smp{};
        one.powerSemanticIpl();
        one.io.internal_wait_states = @intCast(selector);
        for (&one.timers) |*timer| { timer.enabled = true; timer.target = 7; }
        var split = one;
        _ = one.advanceOscillator(core.timing.pal_master_hz, 30_003);
        var elapsed: u64 = 0;
        while (elapsed < 30_003) {
            const part = @min(@as(u64, 31), 30_003 - elapsed);
            _ = split.advanceOscillator(core.timing.pal_master_hz, part);
            elapsed += part;
        }
        try std.testing.expectEqual(one.oscillator_ticks, one.cycles);
        try std.testing.expectEqual(one.cycles, split.cycles);
        try std.testing.expectEqual(one.oscillator_phase, split.oscillator_phase);
        try std.testing.expectEqual(one.dsp_source_remainder, split.dsp_source_remainder);
        try std.testing.expectEqual(one.semantic_timer_remainder, split.semantic_timer_remainder);
        try std.testing.expectEqualDeep(one.timers, split.timers);
        try std.testing.expectEqualDeep(one.dsp, split.dsp);
        const cycles = split.cycles;
        // A new upload preserves peripheral time; an exact reset starts anew.
        split.powerSemanticIpl();
        try std.testing.expectEqual(cycles, split.cycles);
        var exact = [_]u8{0} ** 64;
        try split.installExactIpl(&exact);
        split.reset();
        try std.testing.expectEqual(@as(u64, 0), split.oscillator_ticks);
        try std.testing.expectEqual(@as(u64, 0), split.cycles);
        try std.testing.expectEqual(@as(u1, 0), split.dsp_source_remainder);
    }
}
