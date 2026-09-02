// Copyright 2026 R4
// SPDX-License-Identifier: Apache-2.0
//
// Deterministic Super Nintendo cartridges generated from original R4OS
// source. They are test programs, not commercial dumps, and contain neither
// the proprietary S-SMP IPL nor enhancement-chip firmware. The S-CPU program
// uses the public IPL upload protocol to install an original SPC700 tone
// program and then exercises PPU color, serial controller and battery state.
const std = @import("std");
const board = @import("board.zig");
const cartridge = @import("cartridge.zig");

pub const completion_wram_index: usize = 1;
pub const controller_low_wram_index: usize = 5;
pub const controller_high_wram_index: usize = 6;
pub const completion_witness_value: u8 = 0xa5;
pub const battery_witness_value: u8 = 0x5a;

const spc_destination: u16 = 0x0200;
const spc_directory: u16 = 0x0300;
const spc_sample: u16 = 0x0400;
const spc_payload_bytes: usize = @as(usize, spc_sample + 9 - spc_destination);
const spc_payload_cpu_address: u16 = 0x9000;
const nmi_handler_cpu_address: u16 = 0x8800;

pub const Kind = enum {
    rom_only,
    battery_rtc,
    invalid,
    firmware_required,
};

pub const Metadata = struct {
    title: []const u8,
    extension: []const u8,
    image_bytes: usize,
    battery: bool,
    rtc: bool,
    runnable: bool,
    rejection: ?[]const u8 = null,
};

pub fn metadata(kind: Kind) Metadata {
    return switch (kind) {
        .rom_only => .{
            .title = "R4SNES E2E A",
            .extension = ".sfc",
            .image_bytes = 32 * 1024,
            .battery = false,
            .rtc = false,
            .runnable = true,
        },
        .battery_rtc => .{
            .title = "R4SNES E2E B",
            .extension = ".smc",
            .image_bytes = 2 * 1024 * 1024,
            .battery = true,
            .rtc = true,
            .runnable = true,
        },
        .invalid => .{
            .title = "R4SNES INVALID",
            .extension = ".sfc",
            .image_bytes = 32 * 1024,
            .battery = false,
            .rtc = false,
            .runnable = false,
            .rejection = "cartridge",
        },
        .firmware_required => .{
            .title = "R4SNES DSP REQUIRED",
            .extension = ".sfc",
            .image_bytes = 1024 * 1024,
            .battery = false,
            .rtc = false,
            .runnable = false,
            .rejection = "firmware",
        },
    };
}

pub fn imageBytes(kind: Kind) usize {
    return metadata(kind).image_bytes;
}

pub fn build(out: []u8, kind: Kind) !void {
    return buildForRegion(out, kind, .ntsc_u);
}

/// Build one owner cartridge for an explicit video standard. Keeping region
/// selection in the generated public fixture makes NTSC/PAL runtime parity a
/// product-machine test instead of a synthetic Clock-only assertion.
pub fn buildForRegion(out: []u8, kind: Kind, region: board.Region) !void {
    if (out.len != imageBytes(kind)) return error.InvalidSize;
    if (kind == .invalid) {
        @memset(out, 0xff);
        return;
    }

    @memset(out, 0xea);
    const mapping: board.Mapping = if (kind == .battery_rtc) .hi_rom else .lo_rom;
    const header_offset = headerOffset(mapping);
    const header = out[header_offset .. header_offset + cartridge.header_length];
    @memset(header, 0);
    @memset(header[0..cartridge.title_length], ' ');
    const info = metadata(kind);
    @memcpy(header[0..info.title.len], info.title);
    header[0x15] = switch (kind) {
        .battery_rtc => 0x3a,
        else => 0x20,
    };
    header[0x16] = switch (kind) {
        .battery_rtc => 0xf9, // SPC7110 plus Epson RTC and battery RAM.
        .firmware_required => 0x03, // DSP-1 family, exact user firmware required.
        else => 0x00,
    };
    header[0x17] = romSizeCode(out.len);
    header[0x18] = if (kind == .battery_rtc) 3 else 0;
    header[0x19] = switch (region) {
        .ntsc_j => 0,
        .ntsc_u => 1,
        .pal => 2,
    };
    header[0x1a] = 0x33;
    header[0x3c] = 0x00;
    header[0x3d] = 0x80;

    const program_index = board.decodeRomIndex(mapping, 0x008000, out.len) orelse return error.InvalidMapping;
    const payload_index = board.decodeRomIndex(mapping, spc_payload_cpu_address, out.len) orelse return error.InvalidMapping;
    const nmi_index = board.decodeRomIndex(mapping, nmi_handler_cpu_address, out.len) orelse return error.InvalidMapping;
    if (payload_index + spc_payload_bytes > out.len) return error.InvalidMapping;
    buildSpcPayload(out[payload_index .. payload_index + spc_payload_bytes]);
    buildCpuProgram(out, program_index, kind == .battery_rtc);
    out[nmi_index] = 0x40; // RTI: wake the WAI-paced main loop once per field.
    header[0x2a] = @truncate(nmi_handler_cpu_address); // Native NMI vector.
    header[0x2b] = @truncate(nmi_handler_cpu_address >> 8);
    header[0x3a] = @truncate(nmi_handler_cpu_address); // Emulation NMI vector.
    header[0x3b] = @truncate(nmi_handler_cpu_address >> 8);
    finalizeChecksum(out, header);
}

fn buildSpcPayload(payload: []u8) void {
    std.debug.assert(payload.len == spc_payload_bytes);
    @memset(payload, 0);
    var cursor: usize = 0;
    dspWrite(payload, &cursor, 0x6c, 0x20); // Unmute, leave echo writes disabled.
    dspWrite(payload, &cursor, 0x0c, 0x7f);
    dspWrite(payload, &cursor, 0x1c, 0x60); // Deliberate left/right ratio.
    dspWrite(payload, &cursor, 0x00, 0x7f);
    dspWrite(payload, &cursor, 0x01, 0x60);
    dspWrite(payload, &cursor, 0x02, 0x00);
    dspWrite(payload, &cursor, 0x03, 0x10);
    dspWrite(payload, &cursor, 0x04, 0x00);
    dspWrite(payload, &cursor, 0x05, 0x00);
    dspWrite(payload, &cursor, 0x06, 0x00);
    dspWrite(payload, &cursor, 0x07, 0x7f);
    dspWrite(payload, &cursor, 0x5d, @truncate(spc_directory >> 8));
    dspWrite(payload, &cursor, 0x4c, 0x01);
    emit(payload, &cursor, &.{ 0x2f, 0xfe }); // BRA to itself.

    const directory = spc_directory - spc_destination;
    payload[directory + 0] = @truncate(spc_sample);
    payload[directory + 1] = @truncate(spc_sample >> 8);
    payload[directory + 2] = @truncate(spc_sample);
    payload[directory + 3] = @truncate(spc_sample >> 8);
    const sample = spc_sample - spc_destination;
    payload[sample] = 0xc3; // Finite BRR block with loop/end flags.
    payload[sample + 1 .. sample + 9].* = .{ 0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xde, 0xf0 };
}

fn dspWrite(out: []u8, cursor: *usize, register: u8, value: u8) void {
    emit(out, cursor, &.{
        0x8f, register, 0xf2, // MOV $F2,#register
        0x8f, value, 0xf3, // MOV $F3,#value
    });
}

fn buildCpuProgram(out: []u8, start: usize, battery: bool) void {
    var cursor = start;
    emit(out, &cursor, &.{
        0x78, // SEI
        0x18, // CLC
        0xfb, // XCE: native mode
        0xc2, 0x10, // REP #$10: 16-bit X/Y
        0xe2,                            0x20, // SEP #$20: 8-bit A
        0xa9,                            @truncate(spc_destination),
        0x8d,                            0x42,
        0x21,                            0xa9,
        @truncate(spc_destination >> 8), 0x8d,
        0x43,                            0x21,
        0xa9,                            0xcc,
        0x8d,                            0x41,
        0x21,                            0xa9,
        0xcc,                            0x8d,
        0x40,                            0x21,
        0xa2, 0x00, 0x00, // LDX #0
    });
    const upload_loop = cursor;
    emit(out, &cursor, &.{
        0xbd,                         @truncate(spc_payload_cpu_address), @truncate(spc_payload_cpu_address >> 8),
        0x8d,                         0x41,                               0x21,
        0x8a,                         0x8d,                               0x40,
        0x21,                         0xe8,                               0xe0,
        @truncate(spc_payload_bytes), @truncate(spc_payload_bytes >> 8),
    });
    emitBranch(out, &cursor, 0xd0, upload_loop);
    emit(out, &cursor, &.{
        0xa9,                             0x00,
        0x8d,                             0x41,
        0x21,                             0xa9,
        @truncate(spc_payload_bytes + 1), 0x8d,
        0x40,                             0x21,
        0xad, 0x40, 0x21, // Read launch acknowledgement; semantic IPL starts.
        0xa9, 0x0f,
        0x8d, 0x00, 0x21, // Display on, full brightness.
        0xa9, 0x00, 0x8f,
        0x01, 0x00, 0x7e,
        0x85, 0x04, 0x85,
        0x05, 0x85, 0x06,
        0xa9, 0x80,
        0x8d, 0x00, 0x42, // Enable vblank NMI; controller remains manual.
    });
    if (battery) emit(out, &cursor, &.{
        0xa9, 0x80,
        0x8d, 0x30,
        0x48, // SPC7110 $4830.7 enables the physical SRAM write gate.
        0xa9,
        battery_witness_value,
        0x8f,
        0x00,
        0x60,
        0x20,
    });

    const main_loop = cursor;
    emit(out, &cursor, &.{
        0xa9, 0x01,
        0x8d, 0x16,
        0x40, 0x9c,
        0x16, 0x40,
        0xa9, 0x00,
        0x85, 0x02,
        0x85, 0x03,
    });
    for (0..12) |index| {
        const destination: u8 = if (index < 8) 0x02 else 0x03;
        const mask: u8 = @as(u8, 1) << @intCast(index & 7);
        emit(out, &cursor, &.{
            0xad,        0x16,        0x40,
            0x29,        0x01,        0xf0,
            0x06,        0xa9,        mask,
            0x05,        destination, 0x85,
            destination,
        });
    }
    emit(out, &cursor, &.{
        0xa5, 0x02,
        0x05, 0x05,
        0x85, 0x05,
        0xa5, 0x03,
        0x05, 0x06,
        0x85, 0x06,
        0xa5, 0x02,
        0x29, 0x0c,
        0xc9, 0x0c,
        0xd0, 0x07,
        0xa9, completion_witness_value,
        0x8f, 0x01,
        0x00, 0x7e,
        0xe6, 0x04,
        0x9c, 0x21,
        0x21, 0xa5,
        0x04, 0x8d,
        0x22, 0x21,
        0xa9, 0x20,
        0x8d, 0x22,
        0x21,
    });
    if (battery) emit(out, &cursor, &.{
        0xa5, 0x04,
        0x8f, 0x01,
        0x60, 0x20,
    });
    // Change the backdrop and sample the controller exactly once per field.
    // WAI is the physical 65C816 low-work path; the NMI handler above returns
    // here and keeps long product tests cycle-accurate without a polling loop.
    emit(out, &cursor, &.{0xcb}); // WAI
    const main_loop_address: u16 = @intCast(0x8000 + (main_loop - start));
    emit(out, &cursor, &.{ 0x4c, @truncate(main_loop_address), @truncate(main_loop_address >> 8) });
}

fn emit(out: []u8, cursor: *usize, bytes: []const u8) void {
    std.debug.assert(cursor.* + bytes.len <= out.len);
    @memcpy(out[cursor.* .. cursor.* + bytes.len], bytes);
    cursor.* += bytes.len;
}

fn emitBranch(out: []u8, cursor: *usize, opcode: u8, target: usize) void {
    const next = cursor.* + 2;
    const delta: isize = @as(isize, @intCast(target)) - @as(isize, @intCast(next));
    std.debug.assert(delta >= std.math.minInt(i8) and delta <= std.math.maxInt(i8));
    emit(out, cursor, &.{ opcode, @bitCast(@as(i8, @intCast(delta))) });
}

fn headerOffset(mapping: board.Mapping) usize {
    return switch (mapping) {
        .lo_rom => 0x7fc0,
        .hi_rom => 0xffc0,
        .ex_lo_rom => 0x407fc0,
        .ex_hi_rom => 0x40ffc0,
    };
}

fn romSizeCode(size: usize) u8 {
    var value = size;
    var log2: u8 = 0;
    while (value > 1) : (value >>= 1) log2 += 1;
    return log2 - 10;
}

fn finalizeChecksum(rom: []u8, header: []u8) void {
    header[0x1c] = 0;
    header[0x1d] = 0;
    header[0x1e] = 0;
    header[0x1f] = 0;
    var sum: u16 = 0;
    for (rom) |value| sum +%= value;
    const checksum = sum +% 0x01fe;
    const complement = ~checksum;
    header[0x1c] = @truncate(complement);
    header[0x1d] = @truncate(complement >> 8);
    header[0x1e] = @truncate(checksum);
    header[0x1f] = @truncate(checksum >> 8);
}

test "open E2E fixtures are deterministic executable and reject firmware or header precisely" {
    const allocator = std.testing.allocator;
    const first = try allocator.alloc(u8, imageBytes(.rom_only));
    defer allocator.free(first);
    const second = try allocator.alloc(u8, imageBytes(.rom_only));
    defer allocator.free(second);
    try build(first, .rom_only);
    try build(second, .rom_only);
    try std.testing.expectEqualSlices(u8, first, second);
    var plain = try cartridge.Cartridge.parse(allocator, first);
    defer plain.deinit();
    try std.testing.expectEqual(board.Mapping.lo_rom, plain.board.mapping);
    try std.testing.expectEqual(board.Region.ntsc_u, plain.board.region);
    try std.testing.expect(!plain.board.battery);

    const pal_image = try allocator.alloc(u8, imageBytes(.rom_only));
    defer allocator.free(pal_image);
    try buildForRegion(pal_image, .rom_only, .pal);
    var pal = try cartridge.Cartridge.parse(allocator, pal_image);
    defer pal.deinit();
    try std.testing.expectEqual(board.Region.pal, pal.board.region);
    try std.testing.expect(!std.mem.eql(u8, first, pal_image));

    const battery_image = try allocator.alloc(u8, imageBytes(.battery_rtc));
    defer allocator.free(battery_image);
    try build(battery_image, .battery_rtc);
    var battery_cart = try cartridge.Cartridge.parse(allocator, battery_image);
    defer battery_cart.deinit();
    try std.testing.expectEqual(board.Enhancement.spc7110_epson_rtc, battery_cart.board.capability.enhancement);
    try std.testing.expect(battery_cart.board.battery and battery_cart.spc7110_device.?.has_rtc);
    try std.testing.expectEqual(@as(usize, 8 * 1024), battery_cart.sram().len);

    const firmware_image = try allocator.alloc(u8, imageBytes(.firmware_required));
    defer allocator.free(firmware_image);
    try build(firmware_image, .firmware_required);
    const required = (try cartridge.inspectNecDspRequirement(firmware_image, null)).?;
    try std.testing.expectEqual(@as(usize, 8192), required.firmwareBytes());

    const invalid = try allocator.alloc(u8, imageBytes(.invalid));
    defer allocator.free(invalid);
    try build(invalid, .invalid);
    try std.testing.expectError(error.NoValidHeader, cartridge.Cartridge.parse(allocator, invalid));
}
