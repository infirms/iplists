const std = @import("std");

const Allocator = std.mem.Allocator;
const Io = std.Io;

const max_response_bytes = 8 * 1024 * 1024;

pub const Options = struct {
    request_timeout: Io.Duration = .fromSeconds(10),
    probe_delay: Io.Duration = .fromMilliseconds(500),
    max_retries: u8 = 5,
};

pub const Downloader = struct {
    allocator: Allocator,
    io: Io,
    client: std.http.Client,
    storage: []u8,
    options: Options,
    has_probed: bool = false,

    pub fn init(
        allocator: Allocator,
        io: Io,
        environ_map: *const std.process.Environ.Map,
        options: Options,
    ) !Downloader {
        var client: std.http.Client = .{ .allocator = allocator, .io = io };
        errdefer client.deinit();
        try client.initDefaultProxies(allocator, environ_map);

        const storage = try allocator.alloc(u8, max_response_bytes);
        errdefer allocator.free(storage);

        return .{
            .allocator = allocator,
            .io = io,
            .client = client,
            .storage = storage,
            .options = options,
        };
    }

    pub fn deinit(downloader: *Downloader) void {
        downloader.client.deinit();
        downloader.allocator.free(downloader.storage);
        downloader.* = undefined;
    }

    pub fn fetch(downloader: *Downloader, url: []const u8) ![]const u8 {
        var retries: u8 = 0;
        while (true) {
            try downloader.waitForNextProbe();
            const body = downloader.fetchOnce(url) catch |err| {
                if (err == error.Canceled or retries == downloader.options.max_retries) return err;
                retries += 1;
                std.log.warn("download failed for {s}: {s}; retry {d}/{d}", .{
                    url,
                    @errorName(err),
                    retries,
                    downloader.options.max_retries,
                });
                continue;
            };
            return body;
        }
    }

    fn waitForNextProbe(downloader: *Downloader) !void {
        if (!downloader.has_probed) {
            downloader.has_probed = true;
            return;
        }
        if (downloader.options.probe_delay.nanoseconds == 0) return;
        _ = try downloader.io.sleep(downloader.options.probe_delay, .awake);
    }

    fn fetchOnce(downloader: *Downloader, url: []const u8) ![]const u8 {
        var body_writer = Io.Writer.fixed(downloader.storage);
        const Fetch = union(enum) {
            response: std.http.Client.FetchError!std.http.Client.FetchResult,
            timeout: Io.Cancelable!void,
        };
        var result_buffer: [2]Fetch = undefined;
        var select = Io.Select(Fetch).init(downloader.io, &result_buffer);
        select.async(.response, std.http.Client.fetch, .{
            &downloader.client,
            .{
                .location = .{ .url = url },
                // Reject redirects so HTTPS cannot downgrade to HTTP.
                .redirect_behavior = .not_allowed,
                .response_writer = &body_writer,
            },
        });
        select.async(.timeout, Io.sleep, .{
            downloader.io,
            downloader.options.request_timeout,
            .awake,
        });
        defer select.cancelDiscard();

        const result = switch (try select.await()) {
            .response => |response| try response,
            .timeout => |timeout| {
                try timeout;
                return error.DownloadTimedOut;
            },
        };
        if (result.status.class() != .success) {
            std.log.err("HTTP status {d} for {s}", .{ @intFromEnum(result.status), url });
            return error.HttpStatusNotSuccessful;
        }
        return body_writer.buffered();
    }
};
