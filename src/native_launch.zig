//! Native selectors are outside the opaque guest launch record.
const r4os = @import("r4os");
const std = @import("std");
pub const Diagnostic = enum { product, performance, performance_check, persistence, host, core };
pub fn diagnostic(args: []const u8) Diagnostic {
    if (std.mem.startsWith(u8, args, r4os.subsystem_launch.magic)) return .product;
    var failure: r4os.arguments.Failure = .{};
    var cursor = r4os.arguments.ArgCursor.init(args, .{}, &failure) catch return .product;
    const token = (cursor.next() catch return .product) orelse return .product;
    if (token.switchIs(args, "PERFTEST") catch false) return .performance;
    if (token.switchIs(args, "PERFCHECK") catch false) return .performance_check;
    if ((cursor.next() catch return .product) != null) return .product;
    if (token.switchIs(args, "PERSISTTEST") catch false) return .persistence;
    if (token.switchIs(args, "HOSTTEST") catch false) return .host;
    if (token.switchIs(args, "SELFTEST") catch false) return .core;
    return .product;
}
