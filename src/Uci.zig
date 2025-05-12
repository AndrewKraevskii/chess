const std = @import("std");
const ChessBoard = @import("ChessBoard.zig");
const Uci = @This();
const Move = ChessBoard.Move;
const Io = std.Io;

io: Io,
engine_process: std.process.Child,
promise: ?MovePromise,

pub fn connect(arena: std.mem.Allocator, io: Io, engine_path: []const u8) !@This() {
    const child = try std.process.spawn(io, .{
        .argv = &.{engine_path},
        .stderr = .ignore,
        .stdin = .pipe,
        .stdout = .pipe,
    });
    _ = arena;
    // child.stdin_behavior = .Pipe;
    // child.stdout_behavior = .Pipe;

    return .{
        .io = io,
        .engine_process = child,
        .promise = null,
    };
}

pub fn Promise(comptime T: type) type {
    return struct {
        done: std.atomic.Value(bool),
        result: T,

        pub fn get(self: @This()) ?T {
            if (self.done.load(.acquire)) {
                return self.result;
            }
            return null;
        }
    };
}

pub const MovePromise = Promise(error{EndOfGame}!Move);

pub fn getMoveAsync(self: *@This()) std.Thread.SpawnError!*MovePromise {
    self.promise = .{ .done = .init(false), .result = undefined };
    const thread = try std.Thread.spawn(.{}, struct {
        fn move(
            _self: *Uci,
            promise: *MovePromise,
        ) void {
            promise.result = getMove(_self) catch |e| switch (e) {
                error.EndOfGame => error.EndOfGame,
                else => |other| {
                    std.log.err("{s}", .{@errorName(other)});
                    return;
                },
            };
            promise.done.store(true, .release);
        }
    }.move, .{ self, &self.promise.? });
    thread.detach();

    return &self.promise.?;
}

pub fn getMove(self: *@This()) !Move {
    var buffer: [0x1000]u8 = undefined;
    var reader = self.engine_process.stdout.?.reader(self.io, &buffer);
    while (true) {
        const line = try reader.interface.takeDelimiter('\n') orelse return error.EndOfGame;

        if (std.mem.startsWith(u8, line, "bestmove ")) {
            if (std.mem.startsWith(u8, line, "bestmove (none)")) return error.EndOfGame;

            const move = std.mem.trimStart(u8, line["bestmove ".len..][0..], &std.ascii.whitespace);

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
    const io = self.io;
    var buffer: [0x1000]u8 = undefined;
    var writer = self.engine_process.stdin.?.writer(io, &buffer);

    try writer.interface.writeAll("position fen ");
    try board.writeFen(&writer.interface);
    try writer.interface.writeAll("\n");
    try writer.flush();
}

pub fn quit(self: *@This()) !void {
    try self.engine_process.stdin.?.writeStreamingAll(self.io, "quit\n");
    _ = try self.engine_process.wait(self.io);

    std.log.info("quit engine", .{});
}

const GoConfig = struct {
    // searchmoves: []const Move = &.{},
    // ponde: void = {},
    // wtime: void = {},
    // btime: void = {},
    // winc: void = {},
    // binc: void = {},
    // movestogo: void = {},
    depth: u8,
    // nodes: void = {},
    // mate: void = {},
    // movetime: void = {},
    // infinit: void = {},
};

pub fn go(self: *@This(), config: GoConfig) !void {
    var writer = self.engine_process.stdin.?.writer(self.io, &.{});
    try writer.interface.print("go depth {d}\n", .{config.depth});
}

pub fn close(uci: *Uci) !void {
    try uci.quit();
}

test {
    const args = @import("args");

    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();

    var uci = try connect(arena_state.allocator(), std.testing.io, args.engine_path);
    defer uci.close() catch {};

    var board: ChessBoard = .init;
    while (true) {
        try uci.setPosition(board);
        try uci.go(.{ .depth = 3 });
        const move = uci.getMove() catch |e| switch (e) {
            error.EndOfGame => break,
            else => |others| return others,
        };
        board.applyMove(move);
    }
}
