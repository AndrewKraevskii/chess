const GameState = @import("GameState.zig");
const std = @import("std");
const Writer = std.Io.Writer;
const assert = std.debug.assert;

pub fn serialize(self: *const GameState, writer: *Writer) !void {
    // write board positions
    for (self.cells, 0..) |row, index| {
        var running_empties: u4 = 0;
        for (row) |empty_or_piece| {
            if (empty_or_piece) |piece| {
                assert(running_empties <= 8);
                if (running_empties == 0) {
                    try writer.writeByte(piece.toChar());
                } else {
                    try writer.print("{d}", .{running_empties});
                    try writer.writeByte(piece.toChar());
                    running_empties = 0;
                }
            } else {
                running_empties += 1;
            }
        }
        if (running_empties != 0) {
            try writer.print("{d}", .{running_empties});
        }
        if (index != 7)
            try writer.writeByte('/');
    }

    // write current turn
    try writer.print(" {c}", .{self.turn.toChar()});

    // write castle
    castle: inline for ([_]GameState.Side{ .white, .black }) |side| {
        inline for ([_]GameState.CastleSide{ .king, .queen }) |castle_side| {
            if (self.can_castle.get(side).get(castle_side)) {
                try writer.writeAll(" ");
                if (self.can_castle.get(.white).get(.king)) {
                    try writer.writeAll("K");
                }
                if (self.can_castle.get(.white).get(.queen)) {
                    try writer.writeAll("Q");
                }
                if (self.can_castle.get(.black).get(.king)) {
                    try writer.writeAll("k");
                }
                if (self.can_castle.get(.black).get(.queen)) {
                    try writer.writeAll("q");
                }
                break :castle;
            }
        }
    } else {
        try writer.writeAll(" -");
    }

    // en passant
    if (self.en_passant) |en_passant| {
        try writer.print(" {s}", .{en_passant.serialize()});
    } else {
        try writer.writeAll(" -");
    }

    // number of moves
    try writer.print(" {d} {d}", .{ self.halfmove_clock, self.moves });
}

pub fn parse(fen_string: []const u8) error{InvalidFen}!GameState {
    var tokens = std.mem.tokenizeScalar(u8, fen_string, ' ');
    const board_str = tokens.next() orelse return error.InvalidFen;
    const turn = tokens.next() orelse return error.InvalidFen;
    const castle = tokens.next() orelse return error.InvalidFen;
    const en_passant = tokens.next() orelse return error.InvalidFen;
    const half_turn = tokens.next() orelse return error.InvalidFen;
    const full_turn = tokens.next() orelse return error.InvalidFen;
    if (tokens.next() != null) return error.InvalidFen;

    // fen string can't contain 0s in board part. So it is explicity excluded.
    if (std.mem.findNone(u8, board_str, "rnbqkbnrRNBQKBNRpP12345678/")) |pos| {
        std.log.err("Contains invalid character: {c}", .{board_str[pos]});
        return error.InvalidFen;
    }
    var board: GameState = undefined;

    {
        var rows_strings = std.mem.tokenizeScalar(u8, board_str, '/');
        for (&board.cells) |*row| {
            const row_string = rows_strings.next() orelse return error.InvalidFen;
            @memset(row, null);
            var row_pos: u4 = 0;
            for (row_string) |char| {
                if ('1' <= char and char <= '8') {
                    row_pos += @intCast(char - '1');
                    row_pos += 1;
                    continue;
                }
                if (row_pos >= row.len) return error.InvalidFen;
                row[row_pos] = .fromChar(char);
                row_pos += 1;
            }
        }
        if (rows_strings.next() != null) return error.InvalidFen;
    }

    std.debug.assert(turn.len > 0); // tokenize always returns non empty strings.

    if (turn.len != 1) return error.InvalidFen;
    board.turn = GameState.Side.fromChar(turn[0]) orelse return error.InvalidFen;
    board.can_castle = .init(.{
        .white = .init(.{
            .queen = std.mem.findScalar(u8, castle, 'Q') != null,
            .king = std.mem.findScalar(u8, castle, 'K') != null,
        }),
        .black = .init(.{
            .queen = std.mem.findScalar(u8, castle, 'q') != null,
            .king = std.mem.findScalar(u8, castle, 'k') != null,
        }),
    });

    if (std.mem.eql(u8, en_passant, "-")) {
        board.en_passant = null;
    } else if (en_passant.len == 2) {
        board.en_passant = GameState.Position.fromStringFalible(en_passant[0..2].*) catch return error.InvalidFen;
    } else {
        return error.InvalidFen;
    }

    board.halfmove_clock = std.fmt.parseInt(u32, half_turn, 10) catch return error.InvalidFen;
    board.moves = std.fmt.parseInt(u32, full_turn, 10) catch return error.InvalidFen;

    return board;
}

test parse {
    const chess_board: GameState = try parse(
        \\rnbqkbnr/p7/8/8/8/8/PPPPPPPP/RNBQKBNR b Kq h8 10 100
    );
    var buffer: [0x1000]u8 = undefined;
    var bw: std.Io.Writer = .fixed(&buffer);
    try chess_board.writeFen(&bw);
    try std.testing.expectEqualSlices(u8, "rnbqkbnr/p7/8/8/8/8/PPPPPPPP/RNBQKBNR b Kq h8 10 100", bw.buffered());
}
