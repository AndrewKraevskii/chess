const std = @import("std");
const Io = std.Io;

const GameState = @import("GameState.zig");
const Move = GameState.MovePromotion;
const uci2 = @import("uci2.zig");
const Reader = Io.Reader;
const StringArrayHashMap = @import("stringz_array_hashmap_unmanaged.zig").StringArrayHashMapUnmanaged;

const Uci = @This();

const log = std.log.scoped(.uci);

io: Io,
engine_process: std.process.Child,
group: Io.Group,
reader: Io.File.Reader,
writer: Io.File.Writer,

id: struct {
    author: ?[:0]const u8 = null,
    name: ?[:0]const u8 = null,
},
options: StringArrayHashMap(Option),
arena_state: std.heap.ArenaAllocator.State,

const Option = union(enum) {
    /// a checkbox that can either be true or false
    check: struct {
        default: bool,
    },
    /// a spin wheel that can be an integer in a certain range
    spin: struct {
        default: bool,
        min: i64,
        max: i64,
    },
    /// a combo box that can have different predefined strings as a value
    combo: struct {
        default: []const u8,
        options: []const u8,
    },
    /// a button that can be pressed to send a command to the engine
    button,
    /// a text field that has a string as a value,
    /// an empty string has the value "<empty>"
    string: struct {
        default: []const u8,
    },
};

pub fn connect(io: Io, gpa: std.mem.Allocator, reader_buffer: []u8, writer_buffer: []u8, engine_path: []const u8) !@This() {
    var child = try std.process.spawn(io, .{
        .argv = &.{engine_path},
        .stderr = .ignore,
        .stdin = .pipe,
        .stdout = .pipe,
    });
    errdefer child.kill(io);

    var reader = child.stdout.?.reader(io, reader_buffer);
    var writer = child.stdin.?.writer(io, writer_buffer);

    try sendWriter(&writer.interface, .uci);

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    errdefer arena_state.deinit();
    const arena = arena_state.allocator();

    var author: ?[:0]const u8 = null;
    var name: ?[:0]const u8 = null;
    var options: @FieldType(Uci, "options") = .empty;
    errdefer options.deinit(gpa);

    while (try getCommand(&reader.interface)) |command| {
        switch (command) {
            .option => |opt| {
                try options.put(
                    gpa,
                    try arena.dupeZ(u8, opt.name),
                    opt.type,
                );
            },
            .uciok => {
                break;
            },
            .id => |id| {
                switch (id) {
                    .author => |a| {
                        author = try arena.dupeZ(u8, a);
                    },
                    .name => |n| {
                        name = try arena.dupeZ(u8, n);
                    },
                }
            },
            else => |c| {
                log.err("Expected option or uciok command got {t}", .{c});
            },
        }
    }

    const uci: Uci = .{
        .id = .{
            .author = author,
            .name = name,
        },
        .io = io,
        .engine_process = child,
        .group = .init,
        .writer = writer,
        .reader = reader,
        .arena_state = arena_state.state,
        .options = options,
    };

    return uci;
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
        const command = try getCommand(&self.reader.interface) orelse return error.EndOfGame;
        if (command == .bestmove) {
            log.info("from: {s} ", .{command.bestmove.move.from.serialize()});
            log.info("to {s}\n", .{command.bestmove.move.to.serialize()});
            return command.bestmove.move;
        }
        log.debug("recieved: {t}", .{command});
    }
}

pub fn setPosition(self: *@This(), board: GameState) !void {
    try sendWriter(&self.writer.interface, .{ .set_position = board });
}

pub fn quit(self: *@This()) !void {
    try sendWriter(&self.writer.interface, .quit);
    _ = try self.engine_process.wait(self.io);

    self.group.cancel(self.io);
    log.info("quit engine", .{});
}

pub fn go(self: *@This(), config: uci2.GoConfig) Io.Writer.Error!void {
    try sendWriter(&self.writer.interface, .{ .go = config });
}

pub fn send(self: *@This(), command: Command) Io.Writer.Error!void {
    try sendWriter(&self.writer.interface, command);
}

fn sendWriter(w: *Io.Writer, command: Command) Io.Writer.Error!void {
    switch (command) {
        .uci => try w.writeAll("uci\n"),
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
        .set_option => |option| {
            try w.print("setoption name {s}\n", .{option});
        },
    }
    try w.flush();
}

const Command = union(enum) {
    uci,
    go: uci2.GoConfig,
    quit,
    set_position: GameState,
    set_option: []const u8,
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
const ReadCommand = union(enum) {
    id: union(enum) {
        name: []const u8,
        author: []const u8,
    },
    uciok,
    readyok,
    bestmove: struct {
        move: Move,
        ponder: ?Move,
    },
    copyprotection,
    registration,
    info: union(enum) {
        depth: []const u8,
        seldepth: []const u8,
        time: []const u8,
        nodes: []const u8,
        pv: []const []const u8,
        multipv: []const u8,
        score: union(enum) {
            /// the score from the engine's point of view in centipawns.
            cp: []const u8,
            /// mate in y moves, not plies.
            /// If the engine is getting mated use negative values for y.
            mate: []const u8,
            ///       the score is just a lower bound.
            lowerbound,
            ///    the score is just an upper bound.
            upperbound,
        },
        currmove: []const u8,
        currmovenumber: []const u8,
        hashfull: []const u8,
        nps: []const u8,
        tbhits: []const u8,
        sbhits: []const u8,
        cpuload: []const u8,
        string: []const u8,
        refutation: []const []const u8,
        currline: []const []const u8,
    },
    // TODO: parse it property. For now i don't need to set any options.
    option: struct {
        name: []const u8,
        type: Option,
    },
};

/// It expects inputs lines to be no bigger than Reader's buffer.
pub fn getCommand(reader: *Reader) error{ ReadFailed, StreamTooLong }!?ReadCommand {
    const r = reader;

    parse_line: while (true) {
        log.debug("get loop start", .{});
        // skip all whitespace chars
        readerSkipNone(r, &std.ascii.whitespace) catch |e| switch (e) {
            error.EndOfStream => return null,
            error.ReadFailed => return error.ReadFailed,
        };
        log.debug("skiped whitespace", .{});
        // possible \r will be handled in future `next` call by `readerSkipNone`
        const line = (try r.takeDelimiter('\n')) orelse return null;
        log.debug("took untill delimiter", .{});
        var tokens = std.mem.tokenizeAny(u8, line, "\t ");
        log.debug("recieved string: {s}", .{line});
        // we skipped all whitespace so its impossible to get nothing
        const token_str = tokens.next() orelse unreachable;

        log.debug("token: {s}", .{token_str});

        const command = std.meta.stringToEnum(std.meta.Tag(ReadCommand), token_str) orelse {
            log.info("got unknown token: {s}", .{token_str});
            continue;
        };
        switch (command) {
            inline .uciok, .readyok, .copyprotection, .registration => |t| return t,
            .id => {
                const type_str = tokens.next() orelse continue;

                return switch (std.meta.stringToEnum(std.meta.Tag(@FieldType(ReadCommand, "id")), type_str) orelse continue) {
                    inline else => |type_enum| blk: {
                        const value = @constCast(tokens.rest());

                        break :blk .{ .id = @unionInit(@FieldType(ReadCommand, "id"), @tagName(type_enum), value) };
                    },
                };
            },
            .bestmove => {
                log.info("best move token", .{});
                const move = tokens.next() orelse continue;

                if (std.mem.eql(u8, move, "(none)")) {
                    return null;
                }

                const ponder = ponder: {
                    if (!std.mem.eql(u8, tokens.next() orelse "", "ponder")) break :ponder null;
                    break :ponder tokens.next() orelse continue;
                };
                return .{
                    .bestmove = .{
                        // TODO: this functions will panic with invalid input. Validate it before using.
                        .move = Move.parse(move) catch continue,
                        .ponder = if (ponder) |p| Move.parse(p) catch continue else null,
                    },
                };
            },
            .info => {
                log.info("Recieved info: {s}", .{line});
                continue;
            },
            .option => {
                // apparently names can have spaces in them.
                const name_keyword = tokens.next() orelse continue;
                if (!std.mem.eql(u8, "name", name_keyword)) continue;
                const name = name: {
                    const name_start = tokens.index;
                    while (tokens.peek()) |token| {
                        if (std.mem.eql(u8, token, "type")) {
                            break :name tokens.buffer[name_start..tokens.index];
                        }
                        _ = tokens.next();
                    } else continue :parse_line;
                };
                std.debug.assert(std.mem.eql(u8, tokens.next().?, "type"));

                switch (std.meta.stringToEnum(std.meta.Tag(Option), tokens.next() orelse continue) orelse continue) {
                    .button => {
                        return .{
                            .option = .{
                                .name = name,
                                .type = .button,
                            },
                        };
                    },
                    .check => {
                        const res = blk: {
                            const default_keyword = tokens.next() orelse continue;
                            if (!std.mem.eql(u8, default_keyword, "default")) continue;

                            const token = tokens.next() orelse continue;
                            if (std.mem.eql(u8, token, "false")) break :blk false;
                            if (std.mem.eql(u8, token, "true")) break :blk true;

                            continue;
                        };
                        return .{
                            .option = .{
                                .name = name,
                                .type = .{ .check = .{ .default = res } },
                            },
                        };
                    },
                    else => continue,
                }
            },
        }
        comptime unreachable;
    }
}

test {
    var reader: Reader = .fixed(
        \\id name Test
        \\id author andrew
        \\hellow
        \\option
    );
    var i: usize = 0;
    var expected: []const std.meta.Tag(ReadCommand) = &.{
        .id,
        .id,
        .option,
    };
    while (try getCommand(&reader)) |token| {
        try std.testing.expectEqual(expected[i], @as(std.meta.Tag(ReadCommand), (token)));
        i += 1;
    }
}

fn readerSkipNone(r: *Reader, values: []const u8) Reader.Error!void {
    while (true) {
        const contents = r.buffered();
        if (std.mem.findNone(u8, contents, values)) |first_not_value_index| {
            try r.discardAll(first_not_value_index);
            break;
        }
        try r.discardAll(r.buffered().len);
        try r.fillMore();
    }
}

// TODO: test the case where not all data is buffered from the start.
test readerSkipNone {
    var reader: Reader = .fixed(
        \\
        \\ hellow
        \\
    );
    try readerSkipNone(&reader, &std.ascii.whitespace);
    try std.testing.expectEqualSlices(u8, "hellow\n", reader.buffered());
    try reader.discardAll("hel".len);
    // does nothing if nothing to skip
    try std.testing.expectEqualSlices(u8, "low\n", reader.buffered());
    try readerSkipNone(&reader, &std.ascii.whitespace);
    try std.testing.expectEqualSlices(u8, "low\n", reader.buffered());
    try reader.discardAll("low".len);

    // handling when nothing except for values left.
    try std.testing.expectEqualSlices(u8, "\n", reader.buffered());
    try std.testing.expectError(error.EndOfStream, readerSkipNone(&reader, &std.ascii.whitespace));
}
