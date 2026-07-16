const std = @import("std");
const files = @import("../files.zig");
const format = @import("../formats/sing_box.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;

// note: Preserve compiler diagnostics without allowing CI log flooding.
const max_process_output_bytes = 256 * 1024;

pub fn compile(allocator: Allocator, io: Io) !void {
    const sources = try files.listEntries(allocator, io, format.output_dir, .file, ".json");
    defer files.freeStrings(allocator, sources);
    if (sources.len == 0) return error.NoRenderedLists;

    for (sources) |filename| try compileFile(allocator, io, filename);
}

fn compileFile(allocator: Allocator, io: Io, filename: []const u8) !void {
    const input_path = try std.fs.path.join(allocator, &.{
        format.output_dir,
        filename,
    });
    defer allocator.free(input_path);

    const argv = [_][]const u8{
        "sing-box", "rule-set", "compile", input_path,
    };
    const result = try std.process.run(allocator, io, .{
        .argv = &argv,
        .stdout_limit = .limited(max_process_output_bytes),
        .stderr_limit = .limited(max_process_output_bytes),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| if (code != 0) {
            const diagnostics = if (result.stderr.len != 0) result.stderr else result.stdout;
            std.log.err("sing-box exited with code {d}", .{code});
            if (diagnostics.len != 0) std.log.err("sing-box: {s}", .{
                std.mem.trim(u8, diagnostics, " \t\r\n"),
            });
            return error.SingBoxFailed;
        },
        else => return error.SingBoxTerminated,
    }

    std.log.info("compiled {s}", .{filename});
}
