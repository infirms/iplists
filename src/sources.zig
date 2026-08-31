const std = @import("std");
const config = @import("config.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const UniqueList = std.array_hash_map.String(void);

const max_decompiled_bytes = 32 * 1024 * 1024;
const max_process_output_bytes = 256 * 1024;

pub const Collection = struct {
    allocator: Allocator,
    domains: UniqueList = .empty,
    ipv4_cidrs: UniqueList = .empty,

    pub fn init(allocator: Allocator) Collection {
        return .{ .allocator = allocator };
    }

    pub fn deinit(collection: *Collection) void {
        deinitList(collection.allocator, &collection.domains);
        deinitList(collection.allocator, &collection.ipv4_cidrs);
        collection.* = undefined;
    }

    pub fn append(
        collection: *Collection,
        io: Io,
        source: config.Source,
        body: []const u8,
        operation_timeout: Io.Duration,
    ) !void {
        const output = switch (source.kind) {
            .domains => &collection.domains,
            .ipv4_cidr => &collection.ipv4_cidrs,
            .ipv6_cidr => return error.UnsupportedSourceKind,
        };

        const appended = switch (source.format) {
            .json => try appendJsonList(collection.allocator, output, body),
            .text => try appendDelimitedList(collection.allocator, output, body, '\n'),
            .comma => try appendDelimitedList(collection.allocator, output, body, ','),
            .srs => try appendSrs(
                collection.allocator,
                io,
                output,
                source.kind,
                body,
                operation_timeout,
            ),
        };
        if (appended == 0) return error.EmptySourceList;
    }

    pub fn validate(collection: *const Collection) !void {
        if (collection.domains.count() == 0) return error.EmptyDomainList;
        if (collection.ipv4_cidrs.count() == 0) return error.EmptyIpv4CidrList;
    }
};
fn deinitList(allocator: Allocator, list: *UniqueList) void {
    for (list.keys()) |value| allocator.free(value);
    list.deinit(allocator);
}

fn appendJsonList(allocator: Allocator, output: *UniqueList, json_text: []const u8) !usize {
    const Response = std.json.ArrayHashMap([]const []const u8);
    const parsed = try std.json.parseFromSlice(Response, allocator, json_text, .{});
    defer parsed.deinit();

    const arrays = parsed.value.map.values();
    if (arrays.len != 1) return error.InvalidListJson;
    for (arrays[0]) |value| try appendUnique(allocator, output, value);
    return arrays[0].len;
}

fn appendDelimitedList(
    allocator: Allocator,
    output: *UniqueList,
    text: []const u8,
    delimiter: u8,
) !usize {
    var appended: usize = 0;
    var values = std.mem.splitScalar(u8, text, delimiter);
    while (values.next()) |raw_value| {
        const value = std.mem.trim(u8, raw_value, &std.ascii.whitespace);
        if (value.len == 0) continue;
        try appendUnique(allocator, output, value);
        appended += 1;
    }
    return appended;
}

fn appendUnique(allocator: Allocator, output: *UniqueList, value: []const u8) !void {
    if (output.contains(value)) return;

    const copy = try allocator.dupe(u8, value);
    errdefer allocator.free(copy);
    try output.putNoClobber(allocator, copy, {});
}

const RuleSet = struct {
    rules: []const Rule,
};

const Rule = struct {
    domain: ?[]const []const u8 = null,
    domain_keyword: ?[]const []const u8 = null,
    domain_regex: ?[]const []const u8 = null,
    domain_suffix: ?[]const []const u8 = null,
    ip_cidr: ?[]const []const u8 = null,
    rules: ?[]const Rule = null,
};

fn appendSrs(
    allocator: Allocator,
    io: Io,
    output: *UniqueList,
    kind: config.SourceKind,
    body: []const u8,
    operation_timeout: Io.Duration,
) !usize {
    const json_text = try decompileSrs(allocator, io, body, operation_timeout);
    defer allocator.free(json_text);

    const parsed = try std.json.parseFromSlice(RuleSet, allocator, json_text, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    var appended: usize = 0;
    for (parsed.value.rules) |rule| {
        appended += try appendRule(allocator, output, kind, rule);
    }
    return appended;
}

fn appendRule(
    allocator: Allocator,
    output: *UniqueList,
    kind: config.SourceKind,
    rule: Rule,
) !usize {
    var appended: usize = 0;
    switch (kind) {
        .domains => {
            if (hasValues(rule.domain) or
                hasValues(rule.domain_keyword) or
                hasValues(rule.domain_regex))
            {
                return error.UnsupportedSrsDomainRule;
            }
            if (rule.domain_suffix) |values| {
                for (values) |value| try appendUnique(allocator, output, value);
                appended += values.len;
            }
        },
        .ipv4_cidr => if (rule.ip_cidr) |values| {
            for (values) |value| try appendUnique(allocator, output, value);
            appended += values.len;
        },
        .ipv6_cidr => return error.UnsupportedSourceKind,
    }

    if (rule.rules) |rules| {
        for (rules) |child| appended += try appendRule(allocator, output, kind, child);
    }
    return appended;
}

fn hasValues(values: ?[]const []const u8) bool {
    return if (values) |items| items.len != 0 else false;
}

fn decompileSrs(
    allocator: Allocator,
    io: Io,
    body: []const u8,
    operation_timeout: Io.Duration,
) ![]u8 {
    var random: [8]u8 = undefined;
    io.random(&random);
    const suffix = std.fmt.bytesToHex(random, .lower);
    var path_buffer: [64]u8 = undefined;
    const temp_path = try std.fmt.bufPrint(&path_buffer, ".iplists-tmp-{s}", .{&suffix});

    const cwd = Io.Dir.cwd();
    var temp_dir = try cwd.createDirPathOpen(io, temp_path, .{});
    defer cwd.deleteTree(io, temp_path) catch {};
    defer temp_dir.close(io);

    try temp_dir.writeFile(io, .{ .sub_path = "input.srs", .data = body });
    const argv = [_][]const u8{
        "sing-box", "rule-set", "decompile", "input.srs", "--output", "output.json",
    };
    const result = try std.process.run(allocator, io, .{
        .argv = &argv,
        .cwd = .{ .dir = temp_dir },
        .stdout_limit = .limited(max_process_output_bytes),
        .stderr_limit = .limited(max_process_output_bytes),
        .timeout = .{ .duration = .{ .clock = .awake, .raw = operation_timeout } },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| if (code != 0) {
            const diagnostics = if (result.stderr.len != 0) result.stderr else result.stdout;
            std.log.err("sing-box decompile exited with code {d}", .{code});
            if (diagnostics.len != 0) std.log.err("sing-box: {s}", .{
                std.mem.trim(u8, diagnostics, &std.ascii.whitespace),
            });
            return error.SingBoxDecompileFailed;
        },
        else => return error.SingBoxDecompileTerminated,
    }

    return temp_dir.readFileAlloc(io, "output.json", allocator, .limited(max_decompiled_bytes));
}

test "provider formats deduplicate together in insertion order" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    var collection: Collection = .init(arena.allocator());
    defer collection.deinit();
    const json_source: config.Source = .{
        .kind = .domains,
        .url = "https://example.test/domains.json",
    };
    try collection.append(
        std.testing.io,
        json_source,
        "{\"service\":[\"one\",\"two\"]}",
        .fromSeconds(1),
    );
    try collection.append(
        std.testing.io,
        .{ .kind = .domains, .format = .text, .url = "https://example.test/domains.txt" },
        "two\nthree\n",
        .fromSeconds(1),
    );
    try collection.append(
        std.testing.io,
        .{ .kind = .domains, .format = .comma, .url = "https://example.test/domains.csv" },
        " three, four,one ",
        .fromSeconds(1),
    );

    try std.testing.expectEqual(@as(usize, 4), collection.domains.count());
    try std.testing.expectEqualStrings("one", collection.domains.keys()[0]);
    try std.testing.expectEqualStrings("two", collection.domains.keys()[1]);
    try std.testing.expectEqualStrings("three", collection.domains.keys()[2]);
    try std.testing.expectEqualStrings("four", collection.domains.keys()[3]);
}

test "decompiled SRS rules select the configured list kind" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const text =
        \\{"version":4,"rules":[
        \\  {"domain_suffix":["example.com"],"ip_cidr":["192.0.2.0/24"]},
        \\  {"type":"logical","rules":[{"domain_suffix":["example.net"]}]}
        \\]}
    ;
    const parsed = try std.json.parseFromSlice(RuleSet, arena.allocator(), text, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    var domains: UniqueList = .empty;
    defer domains.deinit(arena.allocator());
    var appended: usize = 0;
    for (parsed.value.rules) |rule| {
        appended += try appendRule(arena.allocator(), &domains, .domains, rule);
    }
    try std.testing.expectEqual(@as(usize, 2), appended);
    try std.testing.expectEqualStrings("example.com", domains.keys()[0]);
    try std.testing.expectEqualStrings("example.net", domains.keys()[1]);
}

test "exact SRS domains are rejected instead of widened to suffixes" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    var domains: UniqueList = .empty;
    defer domains.deinit(arena.allocator());
    try std.testing.expectError(
        error.UnsupportedSrsDomainRule,
        appendRule(arena.allocator(), &domains, .domains, .{
            .domain = &.{"exact.example"},
        }),
    );
}
