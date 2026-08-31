const std = @import("std");
const app = @import("app.zig");
const compilers = @import("compilers/root.zig");

const usage =
    \\Usage: iplists <collect|compile|all> [options]
    \\
    \\Commands:
    \\  collect  Fetch configured JSON, text, comma, and SRS lists
    \\  compile  Run registered optional compilers
    \\  all      Run collect, then compile
    \\
    \\Collect options:
    \\  --request-timeout-ms <ms>  Per-request and SRS decompile timeout (default: 10000)
    \\  --probe-delay-ms <ms>      Delay between HTTP probes (default: 500)
    \\  --retries <count>          Retries after a failed probe (default: 5)
    \\
    \\Options:
    \\  -h, --help  Show this help
    \\
;

const Command = enum { collect, compile, all };

const Cli = struct {
    command: Command,
    collect: app.CollectOptions = .{},
};

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const cli = try parseArgs(args) orelse {
        try std.Io.File.stdout().writeStreamingAll(init.io, usage);
        return;
    };

    switch (cli.command) {
        .collect => try app.collect(init.gpa, init.io, init.environ_map, cli.collect),
        .compile => try compilers.compileAll(init.gpa, init.io),
        .all => {
            try app.collect(init.gpa, init.io, init.environ_map, cli.collect);
            try compilers.compileAll(init.gpa, init.io);
        },
    }
}

fn parseArgs(args: []const []const u8) !?Cli {
    if (args.len < 2) return null;
    if (std.mem.eql(u8, args[1], "-h") or std.mem.eql(u8, args[1], "--help")) return null;

    var cli: Cli = .{
        .command = std.meta.stringToEnum(Command, args[1]) orelse return error.UnknownCommand,
    };
    var index: usize = 2;
    while (index < args.len) : (index += 2) {
        if (index + 1 >= args.len) return error.MissingOptionValue;
        const option = args[index];
        const value = args[index + 1];
        if (std.mem.eql(u8, option, "--request-timeout-ms")) {
            cli.collect.request_timeout = try parseMilliseconds(value, false);
        } else if (std.mem.eql(u8, option, "--probe-delay-ms")) {
            cli.collect.probe_delay = try parseMilliseconds(value, true);
        } else if (std.mem.eql(u8, option, "--retries")) {
            const retries = std.fmt.parseUnsigned(u8, value, 10) catch
                return error.InvalidOptionValue;
            if (retries > 20) return error.InvalidOptionValue;
            cli.collect.max_retries = retries;
        } else {
            return error.UnknownOption;
        }
    }
    if (cli.command == .compile and args.len != 2) return error.CollectOptionsNotSupported;
    return cli;
}

fn parseMilliseconds(text: []const u8, allow_zero: bool) !std.Io.Duration {
    const milliseconds = std.fmt.parseUnsigned(u32, text, 10) catch
        return error.InvalidOptionValue;
    if ((!allow_zero and milliseconds == 0) or milliseconds > 10 * 60 * 1000)
        return error.InvalidOptionValue;
    return .fromMilliseconds(milliseconds);
}

test "CLI arguments" {
    const defaults = (try parseArgs(&.{ "iplists", "all" })).?;
    try std.testing.expectEqual(Command.all, defaults.command);
    try std.testing.expectEqual(@as(i64, 10_000), defaults.collect.request_timeout.toMilliseconds());
    try std.testing.expectEqual(@as(i64, 500), defaults.collect.probe_delay.toMilliseconds());
    try std.testing.expectEqual(@as(u8, 5), defaults.collect.max_retries);
    try std.testing.expectEqual(null, try parseArgs(&.{ "iplists", "--help" }));

    const configured = (try parseArgs(&.{
        "iplists",
        "collect",
        "--request-timeout-ms",
        "2500",
        "--probe-delay-ms",
        "100",
        "--retries",
        "2",
    })).?;
    try std.testing.expectEqual(@as(i64, 2500), configured.collect.request_timeout.toMilliseconds());
    try std.testing.expectEqual(@as(i64, 100), configured.collect.probe_delay.toMilliseconds());
    try std.testing.expectEqual(@as(u8, 2), configured.collect.max_retries);

    try std.testing.expectError(error.UnknownCommand, parseArgs(&.{ "iplists", "wat" }));
    try std.testing.expectError(
        error.CollectOptionsNotSupported,
        parseArgs(&.{ "iplists", "compile", "--retries", "2" }),
    );
    try std.testing.expectError(
        error.InvalidOptionValue,
        parseArgs(&.{ "iplists", "collect", "--request-timeout-ms", "0" }),
    );
}

test {
    _ = @import("app.zig");
    _ = @import("config.zig");
    _ = @import("downloader.zig");
    _ = @import("files.zig");
    _ = @import("lists.zig");
    _ = @import("sources.zig");
}
