pub const ntsc_master_hz: u64 = 21_477_272;
pub const pal_master_hz: u64 = 21_281_370;
pub const nominal_audio_hz: u32 = 32_000;
pub const maximum_host_slice_master_cycles: u32 = 357_368;

pub const Clock = struct {
    master_cycles: u64 = 0,
    paused: bool = false,
};
