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

pub fn r4_app_main(app: *r4os.App) i32 {
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
    // 5A22, DMA/HDMA, PPU and S-SMP are qualified independently; productive
    // execution is rejected until S-DSP and runtime-machine stages complete.
    sys.println("R4SNES: cartridge, CPU, 5A22, complete PPU and SPC700 recognized; S-DSP/runtime integration is not implemented in 0.8.0.");
    return error_not_implemented;
}

fn cartridgeError(fault: anyerror) []const u8 {
    return switch (fault) {
        error.AmbiguousHeader => "R4SNES: cartridge contains ambiguous SNES headers.",
        error.NoValidHeader => "R4SNES: no consistent SNES header was found.",
        error.ExcludedBoard => "R4SNES: cartridge belongs to an excluded adapter or extension system.",
        error.UnsupportedBoard => "R4SNES: cartridge board is unknown or unsupported.",
        error.OutOfMemory => "R4SNES: cartridge memory could not be allocated.",
        else => "R4SNES: cartridge validation failed.",
    };
}

fn selfTest(app: *r4os.App) i32 {
    const sys = app.system();
    var machine = core.machine.Machine.init(1);
    if (!machine.foundationReady() or core.cpu.opcode_table.len != 256 or !machine.scpu.cpuMayRun()) return error_not_implemented;
    machine.smp.bus_mode = .vector_ram;
    machine.smp.pc = 0x0200;
    machine.smp.aram[0x0200] = 0x00;
    machine.smp.step() catch return error_not_implemented;
    if (machine.smp.pc != 0x0201) return error_not_implemented;
    machine.close();
    if (!machine.closed) return error_not_implemented;
    sys.println("R4SNES SELFTEST OK: CPU, timed 5A22, byte-bounded DMA, complete PPU and SPC700/S-SMP owners isolated; incomplete S-DSP/runtime execution safely rejected.");
    return 0;
}
