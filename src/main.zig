const std = @import("std");
const r4os = @import("r4os");
const core = @import("core.zig");

const error_profile: i32 = 64;
const error_launch: i32 = 65;
const error_path: i32 = 66;
const error_missing: i32 = 67;
const error_directory: i32 = 68;
const error_size: i32 = 69;
const error_metadata: i32 = 70;
const error_cartridge: i32 = 71;
const error_not_implemented: i32 = 72;
const error_allocator: i32 = 73;
const error_firmware: i32 = 74;
const error_persistence_selftest: i32 = 75;

pub fn r4_app_main(app: *r4os.App) i32 {
    if (std.mem.indexOf(u8, app.args(), "/PERSISTTEST") != null) return persistenceSelfTest(app);
    if (std.ascii.eqlIgnoreCase(app.args(), "/SELFTEST")) return selfTest(app);
    if (app.profile != .desktop) return error_profile;
    const files = app.files() orelse return r4os.abi.err_no_group;
    const sys = app.system();
    const launch = r4os.subsystem_launch.parse(app.args()) catch {
        sys.println("R4SNES: invalid R4SUBSYS1 launch request.");
        return error_launch;
    };
    var path = r4os.AbsoluteFilePath.parse(launch.guest_path) catch {
        sys.println("R4SNES: invalid absolute cartridge path.");
        return error_path;
    };
    const info = switch (files.info(path.asZ())) {
        .value => |value| value,
        .missing => {
            sys.println("R4SNES: cartridge file not found.");
            return error_missing;
        },
        .failure => {
            sys.println("R4SNES: cartridge metadata could not be read.");
            return error_metadata;
        },
    };
    if (info.is_dir != 0) {
        sys.println("R4SNES: cartridge path is a directory.");
        return error_directory;
    }
    const size = std.math.cast(usize, info.size) orelse {
        sys.println("R4SNES: cartridge is too large for this host.");
        return error_size;
    };
    _ = core.cartridge.inspectCandidateSize(size) catch {
        sys.println("R4SNES: unsupported cartridge geometry.");
        return error_cartridge;
    };
    const allocator = app.allocator() orelse return error_allocator;
    const source = allocator.alloc(u8, size) catch {
        sys.println("R4SNES: cartridge buffer could not be allocated.");
        return error_allocator;
    };
    defer allocator.free(source);
    var offset: usize = 0;
    while (offset < source.len) {
        const count = switch (files.readAt(path.asZ(), @intCast(offset), source[offset..])) {
            .bytes => |value| value,
            .end, .failure => {
                sys.println("R4SNES: cartridge read was incomplete.");
                return error_metadata;
            },
        };
        if (count == 0) {
            sys.println("R4SNES: cartridge read made no progress.");
            return error_metadata;
        }
        offset += count;
    }
    var cartridge = core.cartridge.Cartridge.parse(allocator, source) catch |fault| {
        sys.println(cartridgeError(fault));
        return error_cartridge;
    };
    defer cartridge.deinit();

    const machine = allocator.create(core.machine.Machine) catch {
        sys.println("R4SNES: machine state could not be allocated.");
        return error_allocator;
    };
    defer allocator.destroy(machine);
    machine.* = core.machine.Machine.init(1);
    machine.smp.powerSemanticIpl();
    defer machine.smp.removeExactIpl();
    var firmware_path = r4os.AbsoluteFilePath.parse(core.persistence.spc700_ipl_path) catch {
        sys.println("R4SNES: internal SPC700 IPL path is invalid.");
        return error_firmware;
    };
    switch (files.info(firmware_path.asZ())) {
        .missing => {},
        .failure => {
            sys.println("R4SNES: optional SPC700.IPL metadata could not be read.");
            return error_firmware;
        },
        .value => |firmware_info| {
            if (firmware_info.is_dir != 0 or firmware_info.size != core.smp.exact_ipl_size) {
                sys.println("R4SNES: optional SPC700.IPL must be an exact 64-byte file.");
                return error_firmware;
            }
            var firmware: [core.smp.exact_ipl_size]u8 = undefined;
            var firmware_offset: usize = 0;
            while (firmware_offset < firmware.len) {
                const count = switch (files.readAt(firmware_path.asZ(), @intCast(firmware_offset), firmware[firmware_offset..])) {
                    .bytes => |value| value,
                    .end, .failure => {
                        sys.println("R4SNES: optional SPC700.IPL read was incomplete.");
                        return error_firmware;
                    },
                };
                if (count == 0) {
                    sys.println("R4SNES: optional SPC700.IPL read made no progress.");
                    return error_firmware;
                }
                firmware_offset += count;
            }
            machine.smp.installExactIpl(&firmware) catch {
                sys.println("R4SNES: optional SPC700.IPL validation failed.");
                return error_firmware;
            };
            machine.smp.reset();
            @memset(firmware[0..], 0);
        },
    }

    // Parsing owns a private normalized copy and exposes ROM as read-only. CPU,
    // 5A22, DMA/HDMA, PPU, S-SMP and S-DSP are qualified independently;
    // productive execution is rejected until the runtime-machine/window-host
    // stage composes those owners.
    sys.println("R4SNES: cartridge, OBC-1/S-RTC/S-DD1/SPC7110/Epson-RTC, CPU, 5A22, complete PPU, SPC700 and S-DSP recognized; productive runtime-machine integration is not implemented in 0.12.0.");
    return error_not_implemented;
}

fn cartridgeError(fault: anyerror) []const u8 {
    return switch (fault) {
        error.AmbiguousHeader => "R4SNES: cartridge contains ambiguous SNES headers.",
        error.NoValidHeader => "R4SNES: no consistent SNES header was found.",
        error.ExcludedBoard => "R4SNES: cartridge belongs to an excluded adapter or extension system.",
        error.UnsupportedBoard => "R4SNES: cartridge board is unknown or unsupported.",
        error.UnsupportedOBC1Revision => "R4SNES: cartridge declares an unsupported OBC-1 revision.",
        error.UnsupportedSrtcRevision => "R4SNES: cartridge declares an unsupported S-RTC revision.",
        error.UnsupportedSdd1Revision => "R4SNES: cartridge declares an unsupported S-DD1 revision.",
        error.UnsupportedSpc7110Revision => "R4SNES: cartridge declares an unsupported SPC7110 revision.",
        error.ContradictoryOBC1Board => "R4SNES: OBC-1 header contradicts its LoROM, battery or 8-KiB RAM profile.",
        error.ContradictorySrtcBoard => "R4SNES: S-RTC header contradicts its ExHiROM, battery or save-RAM profile.",
        error.ContradictorySdd1Board => "R4SNES: S-DD1 header contradicts its LoROM, battery or 32-KiB RAM profile.",
        error.ContradictorySpc7110Board => "R4SNES: SPC7110 header contradicts its HiROM, battery, 8-KiB RAM or data-ROM profile.",
        error.UnaddressableBoardGeometry => "R4SNES: cartridge board geometry exceeds its implemented address space.",
        error.OutOfMemory => "R4SNES: cartridge memory could not be allocated.",
        else => "R4SNES: cartridge validation failed.",
    };
}

fn selfTest(app: *r4os.App) i32 {
    const sys = app.system();
    var machine = core.machine.Machine.init(1);
    if (!machine.foundationReady() or core.cpu.opcode_table.len != 256 or !machine.scpu.cpuMayRun()) return error_not_implemented;
    machine.smp.dsp.beginCapture();
    machine.smp.dsp.runClocks(&machine.smp.aram, 64);
    if (machine.smp.dsp.sample_counter != 2 or machine.smp.dsp.queuedFrames() != 2) return error_not_implemented;
    machine.smp.bus_mode = .vector_ram;
    machine.smp.pc = 0x0200;
    machine.smp.aram[0x0200] = 0x00;
    machine.smp.step() catch return error_not_implemented;
    if (machine.smp.pc != 0x0201) return error_not_implemented;
    var object_ram = [_]u8{0} ** core.obc1.ram_bytes;
    var object = core.obc1.Device{};
    object.power(object_ram[0..]) catch return error_not_implemented;
    if (!object.write(object_ram[0..], 0x007FF0, 0xA5).changed or
        object.read(object_ram[0..], 0x807FF0) != 0xA5)
        return error_not_implemented;
    var rtc = core.srtc.Device{};
    rtc.power();
    if (!rtc.write(0x002801, 0x0E) or !rtc.write(0x002801, 0x04) or !rtc.halted)
        return error_not_implemented;
    var stream: [256]u8 = undefined;
    fillEnhancementSelfTest(&stream);
    stream[0] = 0;
    var sdd1 = core.sdd1.Decompressor{};
    sdd1.init(stream[0..], .{ 0, 1, 2, 3 }, 0xC00000);
    if (sdd1.read(stream[0..], .{ 0, 1, 2, 3 }) != 0x28 or
        sdd1.read(stream[0..], .{ 0, 1, 2, 3 }) != 0x07)
        return error_not_implemented;
    fillEnhancementSelfTest(&stream);
    var spc7110 = core.spc7110.Decompressor{};
    spc7110.init(stream[0..], 0, 0) catch return error_not_implemented;
    if ((spc7110.decode(stream[0..]) & 0xFF) != 0x5D) return error_not_implemented;
    var epson = core.epson_rtc.Device{};
    epson.power();
    if (!epson.isHalted() or !epson.writePort(0x4840, 1) or
        (epson.readPort(0x4842, 0) & 0x80) == 0)
        return error_not_implemented;
    machine.close();
    machine.close();
    if (!machine.closed or machine.smp.dsp.capture_enabled or machine.smp.dsp.queuedFrames() != 0) return error_not_implemented;
    sys.println("R4SNES SELFTEST OK: OBC-1/S-RTC/S-DD1/SPC7110/Epson-RTC, CPU, timed 5A22, byte-bounded DMA, complete PPU, SPC700/S-SMP and cycle-clocked S-DSP owners isolated; incomplete runtime-machine execution safely rejected.");
    return 0;
}

fn persistenceSelfTest(app: *r4os.App) i32 {
    runPersistenceSelfTest(app) catch |fault| {
        const sys = app.system();
        sys.write("R4SNES persistence runtime: FAILED ");
        sys.println(@errorName(fault));
        return error_persistence_selftest;
    };
    app.system().println("R4SNES persistence runtime: OK sav=exact rtc=versioned lock=exclusive atomic=recover async=worker+drain");
    return 0;
}

fn runPersistenceSelfTest(app: *r4os.App) !void {
    const allocator = app.allocator() orelse return error.AllocatorUnavailable;
    const files = app.files() orelse return error.FilesUnavailable;
    const sys = app.system();
    const wall = core.persistence_r4os.wallSeconds(sys.timeState());
    const monotonic = sys.monotonicNanoseconds() orelse 0;
    const generation = (sys.ticks() | 1) +| 2;

    var save_cart = try makePersistenceCart(allocator, 8192, true, .none, 0x73);
    defer save_cart.deinit();
    var async_store = core.persistence_r4os.AsyncStore.init(files, allocator);
    async_store.removeTestFiles(&save_cart.identity);
    defer async_store.removeTestFiles(&save_cart.identity);
    var save_session = try core.persistence.Session.open(&save_cart, async_store.backend(), generation, wall, monotonic);
    defer if (!save_session.closed) save_session.close(&save_cart, generation, wall, monotonic) catch {};
    for (save_cart.sram_storage, 0..) |_, index| save_cart.writeSram(index, @truncate(index *% 37 +% 11));
    try save_session.flush(&save_cart, wall, monotonic);
    save_cart.writeSram(0, 0xA7);
    try save_session.flush(&save_cart, wall, monotonic);

    var competing_cart = try makePersistenceCart(allocator, 8192, true, .none, 0x73);
    defer competing_cart.deinit();
    var competing_store = core.persistence_r4os.Store.init(files);
    const contention = core.persistence.Session.open(&competing_cart, competing_store.backend(), generation + 1, wall, monotonic);
    if (contention) |opened| {
        var unexpected = opened;
        unexpected.close(&competing_cart, generation + 1, wall, monotonic) catch {};
        return error.ExclusiveWriterAcceptedTwice;
    } else |fault| {
        if (fault != error.Busy) return fault;
    }
    try save_session.close(&save_cart, generation, wall, monotonic);
    if (async_store.stats.started == 0 or async_store.stats.started != async_store.stats.completed or async_store.stats.errors != 0)
        return error.AsyncPersistenceMismatch;

    var reopened_cart = try makePersistenceCart(allocator, 8192, true, .none, 0x73);
    defer reopened_cart.deinit();
    var reopened_store = core.persistence_r4os.Store.init(files);
    var reopened = try core.persistence.Session.open(&reopened_cart, reopened_store.backend(), generation + 2, wall, monotonic);
    if (reopened_cart.sram_storage[0] != 0xA7 or
        reopened_cart.sram_storage[1] != @as(u8, @truncate(1 * 37 + 11)) or
        reopened_cart.sram_storage[reopened_cart.sram_storage.len - 1] != @as(u8, @truncate((reopened_cart.sram_storage.len - 1) *% 37 +% 11)))
        return error.SramMismatch;
    try reopened.close(&reopened_cart, generation + 2, wall, monotonic);

    const sav_path = try core.persistence_r4os.dataPath(&save_cart.identity, .sram);
    if (!std.mem.startsWith(u8, sav_path.bytes(), core.persistence.save_root) or
        !std.mem.endsWith(u8, sav_path.bytes(), ".SAV") or
        std.mem.indexOf(u8, sav_path.bytes(), "\\APPDATA\\") != null)
        return error.NonCanonicalSavePath;

    var rtc_cart = try makePersistenceCart(allocator, 0, true, .srtc, 0x74);
    defer rtc_cart.deinit();
    var rtc_store = core.persistence_r4os.Store.init(files);
    rtc_store.removeTestFiles(&rtc_cart.identity);
    defer rtc_store.removeTestFiles(&rtc_cart.identity);
    var rtc_session = try core.persistence.Session.open(&rtc_cart, rtc_store.backend(), generation + 3, wall, monotonic);
    const rtc_state = rtc_session.rtcState() orelse return error.RtcMissing;
    setSrtcCalendar(rtc_state, 9, 7);
    rtc_state.overflow = true;
    try rtc_session.close(&rtc_cart, generation + 3, wall, monotonic);

    var recovery_state = core.persistence.RtcState.init(.s_rtc);
    setSrtcCalendar(&recovery_state, 4, 3);
    var recovery_record: [core.persistence.rtc_record_bytes]u8 = undefined;
    core.persistence.encodeRtc(.{
        .state = recovery_state,
        .wall_anchor_seconds = wall orelse 0,
        .monotonic_anchor_ns = monotonic,
        .generation = generation + 4,
    }, &recovery_record);
    try rtc_store.prepareInterruptedPublishForTest(&rtc_cart.identity, .rtc, recovery_record[0..]);
    var recovered_cart = try makePersistenceCart(allocator, 0, true, .srtc, 0x74);
    defer recovered_cart.deinit();
    var recovered = try core.persistence.Session.open(&recovered_cart, rtc_store.backend(), generation + 4, wall, monotonic);
    if (recovered.peekRtcState() == null or
        recovered.peekRtcState().?.registers[0] != 4 or
        recovered.peekRtcState().?.latched[0] != 3)
        return error.RtcRecoveryMismatch;
    try recovered.close(&recovered_cart, generation + 4, wall, monotonic);

    try rtc_store.prepareInterruptedPublishForTest(
        &rtc_cart.identity,
        .rtc,
        recovery_record[0 .. recovery_record.len / 2],
    );
    var rejected_cart = try makePersistenceCart(allocator, 0, true, .srtc, 0x74);
    defer rejected_cart.deinit();
    const rejected = core.persistence.Session.open(&rejected_cart, rtc_store.backend(), generation + 5, wall, monotonic);
    if (rejected) |opened| {
        var unexpected = opened;
        unexpected.close(&rejected_cart, generation + 5, wall, monotonic) catch {};
        return error.PartialRecoveryAccepted;
    } else |fault| {
        if (fault != error.Io) return fault;
    }
    if (!std.mem.eql(u8, rtc_store.failureStageName(), "atomic_recover") or
        rtc_store.failureCode() != r4os.abi.file_stream_error_size_mismatch)
        return error.PartialRecoveryFailureMismatch;

    var epson_cart = try makePersistenceCart(allocator, 8192, true, .spc7110_epson_rtc, 0x75);
    defer epson_cart.deinit();
    var epson_store = core.persistence_r4os.Store.init(files);
    epson_store.removeTestFiles(&epson_cart.identity);
    defer epson_store.removeTestFiles(&epson_cart.identity);
    var epson_session = try core.persistence.Session.open(&epson_cart, epson_store.backend(), generation + 6, wall, monotonic);
    const epson_state = epson_session.rtcState() orelse return error.EpsonRtcMissing;
    setEpsonCalendar(epson_state);
    try epson_session.close(&epson_cart, generation + 6, wall, monotonic);
    var reopened_epson_cart = try makePersistenceCart(allocator, 8192, true, .spc7110_epson_rtc, 0x75);
    defer reopened_epson_cart.deinit();
    var reopened_epson = try core.persistence.Session.open(&reopened_epson_cart, epson_store.backend(), generation + 7, wall, monotonic);
    const reopened_epson_state = reopened_epson.peekRtcState() orelse return error.EpsonRtcMissing;
    if (reopened_epson_state.chip != .epson or reopened_epson_state.registers[0] != 8 or
        reopened_epson_state.registers[1] != 5 or reopened_epson_state.registers[15] != 4)
        return error.EpsonRtcRecoveryMismatch;
    try reopened_epson.close(&reopened_epson_cart, generation + 7, wall, monotonic);
}

fn fillEnhancementSelfTest(bytes: *[256]u8) void {
    var state: u32 = 0x12345678;
    for (bytes) |*byte| {
        state = state *% 1664525 +% 1013904223;
        byte.* = @truncate(state >> 24);
    }
}

fn setSrtcCalendar(state: *core.persistence.RtcState, live_second: u8, latched_second: u8) void {
    const weekday = core.srtc.calculateWeekday(0, 1, 1);
    core.srtc.registersFromCalendar(.{
        .second = live_second,
        .minute = 0,
        .hour = 0,
        .day = 1,
        .month = 1,
        .year = 0,
        .weekday = weekday,
    }, &state.registers);
    core.srtc.registersFromCalendar(.{
        .second = latched_second,
        .minute = 0,
        .hour = 0,
        .day = 1,
        .month = 1,
        .year = 0,
        .weekday = weekday,
    }, &state.latched);
    state.halted = false;
}

fn setEpsonCalendar(state: *core.persistence.RtcState) void {
    state.registers = .{ 8, 5, 9, 5, 3, 2, 9, 2, 2, 0, 4, 2, 4, 2, 0, 4 };
    state.latched = state.registers;
    state.halted = false;
    state.pending_catchup_seconds = 0;
}

fn makePersistenceCart(
    allocator: std.mem.Allocator,
    ram_bytes: usize,
    battery: bool,
    enhancement: core.board.Enhancement,
    identity_byte: u8,
) !core.cartridge.Cartridge {
    const rom = try allocator.alloc(u8, core.cartridge.minimum_rom_size);
    errdefer allocator.free(rom);
    @memset(rom, 0);
    const ram = try allocator.alloc(u8, ram_bytes);
    errdefer allocator.free(ram);
    @memset(ram, 0);
    return .{
        .allocator = allocator,
        .rom_storage = rom,
        .sram_storage = ram,
        .identity = .{identity_byte} ** core.persistence.digest_bytes,
        .header = undefined,
        .board = .{
            .mapping = .lo_rom,
            .region = .ntsc_u,
            .fast_rom = false,
            .capability = core.board.capability(enhancement),
            .sram_bytes = ram_bytes,
            .battery = battery,
        },
        .had_copier_header = false,
    };
}
