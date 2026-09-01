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

    // Parsing owns a private normalized copy and exposes ROM as read-only. CPU
    // execution remains unavailable until the following roadmap stages.
    sys.println("R4SNES: cartridge and board recognized; execution is not implemented in 0.2.0.");
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
    if (!machine.foundationReady()) return error_not_implemented;
    machine.close();
    if (!machine.closed) return error_not_implemented;
    sys.println("R4SNES SELFTEST OK: hardware owners isolated; cartridge execution safely rejected.");
    return 0;
}
