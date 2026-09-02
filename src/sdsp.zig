const std = @import("std");

pub const native_sample_rate: u32 = 32_000;
pub const output_sample_rate: u32 = 48_000;
pub const channels: usize = 2;
pub const sample_bytes: usize = channels * @sizeOf(i16);
pub const maximum_render_frames: usize = 2048;
pub const pcm_capacity_frames: usize = 8192;
pub const register_count: usize = 128;
pub const voice_count: usize = 8;

const brr_buffer_size: usize = 12;
const counter_range: i32 = 2048 * 5 * 3;
const fnv_offset: u64 = 0xcbf29ce484222325;
const fnv_prime: u64 = 0x100000001b3;

const counter_rates = [_]u16{
    0, 2048, 1536, 1280, 1024, 768, 640, 512,
    384, 320, 256, 192, 160, 128, 96, 80,
    64, 48, 40, 32, 24, 20, 16, 12,
    10, 8, 6, 5, 4, 3, 2, 1,
};

const counter_offsets = [_]u16{
    0, 0, 1040, 536, 0, 1040, 536, 0,
    1040, 536, 0, 1040, 536, 0, 1040, 536,
    0, 1040, 536, 0, 1040, 536, 0, 1040,
    536, 0, 1040, 536, 0, 1040, 0, 0,
};

fn defaultRegisters() [register_count]u8 {
    var result = [_]u8{0} ** register_count;
    result[0x6c] = 0xe0;
    return result;
}

fn constructGaussianTable() [512]i16 {
    var source: [512]f64 = undefined;
    var result: [512]i16 = undefined;
    for (0..512) |index| {
        const k = 0.5 + @as(f64, @floatFromInt(index));
        const s = @sin(std.math.pi * k * 1.280 / 1024.0);
        const t = (@cos(std.math.pi * k * 2.000 / 1023.0) - 1.0) * 0.50;
        const u = (@cos(std.math.pi * k * 4.000 / 1023.0) - 1.0) * 0.08;
        source[511 - index] = s * (t + u + 1.0) / k;
    }
    for (0..128) |phase| {
        const sum = source[phase] + source[phase + 256] + source[511 - phase] + source[255 - phase];
        const scale = 2048.0 / sum;
        result[phase] = @intFromFloat(source[phase] * scale + 0.5);
        result[phase + 256] = @intFromFloat(source[phase + 256] * scale + 0.5);
        result[511 - phase] = @intFromFloat(source[511 - phase] * scale + 0.5);
        result[255 - phase] = @intFromFloat(source[255 - phase] * scale + 0.5);
    }
    return result;
}

const gaussian_table = constructGaussianTable();

pub const EnvelopeMode = enum(u2) {
    release,
    attack,
    decay,
    sustain,
};

pub const Voice = struct {
    volume_left: i8 = 0,
    volume_right: i8 = 0,
    pitch: u16 = 0,
    source: u8 = 0,
    adsr0: u8 = 0,
    adsr1: u8 = 0,
    gain: u8 = 0,
    envx: u8 = 0,
    outx: u8 = 0,

    keyon: bool = false,
    keyoff: bool = false,
    key_latch: bool = false,
    latched_keyon: bool = false,
    latched_keyoff: bool = false,
    modulate: bool = false,
    noise: bool = false,
    echo: bool = false,
    latched_modulate: bool = false,
    latched_noise: bool = false,
    latched_echo: bool = false,
    ended: bool = false,
    looped: bool = false,

    buffer: [brr_buffer_size]i16 = [_]i16{0} ** brr_buffer_size,
    buffer_offset: u8 = 0,
    gaussian_offset: u16 = 0,
    brr_address: u16 = 0,
    brr_offset: u8 = 1,
    keyon_delay: u8 = 0,
    envelope_mode: EnvelopeMode = .release,
    envelope: u16 = 0,
    hidden_envelope: i32 = 0,
};

pub const AudioStats = struct {
    native_frames: u64 = 0,
    resampled_frames: u64 = 0,
    frames_queued: u64 = 0,
    frames_rendered: u64 = 0,
    frames_dropped: u64 = 0,
    underflow_frames: u64 = 0,
    silence_frames: u64 = 0,
};

/// Sony S-DSP state. The 32 hardware phases are advanced only from guest
/// clocks. PCM capture is optional and the host can only pull complete frames
/// into its own buffer through renderPcm.
pub const Dsp = struct {
    voices: [voice_count]Voice = [_]Voice{.{}} ** voice_count,
    registers: [register_count]u8 = defaultRegisters(),

    phase: u8 = 0,
    counter: i32 = 0,
    every_other_sample: bool = true,
    noise_lfsr: u16 = 0x4000,
    noise_frequency: u5 = 0,

    main_volume: [2]i8 = .{ 0, 0 },
    echo_volume: [2]i8 = .{ 0, 0 },
    main_output: [2]i32 = .{ 0, 0 },
    muted: bool = true,
    soft_reset: bool = true,

    echo_feedback: i8 = 0,
    echo_fir: [8]i8 = [_]i8{0} ** 8,
    echo_history: [2][8]i16 = .{ [_]i16{0} ** 8, [_]i16{0} ** 8 },
    echo_history_offset: u8 = 0,
    echo_page: u8 = 0,
    echo_delay: u4 = 0,
    echo_readonly: bool = true,
    echo_input: [2]i32 = .{ 0, 0 },
    echo_output_accumulator: [2]i32 = .{ 0, 0 },
    latched_echo_page: u8 = 0,
    latched_echo_readonly: bool = true,
    echo_address: u16 = 0,
    echo_offset: u16 = 0,
    echo_length: u16 = 0,

    brr_bank: u8 = 0,
    latched_brr_bank: u8 = 0,
    latched_source: u8 = 0,
    directory_address: u16 = 0,
    next_brr_address: u16 = 0,
    brr_header: u8 = 0,
    brr_byte: u8 = 0,

    latched_adsr0: u8 = 0,
    latched_pitch: i32 = 0,
    latched_output: i32 = 0,
    latched_envx: u8 = 0,
    latched_outx: u8 = 0,

    sample_counter: u64 = 0,
    last_native: [2]i16 = .{ 0, 0 },
    native_digest: u64 = fnv_offset,
    resampled_digest: u64 = fnv_offset,
    stats: AudioStats = .{},

    capture_enabled: bool = false,
    pcm: [pcm_capacity_frames * channels]i16 = [_]i16{0} ** (pcm_capacity_frames * channels),
    pcm_read_frame: usize = 0,
    pcm_frame_count: usize = 0,
    resampler_seeded: bool = false,
    resampler_previous: [2]i16 = .{ 0, 0 },
    resampler_source_index: u64 = 0,
    resampler_next_numerator: u64 = 0,

    pub fn reset(self: *Dsp) void {
        self.* = .{};
    }

    pub fn read(self: *const Dsp, address: u8) u8 {
        return self.registers[address & 0x7f];
    }

    pub fn write(self: *Dsp, raw_address: u8, value: u8) void {
        const address = raw_address & 0x7f;
        self.registers[address] = value;
        switch (address) {
            0x0c => self.main_volume[0] = signedByte(value),
            0x1c => self.main_volume[1] = signedByte(value),
            0x2c => self.echo_volume[0] = signedByte(value),
            0x3c => self.echo_volume[1] = signedByte(value),
            0x4c => for (&self.voices, 0..) |*voice, index| {
                const set = value & (@as(u8, 1) << @intCast(index)) != 0;
                voice.keyon = set;
                voice.key_latch = set;
            },
            0x5c => for (&self.voices, 0..) |*voice, index| {
                voice.keyoff = value & (@as(u8, 1) << @intCast(index)) != 0;
            },
            0x6c => {
                self.noise_frequency = @truncate(value);
                self.echo_readonly = value & 0x20 != 0;
                self.muted = value & 0x40 != 0;
                self.soft_reset = value & 0x80 != 0;
            },
            0x7c => {
                for (&self.voices) |*voice| voice.ended = false;
                self.registers[0x7c] = 0;
            },
            0x0d => self.echo_feedback = signedByte(value),
            0x2d => {
                for (&self.voices, 0..) |*voice, index| {
                    voice.modulate = index != 0 and value & (@as(u8, 1) << @intCast(index)) != 0;
                }
            },
            0x3d => for (&self.voices, 0..) |*voice, index| {
                voice.noise = value & (@as(u8, 1) << @intCast(index)) != 0;
            },
            0x4d => for (&self.voices, 0..) |*voice, index| {
                voice.echo = value & (@as(u8, 1) << @intCast(index)) != 0;
            },
            0x5d => self.brr_bank = value,
            0x6d => self.echo_page = value,
            0x7d => self.echo_delay = @truncate(value),
            else => {},
        }

        const voice = &self.voices[address >> 4];
        switch (address & 0x0f) {
            0x00 => voice.volume_left = signedByte(value),
            0x01 => voice.volume_right = signedByte(value),
            0x02 => voice.pitch = (voice.pitch & 0x3f00) | value,
            0x03 => voice.pitch = (voice.pitch & 0x00ff) | (@as(u16, value & 0x3f) << 8),
            0x04 => voice.source = value,
            0x05 => voice.adsr0 = value,
            0x06 => voice.adsr1 = value,
            0x07 => voice.gain = value,
            0x08 => voice.envx = value,
            0x09 => voice.outx = value,
            0x0f => self.echo_fir[address >> 4] = signedByte(value),
            else => {},
        }
    }

    pub fn runClocks(self: *Dsp, aram: *[65536]u8, clocks: u64) void {
        var remaining = clocks;
        while (remaining != 0) : (remaining -= 1) {
            self.executePhase(aram);
            self.phase = (self.phase + 1) & 31;
        }
    }

    pub fn beginCapture(self: *Dsp) void {
        self.capture_enabled = true;
        self.clearPcm();
    }

    pub fn endCapture(self: *Dsp) void {
        self.capture_enabled = false;
        self.clearPcm();
    }

    pub fn discardPcm(self: *Dsp) void {
        self.clearPcm();
    }

    pub fn queuedFrames(self: *const Dsp) usize {
        return self.pcm_frame_count;
    }

    pub fn renderPcm(self: *Dsp, out: []u8) i32 {
        if (out.len == 0 or out.len % sample_bytes != 0 or
            out.len / sample_bytes > maximum_render_frames or out.len > std.math.maxInt(i32)) return -1;
        const requested_frames = out.len / sample_bytes;
        const rendered_frames = @min(requested_frames, self.pcm_frame_count);
        self.stats.underflow_frames +%= requested_frames - rendered_frames;
        for (0..rendered_frames) |frame| {
            const source = self.pcm_read_frame * channels;
            const destination = frame * sample_bytes;
            std.mem.writeInt(i16, out[destination..][0..2], self.pcm[source], .little);
            std.mem.writeInt(i16, out[destination + 2 ..][0..2], self.pcm[source + 1], .little);
            self.pcm_read_frame = (self.pcm_read_frame + 1) % pcm_capacity_frames;
            self.pcm_frame_count -= 1;
            self.stats.frames_rendered +%= 1;
        }
        return @intCast(rendered_frames * sample_bytes);
    }

    fn executePhase(self: *Dsp, aram: *[65536]u8) void {
        switch (self.phase) {
            0 => { self.voice5(0); self.voice2(1, aram); },
            1 => { self.voice6(0); self.voice3(1, aram); },
            2 => { self.voice7(0); self.voice4(1, aram); self.voice1(3); },
            3 => { self.voice8(0); self.voice5(1); self.voice2(2, aram); },
            4 => { self.voice9(0); self.voice6(1); self.voice3(2, aram); },
            5 => { self.voice7(1); self.voice4(2, aram); self.voice1(4); },
            6 => { self.voice8(1); self.voice5(2); self.voice2(3, aram); },
            7 => { self.voice9(1); self.voice6(2); self.voice3(3, aram); },
            8 => { self.voice7(2); self.voice4(3, aram); self.voice1(5); },
            9 => { self.voice8(2); self.voice5(3); self.voice2(4, aram); },
            10 => { self.voice9(2); self.voice6(3); self.voice3(4, aram); },
            11 => { self.voice7(3); self.voice4(4, aram); self.voice1(6); },
            12 => { self.voice8(3); self.voice5(4); self.voice2(5, aram); },
            13 => { self.voice9(3); self.voice6(4); self.voice3(5, aram); },
            14 => { self.voice7(4); self.voice4(5, aram); self.voice1(7); },
            15 => { self.voice8(4); self.voice5(5); self.voice2(6, aram); },
            16 => { self.voice9(4); self.voice6(5); self.voice3(6, aram); },
            17 => { self.voice1(0); self.voice7(5); self.voice4(6, aram); },
            18 => { self.voice8(5); self.voice5(6); self.voice2(7, aram); },
            19 => { self.voice9(5); self.voice6(6); self.voice3(7, aram); },
            20 => { self.voice1(1); self.voice7(6); self.voice4(7, aram); },
            21 => { self.voice8(6); self.voice5(7); self.voice2(0, aram); },
            22 => { self.voice3a(0); self.voice9(6); self.voice6(7); self.echo22(aram); },
            23 => { self.voice7(7); self.echo23(aram); },
            24 => { self.voice8(7); self.echo24(); },
            25 => { self.voice3b(0, aram); self.voice9(7); self.echo25(); },
            26 => self.echo26(),
            27 => { self.misc27(); self.echo27(); },
            28 => { self.misc28(); self.echo28(); },
            29 => { self.misc29(); self.echo29(aram); },
            30 => { self.misc30(); self.voice3c(0); self.echo30(aram); },
            31 => { self.voice4(0, aram); self.voice1(2); },
            else => unreachable,
        }
    }

    fn voice1(self: *Dsp, index: usize) void {
        self.directory_address = (@as(u16, self.latched_brr_bank) << 8) +% (@as(u16, self.latched_source) << 2);
        self.latched_source = self.voices[index].source;
    }

    fn voice2(self: *Dsp, index: usize, aram: *const [65536]u8) void {
        const voice = &self.voices[index];
        var address = self.directory_address;
        if (voice.keyon_delay == 0) address +%= 2;
        self.next_brr_address = @as(u16, aram[address]) | (@as(u16, aram[address +% 1]) << 8);
        self.latched_adsr0 = voice.adsr0;
        self.latched_pitch = voice.pitch & 0xff;
    }

    fn voice3(self: *Dsp, index: usize, aram: *const [65536]u8) void {
        self.voice3a(index);
        self.voice3b(index, aram);
        self.voice3c(index);
    }

    fn voice3a(self: *Dsp, index: usize) void {
        self.latched_pitch |= self.voices[index].pitch & 0x3f00;
    }

    fn voice3b(self: *Dsp, index: usize, aram: *const [65536]u8) void {
        const voice = &self.voices[index];
        self.brr_byte = aram[voice.brr_address +% voice.brr_offset];
        self.brr_header = aram[voice.brr_address];
    }

    fn voice3c(self: *Dsp, index: usize) void {
        const voice = &self.voices[index];
        if (voice.latched_modulate) {
            self.latched_pitch += ((self.latched_output >> 5) * self.latched_pitch) >> 10;
        }
        if (voice.keyon_delay != 0) {
            if (voice.keyon_delay == 5) {
                voice.brr_address = self.next_brr_address;
                voice.brr_offset = 1;
                voice.buffer_offset = 0;
                self.brr_header = 0;
            }
            voice.envelope = 0;
            voice.hidden_envelope = 0;
            voice.gaussian_offset = 0;
            voice.keyon_delay -= 1;
            if (voice.keyon_delay & 3 != 0) voice.gaussian_offset = 0x4000;
            self.latched_pitch = 0;
        }

        var output = self.gaussianInterpolate(voice);
        if (voice.latched_noise) output = truncateI16(@as(i32, self.noise_lfsr) << 1);
        self.latched_output = ((output * @as(i32, voice.envelope)) >> 11) & ~@as(i32, 1);
        voice.envx = @truncate(voice.envelope >> 4);

        if (self.soft_reset or self.brr_header & 3 == 1) {
            voice.envelope_mode = .release;
            voice.envelope = 0;
        }
        if (self.every_other_sample) {
            if (voice.latched_keyoff) voice.envelope_mode = .release;
            if (voice.latched_keyon) {
                voice.keyon_delay = 5;
                voice.envelope_mode = .attack;
            }
        }
        if (voice.keyon_delay == 0) self.runEnvelope(voice);
    }

    fn voice4(self: *Dsp, index: usize, aram: *const [65536]u8) void {
        const voice = &self.voices[index];
        voice.looped = false;
        if (voice.gaussian_offset >= 0x4000) {
            self.decodeBrr(voice, aram);
            voice.brr_offset += 2;
            if (voice.brr_offset >= 9) {
                voice.brr_address +%= 9;
                if (self.brr_header & 1 != 0) {
                    voice.brr_address = self.next_brr_address;
                    voice.looped = true;
                }
                voice.brr_offset = 1;
            }
        }
        const next_offset = @as(u32, voice.gaussian_offset & 0x3fff) + @as(u32, @intCast(@max(self.latched_pitch, 0)));
        voice.gaussian_offset = @intCast(@min(next_offset, 0x7fff));
        self.voiceOutput(voice, 0);
    }

    fn voice5(self: *Dsp, index: usize) void {
        const voice = &self.voices[index];
        self.voiceOutput(voice, 1);
        voice.ended = voice.ended or voice.looped;
        if (voice.keyon_delay == 5) voice.ended = false;
    }

    fn voice6(self: *Dsp, _: usize) void {
        self.latched_outx = @bitCast(@as(i8, @truncate(self.latched_output >> 8)));
    }

    fn voice7(self: *Dsp, index: usize) void {
        var endx: u8 = 0;
        for (self.voices, 0..) |voice, voice_index| {
            if (voice.ended) endx |= @as(u8, 1) << @intCast(voice_index);
        }
        self.registers[0x7c] = endx;
        self.latched_envx = self.voices[index].envx;
    }

    fn voice8(self: *Dsp, index: usize) void {
        self.voices[index].outx = self.latched_outx;
        self.registers[index * 0x10 + 0x09] = self.latched_outx;
    }

    fn voice9(self: *Dsp, index: usize) void {
        self.voices[index].envx = self.latched_envx;
        self.registers[index * 0x10 + 0x08] = self.latched_envx;
    }

    fn voiceOutput(self: *Dsp, voice: *const Voice, channel: usize) void {
        const volume: i32 = if (channel == 0) voice.volume_left else voice.volume_right;
        const amplitude = (self.latched_output * volume) >> 7;
        self.main_output[channel] = clampI16Value(self.main_output[channel] + amplitude);
        if (voice.latched_echo) {
            self.echo_output_accumulator[channel] = clampI16Value(self.echo_output_accumulator[channel] + amplitude);
        }
    }

    fn decodeBrr(self: *Dsp, voice: *Voice, aram: *const [65536]u8) void {
        const pair: u16 = (@as(u16, self.brr_byte) << 8) | aram[voice.brr_address +% voice.brr_offset +% 1];
        const filter = (self.brr_header >> 2) & 3;
        const scale = self.brr_header >> 4;
        for (0..4) |index| {
            const shift: u4 = @intCast(12 - index * 4);
            const nibble: u4 = @truncate(pair >> shift);
            var sample: i32 = if (nibble & 8 != 0) @as(i32, nibble) - 16 else nibble;
            if (scale <= 12) {
                sample = (sample << @intCast(scale)) >> 1;
            } else {
                sample &= ~@as(i32, 0x7ff);
            }
            const previous1: i32 = voice.buffer[(voice.buffer_offset + 11) % brr_buffer_size];
            const previous2: i32 = @as(i32, voice.buffer[(voice.buffer_offset + 10) % brr_buffer_size]) >> 1;
            switch (filter) {
                0 => {},
                1 => {
                    sample += previous1 >> 1;
                    sample += (-previous1) >> 5;
                },
                2 => {
                    sample += previous1;
                    sample -= previous2;
                    sample += previous2 >> 4;
                    sample += (previous1 * -3) >> 6;
                },
                3 => {
                    sample += previous1;
                    sample -= previous2;
                    sample += (previous1 * -13) >> 7;
                    sample += (previous2 * 3) >> 4;
                },
                else => unreachable,
            }
            const doubled = clampI16Value(sample) * 2;
            voice.buffer[voice.buffer_offset] = truncateI16Value(doubled);
            voice.buffer_offset = @intCast((voice.buffer_offset + 1) % brr_buffer_size);
        }
    }

    fn gaussianInterpolate(_: *const Dsp, voice: *const Voice) i32 {
        const fraction: usize = (voice.gaussian_offset >> 4) & 0xff;
        var buffer_offset: usize = (voice.buffer_offset + (voice.gaussian_offset >> 12)) % brr_buffer_size;
        var output = (@as(i32, gaussian_table[255 - fraction]) * voice.buffer[buffer_offset]) >> 11;
        buffer_offset = (buffer_offset + 1) % brr_buffer_size;
        output += (@as(i32, gaussian_table[511 - fraction]) * voice.buffer[buffer_offset]) >> 11;
        buffer_offset = (buffer_offset + 1) % brr_buffer_size;
        output += (@as(i32, gaussian_table[256 + fraction]) * voice.buffer[buffer_offset]) >> 11;
        output = truncateI16(output);
        buffer_offset = (buffer_offset + 1) % brr_buffer_size;
        output += (@as(i32, gaussian_table[fraction]) * voice.buffer[buffer_offset]) >> 11;
        return clampI16Value(output) & ~@as(i32, 1);
    }

    fn runEnvelope(self: *Dsp, voice: *Voice) void {
        var envelope: i32 = voice.envelope;
        if (voice.envelope_mode == .release) {
            envelope = @max(envelope - 8, 0);
            voice.envelope = @intCast(envelope);
            return;
        }

        var rate: u5 = 31;
        var envelope_data = voice.adsr1;
        if (self.latched_adsr0 & 0x80 != 0) {
            if (@intFromEnum(voice.envelope_mode) >= @intFromEnum(EnvelopeMode.decay)) {
                envelope -= 1;
                envelope -= envelope >> 8;
                rate = @truncate(envelope_data);
                if (voice.envelope_mode == .decay) rate = @intCast(((self.latched_adsr0 >> 3) & 0x0e) + 0x10);
            } else {
                rate = @intCast((self.latched_adsr0 & 0x0f) * 2 + 1);
                envelope += if (rate < 31) 0x20 else 0x400;
            }
        } else {
            envelope_data = voice.gain;
            const mode = envelope_data >> 5;
            if (mode < 4) {
                envelope = @as(i32, envelope_data) << 4;
                rate = 31;
            } else {
                rate = @truncate(envelope_data);
                switch (mode) {
                    4 => envelope -= 0x20,
                    5 => {
                        envelope -= 1;
                        envelope -= envelope >> 8;
                    },
                    6 => envelope += 0x20,
                    7 => envelope += if (voice.hidden_envelope >= 0x600) 0x08 else 0x20,
                    else => unreachable,
                }
            }
        }
        if ((envelope >> 8) == (envelope_data >> 5) and voice.envelope_mode == .decay) {
            voice.envelope_mode = .sustain;
        }
        voice.hidden_envelope = envelope;
        if (envelope < 0 or envelope > 0x7ff) {
            envelope = std.math.clamp(envelope, 0, 0x7ff);
            if (voice.envelope_mode == .attack) voice.envelope_mode = .decay;
        }
        if (self.counterPoll(rate)) voice.envelope = @intCast(envelope);
    }

    fn misc27(self: *Dsp) void {
        for (&self.voices) |*voice| voice.latched_modulate = voice.modulate;
    }

    fn misc28(self: *Dsp) void {
        for (&self.voices) |*voice| {
            voice.latched_noise = voice.noise;
            voice.latched_echo = voice.echo;
        }
        self.latched_brr_bank = self.brr_bank;
    }

    fn misc29(self: *Dsp) void {
        self.every_other_sample = !self.every_other_sample;
        if (!self.every_other_sample) return;
        for (&self.voices) |*voice| voice.key_latch = voice.key_latch and !voice.latched_keyon;
    }

    fn misc30(self: *Dsp) void {
        if (self.every_other_sample) {
            for (&self.voices) |*voice| {
                voice.latched_keyon = voice.key_latch;
                voice.latched_keyoff = voice.keyoff;
            }
        }
        self.counterTick();
        if (self.counterPoll(self.noise_frequency)) {
            const feedback = (@as(u32, self.noise_lfsr) << 13) ^ (@as(u32, self.noise_lfsr) << 14);
            self.noise_lfsr = @intCast((feedback & 0x4000) | (self.noise_lfsr >> 1));
        }
    }

    fn counterTick(self: *Dsp) void {
        self.counter -= 1;
        if (self.counter < 0) self.counter = counter_range - 1;
    }

    fn counterPoll(self: *const Dsp, rate: u5) bool {
        if (rate == 0) return false;
        return @mod(self.counter + counter_offsets[rate], counter_rates[rate]) == 0;
    }

    fn echoFir(self: *const Dsp, channel: usize, index: usize) i32 {
        const history_index = (self.echo_history_offset + index + 1) & 7;
        return (@as(i32, self.echo_history[channel][history_index]) * self.echo_fir[index]) >> 6;
    }

    fn echoRead(self: *Dsp, channel: usize, aram: *const [65536]u8) void {
        const address = self.echo_address +% @as(u16, @intCast(channel * 2));
        const bits = @as(u16, aram[address]) | (@as(u16, aram[address +% 1]) << 8);
        const sample: i16 = @bitCast(bits);
        self.echo_history[channel][self.echo_history_offset] = sample >> 1;
    }

    fn echoOutput(self: *const Dsp, channel: usize) i32 {
        const main = truncateI16((self.main_output[channel] * self.main_volume[channel]) >> 7);
        const echo = truncateI16((self.echo_input[channel] * self.echo_volume[channel]) >> 7);
        return clampI16Value(main + echo);
    }

    fn echoWrite(self: *Dsp, channel: usize, aram: *[65536]u8) void {
        if (!self.latched_echo_readonly) {
            const address = self.echo_address +% @as(u16, @intCast(channel * 2));
            const sample: i16 = @intCast(clampI16Value(self.echo_output_accumulator[channel]));
            const bits: u16 = @bitCast(sample);
            aram[address] = @truncate(bits);
            aram[address +% 1] = @truncate(bits >> 8);
        }
        self.echo_output_accumulator[channel] = 0;
    }

    fn echo22(self: *Dsp, aram: *const [65536]u8) void {
        self.echo_history_offset = (self.echo_history_offset + 1) & 7;
        self.echo_address = (@as(u16, self.latched_echo_page) << 8) +% self.echo_offset;
        self.echoRead(0, aram);
        self.echo_input[0] = self.echoFir(0, 0);
        self.echo_input[1] = self.echoFir(1, 0);
    }

    fn echo23(self: *Dsp, aram: *const [65536]u8) void {
        self.echo_input[0] += self.echoFir(0, 1) + self.echoFir(0, 2);
        self.echo_input[1] += self.echoFir(1, 1) + self.echoFir(1, 2);
        self.echoRead(1, aram);
    }

    fn echo24(self: *Dsp) void {
        self.echo_input[0] += self.echoFir(0, 3) + self.echoFir(0, 4) + self.echoFir(0, 5);
        self.echo_input[1] += self.echoFir(1, 3) + self.echoFir(1, 4) + self.echoFir(1, 5);
    }

    fn echo25(self: *Dsp) void {
        for (0..2) |channel| {
            var value = truncateI16(self.echo_input[channel] + self.echoFir(channel, 6));
            value += truncateI16(self.echoFir(channel, 7));
            self.echo_input[channel] = clampI16Value(value) & ~@as(i32, 1);
        }
    }

    fn echo26(self: *Dsp) void {
        self.main_output[0] = self.echoOutput(0);
        for (0..2) |channel| {
            const feedback = truncateI16((self.echo_input[channel] * self.echo_feedback) >> 7);
            self.echo_output_accumulator[channel] = clampI16Value(self.echo_output_accumulator[channel] + feedback) & ~@as(i32, 1);
        }
    }

    fn echo27(self: *Dsp) void {
        var left = self.main_output[0];
        var right = self.echoOutput(1);
        self.main_output = .{ 0, 0 };
        if (self.muted) {
            left = 0;
            right = 0;
        }
        self.emitNative(@intCast(left), @intCast(right));
    }

    fn echo28(self: *Dsp) void {
        self.latched_echo_readonly = self.echo_readonly;
    }

    fn echo29(self: *Dsp, aram: *[65536]u8) void {
        self.latched_echo_page = self.echo_page;
        if (self.echo_offset == 0) self.echo_length = @as(u16, self.echo_delay) << 11;
        self.echo_offset +%= 4;
        if (self.echo_offset >= self.echo_length) self.echo_offset = 0;
        self.echoWrite(0, aram);
        self.latched_echo_readonly = self.echo_readonly;
    }

    fn echo30(self: *Dsp, aram: *[65536]u8) void {
        self.echoWrite(1, aram);
    }

    fn emitNative(self: *Dsp, left: i16, right: i16) void {
        self.last_native = .{ left, right };
        self.sample_counter +%= 1;
        self.stats.native_frames +%= 1;
        hashFrame(&self.native_digest, left, right);
        if (self.capture_enabled) self.resample(.{ left, right });
    }

    fn resample(self: *Dsp, current: [2]i16) void {
        if (!self.resampler_seeded) {
            self.resampler_seeded = true;
            self.resampler_previous = current;
            self.resampler_source_index = 0;
            self.resampler_next_numerator = 0;
            self.queueFrame(current[0], current[1]);
            self.resampler_next_numerator = 2;
            return;
        }
        self.resampler_source_index +%= 1;
        const interval_start = (self.resampler_source_index - 1) * 3;
        const interval_end = self.resampler_source_index * 3;
        while (self.resampler_next_numerator <= interval_end) {
            const relative = self.resampler_next_numerator - interval_start;
            const left = interpolateThirds(self.resampler_previous[0], current[0], relative);
            const right = interpolateThirds(self.resampler_previous[1], current[1], relative);
            self.queueFrame(left, right);
            self.resampler_next_numerator +%= 2;
        }
        self.resampler_previous = current;
    }

    fn queueFrame(self: *Dsp, left: i16, right: i16) void {
        if (self.pcm_frame_count == pcm_capacity_frames) {
            self.pcm_read_frame = (self.pcm_read_frame + 1) % pcm_capacity_frames;
            self.pcm_frame_count -= 1;
            self.stats.frames_dropped +%= 1;
        }
        const write_frame = (self.pcm_read_frame + self.pcm_frame_count) % pcm_capacity_frames;
        self.pcm[write_frame * channels] = left;
        self.pcm[write_frame * channels + 1] = right;
        self.pcm_frame_count += 1;
        self.stats.resampled_frames +%= 1;
        self.stats.frames_queued +%= 1;
        if (left == 0 and right == 0) self.stats.silence_frames +%= 1;
        hashFrame(&self.resampled_digest, left, right);
    }

    fn clearPcm(self: *Dsp) void {
        self.pcm_read_frame = 0;
        self.pcm_frame_count = 0;
        self.resampler_seeded = false;
        self.resampler_previous = .{ 0, 0 };
        self.resampler_source_index = 0;
        self.resampler_next_numerator = 0;
    }
};

fn signedByte(value: u8) i8 {
    return @bitCast(value);
}

fn clampI16Value(value: i32) i32 {
    return std.math.clamp(value, std.math.minInt(i16), std.math.maxInt(i16));
}

fn truncateI16(value: i32) i32 {
    return @as(i16, @truncate(value));
}

fn truncateI16Value(value: i32) i16 {
    return @truncate(value);
}

fn interpolateThirds(previous: i16, current: i16, relative: u64) i16 {
    const before: i64 = previous;
    const after: i64 = current;
    const numerator = before * @as(i64, @intCast(3 - relative)) + after * @as(i64, @intCast(relative));
    return @intCast(@divTrunc(numerator, 3));
}

fn hashFrame(digest: *u64, left: i16, right: i16) void {
    const samples = [_]i16{ left, right };
    for (samples) |sample| {
        const bits: u16 = @bitCast(sample);
        digest.* = (digest.* ^ @as(u8, @truncate(bits))) *% fnv_prime;
        digest.* = (digest.* ^ @as(u8, @truncate(bits >> 8))) *% fnv_prime;
    }
}

test "gaussian table matches documented shape" {
    try std.testing.expectEqual(@as(i16, 0), gaussian_table[0]);
    try std.testing.expectEqual(@as(i16, 370), gaussian_table[256]);
    try std.testing.expectEqual(@as(i16, 1305), gaussian_table[511]);
}
