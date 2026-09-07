const std = @import("std");

/// Bounded cumulative pages relative to an exact raw .SAV digest. Each .SDJ
/// is replaced atomically; it never depends on an earlier journal snapshot.
pub const record_bytes = 16 * 1024;
pub const page_bytes = 256;
const header_bytes = 96;
const entry_bytes = 4 + page_bytes;
pub const maximum_pages = (record_bytes - header_bytes) / entry_bytes;
const magic = "R4SNDEL1";
const Hash = std.crypto.hash.sha2.Sha256;

pub const Journal = struct {
    bytes: [record_bytes]u8 = .{0} ** record_bytes,

    pub fn init(size: usize, base_digest: [32]u8) Journal {
        var result = Journal{};
        @memcpy(result.bytes[0..8], magic);
        put(result.bytes[8..12], @intCast(size));
        @memcpy(result.bytes[16..48], &base_digest);
        result.seal();
        return result;
    }

    pub fn count(self: *const Journal) usize {
        return get(self.bytes[12..16]);
    }

    pub fn base(self: *const Journal) [32]u8 {
        return self.bytes[16..48].*;
    }

    /// No mutation on capacity failure. Changed pages are copied only once
    /// into this bounded buffer, then the backend owns its immutable snapshot.
    pub fn capture(self: *Journal, ram: []const u8, first: usize, end: usize) bool {
        std.debug.assert(first < end and end <= ram.len);
        const first_page = first / page_bytes;
        const end_page = (end + page_bytes - 1) / page_bytes;
        var missing: usize = 0;
        for (first_page..end_page) |page| {
            if (self.find(page) == null) missing += 1;
            if (self.count() + missing > maximum_pages) return false;
        }
        for (first_page..end_page) |page| {
            const index = self.find(page) orelse blk: {
                const index = self.count();
                put(self.bytes[12..16], @intCast(index + 1));
                break :blk index;
            };
            const entry = self.bytes[header_bytes + index * entry_bytes ..][0..entry_bytes];
            put(entry[0..4], @intCast(page));
            const start = page * page_bytes;
            const length = @min(page_bytes, ram.len - start);
            @memset(entry[4..], 0);
            @memcpy(entry[4..][0..length], ram[start..][0..length]);
        }
        self.seal();
        return true;
    }

    pub fn apply(self: *const Journal, ram: []u8, expected_base: [32]u8) bool {
        if (get(self.bytes[8..12]) != ram.len or !std.mem.eql(u8, self.bytes[16..48], &expected_base)) return false;
        for (0..self.count()) |index| {
            const entry = self.bytes[header_bytes + index * entry_bytes ..][0..entry_bytes];
            const start = @as(usize, get(entry[0..4])) * page_bytes;
            const length = @min(page_bytes, ram.len - start);
            @memcpy(ram[start..][0..length], entry[4..][0..length]);
        }
        return true;
    }

    fn find(self: *const Journal, page: usize) ?usize {
        for (0..self.count()) |index| {
            if (get(self.bytes[header_bytes + index * entry_bytes ..][0..4]) == page) return index;
        }
        return null;
    }

    fn seal(self: *Journal) void {
        var hash = Hash.init(.{});
        hash.update(self.bytes[0..64]);
        hash.update(self.bytes[96..]);
        hash.final(self.bytes[64..96]);
    }
};

pub fn validate(bytes: []const u8) bool {
    if (bytes.len != record_bytes or !std.mem.eql(u8, bytes[0..8], magic)) return false;
    const size = get(bytes[8..12]);
    const count = get(bytes[12..16]);
    if (size == 0 or size > 2 * 1024 * 1024 or count > maximum_pages) return false;
    for (bytes[48..64]) |byte| if (byte != 0) return false;
    for (0..count) |index| {
        const entry = bytes[header_bytes + index * entry_bytes ..][0..entry_bytes];
        const page = get(entry[0..4]);
        if (page >= (size + page_bytes - 1) / page_bytes) return false;
        for (0..index) |previous| {
            if (page == get(bytes[header_bytes + previous * entry_bytes ..][0..4])) return false;
        }
        const length = @min(page_bytes, size - page * page_bytes);
        for (entry[4 + length ..]) |byte| if (byte != 0) return false;
    }
    for (bytes[header_bytes + count * entry_bytes ..]) |byte| if (byte != 0) return false;
    var digest: [32]u8 = undefined;
    var hash = Hash.init(.{});
    hash.update(bytes[0..64]);
    hash.update(bytes[96..]);
    hash.final(&digest);
    return std.mem.eql(u8, &digest, bytes[64..96]);
}

fn put(bytes: []u8, value: u32) void {
    std.mem.writeInt(u32, bytes[0..4], value, .little);
}

fn get(bytes: []const u8) u32 {
    return std.mem.readInt(u32, bytes[0..4], .little);
}
