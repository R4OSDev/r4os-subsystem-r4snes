pub const save_root = "C:\\R4OS\\SUBSYSTEMS\\r4os.snes\\SAVE";
pub const maximum_sram_bytes: usize = 2 * 1024 * 1024;

pub const State = struct {
    dirty: bool = false,
    generation: u64 = 0,
    writer_owned: bool = false,
};
