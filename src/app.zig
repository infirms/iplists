const std = @import("std");
const config = @import("config.zig");
const files = @import("files.zig");
const formats = @import("formats/root.zig");
const json = @import("json.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

const services_dir = "services";
const lists_dir = "lists";
const list_suffixes = [_][]const u8{ "_domains.json", "_ipv4_cidr.json" };

// note: Accommodate large lists while bounding one HTTP response.
const max_response_bytes = 8 * 1024 * 1024;
// note: Bound retained data when a service combines many sources.
const max_collected_bytes = 32 * 1024 * 1024;
// note: Five retries tolerate transient outages without letting CI loop forever.
const max_download_retries = 5;
// note: Bound the complete HTTP attempt, including connection and response body.
const download_timeout = Io.Duration.fromSeconds(10);

pub fn collect(
    allocator: Allocator,
    io: Io,
    environ_map: *const std.process.Environ.Map,
) !void {
    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();
    try client.initDefaultProxies(allocator, environ_map);

    const filenames = try files.listEntries(allocator, io, services_dir, .file, ".json");
    defer files.freeStrings(allocator, filenames);
    if (filenames.len == 0) return error.NoServiceConfigs;

    const service_names = try allocator.alloc([]const u8, filenames.len);
    defer allocator.free(service_names);
    for (filenames, 0..) |filename, index| {
        const name = std.fs.path.stem(filename);
        service_names[index] = name;
        try collectService(allocator, io, &client, name, filename);
    }
    try files.pruneStaleGeneratedFiles(allocator, io, lists_dir, service_names, &list_suffixes);
    try formats.pruneStaleGeneratedFiles(allocator, io, service_names);
}

fn collectService(
    allocator: Allocator,
    io: Io,
    client: *std.http.Client,
    name: []const u8,
    filename: []const u8,
) !void {
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const service_allocator = arena.allocator();

    const config_path = try std.fs.path.join(service_allocator, &.{ services_dir, filename });
    const config_text = try Io.Dir.cwd().readFileAlloc(
        io,
        config_path,
        service_allocator,
        .unlimited,
    );
    const service = try std.json.parseFromSliceLeaky(
        config.Service,
        service_allocator,
        config_text,
        .{},
    );
    try service.validate();

    var domains: std.ArrayList([]const u8) = .empty;
    var cidrs: std.ArrayList([]const u8) = .empty;
    const response_storage = try service_allocator.alloc(u8, max_response_bytes);
    var collected_bytes: usize = 0;

    for (service.sources) |source| {
        std.log.info("fetching {s} for {s}", .{ @tagName(source.kind), name });
        const body = try downloadJson(client, source.url, response_storage);
        collected_bytes = std.math.add(usize, collected_bytes, body.len) catch
            return error.CollectedListsTooLarge;
        if (collected_bytes > max_collected_bytes) return error.CollectedListsTooLarge;
        const output = switch (source.kind) {
            .domains => &domains,
            .ipv4_cidr => &cidrs,
            .ipv6_cidr => return error.UnsupportedSourceKind,
        };
        try appendJsonList(allocator, service_allocator, output, body);
    }

    if (domains.items.len == 0) return error.EmptyDomainList;
    if (cidrs.items.len == 0) return error.EmptyIpv4CidrList;

    const domain_path = try listPath(service_allocator, name, "domains");
    const cidr_path = try listPath(service_allocator, name, "ipv4_cidr");
    try json.writeAtomic(io, domain_path, domains.items);
    try json.writeAtomic(io, cidr_path, cidrs.items);
    try formats.writeAll(
        service_allocator,
        io,
        name,
        domains.items,
        cidrs.items,
    );
    std.log.info("wrote {s}: {d} domain suffixes, {d} IPv4 CIDRs", .{
        name, domains.items.len, cidrs.items.len,
    });
}

fn listPath(allocator: Allocator, service: []const u8, kind: []const u8) ![]u8 {
    const filename = try std.fmt.allocPrint(allocator, "{s}_{s}.json", .{ service, kind });
    defer allocator.free(filename);
    return std.fs.path.join(allocator, &.{ lists_dir, filename });
}

fn appendJsonList(
    parse_allocator: Allocator,
    list_allocator: Allocator,
    output: *std.ArrayList([]const u8),
    json_text: []const u8,
) !void {
    const Response = std.json.ArrayHashMap([]const []const u8);
    const parsed = try std.json.parseFromSlice(Response, parse_allocator, json_text, .{});
    defer parsed.deinit();

    const lists = parsed.value.map.values();
    if (lists.len != 1) return error.InvalidListJson;
    for (lists[0]) |value| {
        const copy = try list_allocator.dupe(u8, value);
        errdefer list_allocator.free(copy);
        try output.append(list_allocator, copy);
    }
}

fn downloadJson(client: *std.http.Client, url: []const u8, storage: []u8) ![]const u8 {
    var retries: usize = 0;
    while (true) {
        const body = downloadJsonOnce(client, url, storage) catch |err| {
            if (err == error.Canceled or retries == max_download_retries) return err;
            retries += 1;
            std.log.warn("download failed for {s}: {s}; retry {d}/{d}", .{
                url, @errorName(err), retries, max_download_retries,
            });
            continue;
        };
        return body;
    }
}

fn downloadJsonOnce(client: *std.http.Client, url: []const u8, storage: []u8) ![]const u8 {
    var body_writer = Io.Writer.fixed(storage);
    const Fetch = union(enum) {
        response: std.http.Client.FetchError!std.http.Client.FetchResult,
        timeout: Io.Cancelable!void,
    };
    var result_buffer: [2]Fetch = undefined;
    var select = Io.Select(Fetch).init(client.io, &result_buffer);
    select.async(.response, std.http.Client.fetch, .{
        client,
        .{
            .location = .{ .url = url },
            // note (security): Reject redirects so HTTPS cannot downgrade to HTTP.
            .redirect_behavior = .not_allowed,
            .response_writer = &body_writer,
        },
    });
    select.async(.timeout, Io.sleep, .{ client.io, download_timeout, .awake });
    defer select.cancelDiscard();

    const result = switch (try select.await()) {
        .response => |response| try response,
        .timeout => |timeout| {
            try timeout;
            return error.DownloadTimedOut;
        },
    };
    if (result.status.class() != .success) {
        std.log.err("HTTP status {d}", .{@intFromEnum(result.status)});
        return error.HttpStatusNotSuccessful;
    }
    return body_writer.buffered();
}

test "provider JSON accepts a single-key string array" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    var values: std.ArrayList([]const u8) = .empty;
    try appendJsonList(
        std.testing.allocator,
        arena.allocator(),
        &values,
        "{\"service\":[\"one\",\"two\"]}",
    );
    try std.testing.expectEqual(@as(usize, 2), values.items.len);
    try std.testing.expectEqualStrings("one", values.items[0]);
    try std.testing.expectEqualStrings("two", values.items[1]);
}

test "provider JSON rejects an ambiguous shape" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    var values: std.ArrayList([]const u8) = .empty;
    try std.testing.expectError(
        error.InvalidListJson,
        appendJsonList(
            std.testing.allocator,
            arena.allocator(),
            &values,
            "{\"a\":[],\"b\":[]}",
        ),
    );
}
