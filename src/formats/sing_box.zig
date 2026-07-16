const std = @import("std");
const json = @import("../json.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const output_dir = "formats/sing-box";
pub const output_suffixes = [_][]const u8{
    "_domains.json",
    "_domains.srs",
    "_ipv4_cidr.json",
    "_ipv4_cidr.srs",
};

// note: Version 4 is the newest source format supported by sing-box 1.13.x.
const RuleSet = struct {
    version: u8 = 4,
    rules: []const Rule,
};

const Rule = struct {
    domain_suffix: ?[]const []const u8 = null,
    ip_cidr: ?[]const []const u8 = null,
};

pub fn writeService(
    allocator: Allocator,
    io: Io,
    service: []const u8,
    domains: []const []const u8,
    ipv4_cidrs: []const []const u8,
) !void {
    const domain_path = try outputPath(allocator, service, "domains");
    defer allocator.free(domain_path);
    const cidr_path = try outputPath(allocator, service, "ipv4_cidr");
    defer allocator.free(cidr_path);

    const rules = [_]Rule{.{ .domain_suffix = domains }};
    try json.writeAtomic(io, domain_path, RuleSet{ .rules = &rules });

    const cidr_rules = [_]Rule{.{ .ip_cidr = ipv4_cidrs }};
    try json.writeAtomic(io, cidr_path, RuleSet{ .rules = &cidr_rules });
}

fn outputPath(allocator: Allocator, service: []const u8, kind: []const u8) ![]u8 {
    const filename = try std.fmt.allocPrint(allocator, "{s}_{s}.json", .{ service, kind });
    defer allocator.free(filename);
    return std.fs.path.join(allocator, &.{ output_dir, filename });
}
