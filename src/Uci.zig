const std = @import("std");
const ChessBoard = @import("ChessBoard.zig");
const Uci = @This();
const Move = ChessBoard.Move;

engine_process: std.process.Child,

pub fn connect(arena: std.mem.Allocator) !@This() {
    const self_dir_path = try std.fs.selfExeDirPathAlloc(arena);

    var child = std.process.Child.init(
        &.{
            try std.fs.path.join(arena, &.{ self_dir_path, "stockfish" }),
        },
        arena,
    );
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    try child.spawn();

    return .{
        .engine_process = child,
    };
}

pub fn getMove(self: *@This()) !Move {
    const reader = self.engine_process.stdout.?;
    var buffer: [0x1000]u8 = undefined;
    while (true) {
        const bytes_read = try reader.read(buffer[0..]);
        if (bytes_read == 0) return error.Empty;
        const slice = buffer[0..bytes_read];

        try std.io.getStdOut().writeAll(slice);
        if (std.mem.startsWith(u8, slice, "bestmove ")) {
            if (std.mem.startsWith(u8, slice, "bestmove (none)")) return error.EndOfGame;

            const move = std.mem.trimRight(u8, slice["bestmove ".len..][0..], &std.ascii.whitespace);
            std.log.info("Found move {s}", .{move});

            const piece: ?ChessBoard.Piece = if (move.len >= 5 and std.ascii.isAlphabetic(move[4]))
                ChessBoard.PieceWithSide.fromChar(move[4]).?.piece
            else
                null;

            return .{
                .from = .fromString(move[0..2].*),
                .to = .fromString(move[2..4].*),
                .promotion = piece,
            };
        }
    }
}

pub fn setPosition(self: *@This(), board: ChessBoard) !void {
    const writer = self.engine_process.stdin.?;

    try writer.writeAll("position fen ");
    try board.writeFen(writer.writer());
    try writer.writeAll("\n");

    try board.writeFen(std.io.getStdOut().writer());
    try std.io.getStdOut().writer().writeAll("\n");
}

pub fn quit(self: *@This()) void {
    self.engine_process.stdin.?.writeAll("quit\n") catch |e| {
        std.log.err("failed to close engine: {s}", .{@errorName(e)});
        std.log.err("killing engine", .{});

        _ = self.engine_process.kill() catch |ke| {
            std.debug.panic("failed to kill engine {s}", .{@errorName(ke)});
        };
        return;
    };

    std.log.info("quit engine", .{});
}

pub fn go(self: *@This(), depth: u8) !void {
    try self.engine_process.stdin.?.writer().print("go depth {d}\n", .{depth});
}

pub fn deinit(uci: *Uci) !void {
    uci.quit();

    if (try uci.engine_process.wait() != .Exited) {
        return error.FailedToExit;
    }
}
