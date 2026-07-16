const std = @import("std");

const sing_box = @import("sing_box.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub fn compileAll(allocator: Allocator, io: Io) !void {
    return sing_box.compile(allocator, io);
}
