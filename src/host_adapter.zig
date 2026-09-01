const r4os = @import("r4os");
const controller = @import("controller.zig");

pub const Binding = struct {
    usage: u32,
    button: controller.Button,
};

pub const bindings = [_]Binding{
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

pub fn buttonForUsage(usage: u32) ?controller.Button {
    for (bindings) |binding| {
        if (binding.usage == usage) return binding.button;
    }
    return null;
}

pub const InputKind = enum {
    press,
    release,
    repeat,
    focus_lost,
    reset,
};

/// Feed physical keyboard events into the only connected controller.  Repeat
/// is intentionally idempotent; opposing directions remain independently
/// held because the physical SNES pad itself does not arbitrate them.
pub fn applyInput(ports: *controller.Ports, usage: u32, kind: InputKind) bool {
    switch (kind) {
        .focus_lost, .reset => {
            ports.clearInput();
            return true;
        },
        .press, .repeat, .release => {},
    }
    const button = buttonForUsage(usage) orelse return false;
    ports.port1.set(button, kind != .release);
    return true;
}
