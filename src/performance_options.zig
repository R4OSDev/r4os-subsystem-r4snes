const std = @import("std");

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

pub fn command(text: []const u8, name: []const u8) bool {
    return text.len >= name.len and std.ascii.eqlIgnoreCase(text[0..name.len], name) and
        (text.len == name.len or std.ascii.isWhitespace(text[name.len]));
}

pub fn guest(text: []const u8) !Options {
    var options = Options{};
    var words = std.mem.tokenizeAny(u8, text, " \t\r\n");
    _ = words.next();
    while (words.next()) |word| {
        if (std.ascii.eqlIgnoreCase(word, "/PAL")) options.region = .pal else
        if (std.ascii.eqlIgnoreCase(word, "/NTSC")) options.region = .ntsc else
        if (std.ascii.eqlIgnoreCase(word, "/NORMAL")) options.mode = .normal else
        if (std.ascii.eqlIgnoreCase(word, "/DETAIL")) options.mode = .detail else
        if (std.ascii.eqlIgnoreCase(word, "/PAIRED")) options.mode = .paired else return error.InvalidBenchmarkOption;
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
