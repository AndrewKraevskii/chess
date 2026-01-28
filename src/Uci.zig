const std = @import("std");
const Io = std.Io;

const GameState = @import("GameState.zig");
const Move = GameState.MovePromotion;
const uci2 = @import("uci2.zig");

const Uci = @This();

const log = std.log.scoped(.uci);

io: Io,
engine_process: std.process.Child,
promise: ?MovePromise,
group: Io.Group,
reader: Io.File.Reader,
writer: Io.File.Writer,

pub fn connect(io: Io, reader_buffer: []u8, writer_buffer: []u8, engine_path: []const u8) !@This() {
    const child = try std.process.spawn(io, .{
        .argv = &.{engine_path},
        .stderr = .ignore,
        .stdin = .pipe,
        .stdout = .pipe,
    });
    const reader = child.stdout.?.reader(io, reader_buffer);
    const writer = child.stdin.?.writer(io, writer_buffer);

    return .{
        .io = io,
        .engine_process = child,
        .promise = null,
        .group = .init,
        .writer = writer,
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
                    log.err("{s}", .{@errorName(other)});
                    return;
                },
            };
            promise.done.store(true, .release);
        }
    }.move, .{ self, &self.promise.? }) catch @panic("ConcurrencyUnavailable");

    return &self.promise.?;
}

pub fn getMove(self: *@This()) !Move {
    log.debug("getting move", .{});
    while (true) {
        const command = try uci2.getCommand(&self.reader.interface) orelse return error.EndOfGame;
        if (command == .bestmove) {
            log.info("from: {s} ", .{command.bestmove.move.from.serialize()});
            log.info("to {s}\n", .{command.bestmove.move.to.serialize()});
            return command.bestmove.move;
        }
        log.debug("recieved: {t}", .{command});
    }
}

pub fn setPosition(self: *@This(), board: GameState) !void {
    {
        var buffer: [0x100]u8 = undefined;
        var fixed: std.Io.Writer = .fixed(&buffer);
        try board.writeFen(&fixed);
        log.debug("set position: {s}", .{fixed.buffered()});
    }
    try uci2.setPosition(&self.writer.interface, board);
    try self.writer.interface.flush();
}

pub fn quit(self: *@This()) !void {
    try self.writer.interface.writeAll("quit\n");
    try self.writer.interface.flush();
    _ = try self.engine_process.wait(self.io);

    self.group.cancel(self.io);
    log.info("quit engine", .{});
}

pub fn go(self: *@This(), config: uci2.GoConfig) !void {
    try uci2.go(&self.writer.interface, config);
    try self.writer.interface.flush();
}

test {
    if (true) return error.SkipZigTest;
    const args = @import("args");

    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();

    var reader_buffer: [0x1000]u8 = undefined;
    var writer_buffer: [0x1000]u8 = undefined;
    var uci = try connect(std.testing.io, &reader_buffer, &writer_buffer, args.engine_path);
    defer uci.quit() catch {};

    var board: GameState = .init;
    while (true) {
        if (board.result()) |_| break;
        try uci.setPosition(board);
        try uci.go(.{ .depth = 3 });
        const move = uci.getMove() catch |e| switch (e) {
            error.EndOfGame => break,
            else => |others| return others,
        };
        board.applyMove(move);
    }
}
