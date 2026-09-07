// Original, reproducible R4OS cartridge for explicit performance runs.
// The normal E2E cartridge and its compatibility identity stay independent.
const std = @import("std");
const fixture = @import("fixture_rom.zig");

pub const identity = "r4snes.active-scene.v1";
pub const image_bytes = 32 * 1024;
pub const warmup_ns: u64 = 250 * std.time.ns_per_ms;
pub const duration_ns: u64 = 3 * std.time.ns_per_s;
pub const samples: usize = 5;

pub fn build(out: []u8) !void {
    try fixture.build(out, .rom_only);
    // Eight 4-bpp tiles, shared by two backgrounds and 128 bounded sprites.
    for (0..8) |tile| {
        for (0..8) |y| {
            const at = 0x4000 + tile * 32 + y * 2;
            out[at] = @as(u8, 0x81) | (@as(u8, 0x7e) >> @as(u3, @intCast((tile + y) & 3)));
            out[at + 1] = if (y & 1 == 0) 0x55 else 0xaa;
            out[at + 16] = if (tile & 1 == 0) 0xf0 else 0x0f;
            out[at + 17] = if (tile & 2 == 0) 0x33 else 0xcc;
        }
    }
    for (0..1024) |i| {
        out[0x4800 + i * 2] = @intCast((i + i / 32) & 7);
        out[0x4801 + i * 2] = @intCast(((i / 4) & 7) << 2);
    }
    @memset(out[0x5000..0x5220], 0);
    for (0..128) |i| {
        out[0x5000 + i * 4] = @intCast((i % 16) * 16);
        out[0x5001 + i * 4] = @intCast((i / 16) * 28);
        out[0x5002 + i * 4] = @intCast(i & 7);
        out[0x5003 + i * 4] = @intCast(0x30 | ((i & 7) << 1));
    }
    for (0..256) |i| {
        const color: u16 = @intCast(((i * 3) & 31) | (((i * 7) & 31) << 5) | (((i * 11) & 31) << 10));
        out[0x5400 + i * 2] = @truncate(color);
        out[0x5401 + i * 2] = @truncate(color >> 8);
    }

    var init = Writer{ .bytes = out[0x3000..0x3800] };
    init.write(0x2100, 0x80); // Forced blank during all initial DMA uploads.
    init.write(0x2115, 0x80);
    init.write(0x2116, 0);
    init.write(0x2117, 0);
    init.dma(0xc000, 0, 256, 0x18, 1);
    init.write(0x2116, 0);
    init.write(0x2117, 0x10);
    init.dma(0xc800, 0, 2048, 0x18, 1);
    init.write(0x2102, 0);
    init.write(0x2103, 0);
    init.dma(0xd000, 0, 544, 0x04, 0);
    init.write(0x2121, 0);
    init.dma(0xd400, 0, 512, 0x22, 0);
    init.write(0x2101, 0);
    init.write(0x2105, 1);
    init.write(0x2107, 0x10);
    init.write(0x2108, 0x10);
    init.write(0x210b, 0);
    init.write(0x212c, 0x13); // BG1, BG2 and OBJ on both main and sub screens.
    init.write(0x212d, 0x13);
    init.write(0x2130, 0x02); // Subscreen color math, including backgrounds.
    init.write(0x2131, 0x43);
    init.emit(&.{ 0x4c, 0x00, 0x80 }); // Original SPC upload and WAI/controller loop.

    // Move both backgrounds and the first sprite once per vblank. DMA is
    // re-enabled every field, exposing a stale DMA-enable/WAI mirror.
    var nmi = Writer{ .bytes = out[0x0800..0x1000] };
    nmi.emit(&.{ 0x08, 0xc2, 0x20, 0x48, 0xe2, 0x20 }); // PHP; 16-bit PHA; 8-bit A.
    nmi.emit(&.{ 0xad, 0x10, 0x42, 0xe6, 0x08, 0xa5, 0x08 });
    nmi.emit(&.{ 0x8d, 0x0d, 0x21 });
    nmi.write(0x210d, 0);
    nmi.emit(&.{ 0xa5, 0x08, 0x8d, 0x10, 0x21 });
    nmi.write(0x2110, 0);
    nmi.write(0x0009, 24);
    nmi.write(0x2102, 0);
    nmi.write(0x2103, 0);
    nmi.dma(0x0008, 0x7e, 2, 0x04, 0);
    nmi.emit(&.{ 0xc2, 0x20, 0x68, 0x28, 0x40 }); // 16-bit PLA; PLP; RTI.

    const header = out[0x7fc0..0x8000];
    @memset(header[0..21], ' ');
    const title = "R4SNES ACTIVE PERF V1";
    @memcpy(header[0..title.len], title);
    header[0x3c] = 0x00;
    header[0x3d] = 0xb0;
    @memset(header[0x1c..0x20], 0);
    var sum: u16 = 0;
    for (out) |byte| sum +%= byte;
    sum +%= 0x1fe;
    header[0x1c] = @truncate(~sum);
    header[0x1d] = @truncate(~sum >> 8);
    header[0x1e] = @truncate(sum);
    header[0x1f] = @truncate(sum >> 8);
}

const Writer = struct {
    bytes: []u8,
    cursor: usize = 0,

    fn emit(self: *Writer, bytes: []const u8) void {
        @memcpy(self.bytes[self.cursor..][0..bytes.len], bytes);
        self.cursor += bytes.len;
    }

    fn write(self: *Writer, address: u16, value: u8) void {
        self.emit(&.{ 0xa9, value, 0x8d, @truncate(address), @truncate(address >> 8) });
    }

    fn dma(self: *Writer, source: u16, bank: u8, count: u16, target: u8, mode: u8) void {
        self.write(0x4300, mode);
        self.write(0x4301, target);
        self.write(0x4302, @truncate(source));
        self.write(0x4303, @truncate(source >> 8));
        self.write(0x4304, bank);
        self.write(0x4305, @truncate(count));
        self.write(0x4306, @truncate(count >> 8));
        self.write(0x420b, 1);
    }
};
