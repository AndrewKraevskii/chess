const std = @import("std");

const ChessBoard = @This();

cells: [8][8]?PieceWithSide,
turn: Side,
moves: u16,
can_castle: std.EnumArray(Side, std.EnumArray(CastleSide, bool)),
/// Points to square which can be eaten by pawn.
/// In this situation shows square E where p is pawn
/// p    .
/// . -> E
/// .    p
en_passant: ?Position,
halfmove_clock: u32,

pub const Move = struct {
    from: Position,
    to: Position,
    promotion: ?Piece = null,

    pub fn parse(str: []const u8) error{Invalid}!Move {
        if (!(str.len == 4 or str.len == 5)) return error.Invalid;

        var move: Move = .{
            .from = try .fromStringFalible(str[0..2].*),
            .to = try .fromStringFalible(str[2..4].*),
        };

        if (str.len == 5) {
            move.promotion = (PieceWithSide.fromChar(str[4]) orelse return error.Invalid).piece;
        }

        return move;
    }

    fn distanceVertically(move: Move) u3 {
        return if (move.from.row > move.to.row) move.from.row - move.to.row else move.to.row - move.from.row;
    }
    fn distanceHorisontaly(move: Move) u3 {
        return if (move.from.file > move.to.file) move.from.file - move.to.file else move.to.file - move.from.file;
    }
};

pub fn get(board: *ChessBoard, pos: Position) *?PieceWithSide {
    return &board.cells[7 - pos.row][pos.file];
}

const king_start_position: std.EnumArray(Side, Position) = .init(.{
    .white = .fromString("e1".*),
    .black = .fromString("e8".*),
});

const CastleSide = enum {
    king,
    queen,
};

const castle_squares: std.EnumArray(Side, std.EnumArray(CastleSide, struct { king_destination: Position, rook: Move })) = .init(.{
    .white = .init(
        .{
            .king = .{
                .king_destination = .fromString("g1".*),
                .rook = .{ .from = .fromString("h1".*), .to = .fromString("f1".*) },
            },
            .queen = .{
                .king_destination = .fromString("c1".*),
                .rook = .{ .from = .fromString("a1".*), .to = .fromString("d1".*) },
            },
        },
    ),
    .black = .init(
        .{
            .king = .{
                .king_destination = .fromString("g8".*),
                .rook = .{ .from = .fromString("h8".*), .to = .fromString("f8".*) },
            },
            .queen = .{
                .king_destination = .fromString("c8".*),
                .rook = .{ .from = .fromString("a8".*), .to = .fromString("d8".*) },
            },
        },
    ),
});

pub fn applyMove(board: *ChessBoard, move: Move) void {
    if (std.meta.eql(move.from, move.to)) {
        std.log.err("{s} {s}", .{ move.from.serialize(), move.to.serialize() });
        std.debug.assert(!std.meta.eql(move.from, move.to));
    }

    const side = board.turn;

    const from = board.get(move.from);
    const to = board.get(move.to);
    switch (from.*.?.piece) {
        .king => if (std.meta.eql(move.from, king_start_position.get(board.turn))) {
            const castle_squares_for_current_side = castle_squares.get(side);

            inline for ([_]CastleSide{ .king, .queen }) |castle_side| {
                if (std.meta.eql(castle_squares_for_current_side.get(castle_side).king_destination, move.to)) {
                    const to_rook = board.get(castle_squares_for_current_side.get(castle_side).rook.to);
                    const from_rook = board.get(castle_squares_for_current_side.get(castle_side).rook.from);
                    to_rook.* = from_rook.*;
                    from_rook.* = null;
                    board.can_castle.set(side, .initFill(false));
                    break;
                }
            }
            board.en_passant = null;
        },
        .pawn => {
            if (board.en_passant) |en_passant| {
                if (std.meta.eql(en_passant, move.to)) {
                    std.log.debug("umnam", .{});
                    board.get(.{
                        .row = move.from.row,
                        .file = move.to.file,
                    }).* = null;
                }
            }
            if (move.distanceVertically() == 2) {
                board.en_passant = move.from;
                board.en_passant.?.row = @intCast((@as(u4, move.from.row) + move.to.row) >> 1);
                std.log.debug("en_passant {s}", .{board.en_passant.?.serialize()});
            }
            board.halfmove_clock = 0;
        },
        else => {
            board.en_passant = null;
        },
    }

    board.turn = board.turn.next();
    board.moves += 1;

    if (to.* != null) {
        board.halfmove_clock = 0;
    }
    board.halfmove_clock += 1;

    to.* = from.*;
    if (move.promotion) |promotion| {
        to.*.?.piece = promotion;
    }
    from.* = null;

    std.log.info("moved from {s} to {s}", .{ move.from.serialize(), move.to.serialize() });
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

    pub fn fromStringFalible(str: [2]u8) !Position {
        return .{
            .file = std.math.cast(u3, str[0] -% 'a') orelse return error.Invalid,
            .row = std.math.cast(u3, str[1] -% '1') orelse return error.Invalid,
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

fn isRookMovePossible(board: *ChessBoard, from: Position, to: Position, dv: u3, dh: u3) bool {
    if (dv != 0 and dh != 0) return false;

    var x = from.file;
    var y = from.row;
    while (true) {
        switch (std.math.order(from.file, to.file)) {
            .eq => {},
            .lt => x += 1,
            .gt => x -= 1,
        }
        switch (std.math.order(from.row, to.row)) {
            .eq => {},
            .lt => y += 1,
            .gt => y -= 1,
        }
        if (x == to.file and y == to.row) {
            return true;
        }
        if (board.get(.{ .row = y, .file = x }).* != null) {
            return false;
        }
    }
}

fn findAny(board: *ChessBoard, piece: PieceWithSide) ?Position {
    for (0..8) |y| {
        for (0..8) |x| {
            const pos: Position = .{
                .row = @intCast(y),
                .file = @intCast(x),
            };
            if (board.get(pos).*) |piece_on_board| {
                if (std.meta.eql(piece, piece_on_board)) {
                    return pos;
                }
            }
        }
    }
    return null;
}

fn kingInCheck(board: *ChessBoard, side: Side) bool {
    const king_pos = board.findAny(.{ .piece = .king, .side = side }).?;

    for (0..8) |y| {
        for (0..8) |x| {
            const pos: Position = .{
                .row = @intCast(y),
                .file = @intCast(x),
            };
            if (board.isMovePossibleWithNoCheck(pos, king_pos)) return true;
        }
    }
    return false;
}

const pawns_start_row: std.EnumArray(Side, u3) = .init(.{
    .white = 1,
    .black = 6,
});

pub fn isMovePossible(board: *ChessBoard, from: Position, to: Position) bool {
    if (!board.isMovePossibleWithNoCheck(from, to)) return false;

    var board_copy = board.*;
    board_copy.applyMove(.{ .from = from, .to = to });
    return !board_copy.kingInCheck(board.turn);
}

fn isMovePossibleWithNoCheck(board: *ChessBoard, from: Position, to: Position) bool {
    const piece = board.get(from).* orelse return false;

    if (board.get(to).*) |targeted_piece| {
        if (targeted_piece.side == piece.side) return false;
    }

    const move: Move = .{ .from = from, .to = to };
    const dv = move.distanceVertically();
    const dh = move.distanceHorisontaly();
    piece: switch (piece.piece) {
        .king => return dv <= 1 and dh <= 1,
        .knight => return @max(dv, dh) == 2 and @min(dv, dh) == 1,
        .bishop => {
            if (dv != dh) return false;

            var x = from.file;
            var y = from.row;
            while (true) {
                if (from.file < to.file) {
                    x += 1;
                } else {
                    x -= 1;
                }
                if (from.row < to.row) {
                    y += 1;
                } else {
                    y -= 1;
                }
                if (x == to.file) {
                    return true;
                }
                if (board.get(.{ .row = y, .file = x }).* != null) {
                    return false;
                }
            }
            return true;
        },
        .rook => return board.isRookMovePossible(from, to, dv, dh),
        .queen => {
            if (board.isRookMovePossible(from, to, dv, dh)) return true;
            continue :piece .bishop;
        },
        .pawn => {
            if (board.turn == .white and from.row > to.row) return false;
            if (board.turn == .black and from.row < to.row) return false;
            if (dh == 0 and dv == 1) {
                return board.get(to).* == null;
            }
            if (dh == 0 and dv == 2 and pawns_start_row.get(board.turn) == from.row) {
                return board.get(.{
                    .file = from.file,
                    .row = if (board.turn == .white) from.row + 1 else from.row - 1,
                }).* == null and board.get(to).* == null;
            }
            if (dh == 1 and dv == 1) {
                if (board.en_passant) |en_passant| {
                    if (std.meta.eql(en_passant, to)) {
                        return true;
                    }
                }
                return board.get(to).* != null;
            }
            return false;
        },
    }
}

pub fn writeFen(self: *const ChessBoard, writer: *std.Io.Writer) !void {
    // write board positions
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

    // write current turn
    try writer.print(" {c}", .{self.turn.toChar()});

    // write castle
    castle: inline for ([_]Side{ .white, .black }) |side| {
        inline for ([_]CastleSide{ .king, .queen }) |castle_side| {
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
    .halfmove_clock = 0,
    .can_castle = .initFill(.init(.{
        .queen = true,
        .king = true,
    })),
    .en_passant = null,
};

test {
    var buffer: [0x1000]u8 = undefined;
    var bw: std.Io.Writer = .fixed(&buffer);
    try ChessBoard.init.writeFen(&bw);
    try std.testing.expectEqualSlices(u8, "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 0", bw.buffered());
}
