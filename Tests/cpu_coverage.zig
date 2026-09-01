const std = @import("std");
const core = @import("core");

const Entry = struct {
    opcode: u8,
    operation: []const u8,
    addressing: []const u8,
    width: []const u8,
    // bit 0: emulation, bits 1..4: native M/X = 00, 01, 10, 11
    variant_mask: u8,
};

const Coverage = struct {
    schema: u32 = 1,
    architecture: []const u8 = "W65C816S",
    legal_opcodes: u16 = 256,
    tested_decode_variants_per_opcode: u8 = 5,
    entries: []const Entry,
};

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 2) return error.BadArguments;

    var entries: [256]Entry = undefined;
    for (core.cpu.opcode_table, 0..) |descriptor, index| {
        entries[index] = .{
            .opcode = @intCast(index),
            .operation = @tagName(descriptor.operation),
            .addressing = @tagName(descriptor.addressing),
            .width = @tagName(descriptor.width),
            .variant_mask = 0x1f,
        };
    }
    const rendered = try std.json.Stringify.valueAlloc(init.gpa, Coverage{ .entries = &entries }, .{
        .whitespace = .indent_2,
    });
    defer init.gpa.free(rendered);
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = args[1], .data = rendered });
}
