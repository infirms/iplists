const std = @import("std");
const app = @import("app.zig");
const compilers = @import("compilers/root.zig");

const usage =
    \\Usage: iplists <collect|compile|all>
    \\
    \\Commands:
    \\  collect  Fetch and validate configured JSON lists
    \\  compile  Run registered optional compilers
    \\  all      Run collect, then compile
    \\
    \\Options:
    \\  -h, --help  Show this help
    \\
;

const Command = enum { collect, compile, all };

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const command = try parseArgs(args) orelse {
        try std.Io.File.stdout().writeStreamingAll(init.io, usage);
        return;
    };

    switch (command) {
        .collect => try app.collect(init.gpa, init.io, init.environ_map),
        .compile => try compilers.compileAll(init.gpa, init.io),
        .all => {
            try app.collect(init.gpa, init.io, init.environ_map);
            try compilers.compileAll(init.gpa, init.io);
        },
    }
}

fn parseArgs(args: []const []const u8) !?Command {
    if (args.len < 2) return null;
    if (args.len > 2) return error.UnexpectedArgument;
    if (std.mem.eql(u8, args[1], "-h") or std.mem.eql(u8, args[1], "--help")) return null;
    return std.meta.stringToEnum(Command, args[1]) orelse error.UnknownCommand;
}

test "CLI arguments" {
    try std.testing.expectEqual(@as(?Command, .all), try parseArgs(&.{ "iplists", "all" }));
    try std.testing.expectEqual(null, try parseArgs(&.{ "iplists", "--help" }));

    try std.testing.expectError(error.UnknownCommand, parseArgs(&.{ "iplists", "wat" }));
    try std.testing.expectError(
        error.UnexpectedArgument,
        parseArgs(&.{ "iplists", "compile", "sing-box" }),
    );
}

test {
    _ = @import("app.zig");
    _ = @import("config.zig");
    _ = @import("files.zig");
    _ = @import("lists.zig");
}
