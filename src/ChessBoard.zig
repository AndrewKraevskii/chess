const std = @import("std");

const ChessBoard = @This();

cells: [8][8]?PieceWithSide,
turn: Side,
moves: u16,
can_castle: std.EnumArray(Side, struct {
    king_side: bool,
    queen_side: bool,
}),

pub const Move = struct {
    from: ChessBoard.Position,
    to: ChessBoard.Position,
    promotion: ?ChessBoard.Piece,
};

pub fn applyMove(board: *ChessBoard, move: Move) void {
    std.debug.assert(!std.meta.eql(move.from, move.to));

    const from = &board.cells[7 - move.from.row][move.from.file];
    const to = &board.cells[7 - move.to.row][move.to.file];
    if (from.*.?.piece == .king) {
        const distance = @max(move.from.file, move.to.file) - @min(move.from.file, move.to.file);
        if (distance == 2) { // its castle
            if (move.to.file > move.from.file) { // short castle
                std.log.debug("making short castle", .{});
                board.cells[7 - move.to.row][5] = board.cells[7 - move.to.row][7];
                board.cells[7 - move.to.row][7] = null;
            } else { // long castle
                std.log.debug("making long castle", .{});
                board.cells[7 - move.to.row][3] = board.cells[7 - move.to.row][0];
                board.cells[7 - move.to.row][0] = null;
            }
        }
        board.can_castle.set(board.turn, .{ .king_side = false, .queen_side = false });
    }
    board.turn = board.turn.next();
    board.moves += 1;

    to.* = from.*;
    if (move.promotion) |promotion| {
        to.*.?.piece = promotion;
    }
    from.* = null;

    std.debug.print("moved from {s} to {s}\n", .{ move.from.serialize(), move.to.serialize() });
}

pub const Side = enum {
    white,
    black,

    pub fn toChar(side: Side) u8 {
        return switch (side) {
            .white => 'w',
            .black => 'b',
        };
    }

    pub fn next(side: Side) Side {
        return switch (side) {
            .white => .black,
            .black => .white,
        };
    }
};

pub const Position = struct {
    row: u3,
    /// column
    file: u3,

    pub fn serialize(pos: Position) [2]u8 {
        return .{
            @as(u8, pos.file) + 'a',
            @as(u8, pos.row) + '1',
        };
    }

    pub fn fromString(str: [2]u8) Position {
        return .{
            .file = @intCast(str[0] - 'a'),
            .row = @intCast(str[1] - '1'),
        };
    }
};

pub const Piece = enum {
    pawn,
    bishop,
    knight,
    rook,
    queen,
    king,
};

pub const PieceWithSide = struct {
    side: Side,
    piece: Piece,

    pub fn fromChar(char: u8) ?PieceWithSide {
        const side: Side = if (std.ascii.isUpper(char)) .white else .black;
        const lower = std.ascii.toLower(char);
        const piece: Piece = switch (lower) {
            'p' => .pawn,
            'r' => .rook,
            'n' => .knight,
            'b' => .bishop,
            'q' => .queen,
            'k' => .king,
            else => return null,
        };

        return .{
            .side = side,
            .piece = piece,
        };
    }

    pub fn toChar(piece_with_side: PieceWithSide) u8 {
        var piece: u8 = switch (piece_with_side.piece) {
            .pawn => 'p',
            .rook => 'r',
            .knight => 'n',
            .bishop => 'b',
            .queen => 'q',
            .king => 'k',
        };
        if (piece_with_side.side == .white)
            piece = std.ascii.toUpper(piece);

        return piece;
    }
};

pub fn writeFen(self: *const ChessBoard, writer: anytype) !void {
    for (self.cells, 0..) |row, index| {
        var running_empties: u4 = 0;
        for (row) |empty_or_piece| {
            if (empty_or_piece) |piece| {
                std.debug.assert(running_empties <= 8);
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

    try writer.writeByte(' ');
    try writer.writeByte(self.turn.toChar());
    if (self.can_castle.get(.white).king_side or self.can_castle.get(.white).queen_side or self.can_castle.get(.black).king_side or self.can_castle.get(.black).queen_side) {
        try writer.writeAll(" ");
        if (self.can_castle.get(.white).king_side) {
            try writer.writeAll("K");
        }
        if (self.can_castle.get(.white).queen_side) {
            try writer.writeAll("Q");
        }
        if (self.can_castle.get(.black).king_side) {
            try writer.writeAll("k");
        }
        if (self.can_castle.get(.black).queen_side) {
            try writer.writeAll("q");
        }
    } else {
        try writer.writeAll(" -");
    }
    try writer.writeAll(" -");
    try writer.print(" {d} {d}", .{ self.moves, self.moves });
}

pub const init = ChessBoard{
    .cells = .{
        .{ .fromChar('r'), .fromChar('n'), .fromChar('b'), .fromChar('q'), .fromChar('k'), .fromChar('b'), .fromChar('n'), .fromChar('r') },
        .{ .fromChar('p'), .fromChar('p'), .fromChar('p'), .fromChar('p'), .fromChar('p'), .fromChar('p'), .fromChar('p'), .fromChar('p') },
        .{ .fromChar('.'), .fromChar('.'), .fromChar('.'), .fromChar('.'), .fromChar('.'), .fromChar('.'), .fromChar('.'), .fromChar('.') },
        .{ .fromChar('.'), .fromChar('.'), .fromChar('.'), .fromChar('.'), .fromChar('.'), .fromChar('.'), .fromChar('.'), .fromChar('.') },
        .{ .fromChar('.'), .fromChar('.'), .fromChar('.'), .fromChar('.'), .fromChar('.'), .fromChar('.'), .fromChar('.'), .fromChar('.') },
        .{ .fromChar('.'), .fromChar('.'), .fromChar('.'), .fromChar('.'), .fromChar('.'), .fromChar('.'), .fromChar('.'), .fromChar('.') },
        .{ .fromChar('P'), .fromChar('P'), .fromChar('P'), .fromChar('P'), .fromChar('P'), .fromChar('P'), .fromChar('P'), .fromChar('P') },
        .{ .fromChar('R'), .fromChar('N'), .fromChar('B'), .fromChar('Q'), .fromChar('K'), .fromChar('B'), .fromChar('N'), .fromChar('R') },
    },
    .turn = .white,
    .moves = 0,
    .can_castle = .initFill(.{
        .queen_side = true,
        .king_side = true,
    }),
};

test {
    var buffer: [0x1000]u8 = undefined;
    var bw = std.io.fixedBufferStream(&buffer);
    try ChessBoard.init.writeFen(bw.writer());
    try std.testing.expectEqualSlices(u8, "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 0", bw.buffer[0..bw.pos]);
}
