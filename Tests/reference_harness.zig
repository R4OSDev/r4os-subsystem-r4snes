const std = @import("std");
const core = @import("core");

const max_manifest_bytes: usize = 512 * 1024;
const max_vector_bytes: usize = 2 * 1024 * 1024;
const max_rom_bytes: usize = core.cartridge.maximum_rom_size + core.cartridge.copier_header_size + 1;

const Expected = struct {
    schema: u32,
    references_sha256: []const u8,
    qualification_matrix_sha256: []const u8,
    repositories: usize,
    downloads: usize,
    trees: usize,
    test_roms: usize,
    spc700_files: usize,
    spc700_records: usize,
};

const References = struct {
    schema: u32,
    repositories: []const std.json.Value,
    files: []const std.json.Value,
    trees: []const std.json.Value,
};

const Corpus = struct {
    test_roms: usize,
    spc700_single_step_files: usize,
    spc700_single_step_records: usize,
    commercial_roms: usize,
    proprietary_firmware_images: usize,
};

const MatrixSuite = struct {
    rom_count: ?usize = null,
};

const Matrix = struct {
    schema: u32,
    release: []const u8,
    corpus: Corpus,
    suites: []const MatrixSuite,
};

pub fn main(init: std.process.Init) void {
    run(init) catch |fault| {
        std.debug.print("R4SNES reference harness FAILED: {s}\n", .{@errorName(fault)});
        std.process.exit(1);
    };
}

fn run(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const cwd = std.Io.Dir.cwd();
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const root = if (args.len >= 2) args[1] else "../../../ExFiles/Reference/SNES";
    const matrix_path = if (args.len >= 3) args[2] else "../../../Docs/Subsystems/SNESQualificationMatrix.json";

    const expected_bytes = try cwd.readFileAlloc(io, "Tests/reference_manifest.json", allocator, .limited(max_manifest_bytes));
    defer allocator.free(expected_bytes);
    var parsed_expected = try std.json.parseFromSlice(Expected, allocator, expected_bytes, .{});
    defer parsed_expected.deinit();
    const expected = parsed_expected.value;
    if (expected.schema != 1) return error.UnsupportedExpectedSchema;

    const matrix_bytes = try cwd.readFileAlloc(io, matrix_path, allocator, .limited(max_manifest_bytes));
    defer allocator.free(matrix_bytes);
    try expectSha256(matrix_bytes, expected.qualification_matrix_sha256);
    var parsed_matrix = try std.json.parseFromSlice(Matrix, allocator, matrix_bytes, .{ .ignore_unknown_fields = true });
    defer parsed_matrix.deinit();
    const matrix = parsed_matrix.value;
    if (matrix.schema != 1 or !std.mem.eql(u8, matrix.release, "0.73.1")) return error.UnsupportedQualificationMatrix;
    if (matrix.suites.len != 9 or matrix.corpus.test_roms != expected.test_roms or
        matrix.corpus.spc700_single_step_files != expected.spc700_files or
        matrix.corpus.spc700_single_step_records != expected.spc700_records or
        matrix.corpus.commercial_roms != 0 or matrix.corpus.proprietary_firmware_images != 0)
    {
        return error.QualificationMatrixMismatch;
    }
    var matrix_roms: usize = 0;
    for (matrix.suites) |suite| matrix_roms += suite.rom_count orelse 0;
    if (matrix_roms != expected.test_roms) return error.QualificationSuiteCountMismatch;

    cwd.access(io, root, .{}) catch {
        std.debug.print("R4SNES reference harness SKIP: optional root missing: {s}\n", .{root});
        return;
    };

    const references_path = try std.fs.path.join(allocator, &.{ root, "References.json" });
    defer allocator.free(references_path);
    const references_bytes = try cwd.readFileAlloc(io, references_path, allocator, .limited(max_manifest_bytes));
    defer allocator.free(references_bytes);
    try expectSha256(references_bytes, expected.references_sha256);
    var parsed_references = try std.json.parseFromSlice(References, allocator, references_bytes, .{ .ignore_unknown_fields = true });
    defer parsed_references.deinit();
    const references = parsed_references.value;
    if (references.schema != 1 or references.repositories.len != expected.repositories or
        references.files.len != expected.downloads or references.trees.len != expected.trees)
    {
        return error.ReferenceManifestMismatch;
    }

    const rom_root = try std.fs.path.join(allocator, &.{ root, "Tests", "Binaries" });
    defer allocator.free(rom_root);
    const roms = try scanRoms(allocator, io, cwd, rom_root);
    if (roms != expected.test_roms) return error.RomCountMismatch;

    const vector_root = try std.fs.path.join(allocator, &.{ root, "Tests", "SPC700-SingleStep", "v1" });
    defer allocator.free(vector_root);
    const vectors = try scanVectors(allocator, io, cwd, vector_root);
    if (vectors.files != expected.spc700_files or vectors.records != expected.spc700_records) {
        return error.VectorCountMismatch;
    }

    std.debug.print(
        "R4SNES reference harness OK: repositories={d} downloads={d} trees={d} ROMs={d} SPC700-files={d} vectors={d}\n",
        .{ expected.repositories, expected.downloads, expected.trees, roms, vectors.files, vectors.records },
    );
}

fn expectSha256(bytes: []const u8, expected: []const u8) !void {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    var actual: [64]u8 = undefined;
    _ = std.fmt.bufPrint(actual[0..], "{x}", .{digest}) catch unreachable;
    if (!std.mem.eql(u8, expected, actual[0..])) return error.DigestMismatch;
}

fn scanRoms(allocator: std.mem.Allocator, io: std.Io, cwd: std.Io.Dir, root: []const u8) !usize {
    var dir = try cwd.openDir(io, root, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    var count: usize = 0;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or
            (!std.ascii.endsWithIgnoreCase(entry.path, ".sfc") and !std.ascii.endsWithIgnoreCase(entry.path, ".smc"))) continue;
        const path = try std.fs.path.join(allocator, &.{ root, entry.path });
        defer allocator.free(path);
        const bytes = try cwd.readFileAlloc(io, path, allocator, .limited(max_rom_bytes));
        defer allocator.free(bytes);
        _ = try core.cartridge.inspectCandidateSize(bytes.len);
        count += 1;
    }
    return count;
}

const VectorCounts = struct { files: usize = 0, records: usize = 0 };

fn scanVectors(allocator: std.mem.Allocator, io: std.Io, cwd: std.Io.Dir, root: []const u8) !VectorCounts {
    var dir = try cwd.openDir(io, root, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    var result = VectorCounts{};
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.ascii.endsWithIgnoreCase(entry.path, ".json")) continue;
        const path = try std.fs.path.join(allocator, &.{ root, entry.path });
        defer allocator.free(path);
        const bytes = try cwd.readFileAlloc(io, path, allocator, .limited(max_vector_bytes));
        defer allocator.free(bytes);
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
        defer parsed.deinit();
        const records = switch (parsed.value) {
            .array => |array| array.items.len,
            else => return error.InvalidVectorFile,
        };
        if (records != 1000) return error.InvalidVectorRecordCount;
        result.files += 1;
        result.records += records;
    }
    return result;
}
