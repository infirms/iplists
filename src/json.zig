const std = @import("std");

const Io = std.Io;

pub fn writeAtomic(io: Io, output_path: []const u8, value: anytype) !void {
    var atomic = try Io.Dir.cwd().createFileAtomic(io, output_path, .{
        .make_path = true,
        .replace = true,
    });
    defer atomic.deinit(io);

    var buffer: [16 * 1024]u8 = undefined;
    var file_writer = atomic.file.writerStreaming(io, &buffer);
    try std.json.Stringify.value(value, .{
        .whitespace = .indent_2,
        .emit_null_optional_fields = false,
    }, &file_writer.interface);
    try file_writer.interface.writeByte('\n');
    try file_writer.interface.flush();
    try atomic.file.sync(io);
    try atomic.replace(io);
}
