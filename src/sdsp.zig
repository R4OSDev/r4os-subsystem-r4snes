pub const Voice = struct {
    volume_left: i8 = 0,
    volume_right: i8 = 0,
    pitch: u16 = 0,
    source: u8 = 0,
};

pub const Dsp = struct {
    voices: [8]Voice = [_]Voice{.{}} ** 8,
    sample_counter: u64 = 0,
    muted: bool = false,
};
