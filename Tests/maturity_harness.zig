const std = @import("std");
const core = @import("core");

const guest_nanoseconds: u64 = 2 * std.time.ns_per_s;
const maximum_wall_nanoseconds: u64 = 120 * std.time.ns_per_s;
const full_slice: u32 = core.timing.maximum_host_slice_master_cycles;
const split_slice: u32 = 4_096;
const maximum_host_gap_ns: u64 = 250 * std.time.ns_per_ms;

const Pattern = enum {
    one_ms,
    seventeen_ms,
    irregular,
    partitioned,
    regression,
};

const RunEvidence = struct {
    master_cycles: u64,
    beam_frames: u64,
    ppu_frames: u64,
    pcm_frames: u64,
    slices: u64,
    maximum_grant: u32,
    maximum_execution: u64,
    maximum_host_gap_ns: u64,
    controller_low: u8,
    controller_high: u8,
    state_digest: [32]u8,
    pcm_digest: [32]u8,
};

const RunMetrics = struct {
    slices: u64 = 0,
    maximum_grant: u32 = 0,
    maximum_execution: u64 = 0,
};

pub fn main(init: std.process.Init) void {
    qualify(init) catch |fault| {
        std.debug.print("R4SNES maturity harness FAILED: {s}\n", .{@errorName(fault)});
        std.process.exit(1);
    };
}

fn qualify(init: std.process.Init) !void {
    const started = std.Io.Clock.awake.now(init.io);

    const ntsc_fast = try runCase(init.gpa, .ntsc_u, .one_ms, 0x73002201);
    const ntsc_slow = try runCase(init.gpa, .ntsc_u, .seventeen_ms, 0x73002202);
    const ntsc_irregular = try runCase(init.gpa, .ntsc_u, .irregular, 0x73002203);
    const ntsc_partitioned = try runCase(init.gpa, .ntsc_u, .partitioned, 0x73002204);
    const ntsc_regression = try runCase(init.gpa, .ntsc_u, .regression, 0x73002205);
    const ntsc_restart = try runCase(init.gpa, .ntsc_u, .one_ms, 0x73002201);
    const ntsc_second_instance = try runCase(init.gpa, .ntsc_u, .one_ms, 0x73002299);

    try ensureParity(ntsc_fast, ntsc_slow);
    try ensureParity(ntsc_fast, ntsc_irregular);
    try ensureParity(ntsc_fast, ntsc_partitioned);
    try ensureParity(ntsc_fast, ntsc_regression);
    try ensureParity(ntsc_fast, ntsc_restart);
    try ensureParity(ntsc_fast, ntsc_second_instance);

    const pal_fast = try runCase(init.gpa, .pal, .one_ms, 0x73002211);
    const pal_irregular = try runCase(init.gpa, .pal, .irregular, 0x73002212);
    const pal_partitioned = try runCase(init.gpa, .pal, .partitioned, 0x73002213);
    const pal_restart = try runCase(init.gpa, .pal, .one_ms, 0x73002211);

    try ensureParity(pal_fast, pal_irregular);
    try ensureParity(pal_fast, pal_partitioned);
    try ensureParity(pal_fast, pal_restart);
    if (std.mem.eql(u8, &ntsc_fast.state_digest, &pal_fast.state_digest))
        return error.RegionDidNotAffectMachineState;
    // The beam and master-clock profiles differ, but both regions drive the
    // same rational 32-kHz APU oscillator for the same guest duration.
    if (!std.mem.eql(u8, &ntsc_fast.pcm_digest, &pal_fast.pcm_digest))
        return error.RegionAudioRateMismatch;

    const ended = std.Io.Clock.awake.now(init.io);
    const wall_ns = try elapsedNanoseconds(started, ended);
    if (wall_ns > maximum_wall_nanoseconds) return error.MaturityWallBudgetExceeded;

    var ntsc_state_hex: [64]u8 = undefined;
    var ntsc_pcm_hex: [64]u8 = undefined;
    var pal_state_hex: [64]u8 = undefined;
    var pal_pcm_hex: [64]u8 = undefined;
    _ = std.fmt.bufPrint(ntsc_state_hex[0..], "{x}", .{ntsc_fast.state_digest}) catch unreachable;
    _ = std.fmt.bufPrint(ntsc_pcm_hex[0..], "{x}", .{ntsc_fast.pcm_digest}) catch unreachable;
    _ = std.fmt.bufPrint(pal_state_hex[0..], "{x}", .{pal_fast.state_digest}) catch unreachable;
    _ = std.fmt.bufPrint(pal_pcm_hex[0..], "{x}", .{pal_fast.pcm_digest}) catch unreachable;

    std.debug.print(
        "R4SNES maturity: OK cases=11 guest_ns={d} wall_ns={d} slice_limits={d},{d} host_gaps_ns=1000000,17000000,43000000 regression=ignored restart=exact instances=isolated close=idempotent ntsc_cycles={d} ntsc_beam_frames={d} ntsc_ppu_frames={d} ntsc_pcm_frames={d} ntsc_state_sha256={s} ntsc_pcm_sha256={s} pal_cycles={d} pal_beam_frames={d} pal_ppu_frames={d} pal_pcm_frames={d} pal_state_sha256={s} pal_pcm_sha256={s}\n",
        .{
            guest_nanoseconds,
            wall_ns,
            full_slice,
            split_slice,
            ntsc_fast.master_cycles,
            ntsc_fast.beam_frames,
            ntsc_fast.ppu_frames,
            ntsc_fast.pcm_frames,
            ntsc_state_hex[0..],
            ntsc_pcm_hex[0..],
            pal_fast.master_cycles,
            pal_fast.beam_frames,
            pal_fast.ppu_frames,
            pal_fast.pcm_frames,
            pal_state_hex[0..],
            pal_pcm_hex[0..],
        },
    );
}

fn runCase(
    allocator: std.mem.Allocator,
    region: core.board.Region,
    pattern: Pattern,
    instance_id: u64,
) !RunEvidence {
    const image = try allocator.alloc(u8, core.fixture_rom.imageBytes(.rom_only));
    defer allocator.free(image);
    try core.fixture_rom.buildForRegion(image, .rom_only, region);

    var cart = try core.cartridge.Cartridge.parse(allocator, image);
    defer cart.deinit();
    if (cart.board.region != region) return error.FixtureRegionMismatch;

    const machine = try allocator.create(core.machine.Machine);
    defer allocator.destroy(machine);
    try core.machine.Machine.powerInPlace(machine, instance_id, &cart, null);
    defer machine.close();
    if (!machine.foundationReady() or machine.controllers.port2.connected) return error.ControllerTopologyMismatch;

    inline for (std.meta.fields(core.controller.Button)) |field| {
        machine.controllers.port1.set(@enumFromInt(field.value), true);
    }
    machine.smp.dsp.beginCapture();

    var pcm_hash = std.crypto.hash.sha2.Sha256.init(.{});
    var pcm_frames: u64 = 0;
    var metrics = RunMetrics{};
    const slice_limit: u32 = if (pattern == .partitioned) split_slice else full_slice;
    try drainTimestamp(machine, &cart, 0, slice_limit, &pcm_hash, &pcm_frames, &metrics);

    var timestamp: u64 = 0;
    var sequence_index: usize = 0;
    var regression_checked = false;
    var maximum_gap: u64 = 0;
    while (timestamp < guest_nanoseconds) {
        const increment = patternIncrement(pattern, sequence_index);
        sequence_index += 1;
        const next = @min(guest_nanoseconds, timestamp + increment);
        maximum_gap = @max(maximum_gap, next - timestamp);
        timestamp = next;
        try drainTimestamp(machine, &cart, timestamp, slice_limit, &pcm_hash, &pcm_frames, &metrics);

        if (pattern == .regression and !regression_checked and timestamp >= guest_nanoseconds / 2) {
            const before_cycles = machine.clock.master_cycles;
            const before_pending = machine.host_budget.pending_master_cycles;
            const regressed = machine.runHostSlice(&cart, slice_limit, timestamp - 3 * std.time.ns_per_ms);
            if (regressed.fault != null or regressed.granted_master_cycles != 0 or
                regressed.executed_master_cycles != 0 or machine.clock.master_cycles != before_cycles or
                machine.host_budget.pending_master_cycles != before_pending)
            {
                return error.RegressedHostTimeAdvancedGuest;
            }
            regression_checked = true;
        }
    }

    if (maximum_gap > maximum_host_gap_ns or machine.host_budget.pending_master_cycles != 0 or
        machine.host_budget.last_guest_nanoseconds != guest_nanoseconds)
    {
        return error.HostPatternDidNotDrain;
    }
    if (pattern == .regression and !regression_checked) return error.RegressionCaseNotReached;
    if (metrics.maximum_grant > slice_limit or metrics.maximum_execution > @as(u64, slice_limit) + 64)
        return error.SliceBoundExceeded;
    if (machine.smp.dsp.queuedFrames() != 0 or machine.smp.dsp.stats.frames_dropped != 0 or
        machine.smp.dsp.stats.underflow_frames != 0 or
        machine.smp.dsp.stats.frames_queued != machine.smp.dsp.stats.frames_rendered or
        machine.smp.dsp.stats.silence_frames >= machine.smp.dsp.stats.resampled_frames)
    {
        return error.AudioIntegrityFailure;
    }
    if (pcm_frames != machine.smp.dsp.stats.frames_rendered or pcm_frames == 0)
        return error.AudioAccountingMismatch;
    if (machine.bus.wram[core.fixture_rom.completion_wram_index] != core.fixture_rom.completion_witness_value or
        machine.bus.wram[core.fixture_rom.controller_low_wram_index] != 0xff or
        (machine.bus.wram[core.fixture_rom.controller_high_wram_index] & 0x0f) != 0x0f)
    {
        return error.ControllerWitnessMismatch;
    }

    const expected_cycles = (@as(u128, guest_nanoseconds) * machine.clock.profile().master_hz) /
        std.time.ns_per_s;
    if (machine.clock.master_cycles < expected_cycles or
        machine.clock.master_cycles - expected_cycles > 64)
    {
        return error.GuestClockDrift;
    }

    var pcm_digest: [32]u8 = undefined;
    pcm_hash.final(&pcm_digest);
    const evidence = RunEvidence{
        .master_cycles = machine.clock.master_cycles,
        .beam_frames = machine.clock.frame,
        .ppu_frames = machine.ppu.frame_generation,
        .pcm_frames = pcm_frames,
        .slices = metrics.slices,
        .maximum_grant = metrics.maximum_grant,
        .maximum_execution = metrics.maximum_execution,
        .maximum_host_gap_ns = maximum_gap,
        .controller_low = machine.bus.wram[core.fixture_rom.controller_low_wram_index],
        .controller_high = machine.bus.wram[core.fixture_rom.controller_high_wram_index],
        .state_digest = stateDigest(machine, &cart),
        .pcm_digest = pcm_digest,
    };

    machine.close();
    machine.close();
    const after_close = machine.runHostSlice(&cart, slice_limit, guest_nanoseconds);
    if (!machine.closed or after_close.fault != .closed or machine.smp.exact_ipl_loaded or
        machine.smp.dsp.queuedFrames() != 0)
    {
        return error.CloseNotIdempotent;
    }
    return evidence;
}

fn drainTimestamp(
    machine: *core.machine.Machine,
    cart: *core.cartridge.Cartridge,
    timestamp: u64,
    slice_limit: u32,
    pcm_hash: *std.crypto.hash.sha2.Sha256,
    pcm_frames: *u64,
    metrics: *RunMetrics,
) !void {
    while (true) {
        const result = machine.runHostSlice(cart, slice_limit, timestamp);
        if (result.fault != null) return error.MachineFault;
        metrics.maximum_grant = @max(metrics.maximum_grant, result.granted_master_cycles);
        metrics.maximum_execution = @max(metrics.maximum_execution, result.executed_master_cycles);
        if (result.granted_master_cycles != 0) metrics.slices += 1;
        try drainPcm(&machine.smp.dsp, pcm_hash, pcm_frames);
        if (machine.host_budget.pending_master_cycles == 0) break;
        if (result.granted_master_cycles == 0) return error.StalledGuestDebt;
    }
}

fn drainPcm(
    dsp: *core.sdsp.Dsp,
    pcm_hash: *std.crypto.hash.sha2.Sha256,
    pcm_frames: *u64,
) !void {
    var buffer: [core.sdsp.maximum_render_frames * core.sdsp.sample_bytes]u8 = undefined;
    while (dsp.queuedFrames() != 0) {
        const frames = @min(dsp.queuedFrames(), core.sdsp.maximum_render_frames);
        const byte_count = frames * core.sdsp.sample_bytes;
        const rendered = dsp.renderPcm(buffer[0..byte_count]);
        if (rendered != byte_count) return error.AudioDrainFailure;
        pcm_hash.update(buffer[0..byte_count]);
        pcm_frames.* += frames;
    }
}

fn patternIncrement(pattern: Pattern, index: usize) u64 {
    return switch (pattern) {
        .one_ms => std.time.ns_per_ms,
        .seventeen_ms, .regression => 17 * std.time.ns_per_ms,
        .irregular, .partitioned => ([_]u64{ 1, 29, 7, 43, 3, 19 })[index % 6] * std.time.ns_per_ms,
    };
}

fn ensureParity(left: RunEvidence, right: RunEvidence) !void {
    if (left.master_cycles != right.master_cycles or
        left.beam_frames != right.beam_frames or
        left.ppu_frames != right.ppu_frames or
        left.pcm_frames != right.pcm_frames or
        left.controller_low != right.controller_low or
        left.controller_high != right.controller_high or
        !std.mem.eql(u8, &left.state_digest, &right.state_digest) or
        !std.mem.eql(u8, &left.pcm_digest, &right.pcm_digest))
    {
        return error.HostPartitionParityMismatch;
    }
}

fn stateDigest(machine: *const core.machine.Machine, cart: *const core.cartridge.Cartridge) [32]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(machine.bus.wram[0..]);
    hash.update(machine.smp.aram[0..]);
    hash.update(machine.smp.dsp.registers[0..]);
    hash.update(std.mem.sliceAsBytes(machine.ppu.published_frame[0..]));
    hash.update(cart.sram_storage);
    hash.update(cart.identity[0..]);
    updateU64(&hash, machine.clock.master_cycles);
    updateU64(&hash, machine.clock.frame);
    updateU16(&hash, machine.clock.h_counter);
    updateU16(&hash, machine.clock.v_counter);
    updateU64(&hash, machine.clock.apu_ticks);
    updateU64(&hash, machine.cpu.master_cycles);
    updateU64(&hash, machine.cpu.instructions);
    updateU16(&hash, machine.cpu.a);
    updateU16(&hash, machine.cpu.x);
    updateU16(&hash, machine.cpu.y);
    updateU16(&hash, machine.cpu.s);
    updateU16(&hash, machine.cpu.d);
    updateU16(&hash, machine.cpu.pc);
    hash.update(&.{ machine.cpu.db, machine.cpu.pb, machine.cpu.p.byte(), @intFromBool(machine.cpu.waiting) });
    updateU64(&hash, machine.smp.cycles);
    updateU64(&hash, machine.smp.oscillator_ticks);
    updateU64(&hash, machine.smp.dsp.sample_counter);
    updateU64(&hash, machine.smp.dsp.native_digest);
    updateU64(&hash, machine.smp.dsp.resampled_digest);
    updateU64(&hash, machine.ppu.frame_generation);
    updateU64(&hash, machine.ppu.frame_digest);
    updateU64(&hash, machine.ppu.memoryDigest());
    var result: [32]u8 = undefined;
    hash.final(&result);
    return result;
}

fn updateU16(hash: *std.crypto.hash.sha2.Sha256, value: u16) void {
    var bytes: [2]u8 = undefined;
    std.mem.writeInt(u16, bytes[0..], value, .little);
    hash.update(bytes[0..]);
}

fn updateU64(hash: *std.crypto.hash.sha2.Sha256, value: u64) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, bytes[0..], value, .little);
    hash.update(bytes[0..]);
}

fn elapsedNanoseconds(started: std.Io.Timestamp, ended: std.Io.Timestamp) !u64 {
    const elapsed = ended.nanoseconds - started.nanoseconds;
    if (elapsed <= 0) return error.ProfileClockUnavailable;
    return @intCast(elapsed);
}
