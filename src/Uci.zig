const std = @import("std");
const ChessBoard = @import("ChessBoard.zig");
const Uci = @This();
const Move = ChessBoard.Move;

gpa: std.mem.Allocator,
engine_process: std.process.Child,
promise: ?Promise(Move),

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

        pub fn get(self: @This()) ?T {
            return switch (self) {
                .none => null,
                .done => |t| t,
            };
        }
    };
}

pub fn getMoveAsync(self: *@This()) !*Promise(Move) {
    self.promise = .none;
    const thread = try std.Thread.spawn(.{}, struct {
        fn move(
            _self: *Uci,
            promise: *Promise(Move),
        ) void {
            promise.* = .{ .done = getMove(_self) catch @panic("Failed to get move") };
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

        try std.io.getStdOut().writer().print("<{s}>\n", .{line});
        if (std.mem.startsWith(u8, line, "bestmove ")) {
            if (std.mem.startsWith(u8, line, "bestmove (none)")) return error.EndOfGame;

            const move = std.mem.trimRight(u8, line["bestmove ".len..][0..], &std.ascii.whitespace);
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
