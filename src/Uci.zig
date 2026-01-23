const std = @import("std");
const ChessBoard = @import("ChessBoard.zig");
const Uci = @This();
const uci2 = @import("uci2.zig");
const Move = ChessBoard.Move;
const Io = std.Io;

io: Io,
engine_process: std.process.Child,
promise: ?MovePromise,
group: Io.Group,
reader: Io.File.Reader,

pub fn connect(arena: std.mem.Allocator, io: Io, reader_buffer: []u8, engine_path: []const u8) !@This() {
    const child = try std.process.spawn(io, .{
        .argv = &.{engine_path},
        .stderr = .ignore,
        .stdin = .pipe,
        .stdout = .pipe,
    });
    _ = arena;
    const reader = child.stdout.?.reader(io, reader_buffer);

    return .{
        .io = io,
        .engine_process = child,
        .promise = null,
        .group = .init,
        .reader = reader,
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

pub fn getMoveAsync(self: *@This()) *MovePromise {
    self.promise = .{ .done = .init(false), .result = undefined };
    self.group.concurrent(self.io, struct {
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
    }.move, .{ self, &self.promise.? }) catch @panic("ConcurrencyUnavailable");

    return &self.promise.?;
}

pub fn getMove(self: *@This()) !Move {
    std.log.debug("getting move", .{});
    while (true) {
        const command = try uci2.getCommand(&self.reader.interface) orelse return error.EndOfGame;
        if (command == .bestmove) {
            std.log.info("from: {s} ", .{command.bestmove.move.from.serialize()});
            std.log.info("to {s}\n", .{command.bestmove.move.to.serialize()});
            return command.bestmove.move;
        }
        std.log.debug("recieved: {t}", .{command});
    }
}

pub fn setPosition(self: *@This(), board: ChessBoard) !void {
    {
        var buffer: [0x100]u8 = undefined;
        var fixed: std.Io.Writer = .fixed(&buffer);
        try board.writeFen(&fixed);
        std.log.debug("set position: {s}", .{fixed.buffered()});
    }
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

    self.group.cancel(self.io);
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
    std.log.debug("go", .{});
    var writer = self.engine_process.stdin.?.writer(self.io, &.{});
    try writer.interface.print("go depth {d}\n", .{config.depth});
    try writer.interface.flush();
}

test {
    if (true) return error.SkipZigTest;
    const args = @import("args");

    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();

    var buffer: [0x1000]u8 = undefined;
    var uci = try connect(arena_state.allocator(), std.testing.io, &buffer, args.engine_path);
    defer uci.quit() catch {};

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
