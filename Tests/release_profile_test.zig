const std = @import("std");
const core = @import("core");

// An executable, not a Zig test: builtin.is_test must match the real product.
pub fn main(init: std.process.Init) !void {
    if (core.config.diagnostics) return error.DiagnosticsInRelease;
    const image = try init.gpa.alloc(u8, core.performance_scene.image_bytes);
    defer init.gpa.free(image);
    try core.performance_scene.build(image);
    var cart = try core.cartridge.Cartridge.parse(init.gpa, image);
    defer cart.deinit();
    const machine = try init.gpa.create(core.machine.Machine);
    defer init.gpa.destroy(machine);
    try core.machine.Machine.powerInPlace(machine, 1, &cart, null);
    defer machine.close();
    machine.smp.dsp.beginCapture();
    const native_digest = machine.smp.dsp.native_digest;
    const resampled_digest = machine.smp.dsp.resampled_digest;
    const event_digest = machine.scpu.event_digest;
    var pcm: [core.sdsp.maximum_render_frames * core.sdsp.sample_bytes]u8 = undefined;
    var nonzero: usize = 0;
    var pcm_hash = std.crypto.hash.sha2.Sha256.init(.{});
    _ = machine.runHostSlice(&cart, 32_768, 0);
    while (true) {
        const result = machine.runHostSlice(&cart, 32_768, 250_000_000);
        if (result.fault != null) return error.ReleaseMachineFault;
        while (machine.smp.dsp.queuedFrames() != 0) {
            const count = machine.smp.dsp.renderPcm(&pcm);
            if (count <= 0) return error.ReleasePcmStalled;
            pcm_hash.update(pcm[0..@intCast(count)]);
            for (pcm[0..@intCast(count)]) |byte| nonzero += @intFromBool(byte != 0);
        }
        if (machine.host_budget.pending_master_cycles == 0) break;
    }
    if (machine.ppu.frame_generation < 8 or machine.bus.wram[8] < 8 or nonzero == 0 or
        machine.smp.dsp.stats.frames_dropped != 0 or machine.smp.semantic_ipl_state != .running)
        return error.ReleaseSceneInactive;
    if (machine.ppu.frameInfo().digest_available or machine.ppu.frame_digest != 0)
        return error.ReleaseFrameDigestWork;
    if (machine.cpu.trace_len != 0 or machine.cpu.instructions != 0 or
        machine.scpu.dma.trace_len != 0 or machine.scpu.dma.trace_overflow != 0 or
        machine.scpu.dma.manual_bytes != 0 or machine.scpu.dma.hdma_bytes != 0 or
        machine.bus.reads != 0 or machine.bus.writes != 0 or machine.bus.last_address != 0 or
        machine.scpu.interrupt_polls != 0 or machine.scpu.event_digest != event_digest or
        machine.smp.io.port_epoch != 0 or machine.smp.dsp.native_digest != native_digest or
        machine.smp.dsp.resampled_digest != resampled_digest)
        return error.ReleaseDiagnosticWork;
    const other = try init.gpa.create(core.machine.Machine);
    defer init.gpa.destroy(other);
    try core.machine.Machine.powerInPlace(other, 1, &cart, null);
    defer other.close();
    other.smp.dsp.beginCapture();
    var clock: u64 = 0;
    var profile = core.performance.Profile{ .clock = .{ .context = &clock, .read = tick } };
    other.profile = &profile;
    var other_pcm = std.crypto.hash.sha2.Sha256.init(.{});
    _ = other.runHostSlice(&cart, 32_768, 0);
    while (true) {
        const result = other.runHostSlice(&cart, 32_768, 250_000_000);
        if (result.fault != null) return error.InstrumentedMachineFault;
        while (other.smp.dsp.queuedFrames() != 0) {
            const count = other.smp.dsp.renderPcm(&pcm);
            if (count <= 0) return error.InstrumentedPcmStalled;
            other_pcm.update(pcm[0..@intCast(count)]);
        }
        if (other.host_budget.pending_master_cycles == 0) break;
    }
    var expected_pcm: [32]u8 = undefined;
    var actual_pcm: [32]u8 = undefined;
    pcm_hash.final(&expected_pcm);
    other_pcm.final(&actual_pcm);
    if (!std.mem.eql(u8, &expected_pcm, &actual_pcm) or
        !std.mem.eql(u8, &machine.bus.wram, &other.bus.wram) or
        !std.mem.eql(u8, &machine.smp.aram, &other.smp.aram) or
        !std.mem.eql(u32, &machine.ppu.published_frame, &other.ppu.published_frame) or
        machine.clock.master_cycles != other.clock.master_cycles or
        machine.smp.cycles != other.smp.cycles or machine.cpu.pc != other.cpu.pc or
        machine.ppu.frame_generation != other.ppu.frame_generation or
        other.smp.profile != null or profile.cpu_operations == 0 or
        profile.dma_operations == 0 or profile.elapsed(.ppu) == 0 or profile.elapsed(.dsp) == 0 or
        profile.master_cycles != other.clock.master_cycles or profile.clock_regressions != 0)
        return error.InstrumentationChangedWork;
    if (other.ppu.frameInfo().digest_available or other.ppu.frame_digest != 0)
        return error.ProfileFrameDigestWork;
    profile.elapsed_ns[0] = ~@as(u64, 0) - 1;
    profile.add(.cpu_bus, 20);
    if (profile.elapsed_ns[0] != ~@as(u64, 0)) return error.ProfileOverflow;
    clock = 0;
    _ = profile.now();
    if (profile.clock_regressions != 1) return error.ProfileRegressionMissing;
    machine.smp.beginTrace();
    try machine.smp.step();
    if (machine.smp.endTrace().len != 0 or machine.smp.trace_enabled)
        return error.ReleaseSpcTrace;
    std.debug.print("R4SNES ReleaseFast profile: OK (active video/PCM, diagnostic work absent)\n", .{});
    std.debug.print("R4SNES profile equivalence: OK (exact master work, WRAM/ARAM/frame/PCM; DMA/DSP attribution, saturation, clock regression)\n", .{});
}

fn tick(context: *anyopaque) u64 {
    const value: *u64 = @ptrCast(@alignCast(context));
    value.* += 1;
    return value.*;
}
