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
    _ = machine.runHostSlice(&cart, 32_768, 0);
    while (true) {
        const result = machine.runHostSlice(&cart, 32_768, 250_000_000);
        if (result.fault != null) return error.ReleaseMachineFault;
        while (machine.smp.dsp.queuedFrames() != 0) {
            const count = machine.smp.dsp.renderPcm(&pcm);
            if (count <= 0) return error.ReleasePcmStalled;
            for (pcm[0..@intCast(count)]) |byte| nonzero += @intFromBool(byte != 0);
        }
        if (machine.host_budget.pending_master_cycles == 0) break;
    }
    if (machine.ppu.frame_generation < 8 or machine.bus.wram[8] < 8 or nonzero == 0 or
        machine.smp.dsp.stats.frames_dropped != 0 or machine.smp.semantic_ipl_state != .running)
        return error.ReleaseSceneInactive;
    if (machine.cpu.trace_len != 0 or machine.cpu.instructions != 0 or
        machine.scpu.dma.trace_len != 0 or machine.scpu.dma.trace_overflow != 0 or
        machine.scpu.dma.manual_bytes != 0 or machine.scpu.dma.hdma_bytes != 0 or
        machine.bus.reads != 0 or machine.bus.writes != 0 or machine.bus.last_address != 0 or
        machine.scpu.interrupt_polls != 0 or machine.scpu.event_digest != event_digest or
        machine.smp.io.port_epoch != 0 or machine.smp.dsp.native_digest != native_digest or
        machine.smp.dsp.resampled_digest != resampled_digest)
        return error.ReleaseDiagnosticWork;
    machine.smp.beginTrace();
    try machine.smp.step();
    if (machine.smp.endTrace().len != 0 or machine.smp.trace_enabled)
        return error.ReleaseSpcTrace;
    std.debug.print("R4SNES ReleaseFast profile: OK (active video/PCM, diagnostic work absent)\n", .{});
}
