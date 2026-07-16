const std = @import("std");

const files = @import("../files.zig");
const sing_box = @import("sing_box.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub fn writeAll(
    allocator: Allocator,
    io: Io,
    service: []const u8,
    domains: []const []const u8,
    ipv4_cidrs: []const []const u8,
) !void {
    return sing_box.writeService(allocator, io, service, domains, ipv4_cidrs);
}

pub fn pruneStaleGeneratedFiles(
    allocator: Allocator,
    io: Io,
    services: []const []const u8,
) !void {
    return files.pruneStaleGeneratedFiles(
        allocator,
        io,
        sing_box.output_dir,
        services,
        &sing_box.output_suffixes,
    );
}
