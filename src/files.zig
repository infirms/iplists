const std = @import("std");

const Allocator = std.mem.Allocator;
const Io = std.Io;

fn lessThan(_: void, lhs: []u8, rhs: []u8) bool {
    return std.mem.lessThan(u8, lhs, rhs);
}

pub fn listEntries(
    allocator: Allocator,
    io: Io,
    directory_path: []const u8,
    expected_kind: Io.File.Kind,
    suffix: []const u8,
) ![][]u8 {
    var directory = try Io.Dir.cwd().openDir(io, directory_path, .{ .iterate = true });
    defer directory.close(io);

    var names: std.ArrayList([]u8) = .empty;
    errdefer {
        for (names.items) |name| allocator.free(name);
        names.deinit(allocator);
    }

    var iterator = directory.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.kind != expected_kind or !std.mem.endsWith(u8, entry.name, suffix)) continue;
        const name = try allocator.dupe(u8, entry.name);
        errdefer allocator.free(name);
        try names.append(allocator, name);
    }
    std.sort.heap([]u8, names.items, {}, lessThan);
    return names.toOwnedSlice(allocator);
}

pub fn freeStrings(allocator: Allocator, strings: []const []u8) void {
    for (strings) |string| allocator.free(string);
    allocator.free(strings);
}

pub fn pruneStaleGeneratedFiles(
    allocator: Allocator,
    io: Io,
    directory_path: []const u8,
    services: []const []const u8,
    suffixes: []const []const u8,
) !void {
    const filenames = try listEntries(allocator, io, directory_path, .file, "");
    defer freeStrings(allocator, filenames);

    var directory = try Io.Dir.cwd().openDir(io, directory_path, .{
        .follow_symlinks = false,
    });
    defer directory.close(io);

    next_file: for (filenames) |filename| {
        var managed = false;
        for (suffixes) |suffix| {
            if (!std.mem.endsWith(u8, filename, suffix)) continue;
            managed = true;

            const service_name = filename[0 .. filename.len - suffix.len];
            for (services) |service| {
                if (std.mem.eql(u8, service_name, service)) continue :next_file;
            }
        }
        // note (safety): Preserve files outside the explicitly managed naming scheme.
        if (!managed) continue;

        try directory.deleteFile(io, filename);
        std.log.info("removed stale output {s} from {s}", .{ filename, directory_path });
    }
}

test "pruning removes only stale generated files" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const directory_path = try std.fs.path.join(allocator, &.{
        ".zig-cache",
        "tmp",
        tmp.sub_path[0..],
    });
    defer allocator.free(directory_path);

    for ([_][]const u8{
        "spotify_domains.json",
        "spotify_ipv4_cidr.json",
        "removed_domains.json",
        "notes.txt",
    }) |filename| {
        try tmp.dir.writeFile(io, .{ .sub_path = filename, .data = "" });
    }
    var manual_directory = try tmp.dir.createDirPathOpen(io, "manual", .{});
    manual_directory.close(io);

    const services = [_][]const u8{"spotify"};
    const suffixes = [_][]const u8{ "_domains.json", "_ipv4_cidr.json" };
    try pruneStaleGeneratedFiles(allocator, io, directory_path, &services, &suffixes);

    try std.testing.expect((try tmp.dir.statFile(io, "spotify_domains.json", .{})).kind == .file);
    try std.testing.expect((try tmp.dir.statFile(io, "spotify_ipv4_cidr.json", .{})).kind == .file);
    try std.testing.expect((try tmp.dir.statFile(io, "notes.txt", .{})).kind == .file);
    try std.testing.expect((try tmp.dir.statFile(io, "manual", .{})).kind == .directory);
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "removed_domains.json", .{}));
}
