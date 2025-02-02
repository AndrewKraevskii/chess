const std = @import("std");
const ChessBoard = @import("ChessBoard.zig");
const Uci = @This();
const Move = ChessBoard.Move;

gpa: std.mem.Allocator,
engine_process: std.process.Child,
promise: ?MovePromise,

pub fn connect(gpa: std.mem.Allocator) !@This() {
    const self_dir_path = try std.fs.selfExeDirPathAlloc(gpa);
    defer gpa.free(self_dir_path);
    const full_path = try std.fs.path.join(gpa, &.{ self_dir_path, "stockfish" });
    defer gpa.free(full_path);

    var child = std.process.Child.init(
        &.{full_path},
        gpa,
    );
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    try child.spawn();

    return .{
        .gpa = gpa,
        .engine_process = child,
        .promise = null,
    };
}

pub fn Promise(comptime T: type) type {
    return union(enum) {
        none,
        done: T,
        err,

        pub fn get(self: @This()) !?T {
            return switch (self) {
                .none => null,
                .done => |t| t,
                .err => error.EndOfGame,
            };
        }
    };
}

pub const MovePromise = Promise(Move);

pub fn getMoveAsync(self: *@This()) std.Thread.SpawnError!*MovePromise {
    self.promise = .none;
    const thread = try std.Thread.spawn(.{}, struct {
        fn move(
            _self: *Uci,
            promise: *MovePromise,
        ) void {
            promise.* = if (getMove(_self)) |_move|
                .{ .done = _move }
            else |_|
                .err;
        }
    }.move, .{ self, &self.promise.? });
    thread.detach();

    return &self.promise.?;
}

pub fn getMove(self: *@This()) !Move {
    const reader = self.engine_process.stdout.?;
    var buffer: [0x1000]u8 = undefined;
    while (true) {
        const line = try reader.reader().readUntilDelimiter(&buffer, '\n');

        if (std.mem.startsWith(u8, line, "bestmove ")) {
            if (std.mem.startsWith(u8, line, "bestmove (none)")) return error.EndOfGame;

            const move = std.mem.trimRight(u8, line["bestmove ".len..][0..], &std.ascii.whitespace);

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

pub fn quit(self: *@This()) !void {
    if (self.engine_process.stdin) |stdin| {
        try stdin.writeAll("quit\n");
    }
    std.log.info("quit engine", .{});
}

const GoConfig = struct {
    searchmoves: []const Move = &.{},
    ponde: void = {},
    wtime: void = {},
    btime: void = {},
    winc: void = {},
    binc: void = {},
    movestogo: void = {},
    depth: u8,
    nodes: void = {},
    mate: void = {},
    movetime: void = {},
    infinit: void = {},
};

pub fn go(self: *@This(), config: GoConfig) !void {
    try self.engine_process.stdin.?.writer().print("go depth {d}\n", .{config.depth});
}

pub fn close(uci: *Uci) !void {
    try uci.quit();
}

test {
    var uci = try connect(std.testing.allocator);
    defer uci.close() catch {};

    var board: ChessBoard = .init;
    while (true) {
        try uci.setPosition(board);
        try uci.go(.{ .depth = 3 });
        const move = try uci.getMove();
        board.applyMove(move);
    }
}
