const std = @import("std");
const r4os = @import("r4os");

pub const Region = enum { ntsc, pal };
pub const Mode = enum { normal, detail, paired };
pub const Options = struct {
    region: Region = .ntsc,
    mode: Mode = .paired,
    check: bool = false,

    pub fn count(self: Options, check: bool) usize {
        return if (check) 1 else if (self.mode == .paired) 10 else 5;
    }
    pub fn sample(self: Options, index: usize) usize {
        return if (self.mode == .paired) index / 2 + 1 else index + 1;
    }
    pub fn detailed(self: Options, index: usize) bool {
        return switch (self.mode) {
            .normal => false,
            .detail => true,
            .paired => index % 2 == (index / 2) % 2,
        };
    }
};

pub fn guest(text: []const u8) !Options {
    var options = Options{};
    var failure: r4os.arguments.Failure = .{};
    var cursor = try r4os.arguments.ArgCursor.init(text, .{}, &failure);
    _ = (try cursor.next()) orelse return error.InvalidBenchmarkOption;
    while (try cursor.next()) |word| {
        if (try word.switchIs(text, "PAL")) options.region = .pal else
        if (try word.switchIs(text, "NTSC")) options.region = .ntsc else
        if (try word.switchIs(text, "NORMAL")) options.mode = .normal else
        if (try word.switchIs(text, "DETAIL")) options.mode = .detail else
        if (try word.switchIs(text, "PAIRED")) options.mode = .paired else return error.InvalidBenchmarkOption;
    }
    return options;
}

pub fn host(args: []const []const u8) !Options {
    var options = Options{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const key = args[i];
        if (std.mem.eql(u8, key, "--check-scene")) {
            options.check = true;
            continue;
        }
        i += 1;
        if (i >= args.len) return error.MissingBenchmarkOption;
        if (std.mem.eql(u8, key, "--region")) {
            options.region = std.meta.stringToEnum(Region, args[i]) orelse return error.InvalidBenchmarkOption;
        } else if (std.mem.eql(u8, key, "--mode")) {
            options.mode = std.meta.stringToEnum(Mode, args[i]) orelse return error.InvalidBenchmarkOption;
        } else return error.InvalidBenchmarkOption;
    }
    return options;
}
