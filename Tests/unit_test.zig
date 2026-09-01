const std = @import("std");
const r4os = @import("r4os");
const core = @import("core");

test "all foundation component owners are analyzable" {
    std.testing.refAllDecls(core);
}

test "candidate inspection is bounded metadata and supports copier headers" {
    const plain = try core.cartridge.inspectCandidateSize(32 * 1024);
    try std.testing.expectEqual(@as(usize, 32 * 1024), plain.rom_size);
    try std.testing.expect(!plain.copier_header);
    const headered = try core.cartridge.inspectCandidateSize((128 * 1024) + 512);
    try std.testing.expectEqual(@as(usize, 128 * 1024), headered.rom_size);
    try std.testing.expect(headered.copier_header);
    try std.testing.expectError(error.CartridgeTooSmall, core.cartridge.inspectCandidateSize(512));
    try std.testing.expectError(error.InvalidCartridgeGeometry, core.cartridge.inspectCandidateSize(32 * 1024 + 1));
    try std.testing.expectError(error.CartridgeTooLarge, core.cartridge.inspectCandidateSize(65 * 1024 * 1024));
}

test "keyboard policy is exact and remains inside R4SNES" {
    const Expected = struct { usage: u32, button: core.controller.Button };
    const expected = [_]Expected{
        .{ .usage = r4os.abi.physical_key_usage_up, .button = .up },
        .{ .usage = r4os.abi.physical_key_usage_down, .button = .down },
        .{ .usage = r4os.abi.physical_key_usage_left, .button = .left },
        .{ .usage = r4os.abi.physical_key_usage_right, .button = .right },
        .{ .usage = r4os.abi.physical_key_usage_enter, .button = .start },
        .{ .usage = r4os.abi.physical_key_usage_right_control, .button = .select },
        .{ .usage = r4os.abi.physical_key_usage_keypad_8, .button = .x },
        .{ .usage = r4os.abi.physical_key_usage_keypad_6, .button = .a },
        .{ .usage = r4os.abi.physical_key_usage_keypad_2, .button = .b },
        .{ .usage = r4os.abi.physical_key_usage_keypad_4, .button = .y },
        .{ .usage = r4os.abi.physical_key_usage_keypad_7, .button = .l },
        .{ .usage = r4os.abi.physical_key_usage_keypad_9, .button = .r },
    };
    try std.testing.expectEqual(expected.len, core.host_adapter.bindings.len);
    for (expected) |entry| {
        try std.testing.expectEqual(entry.button, core.host_adapter.buttonForUsage(entry.usage).?);
    }
    try std.testing.expect(core.host_adapter.buttonForUsage(0x25) == null); // numeric row 8
    try std.testing.expect(core.host_adapter.buttonForUsage(r4os.abi.physical_key_usage_left_control) == null);
}

test "controller port two is disconnected and serially high" {
    var ports = core.controller.Ports{};
    try std.testing.expect(ports.port1.connected);
    try std.testing.expect(!ports.port2.connected);
    ports.port2.set(.a, true);
    ports.port2.latch();
    var bit: usize = 0;
    while (bit < 16) : (bit += 1) try std.testing.expectEqual(@as(u1, 1), ports.port2.serialBit());
}

test "machines own isolated state and close idempotently" {
    var first = core.machine.Machine.init(1);
    var second = core.machine.Machine.init(2);
    try std.testing.expect(first.foundationReady());
    try std.testing.expect(second.foundationReady());
    first.cpu.a = 0xBEEF;
    first.controllers.port1.set(.x, true);
    try std.testing.expectEqual(@as(u16, 0), second.cpu.a);
    try std.testing.expectEqual(@as(u16, 0), second.controllers.port1.held);
    first.close();
    first.close();
    try std.testing.expect(first.closed);
    try std.testing.expect(second.foundationReady());
}

test "bus is bounded to 24 bits and persistence path is canonical" {
    var bus = core.bus.Bus{};
    bus.observeWrite(0xAB12_3456, 0x77);
    try std.testing.expectEqual(@as(u32, 0x12_3456), bus.last_address);
    try std.testing.expectEqual(@as(u8, 0x77), bus.open_bus);
    try std.testing.expectEqualStrings("C:\\R4OS\\SUBSYSTEMS\\r4os.snes\\SAVE", core.persistence.save_root);
}

test "enhancement chips cannot silently fall back in the foundation" {
    var registry = core.coprocessors.Registry{};
    try std.testing.expect(registry.implemented());
    registry.selected = .sa1;
    try std.testing.expect(!registry.implemented());
    registry.selected = .super_fx;
    try std.testing.expect(!registry.implemented());
}
