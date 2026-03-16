const Server = @import("Server.zig");
const std = @import("std");
const Io = std.Io;
const Chess = @import("Chess");
const Sse = @import("Sse.zig");

const Args = struct {
    address: std.Io.net.IpAddress,

    const default: Args = .{
        .address = std.Io.net.IpAddress.parse("0.0.0.0", 8080) catch unreachable,
    };
};

pub fn parseArgs(process_args: std.process.Args, arena: std.mem.Allocator) !Args {
    const slice = try process_args.toSlice(arena);

    var args: Args = .default;
    for (slice) |arg| {
        if (std.mem.cutPrefix(u8, arg, "--listen=")) |address| {
            args.address = try std.Io.net.IpAddress.parseLiteral(address);
        }
    }
    return args;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    const args = try parseArgs(init.minimal.args, init.arena.allocator());
    std.log.info("Listening on {f}", .{args.address});

    const exe_path = try std.process.executableDirPathAlloc(io, init.arena.allocator());
    const exe_dir = try Io.Dir.cwd().openDir(io, exe_path, .{});
    defer exe_dir.close(io);

    const assets_dir = try exe_dir.openDir(io, "assets", .{});
    defer assets_dir.close(io);

    var server: Server = try .init(io, init.gpa, assets_dir);
    defer server.deinit();
    try server.start(args.address);
}

test {
    _ = @import("Sse.zig");
}
