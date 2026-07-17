const std = @import("std");

// note: Accommodate normal HTTPS URLs while bounding config allocations.
const max_url_bytes = 4 * 1024;
// note: Five mirrors per kind allow fallback sources while bounding CI network work.
const max_sources_per_kind = 5;

pub const SourceKind = enum {
    domains,
    ipv4_cidr,
    ipv6_cidr,
};

pub const SourceFormat = enum {
    json,
    text,
    comma,
};

pub const Source = struct {
    kind: SourceKind,
    format: SourceFormat = .json,
    url: []const u8,
};

pub const Service = struct {
    sources: []const Source,

    pub fn validate(service: Service) !void {
        if (service.sources.len == 0) return error.InvalidSourceCount;

        var domain_sources: usize = 0;
        var ipv4_sources: usize = 0;
        for (service.sources) |source| {
            try validateUrl(source.url);
            switch (source.kind) {
                .domains => {
                    if (domain_sources == max_sources_per_kind) return error.TooManySources;
                    domain_sources += 1;
                },
                .ipv4_cidr => {
                    if (ipv4_sources == max_sources_per_kind) return error.TooManySources;
                    ipv4_sources += 1;
                },
                .ipv6_cidr => return error.UnsupportedSourceKind,
            }
        }
        if (domain_sources == 0 or ipv4_sources == 0) return error.MissingSourceKind;
    }
};

fn validateUrl(url: []const u8) !void {
    if (url.len == 0 or url.len > max_url_bytes) return error.InvalidUrl;

    const uri = std.Uri.parse(url) catch return error.InvalidUrl;
    if (!std.mem.eql(u8, uri.scheme, "https")) return error.HttpsRequired;
    const host = uri.host orelse return error.InvalidUrl;
    if (host.isEmpty()) return error.InvalidUrl;
}

test "service config validation" {
    const valid = Service{ .sources = &.{
        .{ .kind = .domains, .url = "https://example.test/domains" },
        .{ .kind = .ipv4_cidr, .url = "https://example.test/cidrs" },
    } };
    try valid.validate();

    const unsafe = Service{ .sources = &.{
        .{ .kind = .domains, .url = "http://example.test/domains" },
        .{ .kind = .ipv4_cidr, .url = "https://example.test/cidrs" },
    } };
    try std.testing.expectError(error.HttpsRequired, unsafe.validate());
}

test "URL must be structurally valid and have a host" {
    try std.testing.expectError(error.InvalidUrl, validateUrl("not a URL"));
    try std.testing.expectError(error.InvalidUrl, validateUrl("https:///list.json"));
    try std.testing.expectError(error.InvalidUrl, validateUrl("https://:443/list.json"));
    try validateUrl("https://example.test/list.json?kind=domains");
    try std.testing.expectError(
        error.HttpsRequired,
        validateUrl("HTTPS://example.test/list.json"),
    );
}

test "service accepts at most five sources of each implemented kind" {
    const service = Service{ .sources = &.{
        .{ .kind = .domains, .url = "https://one.example.test/domains" },
        .{ .kind = .domains, .url = "https://two.example.test/domains" },
        .{ .kind = .domains, .url = "https://three.example.test/domains" },
        .{ .kind = .domains, .url = "https://four.example.test/domains" },
        .{ .kind = .domains, .url = "https://five.example.test/domains" },
        .{ .kind = .domains, .url = "https://six.example.test/domains" },
        .{ .kind = .ipv4_cidr, .url = "https://example.test/cidrs" },
    } };
    try std.testing.expectError(error.TooManySources, service.validate());
}

test "IPv6 is reserved but not implemented" {
    const service = Service{ .sources = &.{
        .{ .kind = .domains, .url = "https://example.test/domains" },
        .{ .kind = .ipv6_cidr, .url = "https://example.test/cidrs" },
    } };
    try std.testing.expectError(error.UnsupportedSourceKind, service.validate());
}

test "source format is explicit and defaults to JSON" {
    const allocator = std.testing.allocator;

    const default = try std.json.parseFromSlice(
        Source,
        allocator,
        "{\"kind\":\"domains\",\"url\":\"https://example.test/domains\"}",
        .{},
    );
    defer default.deinit();
    try std.testing.expectEqual(SourceFormat.json, default.value.format);

    const text = try std.json.parseFromSlice(
        Source,
        allocator,
        "{\"kind\":\"ipv4_cidr\",\"format\":\"text\",\"url\":\"https://example.test/cidrs\"}",
        .{},
    );
    defer text.deinit();
    try std.testing.expectEqual(SourceFormat.text, text.value.format);

    const comma = try std.json.parseFromSlice(
        Source,
        allocator,
        "{\"kind\":\"domains\",\"format\":\"comma\",\"url\":\"https://example.test/domains\"}",
        .{},
    );
    defer comma.deinit();
    try std.testing.expectEqual(SourceFormat.comma, comma.value.format);
}
