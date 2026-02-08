const std = @import("std");
const Io = std.Io;

const GameState = @import("GameState.zig");
const Move = GameState.MovePromotion;
const uci2 = @import("uci2.zig");

const Uci = @This();

const log = std.log.scoped(.uci);

io: Io,
engine_process: std.process.Child,
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
        .group = .init,
        .writer = writer,
        .reader = reader,
    };
}

pub fn getMoveAsync(self: *@This(), io: Io, queue: *Io.Queue(Move)) void {
    self.group.async(self.io, struct {
        fn move(
            _self: *Uci,
            _io: Io,
            promise: *Io.Queue(Move),
        ) void {
            promise.putOne(_io, getMove(_self) catch |e| switch (e) {
                error.EndOfGame => {
                    promise.close(_io);
                    return;
                },
                else => |other| {
                    log.err("{s}", .{@errorName(other)});
                    return;
                },
            }) catch |e|
                switch (e) {
                    error.Canceled, error.Closed => {},
                };
        }
    }.move, .{ self, io, queue });
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
    try send(&self.writer.interface, .{ .set_position = board });
}

pub fn quit(self: *@This()) !void {
    try send(&self.writer.interface, .quit);
    _ = try self.engine_process.wait(self.io);

    self.group.cancel(self.io);
    log.info("quit engine", .{});
}

pub fn go(self: *@This(), config: uci2.GoConfig) Io.Writer.Error!void {
    try send(&self.writer.interface, .{ .go = config });
}

fn send(w: *Io.Writer, command: Command) Io.Writer.Error!void {
    switch (command) {
        .go => |config| {
            std.log.debug("go", .{});
            try w.print("go depth {d}\n", .{config.depth});
        },
        .quit => {
            try w.writeAll("quit\n");
        },
        .set_position => |board| {
            log.debug("set position: {f}", .{board});
            try w.print("position fen {f}\n", .{board});
        },
    }
    try w.flush();
}

const Command = union(enum) {
    go: uci2.GoConfig,
    quit,
    set_position: GameState,
};

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
        if (board.result() != .playing) break;
        try uci.setPosition(board);
        try uci.go(.{ .depth = 1 });
        const move = uci.getMove() catch |e| switch (e) {
            error.EndOfGame => break,
            else => |others| return others,
        };
        board = board.applyMove(move);
    }
}
