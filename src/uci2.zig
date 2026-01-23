const std = @import("std");
const Reader = std.Io.Reader;
const Writer = std.Io.Writer;
const ChessBoard = @import("ChessBoard.zig");
const Move = ChessBoard.Move;
const log = std.log.scoped(.uci2);

reader: *Reader,
writer: *Writer,

pub fn init(stdin: *Reader, stdout: *Writer) void {
    return .{
        .stdin = stdin,
        .stdout = stdout,
    };
}

fn setPosition(w: *Writer, c: ChessBoard) !void {
    try w.writeAll("position fen ");
    try c.writeFen(w);
    try w.writeAll("\n");
    try w.flush();
}

const Command = union(enum) {
    id: struct {
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
    option: []const []const u8,
};

/// It expects inputs lines to be no bigger than Reader's buffer.
pub fn getCommand(reader: *Reader) error{ ReadFailed, StreamTooLong }!?Command {
    const r = reader;

    while (true) {
        log.debug("get loop start", .{});
        // skip all whitespace chars
        readerSkipNone(r, &std.ascii.whitespace) catch |e| switch (e) {
            error.EndOfStream => return null,
            error.ReadFailed => return error.ReadFailed,
        };
        log.debug("skiped whitespace", .{});
        // possible \r will be handled in future `next` call by `readerSkipNone`
        const buffer = (try r.takeDelimiter('\n')) orelse return null;
        log.debug("took untill delimiter", .{});
        var tokens = std.mem.tokenizeAny(u8, buffer, "\t ");
        log.debug("recieved string: {s}", .{buffer});
        // we skipped all whitespace so its impossible to get nothing
        const token_str = tokens.next() orelse unreachable;

        const token = std.meta.stringToEnum(std.meta.Tag(Command), token_str) orelse {
            log.err("got unknown token: {s}", .{token_str});
            continue;
        };
        switch (token) {
            inline .uciok, .readyok, .copyprotection, .registration => |t| return t,
            .id => {
                return .{ .id = .{
                    .name = tokens.next() orelse continue,
                    .author = tokens.next() orelse continue,
                } };
            },
            .bestmove => {
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
                log.info("Recieved info: {s}", .{buffer});
                continue;
            },
            .option => {
                log.info("Recieved option: {s}", .{buffer});
                continue;
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
    while (try getCommand(&reader)) |token| {
        log.err("{any}\n", .{token});
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

const Uci = @This();
