const bus = @import("bus.zig");
const timing = @import("timing.zig");

pub const frame_width: usize = 256;
pub const hires_width: usize = 512;
pub const standard_height: usize = 224;
pub const overscan_height: usize = 239;
pub const interlace_standard_height: usize = standard_height * 2;
pub const interlace_overscan_height: usize = overscan_height * 2;
pub const frame_capacity: usize = hires_width * interlace_overscan_height;
pub const vram_size: usize = 64 * 1024;
pub const cgram_size: usize = 512;
pub const oam_size: usize = 544;

const visible_h_start: u16 = 88;
const fnv_offset: u64 = 0xcbf29ce484222325;
const fnv_prime: u64 = 0x100000001b3;

pub const FrameInfo = struct {
    width: u16,
    height: u16,
    generation: u64,
    digest: u64,
};

pub const FrameDamage = struct {
    revision: u64,
    x: u16,
    y: u16,
    width: u16,
    height: u16,
};

const Background = struct {
    screen_base: u16 = 0,
    screen_size: u2 = 0,
    character_base: u16 = 0,
    tile_size_16: bool = false,
    horizontal_scroll: u16 = 0,
    vertical_scroll: u16 = 0,
};

const Candidate = struct {
    present: bool = false,
    colour: u16 = 0,
    priority: u8 = 0,
    layer: u3 = 5,
    colour_math: bool = false,
};

const Window = struct {
    one_enabled: bool = false,
    one_inverted: bool = false,
    two_enabled: bool = false,
    two_inverted: bool = false,
    logic: u2 = 0,
};

const SpriteTile = struct {
    sprite: u8,
    screen_x: i16,
    source_column: u8,
    source_row: u8,
};

/// Integer, dot-observed S-PPU base used by the private SNES machine. The
/// renderer exposes only copied complete generations; no host viewport, wait
/// policy or mutable internal surface escapes this owner.
pub const Ppu = struct {
    v_counter: u16 = 0,
    h_counter: u16 = 0,
    frame: u64 = 0,
    region: timing.Region = .ntsc,

    forced_blank: bool = true,
    brightness: u4 = 0,
    mode: u3 = 0,
    bg3_priority: bool = false,
    direct_colour: bool = false,
    overscan: bool = false,
    interlace: bool = false,
    object_interlace: bool = false,
    pseudo_hires: bool = false,
    mode7_extbg: bool = false,
    main_enable: u5 = 0,
    sub_enable: u5 = 0,
    main_window_enable: u5 = 0,
    sub_window_enable: u5 = 0,

    mosaic_size: u5 = 1,
    mosaic_enabled: [4]bool = [_]bool{false} ** 4,
    windows: [6]Window = [_]Window{.{}} ** 6,
    window_one_left: u8 = 0,
    window_one_right: u8 = 0,
    window_two_left: u8 = 0,
    window_two_right: u8 = 0,
    clip_mode: u2 = 0,
    math_window_mode: u2 = 0,
    blend_subscreen: bool = false,
    colour_math_enable: u6 = 0,
    colour_math_half: bool = false,
    colour_math_subtract: bool = false,
    fixed_colour: u16 = 0,

    mode7_repeat: u2 = 0,
    mode7_hflip: bool = false,
    mode7_vflip: bool = false,
    mode7_a: i16 = 0,
    mode7_b: i16 = 0,
    mode7_c: i16 = 0,
    mode7_d: i16 = 0,
    mode7_x: i16 = 0,
    mode7_y: i16 = 0,
    mode7_latch: u8 = 0,
    mode7_product: i32 = 0,

    vram: [vram_size]u8 = [_]u8{0} ** vram_size,
    cgram: [cgram_size]u8 = [_]u8{0} ** cgram_size,
    oam: [oam_size]u8 = [_]u8{0} ** oam_size,

    vram_address: u16 = 0,
    vram_increment: u16 = 1,
    vram_remap: u2 = 0,
    vram_increment_high: bool = true,
    vram_read_latch: u16 = 0,

    cgram_address: u8 = 0,
    cgram_second: bool = false,
    cgram_write_latch: u8 = 0,
    cgram_internal_address: u8 = 0,

    oam_base_address: u10 = 0,
    oam_address: u10 = 0,
    oam_write_latch: u8 = 0,
    oam_priority_rotation: bool = false,
    oam_internal_sprite: u7 = 0,
    object_tile_base: u16 = 0,
    object_name_select: u2 = 0,
    object_size_select: u3 = 0,

    backgrounds: [4]Background = [_]Background{.{}} ** 4,
    bg_scroll_latch: u8 = 0,
    bg_horizontal_latch: u8 = 0,

    range_over: bool = false,
    time_over: bool = false,
    sprite_line_valid: bool = false,
    sprite_line_y: u16 = 0,
    object_present: [frame_width]bool = [_]bool{false} ** frame_width,
    object_colour: [frame_width]u8 = [_]u8{0} ** frame_width,
    object_palette: [frame_width]u8 = [_]u8{0} ** frame_width,
    object_priority: [frame_width]u2 = [_]u2{0} ** frame_width,

    /// The working surface always uses the maximum native stride. Published
    /// frames are packed to their current native geometry before exposure.
    working_frame: [frame_capacity]u32 = [_]u32{0xff000000} ** frame_capacity,
    published_frame: [frame_capacity]u32 = [_]u32{0xff000000} ** frame_capacity,
    sub_line: [hires_width]u32 = [_]u32{0xff000000} ** hires_width,
    frame_generation: u64 = 0,
    frame_digest: u64 = fnv_offset,
    last_published_beam_frame: u64 = ~@as(u64, 0),
    interlace_pair_started: bool = false,
    published_width: u16 = frame_width,
    published_height: u16 = standard_height,
    damage_pending: bool = false,
    damage_min_x: u16 = 0,
    damage_min_y: u16 = 0,
    damage_max_x: u16 = 0,
    damage_max_y: u16 = 0,

    pub fn visibleHeight(self: *const Ppu) u16 {
        return if (self.overscan) overscan_height else standard_height;
    }

    pub fn nativeWidth(self: *const Ppu) u16 {
        return if (self.mode == 5 or self.mode == 6 or self.pseudo_hires) hires_width else frame_width;
    }

    pub fn nativeHeight(self: *const Ppu) u16 {
        const base = self.visibleHeight();
        return if (self.interlace) base * 2 else base;
    }

    pub fn setBeam(self: *Ppu, h: u16, v: u16, beam_frame: u64) void {
        self.h_counter = h;
        self.v_counter = v;
        self.frame = beam_frame;
    }

    /// Observe one physical master clock. Register changes affect the first
    /// not-yet-produced pixel; OAM evaluation remains scanline-latched.
    pub fn onMasterTick(self: *Ppu, clock: *const timing.Clock) void {
        self.setBeam(clock.h_counter, clock.v_counter, clock.frame);
        self.region = clock.region;
        if (clock.h_counter == 0 and clock.v_counter == 0) self.beginField(clock.field);
        const height = self.visibleHeight();
        if (clock.h_counter == 0 and clock.v_counter >= 1 and clock.v_counter <= height) {
            self.prepareSpriteLine(clock.v_counter - 1);
        }
        const width = self.nativeWidth();
        const clocks_per_pixel: u16 = if (width == hires_width) 2 else 4;
        if (clock.v_counter >= 1 and clock.v_counter <= height and
            clock.h_counter >= visible_h_start and clock.h_counter < visible_h_start + width * clocks_per_pixel and
            (clock.h_counter - visible_h_start) % clocks_per_pixel == 0)
        {
            const x: u16 = (clock.h_counter - visible_h_start) / clocks_per_pixel;
            self.renderPixel(x, clock.v_counter - 1, clock.field);
        }
        if (clock.h_counter == 0 and clock.v_counter == height + 1 and
            self.last_published_beam_frame != clock.frame)
        {
            if (!self.interlace or (clock.field and self.interlace_pair_started)) {
                self.publishFrame(clock.frame);
                self.interlace_pair_started = false;
            }
            self.last_published_beam_frame = clock.frame;
        }
    }

    pub fn renderScanline(self: *Ppu, y: u16) void {
        self.renderScanlineField(y, false);
    }

    fn renderScanlineField(self: *Ppu, y: u16, field: bool) void {
        if (y >= self.visibleHeight()) return;
        self.prepareSpriteLine(y);
        var x: u16 = 0;
        while (x < self.nativeWidth()) : (x += 1) self.renderPixel(x, y, field);
    }

    /// Deterministic model entry point for unit/reference oracles. Production
    /// execution advances through onMasterTick instead.
    pub fn renderCompleteFrame(self: *Ppu) FrameInfo {
        self.beginField(false);
        var y: u16 = 0;
        while (y < self.visibleHeight()) : (y += 1) self.renderScanlineField(y, false);
        if (self.interlace) {
            y = 0;
            while (y < self.visibleHeight()) : (y += 1) self.renderScanlineField(y, true);
        }
        self.publishFrame(self.frame);
        self.interlace_pair_started = false;
        return self.frameInfo();
    }

    pub fn frameInfo(self: *const Ppu) FrameInfo {
        return .{
            .width = self.published_width,
            .height = self.published_height,
            .generation = self.frame_generation,
            .digest = self.frame_digest,
        };
    }

    pub fn copyFrame(self: *const Ppu, destination: []u32) !FrameInfo {
        const count = @as(usize, self.published_width) * self.published_height;
        if (destination.len < count) return error.FrameBufferTooSmall;
        @memcpy(destination[0..count], self.published_frame[0..count]);
        return self.frameInfo();
    }

    pub fn takeDamage(self: *Ppu) ?FrameDamage {
        if (!self.damage_pending) return null;
        self.damage_pending = false;
        return .{
            .revision = self.frame_generation,
            .x = self.damage_min_x,
            .y = self.damage_min_y,
            .width = self.damage_max_x - self.damage_min_x + 1,
            .height = self.damage_max_y - self.damage_min_y + 1,
        };
    }

    pub fn synchronizeClock(self: *const Ppu, clock: *timing.Clock) void {
        clock.interlace = self.interlace;
    }

    pub fn memoryDigest(self: *const Ppu) u64 {
        var digest = fnv_offset;
        for (self.vram) |value| digest = mix(digest, value);
        for (self.cgram) |value| digest = mix(digest, value);
        for (self.oam) |value| digest = mix(digest, value);
        return digest;
    }

    pub fn read(self: *Ppu, address: u32, _: u8, ppu_open_bus: u8) bus.MmioRead {
        const offset: u16 = @truncate(address);
        const value: u8 = switch (offset) {
            0x2134 => @truncate(@as(u32, @bitCast(self.mode7_product))),
            0x2135 => @truncate(@as(u32, @bitCast(self.mode7_product)) >> 8),
            0x2136 => @truncate(@as(u32, @bitCast(self.mode7_product)) >> 16),
            0x2138 => self.readOam(),
            0x2139 => self.readVram(false),
            0x213a => self.readVram(true),
            0x213b => self.readCgram(ppu_open_bus),
            0x213e => (if (self.time_over) @as(u8, 0x80) else 0) |
                (if (self.range_over) @as(u8, 0x40) else 0) | 0x01,
            0x213f => (ppu_open_bus & 0x20) |
                (if (self.region == .pal) @as(u8, 0x10) else 0) | 0x03,
            else => if (offset >= 0x2100 and offset <= 0x213f) ppu_open_bus else return .{},
        };
        return .{ .handled = true, .value = value, .latch = .ppu };
    }

    pub fn write(self: *Ppu, address: u32, value: u8, _: u8, _: u8) bool {
        const offset: u16 = @truncate(address);
        switch (offset) {
            0x2100 => {
                self.forced_blank = (value & 0x80) != 0;
                self.brightness = @truncate(value);
            },
            0x2101 => {
                self.object_tile_base = @as(u16, value & 0x07) << 13;
                self.object_name_select = @truncate(value >> 3);
                self.object_size_select = @truncate(value >> 5);
                self.sprite_line_valid = false;
            },
            0x2102 => {
                self.oam_base_address = (self.oam_base_address & 0x200) | (@as(u10, value) << 1);
                self.oam_address = self.oam_base_address;
            },
            0x2103 => {
                self.oam_base_address = (self.oam_base_address & 0x1ff) | (@as(u10, value & 1) << 9);
                self.oam_address = self.oam_base_address;
                self.oam_priority_rotation = (value & 0x80) != 0;
                self.sprite_line_valid = false;
            },
            0x2104 => self.writeOam(value),
            0x2105 => {
                self.mode = @truncate(value);
                self.bg3_priority = (value & 0x08) != 0;
                for (0..4) |index| self.backgrounds[index].tile_size_16 = (value & (@as(u8, 0x10) << @intCast(index))) != 0;
            },
            0x2106 => {
                self.mosaic_size = @intCast((value >> 4) + 1);
                for (0..4) |index| self.mosaic_enabled[index] = (value & (@as(u8, 1) << @intCast(index))) != 0;
            },
            0x2107...0x210a => {
                const index: usize = offset - 0x2107;
                self.backgrounds[index].screen_base = @as(u16, value & 0xfc) << 8;
                self.backgrounds[index].screen_size = @truncate(value);
            },
            0x210b => {
                self.backgrounds[0].character_base = @as(u16, value & 0x0f) << 12;
                self.backgrounds[1].character_base = @as(u16, value >> 4) << 12;
            },
            0x210c => {
                self.backgrounds[2].character_base = @as(u16, value & 0x0f) << 12;
                self.backgrounds[3].character_base = @as(u16, value >> 4) << 12;
            },
            0x210d, 0x210f, 0x2111, 0x2113 => self.writeHorizontalScroll((offset - 0x210d) >> 1, value),
            0x210e, 0x2110, 0x2112, 0x2114 => self.writeVerticalScroll((offset - 0x210e) >> 1, value),
            0x2115 => {
                const increments = [_]u16{ 1, 32, 128, 128 };
                self.vram_increment = increments[value & 3];
                self.vram_remap = @truncate(value >> 2);
                self.vram_increment_high = (value & 0x80) != 0;
            },
            0x2116 => {
                self.vram_address = (self.vram_address & 0xff00) | value;
                self.prefetchVram();
            },
            0x2117 => {
                self.vram_address = (self.vram_address & 0x00ff) | (@as(u16, value) << 8);
                self.prefetchVram();
            },
            0x2118 => self.writeVram(false, value),
            0x2119 => self.writeVram(true, value),
            0x211a => {
                self.mode7_repeat = @truncate(value >> 6);
                self.mode7_vflip = (value & 0x02) != 0;
                self.mode7_hflip = (value & 0x01) != 0;
            },
            0x211b => self.writeMode7(&self.mode7_a, value, true),
            0x211c => self.writeMode7(&self.mode7_b, value, true),
            0x211d => self.writeMode7(&self.mode7_c, value, false),
            0x211e => self.writeMode7(&self.mode7_d, value, false),
            0x211f => self.writeMode7(&self.mode7_x, value, false),
            0x2120 => self.writeMode7(&self.mode7_y, value, false),
            0x2121 => {
                self.cgram_address = value;
                self.cgram_second = false;
            },
            0x2122 => self.writeCgram(value),
            0x2123 => {
                self.writeWindowSelection(0, value & 0x0f);
                self.writeWindowSelection(1, value >> 4);
            },
            0x2124 => {
                self.writeWindowSelection(2, value & 0x0f);
                self.writeWindowSelection(3, value >> 4);
            },
            0x2125 => {
                self.writeWindowSelection(4, value & 0x0f);
                self.writeWindowSelection(5, value >> 4);
            },
            0x2126 => self.window_one_left = value,
            0x2127 => self.window_one_right = value,
            0x2128 => self.window_two_left = value,
            0x2129 => self.window_two_right = value,
            0x212a => {
                for (0..4) |index| self.windows[index].logic = @truncate(value >> @intCast(index * 2));
            },
            0x212b => {
                self.windows[4].logic = @truncate(value);
                self.windows[5].logic = @truncate(value >> 2);
            },
            0x212c => self.main_enable = @truncate(value),
            0x212d => self.sub_enable = @truncate(value),
            0x212e => self.main_window_enable = @truncate(value),
            0x212f => self.sub_window_enable = @truncate(value),
            0x2130 => {
                self.direct_colour = (value & 0x01) != 0;
                self.blend_subscreen = (value & 0x02) != 0;
                self.math_window_mode = @truncate(value >> 4);
                self.clip_mode = @truncate(value >> 6);
            },
            0x2131 => {
                self.colour_math_enable = @truncate(value);
                self.colour_math_half = (value & 0x40) != 0;
                self.colour_math_subtract = (value & 0x80) != 0;
            },
            0x2132 => {
                const component: u16 = value & 0x1f;
                if ((value & 0x20) != 0) self.fixed_colour = (self.fixed_colour & ~@as(u16, 0x001f)) | component;
                if ((value & 0x40) != 0) self.fixed_colour = (self.fixed_colour & ~@as(u16, 0x03e0)) | (component << 5);
                if ((value & 0x80) != 0) self.fixed_colour = (self.fixed_colour & ~@as(u16, 0x7c00)) | (component << 10);
            },
            0x2133 => {
                self.interlace = (value & 0x01) != 0;
                self.object_interlace = (value & 0x02) != 0;
                self.overscan = (value & 0x04) != 0;
                self.pseudo_hires = (value & 0x08) != 0;
                self.mode7_extbg = (value & 0x40) != 0;
            },
            else => if (offset < 0x2100 or offset > 0x213f) return false,
        }
        return true;
    }

    fn writeMode7(self: *Ppu, target: *i16, value: u8, update_product: bool) void {
        target.* = @bitCast((@as(u16, value) << 8) | self.mode7_latch);
        self.mode7_latch = value;
        if (update_product) {
            const multiplier: i8 = @bitCast(@as(u8, @truncate(@as(u16, @bitCast(self.mode7_b)) >> 8)));
            self.mode7_product = @as(i32, self.mode7_a) * @as(i32, multiplier);
        }
    }

    fn writeWindowSelection(self: *Ppu, index: usize, value: u8) void {
        self.windows[index].one_inverted = (value & 0x01) != 0;
        self.windows[index].one_enabled = (value & 0x02) != 0;
        self.windows[index].two_inverted = (value & 0x04) != 0;
        self.windows[index].two_enabled = (value & 0x08) != 0;
    }

    fn beginField(self: *Ppu, field: bool) void {
        if (!self.interlace) {
            @memset(self.working_frame[0..], 0xff000000);
            self.interlace_pair_started = false;
        } else if (!field) {
            @memset(self.working_frame[0..], 0xff000000);
            self.interlace_pair_started = true;
        } else if (!self.interlace_pair_started) {
            @memset(self.working_frame[0..], 0xff000000);
        }
        self.range_over = false;
        self.time_over = false;
        self.sprite_line_valid = false;
        self.oam_address = self.oam_base_address;
    }

    fn publishFrame(self: *Ppu, beam_frame: u64) void {
        const width = self.nativeWidth();
        const height = self.nativeHeight();
        const count = @as(usize, width) * height;
        const geometry_changed = width != self.published_width or height != self.published_height or self.frame_generation == 0;
        var changed = geometry_changed;
        var min_x: u16 = width;
        var min_y: u16 = height;
        var max_x: u16 = 0;
        var max_y: u16 = 0;
        var y: u16 = 0;
        while (y < height) : (y += 1) {
            var x: u16 = 0;
            while (x < width) : (x += 1) {
                const destination = @as(usize, y) * width + x;
                const next = self.working_frame[@as(usize, y) * hires_width + x];
                if (!geometry_changed and self.published_frame[destination] != next) {
                    changed = true;
                    min_x = @min(min_x, x);
                    min_y = @min(min_y, y);
                    max_x = @max(max_x, x);
                    max_y = @max(max_y, y);
                }
                self.published_frame[destination] = next;
            }
        }
        if (!changed) {
            self.last_published_beam_frame = beam_frame;
            return;
        }
        if (count < frame_capacity) @memset(self.published_frame[count..], 0xff000000);
        var digest = fnv_offset;
        for (self.published_frame[0..count]) |pixel| {
            digest = mix(digest, @truncate(pixel));
            digest = mix(digest, @truncate(pixel >> 8));
            digest = mix(digest, @truncate(pixel >> 16));
            digest = mix(digest, @truncate(pixel >> 24));
        }
        self.frame_digest = digest;
        self.frame_generation +%= 1;
        self.published_width = width;
        self.published_height = height;
        self.damage_pending = true;
        if (geometry_changed) {
            self.damage_min_x = 0;
            self.damage_min_y = 0;
            self.damage_max_x = width - 1;
            self.damage_max_y = height - 1;
        } else {
            self.damage_min_x = min_x;
            self.damage_min_y = min_y;
            self.damage_max_x = max_x;
            self.damage_max_y = max_y;
        }
        self.last_published_beam_frame = beam_frame;
    }

    fn renderPixel(self: *Ppu, x: u16, y: u16, field: bool) void {
        if (!self.sprite_line_valid or self.sprite_line_y != y) self.prepareSpriteLine(y);
        const output_y: u16 = if (self.interlace) y * 2 + @intFromBool(field) else y;
        const index = @as(usize, output_y) * hires_width + x;
        if (self.forced_blank) {
            self.working_frame[index] = 0xff000000;
            self.sub_line[x] = 0xff000000;
            return;
        }
        const logical_x: u16 = if (self.nativeWidth() == hires_width) x >> 1 else x;
        const layer_x: u16 = if (self.mode == 5 or self.mode == 6) x else logical_x;
        const main = self.outputCandidate(self.main_enable, self.main_window_enable, layer_x, logical_x, y, field);
        const sub = self.outputCandidate(self.sub_enable, self.sub_window_enable, layer_x, logical_x, y, field);
        const main_colour = self.composeMain(main, sub, logical_x);
        const output_colour = if ((self.pseudo_hires or self.mode == 5 or self.mode == 6) and (x & 1) == 0)
            self.composeMain(sub, main, logical_x)
        else
            main_colour;
        self.working_frame[index] = self.toXrgb(output_colour);
        self.sub_line[x] = self.toXrgb(sub.colour);
    }

    fn outputCandidate(self: *Ppu, enable: u5, window_enable: u5, raw_x: u16, logical_x: u16, y: u16, field: bool) Candidate {
        var best = Candidate{ .present = true, .colour = self.colour(0), .priority = 0, .layer = 5 };
        for (0..4) |index| {
            if ((enable & (@as(u5, 1) << @intCast(index))) == 0) continue;
            if ((window_enable & (@as(u5, 1) << @intCast(index))) != 0 and self.windowTest(index, @truncate(logical_x))) continue;
            const candidate = self.backgroundPixel(index, raw_x, y, field);
            if (candidate.present and candidate.priority > best.priority) best = candidate;
        }
        if ((enable & 0x10) != 0 and ((window_enable & 0x10) == 0 or !self.windowTest(4, @truncate(logical_x))) and self.object_present[logical_x]) {
            const candidate = Candidate{
                .present = true,
                .colour = self.colour(@as(u16, 128) + @as(u16, self.object_palette[logical_x]) * 16 + self.object_colour[logical_x]),
                .priority = objectPriority(self.mode, self.bg3_priority, self.object_priority[logical_x]),
                .layer = 4,
            };
            if (candidate.priority > best.priority) best = candidate;
        }
        best.colour_math = (self.colour_math_enable & (@as(u6, 1) << best.layer)) != 0 and
            (best.layer != 4 or self.object_palette[logical_x] >= 4);
        return best;
    }

    fn backgroundPixel(self: *Ppu, index: usize, raw_x: u16, raw_y: u16, field: bool) Candidate {
        if (self.mode == 7) return self.mode7Pixel(index, raw_x, raw_y);
        const bpp = bitsPerPixel(self.mode, index) orelse return .{};
        const hires = self.mode == 5 or self.mode == 6;
        const horizontal_scale: u16 = if (self.nativeWidth() == hires_width and !hires) 2 else 1;
        const mosaic_span: u16 = if (self.mosaic_enabled[index]) @as(u16, self.mosaic_size) * horizontal_scale else 1;
        const sample_x = raw_x - raw_x % mosaic_span;
        var interlace_y: u16 = raw_y;
        if (hires and self.interlace) interlace_y = raw_y * 2 + @intFromBool(field and !self.mosaic_enabled[index]);
        const sample_y = if (self.mosaic_enabled[index]) interlace_y - interlace_y % self.mosaic_size else interlace_y;
        const scroll_x = self.backgrounds[index].horizontal_scroll *% (if (hires) @as(u16, 2) else 1);
        var x: u16 = sample_x +% scroll_x;
        var y: u16 = sample_y +% self.backgrounds[index].vertical_scroll;
        self.applyOffsetPerTile(index, sample_x, sample_y, &x, &y);

        const bg = self.backgrounds[index];
        const tile_width: u16 = if (hires or bg.tile_size_16) 16 else 8;
        const tile_height: u16 = if (bg.tile_size_16) 16 else 8;
        const tile_x: u16 = x / tile_width;
        const tile_y: u16 = y / tile_height;
        const entry = self.tilemapEntry(index, tile_x, tile_y);
        const high_priority = (entry & 0x2000) != 0;
        const horizontal_flip = (entry & 0x4000) != 0;
        const vertical_flip = (entry & 0x8000) != 0;
        var pixel_x: u8 = @truncate(x % tile_width);
        var pixel_y: u8 = @truncate(y % tile_height);
        if (horizontal_flip) pixel_x = @as(u8, @intCast(tile_width - 1)) - pixel_x;
        if (vertical_flip) pixel_y = @as(u8, @intCast(tile_height - 1)) - pixel_y;

        var character: u16 = entry & 0x03ff;
        if (hires or bg.tile_size_16) character +%= pixel_x >> 3;
        if (bg.tile_size_16) character +%= @as(u16, pixel_y >> 3) << 4;
        pixel_x &= 7;
        pixel_y &= 7;
        const colour_index = self.planarPixel(bg.character_base, character, bpp, pixel_x, pixel_y);
        if (colour_index == 0) return .{};
        const group: u3 = @truncate(entry >> 10);
        const colour_word = if (self.direct_colour and index == 0 and (self.mode == 3 or self.mode == 4) and bpp == 8)
            directColour(group, colour_index)
        else
            self.colour(backgroundPaletteIndex(self.mode, index, bpp, group, colour_index));
        return .{
            .present = true,
            .colour = colour_word,
            .priority = backgroundPriority(self.mode, self.bg3_priority, index, high_priority),
            .layer = @truncate(index),
        };
    }

    fn mode7Pixel(self: *Ppu, index: usize, raw_x: u16, raw_y: u16) Candidate {
        if (index > 1 or (index == 1 and !self.mode7_extbg)) return .{};
        const sample_span: u16 = if (self.mosaic_enabled[0]) self.mosaic_size else 1;
        var x: i32 = @intCast(raw_x - raw_x % sample_span);
        var y: i32 = @intCast(raw_y - raw_y % sample_span);
        if (self.mode7_hflip) x = 255 - x;
        if (self.mode7_vflip) y = 255 - y;

        const hofs = signed13(self.backgrounds[0].horizontal_scroll);
        const vofs = signed13(self.backgrounds[0].vertical_scroll);
        const center_x: i32 = signed13(@bitCast(self.mode7_x));
        const center_y: i32 = signed13(@bitCast(self.mode7_y));
        const a: i32 = self.mode7_a;
        const b: i32 = self.mode7_b;
        const c: i32 = self.mode7_c;
        const d: i32 = self.mode7_d;
        const origin_x = (a * clipMode7(hofs - center_x) & ~@as(i32, 63)) +
            (b * clipMode7(vofs - center_y) & ~@as(i32, 63)) + (b * y & ~@as(i32, 63)) + center_x * 256;
        const origin_y = (c * clipMode7(hofs - center_x) & ~@as(i32, 63)) +
            (d * clipMode7(vofs - center_y) & ~@as(i32, 63)) + (d * y & ~@as(i32, 63)) + center_y * 256;
        const pixel_x = (origin_x + a * x) >> 8;
        const pixel_y = (origin_y + c * x) >> 8;
        const outside = ((pixel_x | pixel_y) & ~@as(i32, 1023)) != 0;
        if (outside and self.mode7_repeat == 1) return .{};
        const palette_address: u16 = @intCast(((pixel_y & 7) << 3) | (pixel_x & 7));
        const tile_x: u16 = @intCast((pixel_x >> 3) & 127);
        const tile_y: u16 = @intCast((pixel_y >> 3) & 127);
        const tile_address: u16 = (tile_y << 7) | tile_x;
        const tile: u8 = if (outside and self.mode7_repeat == 3) 0 else @truncate(self.vramWord(tile_address));
        var palette: u8 = if (outside and self.mode7_repeat == 2)
            0
        else
            @truncate(self.vramWord(@as(u16, tile) * 64 + palette_address) >> 8);
        if (index == 0) {
            if (palette == 0) return .{};
            const colour_word = if (self.direct_colour) directColour(0, palette) else self.colour(palette);
            return .{ .present = true, .colour = colour_word, .priority = if (self.mode7_extbg) 3 else 2, .layer = 0 };
        }
        const high = (palette & 0x80) != 0;
        palette &= 0x7f;
        if (palette == 0) return .{};
        return .{ .present = true, .colour = self.colour(palette), .priority = if (high) 5 else 1, .layer = 1 };
    }

    fn composeMain(self: *Ppu, main: Candidate, sub: Candidate, logical_x: u16) u16 {
        const inside = self.windowTest(5, @truncate(logical_x));
        const above_allowed = maskAllows(self.clip_mode, inside);
        var colour_word: u16 = if (above_allowed) main.colour else 0;
        if (!main.colour_math or !maskAllows(self.math_window_mode, inside)) return colour_word;
        const hires = self.pseudo_hires or self.mode == 5 or self.mode == 6;
        const operand: u16 = if (!self.blend_subscreen)
            self.fixed_colour
        else if (sub.layer == 5 and !hires)
            self.fixed_colour
        else
            sub.colour;
        const halve = self.colour_math_half and above_allowed and (!self.blend_subscreen or sub.layer != 5);
        colour_word = blendColour(colour_word, operand, self.colour_math_subtract, halve);
        return colour_word;
    }

    fn windowTest(self: *const Ppu, index: usize, x: u8) bool {
        const config = self.windows[index];
        const one = x >= self.window_one_left and x <= self.window_one_right;
        const two = x >= self.window_two_left and x <= self.window_two_right;
        const first = one != config.one_inverted;
        const second = two != config.two_inverted;
        if (!config.one_enabled and !config.two_enabled) return false;
        if (!config.one_enabled) return second;
        if (!config.two_enabled) return first;
        return switch (config.logic) {
            0 => first or second,
            1 => first and second,
            2 => first != second,
            3 => first == second,
        };
    }

    fn applyOffsetPerTile(self: *Ppu, index: usize, raw_x: u16, raw_y: u16, x: *u16, y: *u16) void {
        if (index >= 2 or (self.mode != 2 and self.mode != 4 and self.mode != 6)) return;
        const hires = self.mode == 6;
        const first_column: u16 = if (hires) 16 else 8;
        if (raw_x < first_column) return;
        const offset_scroll = self.backgrounds[2].horizontal_scroll *% (if (hires) @as(u16, 2) else 1);
        const offset_x = raw_x +% (offset_scroll & ~@as(u16, 7)) -% first_column;
        const offset_y = raw_y +% self.backgrounds[2].vertical_scroll;
        const horizontal = self.tilemapWordAtPixel(2, offset_x, offset_y);
        const valid: u16 = @as(u16, 1) << @intCast(13 + index);
        if (self.mode == 2 or self.mode == 6) {
            const target_fine = (self.backgrounds[index].horizontal_scroll *% (if (hires) @as(u16, 2) else 1)) & 7;
            if ((horizontal & valid) != 0) x.* = (horizontal & 0x1ff8) +% target_fine +% raw_x;
            const vertical = self.tilemapWordAtPixel(2, offset_x, offset_y +% 8);
            if ((vertical & valid) != 0) y.* = (vertical & 0x1fff) +% raw_y;
        } else if ((horizontal & valid) != 0) {
            if ((horizontal & 0x8000) != 0)
                y.* = (horizontal & 0x1fff) +% raw_y
            else
                x.* = (horizontal & 0x1ff8) +% (self.backgrounds[index].horizontal_scroll & 7) +% raw_x;
        }
    }

    fn tilemapWordAtPixel(self: *const Ppu, index: usize, x: u16, y: u16) u16 {
        const width: u16 = if (self.mode == 5 or self.mode == 6 or self.backgrounds[index].tile_size_16) 16 else 8;
        const height: u16 = if (self.backgrounds[index].tile_size_16) 16 else 8;
        return self.tilemapEntry(index, x / width, y / height);
    }

    fn tilemapEntry(self: *const Ppu, index: usize, raw_tile_x: u16, raw_tile_y: u16) u16 {
        const bg = self.backgrounds[index];
        const width: u16 = if ((bg.screen_size & 1) != 0) 64 else 32;
        const height: u16 = if ((bg.screen_size & 2) != 0) 64 else 32;
        const tile_x = raw_tile_x % width;
        const tile_y = raw_tile_y % height;
        const horizontal_block: u16 = if (tile_x >= 32) 1024 else 0;
        const vertical_block: u16 = if (tile_y >= 32) (if (width == 64) 2048 else 1024) else 0;
        const word_address = (bg.screen_base +% horizontal_block +% vertical_block +%
            ((tile_y & 31) << 5) +% (tile_x & 31)) & 0x7fff;
        return self.vramWord(word_address);
    }

    fn planarPixel(self: *const Ppu, character_base: u16, character: u16, bpp: u4, x: u8, y: u8) u8 {
        const words_per_character: u16 = @as(u16, bpp) * 4;
        const base = character_base +% character *% words_per_character;
        const mask: u8 = @as(u8, 0x80) >> @intCast(x & 7);
        var result: u8 = 0;
        var pair: u4 = 0;
        while (pair < bpp / 2) : (pair += 1) {
            const word = self.vramWord(base +% @as(u16, pair) * 8 +% y);
            if ((@as(u8, @truncate(word)) & mask) != 0) result |= @as(u8, 1) << @intCast(pair * 2);
            if ((@as(u8, @truncate(word >> 8)) & mask) != 0) result |= @as(u8, 2) << @intCast(pair * 2);
        }
        return result;
    }

    pub fn prepareSpriteLine(self: *Ppu, y: u16) void {
        @memset(self.object_present[0..], false);
        @memset(self.object_colour[0..], 0);
        @memset(self.object_palette[0..], 0);
        @memset(self.object_priority[0..], 0);
        self.sprite_line_y = y;
        self.sprite_line_valid = true;

        var selected: [32]u8 = undefined;
        var selected_count: usize = 0;
        const first: u8 = if (self.oam_priority_rotation) @truncate(self.oam_base_address >> 2) else 0;
        var ordinal: u16 = 0;
        while (ordinal < 128) : (ordinal += 1) {
            const sprite: u8 = @truncate(@as(u16, first) +% ordinal);
            const base = @as(usize, sprite) * 4;
            const high = self.oam[512 + @as(usize, sprite >> 2)];
            const shift: u3 = @truncate((sprite & 3) * 2);
            const large = ((high >> shift) & 2) != 0;
            const height = spriteHeight(self.object_size_select, large);
            const delta: u8 = @truncate(y -% self.oam[base + 1]);
            if (delta >= height) continue;
            self.oam_internal_sprite = @truncate(sprite);
            if (selected_count == selected.len) {
                self.range_over = true;
                break;
            }
            selected[selected_count] = sprite;
            selected_count += 1;
        }

        var tiles: [34]SpriteTile = undefined;
        var tile_count: usize = 0;
        for (selected[0..selected_count]) |sprite| {
            const base = @as(usize, sprite) * 4;
            const high = self.oam[512 + @as(usize, sprite >> 2)];
            const shift: u3 = @truncate((sprite & 3) * 2);
            const large = ((high >> shift) & 2) != 0;
            const width = spriteWidth(self.object_size_select, large);
            const height = spriteHeight(self.object_size_select, large);
            var screen_x: i16 = self.oam[base];
            if (((high >> shift) & 1) != 0) screen_x += 256;
            if (screen_x >= 256) screen_x -= 512;
            const attributes = self.oam[base + 3];
            var source_row: u8 = @truncate(y -% self.oam[base + 1]);
            if ((attributes & 0x80) != 0) source_row = height - 1 - source_row;

            const columns: u8 = width / 8;
            var column: u8 = 0;
            while (column < columns) : (column += 1) {
                const tile_x = screen_x + @as(i16, column) * 8;
                if (tile_x <= -8 or tile_x >= 256) continue;
                if (tile_count == tiles.len) {
                    self.time_over = true;
                    break;
                }
                tiles[tile_count] = .{
                    .sprite = sprite,
                    .screen_x = tile_x,
                    .source_column = if ((attributes & 0x40) != 0) columns - 1 - column else column,
                    .source_row = source_row,
                };
                tile_count += 1;
            }
            if (self.time_over) break;
        }

        var tile_index = tile_count;
        while (tile_index > 0) {
            tile_index -= 1;
            self.drawSpriteTile(tiles[tile_index]);
        }
    }

    fn drawSpriteTile(self: *Ppu, tile: SpriteTile) void {
        const base = @as(usize, tile.sprite) * 4;
        const character = self.oam[base + 2];
        const attributes = self.oam[base + 3];
        const row_tile: u8 = tile.source_row >> 3;
        const character_x: u8 = (character & 0x0f) +% tile.source_column;
        const character_y: u8 = (character >> 4) +% row_tile;
        const tile_number: u16 = (@as(u16, character_y & 0x0f) << 4) | (character_x & 0x0f);
        var tile_base = self.object_tile_base;
        if ((attributes & 1) != 0) tile_base +%= (@as(u16, self.object_name_select) + 1) << 12;
        const row: u8 = tile.source_row & 7;
        const word0 = self.vramWord(tile_base +% tile_number *% 16 +% row);
        const word1 = self.vramWord(tile_base +% tile_number *% 16 +% 8 +% row);
        var output_x: u8 = 0;
        while (output_x < 8) : (output_x += 1) {
            const screen_x = tile.screen_x + output_x;
            if (screen_x < 0 or screen_x >= frame_width) continue;
            const source_x: u8 = if ((attributes & 0x40) != 0) 7 - output_x else output_x;
            const mask: u8 = @as(u8, 0x80) >> @intCast(source_x);
            var colour_index: u8 = 0;
            if ((@as(u8, @truncate(word0)) & mask) != 0) colour_index |= 1;
            if ((@as(u8, @truncate(word0 >> 8)) & mask) != 0) colour_index |= 2;
            if ((@as(u8, @truncate(word1)) & mask) != 0) colour_index |= 4;
            if ((@as(u8, @truncate(word1 >> 8)) & mask) != 0) colour_index |= 8;
            if (colour_index == 0) continue;
            const index: usize = @intCast(screen_x);
            self.object_present[index] = true;
            self.object_colour[index] = colour_index;
            self.object_palette[index] = @truncate(attributes >> 1);
            self.object_priority[index] = @truncate(attributes >> 4);
        }
    }

    fn writeHorizontalScroll(self: *Ppu, index: usize, value: u8) void {
        self.backgrounds[index].horizontal_scroll = (@as(u16, value) << 8) |
            (@as(u16, self.bg_scroll_latch) & 0xf8) | (self.bg_horizontal_latch & 7);
        self.bg_scroll_latch = value;
        self.bg_horizontal_latch = value;
    }

    fn writeVerticalScroll(self: *Ppu, index: usize, value: u8) void {
        self.backgrounds[index].vertical_scroll = (@as(u16, value) << 8) | self.bg_scroll_latch;
        self.bg_scroll_latch = value;
    }

    fn remappedVramAddress(self: *const Ppu) u16 {
        const address = self.vram_address;
        return switch (self.vram_remap) {
            0 => address,
            1 => (address & 0xff00) | ((address & 0x001f) << 3) | ((address & 0x00e0) >> 5),
            2 => (address & 0xfe00) | ((address & 0x003f) << 3) | ((address & 0x01c0) >> 6),
            3 => (address & 0xfc00) | ((address & 0x007f) << 3) | ((address & 0x0380) >> 7),
        };
    }

    fn prefetchVram(self: *Ppu) void {
        self.vram_read_latch = if (self.vramAccessible()) self.vramWord(self.remappedVramAddress()) else 0;
    }

    fn incrementVram(self: *Ppu) void {
        self.vram_address +%= self.vram_increment;
        self.prefetchVram();
    }

    fn writeVram(self: *Ppu, high: bool, value: u8) void {
        if (self.vramAccessible()) {
            const index = @as(usize, self.remappedVramAddress()) * 2 + @intFromBool(high);
            self.vram[index] = value;
        }
        if (high == self.vram_increment_high) self.incrementVram();
    }

    fn readVram(self: *Ppu, high: bool) u8 {
        const value: u8 = if (self.vramAccessible())
            (if (high) @truncate(self.vram_read_latch >> 8) else @truncate(self.vram_read_latch))
        else
            0;
        if (high == self.vram_increment_high) self.incrementVram();
        return value;
    }

    fn vramAccessible(self: *const Ppu) bool {
        return self.forced_blank or self.v_counter > self.visibleHeight();
    }

    fn vramWord(self: *const Ppu, raw_word: u16) u16 {
        const word = raw_word & 0x7fff;
        const index = @as(usize, word) * 2;
        return self.vram[index] | (@as(u16, self.vram[index + 1]) << 8);
    }

    fn writeCgram(self: *Ppu, value: u8) void {
        const address = self.cgramMappedAddress();
        const index = @as(usize, address) * 2;
        if (!self.cgram_second) {
            self.cgram_write_latch = value;
        } else {
            self.cgram[index] = self.cgram_write_latch;
            self.cgram[index + 1] = value & 0x7f;
            self.cgram_address +%= 1;
        }
        self.cgram_second = !self.cgram_second;
    }

    fn readCgram(self: *Ppu, open_bus: u8) u8 {
        const address = self.cgramMappedAddress();
        const index = @as(usize, address) * 2;
        const value = if (!self.cgram_second) self.cgram[index] else (self.cgram[index + 1] & 0x7f) | (open_bus & 0x80);
        if (self.cgram_second) self.cgram_address +%= 1;
        self.cgram_second = !self.cgram_second;
        return value;
    }

    fn cgramMappedAddress(self: *const Ppu) u8 {
        return if (self.activeCgramWindow()) self.cgram_internal_address else self.cgram_address;
    }

    fn activeCgramWindow(self: *const Ppu) bool {
        return !self.forced_blank and self.v_counter >= 1 and self.v_counter <= self.visibleHeight() and
            self.h_counter >= visible_h_start and self.h_counter < timing.hblank_start_master_cycle;
    }

    fn colour(self: *Ppu, index: u16) u16 {
        self.cgram_internal_address = @truncate(index);
        const byte = @as(usize, index & 0xff) * 2;
        return (self.cgram[byte] | (@as(u16, self.cgram[byte + 1]) << 8)) & 0x7fff;
    }

    fn writeOam(self: *Ppu, value: u8) void {
        const scanline_latched = self.activeOamWindow();
        const raw = self.oamMappedAddress();
        if ((raw & 0x200) == 0 and (raw & 1) == 0) {
            self.oam_write_latch = value;
        } else if ((raw & 0x200) == 0) {
            self.oam[oamPhysical(raw -% 1)] = self.oam_write_latch;
            self.oam[oamPhysical(raw)] = value;
            if (!scanline_latched) self.sprite_line_valid = false;
        } else {
            self.oam[oamPhysical(raw)] = value;
            if (!scanline_latched) self.sprite_line_valid = false;
        }
        self.oam_address +%= 1;
    }

    fn readOam(self: *Ppu) u8 {
        const value = self.oam[oamPhysical(self.oamMappedAddress())];
        self.oam_address +%= 1;
        return value;
    }

    fn oamMappedAddress(self: *const Ppu) u10 {
        if (!self.activeOamWindow()) return self.oam_address;
        if ((self.oam_address & 0x200) != 0) return 0x200 | (@as(u10, self.oam_internal_sprite) >> 2);
        return (@as(u10, self.oam_internal_sprite) << 2) | (self.oam_address & 3);
    }

    fn activeOamWindow(self: *const Ppu) bool {
        return !self.forced_blank and self.v_counter >= 1 and self.v_counter <= self.visibleHeight() and
            self.h_counter < timing.hblank_start_master_cycle;
    }

    fn toXrgb(self: *const Ppu, colour_word: u16) u32 {
        const factor: u32 = @as(u32, self.brightness) + 1;
        const red5: u32 = colour_word & 0x1f;
        const green5: u32 = (colour_word >> 5) & 0x1f;
        const blue5: u32 = (colour_word >> 10) & 0x1f;
        const red = (((red5 << 3) | (red5 >> 2)) * factor + 15) / 16;
        const green = (((green5 << 3) | (green5 >> 2)) * factor + 15) / 16;
        const blue = (((blue5 << 3) | (blue5 >> 2)) * factor + 15) / 16;
        return 0xff000000 | (red << 16) | (green << 8) | blue;
    }
};

fn oamPhysical(raw: u10) usize {
    if ((raw & 0x200) != 0) return 512 + @as(usize, raw & 0x1f);
    return raw & 0x1ff;
}

fn bitsPerPixel(mode: u3, background: usize) ?u4 {
    return switch (mode) {
        0 => if (background < 4) 2 else null,
        1 => if (background < 2) 4 else if (background == 2) 2 else null,
        2 => if (background < 2) 4 else null,
        3 => if (background == 0) 8 else if (background == 1) 4 else null,
        4 => if (background == 0) 8 else if (background == 1) 2 else null,
        5 => if (background == 0) 4 else if (background == 1) 2 else null,
        6 => if (background == 0) 4 else null,
        else => null,
    };
}

fn backgroundPaletteIndex(mode: u3, background: usize, bpp: u4, group: u3, colour_index: u8) u16 {
    if (mode == 0) return @as(u16, @intCast(background * 32)) + @as(u16, group) * 4 + colour_index;
    return switch (bpp) {
        2 => @as(u16, group) * 4 + colour_index,
        4 => @as(u16, group) * 16 + colour_index,
        8 => colour_index,
        else => 0,
    };
}

fn directColour(group: u3, palette: u8) u16 {
    return (@as(u16, palette) << 7 & 0x6000) |
        (@as(u16, group) << 10 & 0x1000) |
        (@as(u16, palette) << 4 & 0x0380) |
        (@as(u16, group) << 5 & 0x0040) |
        (@as(u16, palette) << 2 & 0x001c) |
        (@as(u16, group) << 1 & 0x0002);
}

fn backgroundPriority(mode: u3, bg3_high: bool, background: usize, high: bool) u8 {
    const level: usize = @intFromBool(high);
    return switch (mode) {
        0 => ([_][2]u8{ .{ 8, 11 }, .{ 7, 10 }, .{ 2, 5 }, .{ 1, 4 } })[background][level],
        1 => if (bg3_high)
            ([_][2]u8{ .{ 5, 8 }, .{ 4, 7 }, .{ 1, 10 }, .{ 0, 0 } })[background][level]
        else
            ([_][2]u8{ .{ 6, 9 }, .{ 5, 8 }, .{ 1, 3 }, .{ 0, 0 } })[background][level],
        2, 3, 4 => ([_][2]u8{ .{ 3, 7 }, .{ 1, 5 }, .{ 0, 0 }, .{ 0, 0 } })[background][level],
        5 => ([_][2]u8{ .{ 3, 7 }, .{ 1, 5 }, .{ 0, 0 }, .{ 0, 0 } })[background][level],
        6 => ([_][2]u8{ .{ 2, 5 }, .{ 0, 0 }, .{ 0, 0 }, .{ 0, 0 } })[background][level],
        7 => if (background == 0) (if (bg3_high) 3 else 2) else if (high) 5 else 1,
    };
}

fn objectPriority(mode: u3, bg3_high: bool, priority: u2) u8 {
    const maps = switch (mode) {
        0 => [4]u8{ 3, 6, 9, 12 },
        1 => if (bg3_high) [4]u8{ 2, 3, 6, 9 } else [4]u8{ 2, 4, 7, 10 },
        2, 3, 4, 5 => [4]u8{ 2, 4, 6, 8 },
        6 => [4]u8{ 1, 3, 4, 6 },
        7 => if (bg3_high) [4]u8{ 2, 4, 6, 7 } else [4]u8{ 1, 3, 4, 5 },
    };
    return maps[priority];
}

fn spriteWidth(size_select: u3, large: bool) u8 {
    const small = [_]u8{ 8, 8, 8, 16, 16, 32, 16, 16 };
    const big = [_]u8{ 16, 32, 64, 32, 64, 64, 32, 32 };
    return if (large) big[size_select] else small[size_select];
}

fn spriteHeight(size_select: u3, large: bool) u8 {
    const small = [_]u8{ 8, 8, 8, 16, 16, 32, 32, 32 };
    const big = [_]u8{ 16, 32, 64, 32, 64, 64, 64, 32 };
    return if (large) big[size_select] else small[size_select];
}

fn mix(digest: u64, value: u8) u64 {
    return (digest ^ value) *% fnv_prime;
}

fn signed13(value: u16) i32 {
    const masked: u16 = value & 0x1fff;
    return if ((masked & 0x1000) != 0) @as(i32, masked) - 0x2000 else masked;
}

fn clipMode7(value: i32) i32 {
    const bits: u32 = @bitCast(value);
    const low: i32 = @intCast(bits & 0x03ff);
    return if ((bits & 0x2000) != 0) low - 0x0400 else low;
}

fn maskAllows(mode: u2, inside: bool) bool {
    return switch (mode) {
        0 => true,
        1 => inside,
        2 => !inside,
        3 => false,
    };
}

fn blendColour(first: u16, second: u16, subtract: bool, half: bool) u16 {
    var red: i16 = @intCast(first & 0x1f);
    var green: i16 = @intCast((first >> 5) & 0x1f);
    var blue: i16 = @intCast((first >> 10) & 0x1f);
    const second_red: i16 = @intCast(second & 0x1f);
    const second_green: i16 = @intCast((second >> 5) & 0x1f);
    const second_blue: i16 = @intCast((second >> 10) & 0x1f);
    if (subtract) {
        red = @max(0, red - second_red);
        green = @max(0, green - second_green);
        blue = @max(0, blue - second_blue);
    } else {
        red = @min(31, red + second_red);
        green = @min(31, green + second_green);
        blue = @min(31, blue + second_blue);
    }
    if (half) {
        red >>= 1;
        green >>= 1;
        blue >>= 1;
    }
    return @as(u16, @intCast(red)) | (@as(u16, @intCast(green)) << 5) | (@as(u16, @intCast(blue)) << 10);
}
