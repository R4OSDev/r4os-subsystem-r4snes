const std = @import("std");
const core = @import("core");

test "original product fixture executes CPU input PPU and uploaded SPC tone through Machine" {
    const allocator = std.testing.allocator;
    const image = try allocator.alloc(u8, core.fixture_rom.imageBytes(.rom_only));
    defer allocator.free(image);
    try core.fixture_rom.build(image, .rom_only);
    var cart = try core.cartridge.Cartridge.parse(allocator, image);
    defer cart.deinit();
    var machine = try core.machine.Machine.power(0x730021, &cart, null);
    defer machine.close();
    machine.smp.dsp.beginCapture();
    machine.controllers.port1.set(.select, true);
    machine.controllers.port1.set(.start, true);

    _ = machine.runHostSlice(&cart, core.timing.maximum_host_slice_master_cycles, 0);
    var millisecond: u64 = 1;
    while (millisecond <= 50) : (millisecond += 1) {
        const result = machine.runHostSlice(
            &cart,
            core.timing.maximum_host_slice_master_cycles,
            millisecond * std.time.ns_per_ms,
        );
        try std.testing.expect(result.fault == null);
    }
    try std.testing.expectEqual(core.smp.SemanticIplState.running, machine.smp.semantic_ipl_state);
    try std.testing.expectEqual(core.fixture_rom.completion_witness_value, machine.bus.wram[core.fixture_rom.completion_wram_index]);
    try std.testing.expect((machine.bus.wram[core.fixture_rom.controller_low_wram_index] & 0x0c) == 0x0c);
    try std.testing.expect(machine.clock.frame != 0 and machine.ppu.frame_generation != 0);
    try std.testing.expect(machine.cpu.waiting);
    try std.testing.expect(machine.cpu.master_cycles > machine.clock.master_cycles / 2);
    try std.testing.expect(machine.cpu.instructions < 30_000);
    try std.testing.expect(machine.smp.dsp.stats.native_frames != 0);
    try std.testing.expect(machine.smp.dsp.stats.frames_queued != 0);
    try std.testing.expect(machine.smp.dsp.stats.silence_frames < machine.smp.dsp.stats.resampled_frames);

    const battery_image = try allocator.alloc(u8, core.fixture_rom.imageBytes(.battery_rtc));
    defer allocator.free(battery_image);
    try core.fixture_rom.build(battery_image, .battery_rtc);
    var battery_cart = try core.cartridge.Cartridge.parse(allocator, battery_image);
    defer battery_cart.deinit();
    var battery_machine = try core.machine.Machine.power(0x730022, &battery_cart, null);
    defer battery_machine.close();
    battery_machine.controllers.port1.set(.b, true);
    _ = battery_machine.runHostSlice(&battery_cart, core.timing.maximum_host_slice_master_cycles, 0);
    millisecond = 1;
    while (millisecond <= 50) : (millisecond += 1) {
        const result = battery_machine.runHostSlice(
            &battery_cart,
            core.timing.maximum_host_slice_master_cycles,
            millisecond * std.time.ns_per_ms,
        );
        try std.testing.expect(result.fault == null);
    }
    try std.testing.expect(battery_cart.sram_dirty);
    try std.testing.expectEqual(core.fixture_rom.battery_witness_value, battery_cart.sram_storage[0]);
    try std.testing.expect((battery_machine.bus.wram[core.fixture_rom.controller_low_wram_index] & 0x01) != 0);
}
