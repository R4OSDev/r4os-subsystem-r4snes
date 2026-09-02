const std = @import("std");
const board = @import("board.zig");
const obc1 = @import("obc1.zig");
const sdd1 = @import("sdd1.zig");
const spc7110 = @import("spc7110.zig");
const srtc = @import("srtc.zig");
const superfx = @import("superfx.zig");
const sa1 = @import("sa1.zig");
const cx4 = @import("cx4.zig");
const nec_dsp = @import("nec_dsp.zig");
const st018 = @import("st018.zig");

pub const copier_header_size: usize = 512;
pub const mapping_granularity: usize = 32 * 1024;
pub const minimum_rom_size: usize = mapping_granularity;
pub const maximum_rom_size: usize = 64 * 1024 * 1024;
pub const maximum_source_size: usize = maximum_rom_size + copier_header_size;
pub const title_length: usize = 21;
pub const header_length: usize = 64;

pub const CandidateGeometry = struct {
    file_size: usize,
    rom_size: usize,
    copier_header: bool,
};

pub const Header = struct {
    offset: usize,
    mapping: board.Mapping,
    region: board.Region,
    map_mode: u8,
    rom_type: u8,
    rom_size_code: u8,
    ram_size_code: u8,
    region_code: u8,
    licensee_code: u8,
    version: u8,
    expansion_ram_size_code: u8 = 0,
    cartridge_subtype: u8 = 0,
    reset_vector: u16,
    startup_opcode: u8,
    checksum: u16,
    checksum_complement: u16,
    checksum_present: bool,
    checksum_matches: bool,
    declared_rom_bytes: usize,
    declared_sram_bytes: usize,
    title: [title_length]u8,
    score: i16,
};

pub const ParseOptions = struct {
    /// The standard SNES header identifies the GSU family, but has no field
    /// that distinguishes GSU-1 from GSU-2.  GSU-2 is the compatible default
    /// used by open homebrew; callers with board metadata may select GSU-1.
    superfx_revision: ?superfx.Revision = null,
    /// DSP-2/3/4 are inferred from non-title header fields. DSP-1B is the
    /// default for the otherwise indistinguishable DSP-1 package revisions;
    /// exact board metadata may select DSP-1 or DSP-1A explicitly.
    nec_dsp_revision: ?nec_dsp.Revision = null,
    nec_dsp_firmware: ?[]const u8 = null,
    nec_dsp_firmware_validation: nec_dsp.FirmwareValidation = .known_only,
    st018_firmware: ?[]const u8 = null,
    st018_firmware_validation: st018.FirmwareValidation = .known_only,
};

pub const NecDspRequirement = struct {
    revision: nec_dsp.Revision,
    appended: bool,

    pub fn chipName(self: NecDspRequirement) []const u8 {
        return self.revision.chipName();
    }

    pub fn fileName(self: NecDspRequirement) []const u8 {
        return self.revision.fileName();
    }

    pub fn firmwarePath(self: NecDspRequirement) []const u8 {
        return self.revision.firmwarePath();
    }

    pub fn firmwareBytes(self: NecDspRequirement) usize {
        return self.revision.firmwareBytes();
    }
};

pub const St018Requirement = struct {
    pub fn chipName(_: St018Requirement) []const u8 {
        return "ST018";
    }

    pub fn fileName(_: St018Requirement) []const u8 {
        return st018.firmware_file;
    }

    pub fn firmwarePath(_: St018Requirement) []const u8 {
        return st018.firmware_path;
    }

    pub fn firmwareBytes(_: St018Requirement) usize {
        return st018.firmware_bytes;
    }
};

pub const Cartridge = struct {
    allocator: std.mem.Allocator,
    rom_storage: []u8,
    sram_storage: []u8,
    identity: [32]u8,
    header: Header,
    board: board.Board,
    had_copier_header: bool,
    sram_dirty: bool = false,
    sram_dirty_first: usize = 0,
    sram_dirty_end: usize = 0,
    obc1_device: ?obc1.Device = null,
    srtc_device: ?srtc.Device = null,
    sdd1_device: ?sdd1.Device = null,
    spc7110_device: ?spc7110.Device = null,
    superfx_device: ?superfx.Device = null,
    sa1_device: ?sa1.Device = null,
    cx4_device: ?cx4.Device = null,
    nec_dsp_device: ?nec_dsp.Device = null,
    st018_device: ?st018.Device = null,
    had_appended_firmware: bool = false,

    pub fn parse(allocator: std.mem.Allocator, source: []const u8) !Cartridge {
        return parseWithOptions(allocator, source, .{});
    }

    pub fn parseWithOptions(allocator: std.mem.Allocator, source: []const u8, options: ParseOptions) !Cartridge {
        const parts = try splitSource(source);
        const geometry = parts.geometry;
        const normalized_start: usize = if (geometry.copier_header) copier_header_size else 0;
        const normalized = parts.cartridge[normalized_start..];
        const header = try selectHeader(normalized);
        const enhancement = board.enhancementForHeader(header.rom_type, header.map_mode);
        const capability = board.capability(enhancement);
        const has_nec_dsp = enhancement == .dsp1_family or enhancement == .st010_st011;
        if (parts.appended_firmware != null and !has_nec_dsp)
            return error.UnexpectedAppendedFirmware;
        if (parts.appended_firmware != null and options.nec_dsp_firmware != null)
            return error.AmbiguousNecDspFirmwareSource;
        if (options.st018_firmware != null and enhancement != .st018)
            return error.UnexpectedSt018Firmware;
        if (enhancement == .unknown) {
            if (board.unsupportedRevisionFamily(header.rom_type, header.map_mode)) |family| {
                return switch (family) {
                    .obc1 => error.UnsupportedOBC1Revision,
                    .srtc => error.UnsupportedSrtcRevision,
                    .sdd1 => error.UnsupportedSdd1Revision,
                    .spc7110 => error.UnsupportedSpc7110Revision,
                    .super_fx => error.UnsupportedSuperFxRevision,
                    .sa1 => error.UnsupportedSa1Revision,
                    .cx4 => error.UnsupportedCx4Revision,
                };
            }
        }
        if (capability.disposition == .excluded) return error.ExcludedBoard;
        if (capability.disposition == .unsupported) return error.UnsupportedBoard;
        if (capability.disposition == .base_implemented and normalized.len > 8 * 1024 * 1024) {
            return error.UnaddressableBoardGeometry;
        }
        const battery = hasBattery(header.rom_type);
        const superfx_revision = if (enhancement == .super_fx)
            options.superfx_revision orelse superfx.default_revision
        else
            null;
        const cartridge_ram_bytes = if (enhancement == .super_fx) blk: {
            if (header.expansion_ram_size_code >= 1 and header.expansion_ram_size_code <= 7) {
                break :blk superfx.workRamBytes(header.expansion_ram_size_code);
            }
            if (header.declared_sram_bytes != 0) break :blk header.declared_sram_bytes;
            break :blk superfx.default_ram_bytes;
        } else if (enhancement == .st010_st011)
            nec_dsp.st_data_ram_bytes
        else if (enhancement == .st018)
            st018.work_ram_bytes
        else
            header.declared_sram_bytes;
        const nec_revision = if (has_nec_dsp)
            try selectNecDspRevision(header, parts.appended_firmware, options.nec_dsp_revision)
        else
            null;
        switch (enhancement) {
            .obc1 => if (header.mapping != .lo_rom or header.declared_sram_bytes != obc1.ram_bytes or !battery)
                return error.ContradictoryOBC1Board,
            .srtc => if (header.mapping != .ex_hi_rom or header.declared_sram_bytes == 0 or !battery or normalized.len <= 4 * 1024 * 1024)
                return error.ContradictorySrtcBoard,
            .sdd1 => if (header.mapping != .lo_rom or
                (header.rom_type == 0x43 and (battery or header.declared_sram_bytes != 0)) or
                (header.rom_type == 0x45 and (!battery or header.declared_sram_bytes != 32 * 1024)))
                return error.ContradictorySdd1Board,
            .spc7110_epson_rtc => if (header.mapping != .hi_rom or !battery or
                header.declared_sram_bytes != 8 * 1024 or normalized.len <= spc7110.programRomBytes(normalized.len))
                return error.ContradictorySpc7110Board,
            .super_fx => {
                if (header.mapping != .lo_rom) return error.ContradictorySuperFxBoard;
                superfx.validateGeometry(superfx_revision.?, normalized.len, cartridge_ram_bytes) catch
                    return error.ContradictorySuperFxBoard;
            },
            .sa1 => {
                if (header.mapping != .lo_rom) return error.ContradictorySa1Board;
                sa1.validateGeometry(normalized.len, cartridge_ram_bytes) catch
                    return error.ContradictorySa1Board;
            },
            .cx4 => {
                if (header.mapping != .lo_rom) return error.ContradictoryCx4Board;
                cx4.validateGeometry(normalized.len, cartridge_ram_bytes) catch
                    return error.ContradictoryCx4Board;
            },
            .dsp1_family => {
                validateNecDspHeader(nec_revision.?, header) catch
                    return error.ContradictoryNecDspBoard;
                _ = nec_dsp.selectHostMap(nec_revision.?, header.mapping, normalized.len, cartridge_ram_bytes) catch
                    return error.ContradictoryNecDspBoard;
            },
            .st010_st011 => {
                validateNecDspHeader(nec_revision.?, header) catch
                    return error.ContradictoryNecDspBoard;
                _ = nec_dsp.selectHostMap(nec_revision.?, header.mapping, normalized.len, cartridge_ram_bytes) catch
                    return error.ContradictoryNecDspBoard;
            },
            .st018 => validateSt018Header(header, battery, cartridge_ram_bytes) catch
                return error.ContradictorySt018Board,
            else => {},
        }

        const rom_copy = try allocator.alloc(u8, normalized.len);
        errdefer allocator.free(rom_copy);
        @memcpy(rom_copy, normalized);
        const sram_copy = try allocator.alloc(u8, cartridge_ram_bytes);
        errdefer allocator.free(sram_copy);
        @memset(sram_copy, 0);

        var nec_device: ?nec_dsp.Device = null;
        errdefer if (nec_device) |*device| device.close();
        var st018_device: ?st018.Device = null;
        errdefer if (st018_device) |*device| device.close();
        if (nec_revision) |revision| {
            const firmware = parts.appended_firmware orelse options.nec_dsp_firmware orelse
                return error.MissingNecDspFirmware;
            const firmware_source: nec_dsp.FirmwareSource = if (options.nec_dsp_firmware_validation == .allow_open_test)
                .open_test
            else if (parts.appended_firmware != null)
                .appended
            else
                .separate;
            nec_device = try nec_dsp.Device.init(
                allocator,
                revision,
                header.mapping,
                normalized.len,
                cartridge_ram_bytes,
                firmware,
                options.nec_dsp_firmware_validation,
                firmware_source,
            );
        } else if (options.nec_dsp_firmware != null) {
            return error.UnexpectedNecDspFirmware;
        }
        if (enhancement == .st018) {
            const firmware = options.st018_firmware orelse return error.MissingSt018Firmware;
            const firmware_source: st018.FirmwareSource = if (options.st018_firmware_validation == .allow_open_test)
                .open_test
            else
                .separate;
            st018_device = try st018.Device.init(
                allocator,
                firmware,
                options.st018_firmware_validation,
                firmware_source,
            );
        }

        var identity: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(normalized, &identity, .{});
        var result = Cartridge{
            .allocator = allocator,
            .rom_storage = rom_copy,
            .sram_storage = sram_copy,
            .identity = identity,
            .header = header,
            .board = .{
                .mapping = header.mapping,
                .region = header.region,
                .fast_rom = (header.map_mode & 0x10) != 0,
                .capability = capability,
                .sram_bytes = sram_copy.len,
                .battery = battery,
            },
            .had_copier_header = geometry.copier_header,
            .had_appended_firmware = parts.appended_firmware != null,
            .obc1_device = if (enhancement == .obc1) .{} else null,
            .srtc_device = if (enhancement == .srtc) .{} else null,
            .sdd1_device = if (enhancement == .sdd1) .{} else null,
            .spc7110_device = if (enhancement == .spc7110_epson_rtc)
                .{ .has_rtc = header.rom_type == 0xF9 }
            else
                null,
            .superfx_device = if (superfx_revision) |revision| superfx.Device.init(revision) else null,
            .sa1_device = if (enhancement == .sa1) .{} else null,
            .cx4_device = if (enhancement == .cx4) .{} else null,
            .nec_dsp_device = nec_device,
            .st018_device = st018_device,
        };
        if (result.obc1_device) |*device| try device.power(result.sram_storage);
        if (result.srtc_device) |*device| device.power();
        if (result.sdd1_device) |*device| device.power();
        if (result.spc7110_device) |*device| device.power();
        if (result.superfx_device) |*device| try device.power(device.revision, result.rom_storage.len, result.sram_storage.len);
        if (result.sa1_device) |*device| try device.power(
            if (header.region == .pal) .pal else .ntsc,
            result.rom_storage.len,
            result.sram_storage.len,
        );
        if (result.cx4_device) |*device| try device.power(result.rom_storage.len, result.sram_storage.len);
        return result;
    }

    pub fn deinit(self: *Cartridge) void {
        if (self.nec_dsp_device) |*device| device.close();
        if (self.st018_device) |*device| device.close();
        self.allocator.free(self.sram_storage);
        self.allocator.free(self.rom_storage);
        self.sram_storage = &.{};
        self.rom_storage = &.{};
        self.sram_dirty = false;
        self.sram_dirty_first = 0;
        self.sram_dirty_end = 0;
        self.obc1_device = null;
        self.srtc_device = null;
        self.sdd1_device = null;
        self.spc7110_device = null;
        self.superfx_device = null;
        self.sa1_device = null;
        self.cx4_device = null;
        self.nec_dsp_device = null;
        self.st018_device = null;
        self.had_appended_firmware = false;
    }

    pub fn rom(self: *const Cartridge) []const u8 {
        return self.rom_storage;
    }

    pub fn sram(self: *const Cartridge) []const u8 {
        return self.sram_storage;
    }

    pub fn readRom(self: *const Cartridge, index: usize) u8 {
        return self.rom_storage[index];
    }

    pub fn readSram(self: *const Cartridge, index: usize) u8 {
        return self.sram_storage[index];
    }

    pub fn writeSram(self: *Cartridge, index: usize, value: u8) void {
        if (self.sram_storage[index] == value) return;
        self.sram_storage[index] = value;
        self.markSramDirty(index, index + 1);
    }

    pub fn readEnhancement(self: *Cartridge, address: u32, open_bus: u8) ?u8 {
        if (self.obc1_device) |*device| {
            if (device.read(self.sram_storage, address)) |value| return value;
        }
        if (self.srtc_device) |*device| return device.read(address, open_bus);
        if (self.sdd1_device) |*device| return device.read(self.rom_storage, self.sram_storage, address, open_bus);
        if (self.spc7110_device) |*device| return device.read(self.rom_storage, self.sram_storage, address, open_bus);
        if (self.superfx_device) |*device| return device.readCpu(self.rom_storage, self.sram_storage, address, open_bus);
        if (self.sa1_device) |*device| return device.readCpu(self.rom_storage, self.sram_storage, address, open_bus);
        if (self.cx4_device) |*device| return device.readCpu(self.rom_storage, self.sram_storage, address, open_bus);
        if (self.nec_dsp_device) |*device| return device.readCpu(address, open_bus);
        if (self.st018_device) |*device| return device.readCpu(address, open_bus);
        return null;
    }

    pub fn observeEnhancementWrite(self: *Cartridge, address: u32, value: u8) void {
        if (self.sdd1_device) |*device| device.observeDmaWrite(address, value);
    }

    pub fn writeEnhancement(self: *Cartridge, address: u32, value: u8) bool {
        if (self.obc1_device) |*device| {
            const result = device.write(self.sram_storage, address, value);
            if (result.handled) {
                if (result.changed) self.markSramDirty(result.first, result.end);
                return true;
            }
        }
        if (self.srtc_device) |*device| return device.write(address, value);
        if (self.sdd1_device) |*device| {
            const result = device.write(self.sram_storage, address, value);
            if (result.handled) {
                if (result.changed) self.markSramDirty(result.first, result.end);
                return true;
            }
        }
        if (self.spc7110_device) |*device| {
            const result = device.write(self.rom_storage, self.sram_storage, address, value);
            if (result.handled) {
                if (result.changed) self.markSramDirty(result.first, result.end);
                return true;
            }
        }
        if (self.superfx_device) |*device| {
            const result = device.writeCpu(self.sram_storage, address, value);
            if (result.handled) {
                if (result.changed and self.board.battery) self.markSramDirty(result.first, result.end);
                _ = device.takeDirtyRange();
                return true;
            }
        }
        if (self.sa1_device) |*device| {
            const result = device.writeCpu(self.rom_storage, self.sram_storage, address, value);
            if (result.handled) {
                if (result.changed and self.board.battery) self.markSramDirty(result.first, result.end);
                _ = device.takeDirtyRange();
                return true;
            }
        }
        if (self.cx4_device) |*device| {
            return device.writeCpu(self.rom_storage, self.sram_storage, address, value).handled;
        }
        if (self.nec_dsp_device) |*device| {
            const handled = device.writeCpu(address, value);
            if (handled) self.collectNecDspDirty(device);
            return handled;
        }
        if (self.st018_device) |*device| return device.writeCpu(address, value);
        return false;
    }

    pub fn runSuperFxSlice(self: *Cartridge, maximum_instructions: usize) ?superfx.RunResult {
        if (self.superfx_device) |*device| {
            const result = device.runSlice(self.rom_storage, self.sram_storage, maximum_instructions);
            if (device.takeDirtyRange()) |dirty| {
                if (self.board.battery) self.markSramDirty(dirty.first, dirty.end);
            }
            return result;
        }
        return null;
    }

    pub fn runSa1Slice(self: *Cartridge, maximum_instructions: usize) ?sa1.RunResult {
        if (self.sa1_device) |*device| {
            const result = device.runSlice(self.rom_storage, self.sram_storage, maximum_instructions);
            self.collectSa1Dirty(device);
            return result;
        }
        return null;
    }

    pub fn runSa1UntilMasterClock(self: *Cartridge, target: u64, maximum_instructions: usize) ?sa1.RunResult {
        if (self.sa1_device) |*device| {
            const result = device.runUntilMasterClock(self.rom_storage, self.sram_storage, target, maximum_instructions);
            self.collectSa1Dirty(device);
            return result;
        }
        return null;
    }

    pub fn sa1CpuIrqPending(self: *const Cartridge) bool {
        if (self.sa1_device) |*device| return device.cpuIrqPending();
        return false;
    }

    pub fn runCx4Slice(self: *Cartridge, maximum_cycles: usize) ?cx4.RunResult {
        if (self.cx4_device) |*device| return device.runSlice(self.rom_storage, self.sram_storage, maximum_cycles);
        return null;
    }

    pub fn cx4CpuIrqPending(self: *const Cartridge) bool {
        if (self.cx4_device) |*device| return device.irqPending();
        return false;
    }

    pub fn runNecDspSlice(self: *Cartridge, maximum_instructions: usize) ?nec_dsp.RunResult {
        if (self.nec_dsp_device) |*device| {
            const result = device.runSlice(maximum_instructions);
            self.collectNecDspDirty(device);
            return result;
        }
        return null;
    }

    pub fn runSt018Slice(self: *Cartridge, maximum_steps: usize) ?st018.RunResult {
        if (self.st018_device) |*device| {
            const result = device.runSlice(maximum_steps);
            self.collectSt018Dirty(device);
            return result;
        }
        return null;
    }

    pub fn restoreNecDspPersistentRam(self: *Cartridge) !void {
        if (self.nec_dsp_device) |*device| {
            if (device.revision.isSt01x()) try device.restorePersistentRam(self.sram_storage);
        }
    }

    pub fn restoreSt018PersistentRam(self: *Cartridge) !void {
        if (self.st018_device) |*device| try device.restorePersistentRam(self.sram_storage);
    }

    fn collectNecDspDirty(self: *Cartridge, device: *nec_dsp.Device) void {
        const dirty = device.takeDirtyRange() orelse return;
        device.copyPersistentRamRange(self.sram_storage, dirty.first, dirty.end) catch return;
        if (self.board.battery) self.markSramDirty(dirty.first, dirty.end);
    }

    fn collectSt018Dirty(self: *Cartridge, device: *st018.Device) void {
        const dirty = device.takeDirtyRange() orelse return;
        device.copyPersistentRamRange(self.sram_storage, dirty.first, dirty.end) catch return;
        if (self.board.battery) self.markSramDirty(dirty.first, dirty.end);
    }

    fn collectSa1Dirty(self: *Cartridge, device: *sa1.Device) void {
        if (device.takeDirtyRange()) |dirty| {
            if (self.board.battery) self.markSramDirty(dirty.first, dirty.end);
        }
    }

    pub fn dirtyRange(self: *const Cartridge) ?struct { first: usize, end: usize } {
        if (!self.sram_dirty) return null;
        return .{ .first = self.sram_dirty_first, .end = self.sram_dirty_end };
    }

    pub fn clearSramDirty(self: *Cartridge) void {
        self.sram_dirty = false;
        self.sram_dirty_first = 0;
        self.sram_dirty_end = 0;
    }

    fn markSramDirty(self: *Cartridge, first: usize, end: usize) void {
        if (!self.sram_dirty) {
            self.sram_dirty = true;
            self.sram_dirty_first = first;
            self.sram_dirty_end = end;
            return;
        }
        self.sram_dirty_first = @min(self.sram_dirty_first, first);
        self.sram_dirty_end = @max(self.sram_dirty_end, end);
    }

    pub fn identityHex(self: *const Cartridge) [64]u8 {
        var result: [64]u8 = undefined;
        _ = std.fmt.bufPrint(result[0..], "{x}", .{self.identity}) catch unreachable;
        return result;
    }
};

pub const ContainerGeometry = struct {
    cartridge: CandidateGeometry,
    appended_firmware: bool,
    appended_firmware_bytes: usize = 0,
};

const SourceParts = struct {
    geometry: CandidateGeometry,
    cartridge: []const u8,
    appended_firmware: ?[]const u8,
};

/// Size-only preflight. The appended case remains provisional until parsing
/// proves that the normalized cartridge actually declares a NEC-DSP board.
pub fn inspectContainerSize(file_size: usize) !ContainerGeometry {
    if (inspectCandidateSize(file_size)) |geometry| {
        return .{ .cartridge = geometry, .appended_firmware = false };
    } else |ordinary_fault| {
        const firmware_sizes = [_]usize{ nec_dsp.firmware_bytes, nec_dsp.st_firmware_bytes };
        for (firmware_sizes) |firmware_size| {
            if (file_size < firmware_size) continue;
            const cartridge_size = file_size - firmware_size;
            const geometry = inspectCandidateSize(cartridge_size) catch continue;
            return .{
                .cartridge = geometry,
                .appended_firmware = true,
                .appended_firmware_bytes = firmware_size,
            };
        }
        return ordinary_fault;
    }
}

pub fn inspectNecDspRequirement(source: []const u8, revision_override: ?nec_dsp.Revision) !?NecDspRequirement {
    const parts = try splitSource(source);
    const normalized_start: usize = if (parts.geometry.copier_header) copier_header_size else 0;
    const normalized = parts.cartridge[normalized_start..];
    const header = try selectHeader(normalized);
    const enhancement = board.enhancementForHeader(header.rom_type, header.map_mode);
    if (enhancement != .dsp1_family and enhancement != .st010_st011) {
        if (parts.appended_firmware != null) return error.UnexpectedAppendedFirmware;
        return null;
    }
    const revision = try selectNecDspRevision(header, parts.appended_firmware, revision_override);
    try validateNecDspHeader(revision, header);
    return .{ .revision = revision, .appended = parts.appended_firmware != null };
}

pub fn inspectSt018Requirement(source: []const u8) !?St018Requirement {
    const parts = try splitSource(source);
    const normalized_start: usize = if (parts.geometry.copier_header) copier_header_size else 0;
    const normalized = parts.cartridge[normalized_start..];
    const header = try selectHeader(normalized);
    if (board.enhancementForHeader(header.rom_type, header.map_mode) != .st018) return null;
    try validateSt018Header(header, hasBattery(header.rom_type), st018.work_ram_bytes);
    return .{};
}

fn splitSource(source: []const u8) !SourceParts {
    const container = try inspectContainerSize(source.len);
    if (!container.appended_firmware) {
        return .{ .geometry = container.cartridge, .cartridge = source, .appended_firmware = null };
    }
    const split_at = source.len - container.appended_firmware_bytes;
    return .{
        .geometry = container.cartridge,
        .cartridge = source[0..split_at],
        .appended_firmware = source[split_at..],
    };
}

fn selectNecDspRevision(
    header: Header,
    appended_firmware: ?[]const u8,
    revision_override: ?nec_dsp.Revision,
) !nec_dsp.Revision {
    if (revision_override) |revision| {
        try validateNecDspHeader(revision, header);
        return revision;
    }
    const detected = detectNecDspRevision(header);
    if (appended_firmware) |firmware| {
        if (revisionFromKnownFirmware(firmware)) |firmware_revision| {
            const detected_is_dsp1 = detected == .dsp1 or detected == .dsp1a or detected == .dsp1b;
            const firmware_is_dsp1 = firmware_revision == .dsp1 or firmware_revision == .dsp1a or firmware_revision == .dsp1b;
            if (detected_is_dsp1 and firmware_is_dsp1) return firmware_revision;
            if (detected != firmware_revision) return error.NecDspFirmwareRevisionMismatch;
        }
    }
    return detected;
}

fn detectNecDspRevision(header: Header) nec_dsp.Revision {
    const mode = header.map_mode & 0x3f;
    if (header.rom_type == 0xf6 and mode == 0x30) {
        // The only ST011 board uses a 512-KiB program ROM. Explicit board
        // metadata or a known appended firmware digest remains authoritative.
        return if (header.rom_size_code == 0x09) .st011 else .st010;
    }
    if (header.rom_type == 0x03 and mode == 0x30) return .dsp4;
    if (header.rom_type == 0x05 and mode == 0x20) return .dsp2;
    if (header.rom_type == 0x05 and mode == 0x30 and header.licensee_code == 0xb2) return .dsp3;
    return .dsp1b;
}

fn validateNecDspHeader(revision: nec_dsp.Revision, header: Header) !void {
    const mode = header.map_mode & 0x3f;
    switch (revision) {
        .dsp1, .dsp1a, .dsp1b => {
            // The standard header is ambiguous: explicit board metadata may
            // override the common DSP-2/3/4 heuristics for a DSP-1 package.
            if ((header.mapping != .lo_rom and header.mapping != .hi_rom) or
                (header.rom_type != 0x03 and header.rom_type != 0x05))
                return error.ContradictoryNecDspBoard;
        },
        .dsp2 => if (header.rom_type != 0x05 or mode != 0x20)
            return error.ContradictoryNecDspBoard,
        .dsp3 => if (header.rom_type != 0x05 or mode != 0x30 or header.licensee_code != 0xb2)
            return error.ContradictoryNecDspBoard,
        .dsp4 => if (header.rom_type != 0x03 or mode != 0x30)
            return error.ContradictoryNecDspBoard,
        .st010, .st011 => if (header.mapping != .lo_rom or header.rom_type != 0xf6 or
            mode != 0x30 or header.cartridge_subtype != 0x01)
            return error.ContradictoryNecDspBoard,
    }
}

fn validateSt018Header(header: Header, battery: bool, persistent_bytes: usize) !void {
    if (header.mapping != .lo_rom or header.rom_type != 0xf5 or
        (header.map_mode & 0x3f) != 0x30 or header.cartridge_subtype != 0x02 or
        !battery or persistent_bytes != st018.work_ram_bytes)
        return error.ContradictorySt018Board;
}

fn revisionFromKnownFirmware(bytes: []const u8) ?nec_dsp.Revision {
    var actual: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &actual, .{});
    const revisions = [_]nec_dsp.Revision{ .dsp1a, .dsp1b, .dsp2, .dsp3, .dsp4, .st010, .st011 };
    for (revisions) |revision| {
        if (bytes.len != revision.firmwareBytes()) continue;
        const known = revision.knownDigest();
        if (std.mem.eql(u8, &actual, &known)) return revision;
    }
    return null;
}

/// Performs bounds and copier-header geometry validation without reading or
/// mutating cartridge bytes.
pub fn inspectCandidateSize(file_size: usize) !CandidateGeometry {
    if (file_size > maximum_source_size) return error.CartridgeTooLarge;
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

const HeaderLocation = struct {
    offset: usize,
    mapping: board.Mapping,
};

const locations = [_]HeaderLocation{
    .{ .offset = 0x007FC0, .mapping = .lo_rom },
    .{ .offset = 0x00FFC0, .mapping = .hi_rom },
    .{ .offset = 0x407FC0, .mapping = .ex_lo_rom },
    .{ .offset = 0x40FFC0, .mapping = .ex_hi_rom },
};

fn selectHeader(rom: []const u8) !Header {
    var selected: ?Header = null;
    var tied = false;
    for (locations) |location| {
        const candidate = parseHeaderCandidate(rom, location) orelse continue;
        if (selected == null or candidate.score > selected.?.score) {
            selected = candidate;
            tied = false;
        } else if (candidate.score == selected.?.score) {
            tied = true;
        }
    }
    if (selected == null) return error.NoValidHeader;
    if (tied) return error.AmbiguousHeader;
    return selected.?;
}

fn parseHeaderCandidate(rom: []const u8, location: HeaderLocation) ?Header {
    if (location.offset + header_length > rom.len) return null;
    const bytes = rom[location.offset .. location.offset + header_length];
    const map_mode = bytes[0x15];
    if ((map_mode & 0x20) == 0) return null;
    const enhancement = board.enhancementForHeader(bytes[0x16], map_mode);
    const revision_family = if (enhancement == .unknown) board.unsupportedRevisionFamily(bytes[0x16], map_mode) else null;
    const candidate_mapping: ?board.Mapping = if (enhancement == .unknown)
        if (revision_family) |family| switch (family) {
            .obc1, .sdd1 => .lo_rom,
            .srtc => .ex_hi_rom,
            .spc7110 => .hi_rom,
            .super_fx, .sa1, .cx4 => .lo_rom,
        } else board.mappingForHeader(map_mode, enhancement)
    else
        board.mappingForHeader(map_mode, enhancement);
    const special_normal_mapping = enhancement == .sdd1 or enhancement == .spc7110_epson_rtc or
        revision_family == .sdd1 or revision_family == .spc7110;
    if ((location.mapping == .ex_lo_rom or location.mapping == .ex_hi_rom) and rom.len <= 4 * 1024 * 1024) return null;
    if ((location.mapping == .lo_rom or location.mapping == .hi_rom) and rom.len > 4 * 1024 * 1024 and
        !special_normal_mapping) return null;
    if (candidate_mapping != location.mapping) return null;
    const region = board.regionForCode(bytes[0x19]) orelse return null;
    const reset_vector = readU16(bytes[0x3C..0x3E]);
    if (reset_vector < 0x8000) return null;
    const startup_index = board.decodeRomIndex(location.mapping, @as(u32, reset_vector), rom.len) orelse return null;
    const startup_opcode = rom[startup_index];
    if (startup_opcode == 0x00 or startup_opcode == 0xFF) return null;

    const declared_rom_bytes = sizeCodeBytes(bytes[0x17]) orelse return null;
    if (declared_rom_bytes < minimum_rom_size or declared_rom_bytes > maximum_rom_size) return null;
    if (declared_rom_bytes > rom.len *| 2 or rom.len > declared_rom_bytes *| 2) return null;
    const declared_sram_bytes = ramCodeBytes(bytes[0x18]) orelse return null;
    if (enhancement == .none) {
        if (bytes[0x16] == 0x00 and declared_sram_bytes != 0) return null;
        if ((bytes[0x16] == 0x01 or bytes[0x16] == 0x02) and declared_sram_bytes == 0) return null;
    }

    const complement = readU16(bytes[0x1C..0x1E]);
    const checksum = readU16(bytes[0x1E..0x20]);
    const checksum_present = checksum != 0 or complement != 0;
    if (checksum_present and (checksum ^ complement) != 0xFFFF) return null;
    const calculated_checksum = checksum16(rom);

    var title: [title_length]u8 = undefined;
    @memcpy(title[0..], bytes[0..title_length]);
    if (!plausibleTitle(title[0..])) return null;

    var score: i16 = 16;
    if (plausibleStartup(startup_opcode)) score += 4 else score += 1;
    if (declared_rom_bytes == rom.len) score += 4;
    if (checksum_present) score += 2;
    if (checksum_present and checksum == calculated_checksum) score += 2;
    if (enhancement != .unknown) score += 2;
    if (bytes[0x18] == 0 or bytes[0x16] != 0x00) score += 1;

    return .{
        .offset = location.offset,
        .mapping = location.mapping,
        .region = region,
        .map_mode = map_mode,
        .rom_type = bytes[0x16],
        .rom_size_code = bytes[0x17],
        .ram_size_code = bytes[0x18],
        .region_code = bytes[0x19],
        .licensee_code = bytes[0x1A],
        .version = bytes[0x1B],
        .expansion_ram_size_code = rom[location.offset - 3],
        .cartridge_subtype = rom[location.offset - 1],
        .reset_vector = reset_vector,
        .startup_opcode = startup_opcode,
        .checksum = checksum,
        .checksum_complement = complement,
        .checksum_present = checksum_present,
        .checksum_matches = checksum_present and checksum == calculated_checksum,
        .declared_rom_bytes = declared_rom_bytes,
        .declared_sram_bytes = declared_sram_bytes,
        .title = title,
        .score = score,
    };
}

fn sizeCodeBytes(code: u8) ?usize {
    if (code > 16) return null;
    return @as(usize, 1) << @intCast(@as(u16, code) + 10);
}

fn ramCodeBytes(code: u8) ?usize {
    if (code == 0) return 0;
    if (code > 11) return null;
    return @as(usize, 1) << @intCast(@as(u16, code) + 10);
}

fn hasBattery(rom_type: u8) bool {
    return switch (rom_type & 0x0F) {
        0x02, 0x05, 0x06, 0x09, 0x0A => true,
        else => false,
    };
}

fn readU16(bytes: []const u8) u16 {
    return @as(u16, bytes[0]) | (@as(u16, bytes[1]) << 8);
}

fn checksum16(bytes: []const u8) u16 {
    var result: u16 = 0;
    for (bytes) |value| result +%= value;
    return result;
}

fn plausibleTitle(title: []const u8) bool {
    var visible: usize = 0;
    for (title) |value| {
        if (value == 0 or value == 0xFF) continue;
        if (value < 0x20 or value == 0x7F) return false;
        if (value != ' ') visible += 1;
    }
    return visible >= 3;
}

fn plausibleStartup(opcode: u8) bool {
    return switch (opcode) {
        0x18, 0x38, 0x4C, 0x5C, 0x78, 0x9C, 0xA2, 0xA9, 0xC2, 0xD8, 0xE2, 0xF8, 0xFB => true,
        else => false,
    };
}
