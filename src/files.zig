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

pub fn removeUnlistedDirectories(
    allocator: Allocator,
    io: Io,
    directory_path: []const u8,
    keep: []const []const u8,
) !void {
    const directories = try listEntries(allocator, io, directory_path, .directory, "");
    defer freeStrings(allocator, directories);

    next_directory: for (directories) |name| {
        for (keep) |kept| {
            if (std.mem.eql(u8, name, kept)) continue :next_directory;
        }

        const path = try std.fs.path.join(allocator, &.{ directory_path, name });
        defer allocator.free(path);
        try Io.Dir.cwd().deleteTree(io, path);
        std.log.info("removed stale output {s}", .{path});
    }
}
