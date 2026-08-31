const std = @import("std");
const config = @import("config.zig");
const downloader = @import("downloader.zig");
const files = @import("files.zig");
const formats = @import("formats/root.zig");
const lists = @import("lists.zig");
const sources = @import("sources.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

const services_dir = "services";
// Bound retained data when a service combines many sources.
const max_collected_bytes = 32 * 1024 * 1024;

pub const CollectOptions = downloader.Options;

pub fn collect(
    allocator: Allocator,
    io: Io,
    environ_map: *const std.process.Environ.Map,
    options: CollectOptions,
) !void {
    var fetcher = try downloader.Downloader.init(allocator, io, environ_map, options);
    defer fetcher.deinit();

    const filenames = try files.listEntries(allocator, io, services_dir, .file, ".json");
    defer files.freeStrings(allocator, filenames);
    if (filenames.len == 0) return error.NoServiceConfigs;

    const service_names = try allocator.alloc([]const u8, filenames.len);
    defer allocator.free(service_names);
    for (filenames, 0..) |filename, index| {
        const name = std.fs.path.stem(filename);
        service_names[index] = name;
        try collectService(allocator, io, &fetcher, name, filename);
    }
    try lists.pruneStaleGeneratedFiles(allocator, io, service_names);
    try formats.pruneStaleGeneratedFiles(allocator, io, service_names);
}

fn collectService(
    allocator: Allocator,
    io: Io,
    fetcher: *downloader.Downloader,
    name: []const u8,
    filename: []const u8,
) !void {
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const service_allocator = arena.allocator();

    const service = try readServiceConfig(service_allocator, io, filename);
    var collection: sources.Collection = .init(service_allocator);
    defer collection.deinit();

    var collected_bytes: usize = 0;
    for (service.sources) |source| {
        std.log.info("fetching {s} ({s}) for {s}", .{
            @tagName(source.kind),
            @tagName(source.format),
            name,
        });
        const body = try fetcher.fetch(source.url);
        collected_bytes = std.math.add(usize, collected_bytes, body.len) catch
            return error.CollectedListsTooLarge;
        if (collected_bytes > max_collected_bytes) return error.CollectedListsTooLarge;
        try collection.append(io, source, body, fetcher.options.request_timeout);
    }
    try collection.validate();

    try lists.writeAll(
        service_allocator,
        io,
        name,
        collection.domains.keys(),
        collection.ipv4_cidrs.keys(),
    );
    try formats.writeAll(
        service_allocator,
        io,
        name,
        collection.domains.keys(),
        collection.ipv4_cidrs.keys(),
    );
    std.log.info("wrote {s}: {d} unique domain suffixes, {d} unique IPv4 CIDRs", .{
        name,
        collection.domains.count(),
        collection.ipv4_cidrs.count(),
    });
}

fn readServiceConfig(allocator: Allocator, io: Io, filename: []const u8) !config.Service {
    const config_path = try std.fs.path.join(allocator, &.{ services_dir, filename });
    const config_text = try Io.Dir.cwd().readFileAlloc(
        io,
        config_path,
        allocator,
        .unlimited,
    );
    const service = try std.json.parseFromSliceLeaky(
        config.Service,
        allocator,
        config_text,
        .{},
    );
    try service.validate();
    return service;
}
