pub const copier_header_size: usize = 512;
pub const mapping_granularity: usize = 32 * 1024;
pub const minimum_rom_size: usize = mapping_granularity;
pub const maximum_rom_size: usize = 64 * 1024 * 1024;

pub const CandidateGeometry = struct {
    file_size: usize,
    rom_size: usize,
    copier_header: bool,
};

/// Performs metadata-only bounds validation. Cartridge bytes are deliberately
/// outside this foundation API, so the caller cannot accidentally mutate or
/// execute an unimplemented image.
pub fn inspectCandidateSize(file_size: usize) !CandidateGeometry {
    const remainder = file_size % mapping_granularity;
    const has_copier_header = remainder == copier_header_size;
    if (remainder != 0 and !has_copier_header) return error.InvalidCartridgeGeometry;
    const rom_size = if (has_copier_header) file_size - copier_header_size else file_size;
    if (rom_size < minimum_rom_size) return error.CartridgeTooSmall;
    if (rom_size > maximum_rom_size) return error.CartridgeTooLarge;
    return .{
        .file_size = file_size,
        .rom_size = rom_size,
        .copier_header = has_copier_header,
    };
}
