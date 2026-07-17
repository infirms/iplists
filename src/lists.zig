const std = @import("std");
const files = @import("files.zig");
const json = @import("json.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const output_dir = "lists";
pub const output_suffixes = [_][]const u8{
    "_domains.json",
    "_domains.txt",
    "_domains.csv",
    "_ipv4_cidr.json",
    "_ipv4_cidr.txt",
    "_ipv4_cidr.csv",
};

pub fn writeAll(
    allocator: Allocator,
    io: Io,
    service: []const u8,
    domains: []const []const u8,
    ipv4_cidrs: []const []const u8,
) !void {
    try writeList(allocator, io, service, "domains", domains);
    try writeList(allocator, io, service, "ipv4_cidr", ipv4_cidrs);
}

pub fn pruneStaleGeneratedFiles(
    allocator: Allocator,
    io: Io,
    services: []const []const u8,
) !void {
    return files.pruneStaleGeneratedFiles(
        allocator,
        io,
        output_dir,
        services,
        &output_suffixes,
    );
}

fn writeList(
    allocator: Allocator,
    io: Io,
    service: []const u8,
    kind: []const u8,
    values: []const []const u8,
) !void {
    const json_path = try outputPath(allocator, service, kind, "json");
    defer allocator.free(json_path);
    try json.writeAtomic(io, json_path, values);

    const text_path = try outputPath(allocator, service, kind, "txt");
    defer allocator.free(text_path);
    try writeDelimitedAtomic(io, text_path, values, "\n");

    const csv_path = try outputPath(allocator, service, kind, "csv");
    defer allocator.free(csv_path);
    try writeDelimitedAtomic(io, csv_path, values, ",\n");
}

fn outputPath(
    allocator: Allocator,
    service: []const u8,
    kind: []const u8,
    extension: []const u8,
) ![]u8 {
    const filename = try std.fmt.allocPrint(allocator, "{s}_{s}.{s}", .{
        service,
        kind,
        extension,
    });
    defer allocator.free(filename);
    return std.fs.path.join(allocator, &.{ output_dir, filename });
}

fn writeDelimitedAtomic(
    io: Io,
    output_path: []const u8,
    values: []const []const u8,
    delimiter: []const u8,
) !void {
    var atomic = try Io.Dir.cwd().createFileAtomic(io, output_path, .{
        .make_path = true,
        .replace = true,
    });
    defer atomic.deinit(io);

    var buffer: [16 * 1024]u8 = undefined;
    var file_writer = atomic.file.writerStreaming(io, &buffer);
    try writeDelimited(&file_writer.interface, values, delimiter);
    try file_writer.interface.flush();
    try atomic.file.sync(io);
    try atomic.replace(io);
}

fn writeDelimited(
    writer: *Io.Writer,
    values: []const []const u8,
    delimiter: []const u8,
) !void {
    for (values, 0..) |value, index| {
        if (index != 0) try writer.writeAll(delimiter);
        try writer.writeAll(value);
    }
    try writer.writeByte('\n');
}

test "text and multiline comma serialization are stable" {
    const allocator = std.testing.allocator;
    const values = [_][]const u8{ "one", "two" };

    var text = Io.Writer.Allocating.init(allocator);
    defer text.deinit();
    try writeDelimited(&text.writer, &values, "\n");
    try std.testing.expectEqualStrings("one\ntwo\n", text.written());

    var csv = Io.Writer.Allocating.init(allocator);
    defer csv.deinit();
    try writeDelimited(&csv.writer, &values, ",\n");
    try std.testing.expectEqualStrings("one,\ntwo\n", csv.written());
}
