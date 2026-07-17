const std = @import("std");
const config = @import("config.zig");
const files = @import("files.zig");
const formats = @import("formats/root.zig");
const lists = @import("lists.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
// note: Preserve first-seen order while enforcing exact string uniqueness.
const UniqueList = std.array_hash_map.String(void);

const services_dir = "services";

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
    try lists.pruneStaleGeneratedFiles(allocator, io, service_names);
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

    var domains: UniqueList = .empty;
    defer domains.deinit(service_allocator);
    var cidrs: UniqueList = .empty;
    defer cidrs.deinit(service_allocator);
    const response_storage = try service_allocator.alloc(u8, max_response_bytes);
    var collected_bytes: usize = 0;

    for (service.sources) |source| {
        std.log.info("fetching {s} ({s}) for {s}", .{
            @tagName(source.kind),
            @tagName(source.format),
            name,
        });
        const body = try download(client, source.url, response_storage);
        collected_bytes = std.math.add(usize, collected_bytes, body.len) catch
            return error.CollectedListsTooLarge;
        if (collected_bytes > max_collected_bytes) return error.CollectedListsTooLarge;
        const output = switch (source.kind) {
            .domains => &domains,
            .ipv4_cidr => &cidrs,
            .ipv6_cidr => return error.UnsupportedSourceKind,
        };
        switch (source.format) {
            .json => try appendJsonList(allocator, service_allocator, output, body),
            .text => try appendDelimitedList(service_allocator, output, body, '\n'),
            .comma => try appendDelimitedList(service_allocator, output, body, ','),
        }
    }

    if (domains.count() == 0) return error.EmptyDomainList;
    if (cidrs.count() == 0) return error.EmptyIpv4CidrList;

    try lists.writeAll(service_allocator, io, name, domains.keys(), cidrs.keys());
    try formats.writeAll(
        service_allocator,
        io,
        name,
        domains.keys(),
        cidrs.keys(),
    );
    std.log.info("wrote {s}: {d} unique domain suffixes, {d} unique IPv4 CIDRs", .{
        name, domains.count(), cidrs.count(),
    });
}

fn appendJsonList(
    parse_allocator: Allocator,
    list_allocator: Allocator,
    output: *UniqueList,
    json_text: []const u8,
) !void {
    const Response = std.json.ArrayHashMap([]const []const u8);
    const parsed = try std.json.parseFromSlice(Response, parse_allocator, json_text, .{});
    defer parsed.deinit();

    const arrays = parsed.value.map.values();
    if (arrays.len != 1) return error.InvalidListJson;
    for (arrays[0]) |value| try appendUnique(list_allocator, output, value);
}

fn appendDelimitedList(
    allocator: Allocator,
    output: *UniqueList,
    text: []const u8,
    delimiter: u8,
) !void {
    var values = std.mem.splitScalar(u8, text, delimiter);
    while (values.next()) |raw_value| {
        const value = std.mem.trim(u8, raw_value, &std.ascii.whitespace);
        if (value.len == 0) continue;
        try appendUnique(allocator, output, value);
    }
}

fn appendUnique(allocator: Allocator, output: *UniqueList, value: []const u8) !void {
    if (output.contains(value)) return;

    const copy = try allocator.dupe(u8, value);
    errdefer allocator.free(copy);
    try output.putNoClobber(allocator, copy, {});
}

fn download(client: *std.http.Client, url: []const u8, storage: []u8) ![]const u8 {
    var retries: usize = 0;
    while (true) {
        const body = downloadOnce(client, url, storage) catch |err| {
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

fn downloadOnce(client: *std.http.Client, url: []const u8, storage: []u8) ![]const u8 {
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

    var values: UniqueList = .empty;
    defer values.deinit(arena.allocator());
    try appendJsonList(
        std.testing.allocator,
        arena.allocator(),
        &values,
        "{\"service\":[\"one\",\"two\",\"one\"]}",
    );
    try std.testing.expectEqual(@as(usize, 2), values.count());
    try std.testing.expectEqualStrings("one", values.keys()[0]);
    try std.testing.expectEqualStrings("two", values.keys()[1]);
}

test "provider JSON rejects an ambiguous shape" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    var values: UniqueList = .empty;
    defer values.deinit(arena.allocator());
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

test "text source accepts trimmed LF and CRLF lines" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    var values: UniqueList = .empty;
    defer values.deinit(arena.allocator());
    try appendDelimitedList(
        arena.allocator(),
        &values,
        "  192.0.2.0/24\r\n\r\n198.51.100.0/24 \n192.0.2.0/24\n",
        '\n',
    );
    try std.testing.expectEqual(@as(usize, 2), values.count());
    try std.testing.expectEqualStrings("192.0.2.0/24", values.keys()[0]);
    try std.testing.expectEqualStrings("198.51.100.0/24", values.keys()[1]);
}

test "JSON, text, and comma sources deduplicate together in insertion order" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    var values: UniqueList = .empty;
    defer values.deinit(arena.allocator());
    try appendJsonList(
        std.testing.allocator,
        arena.allocator(),
        &values,
        "{\"service\":[\"one\",\"two\"]}",
    );
    try appendDelimitedList(arena.allocator(), &values, "two\nthree\n", '\n');
    try appendDelimitedList(arena.allocator(), &values, " three, four,one ", ',');

    try std.testing.expectEqual(@as(usize, 4), values.count());
    try std.testing.expectEqualStrings("one", values.keys()[0]);
    try std.testing.expectEqualStrings("two", values.keys()[1]);
    try std.testing.expectEqualStrings("three", values.keys()[2]);
    try std.testing.expectEqualStrings("four", values.keys()[3]);
}
