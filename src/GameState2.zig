const std = @import("std");

pub const parse = @import("fen.zig").parse;

const GameState = @This();
// fields here are orderd same as in FEN string.

cells: [8][8]?Piece,
turn: Side,
can_castle: std.EnumArray(Side, std.EnumSet(CastleSide)),
/// Points to square which can be eaten by pawn.
/// In this situation shows square E where p is pawn
/// p    .
/// . -> E
/// .    p
en_passant: ?Position,
/// Tracks number of moves since last pawn movment or piece capture.
half_moves: u32,
full_moves: u32,

/// Maximum number of moves.
/// https://lichess.org/@/Tobs40/blog/why-a-reachable-position-can-have-at-most-218-playable-moves/a5xdxeqs#other-stuff-solved-along-the-way
pub const max_moves_from_position = 288;

pub const init: GameState = .{
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
    .full_moves = 1,
    .half_moves = 0,
    .can_castle = .initFill(.init(.{
        .queen = true,
        .king = true,
    })),
    .en_passant = null,
};

/// Usefull for setting up board programmaticaly.
pub const empty: GameState = .{
    .cells = .{
        .{ .fromChar('.'), .fromChar('.'), .fromChar('.'), .fromChar('.'), .fromChar('.'), .fromChar('.'), .fromChar('.'), .fromChar('.') },
        .{ .fromChar('.'), .fromChar('.'), .fromChar('.'), .fromChar('.'), .fromChar('.'), .fromChar('.'), .fromChar('.'), .fromChar('.') },
        .{ .fromChar('.'), .fromChar('.'), .fromChar('.'), .fromChar('.'), .fromChar('.'), .fromChar('.'), .fromChar('.'), .fromChar('.') },
        .{ .fromChar('.'), .fromChar('.'), .fromChar('.'), .fromChar('.'), .fromChar('.'), .fromChar('.'), .fromChar('.'), .fromChar('.') },
        .{ .fromChar('.'), .fromChar('.'), .fromChar('.'), .fromChar('.'), .fromChar('.'), .fromChar('.'), .fromChar('.'), .fromChar('.') },
        .{ .fromChar('.'), .fromChar('.'), .fromChar('.'), .fromChar('.'), .fromChar('.'), .fromChar('.'), .fromChar('.'), .fromChar('.') },
        .{ .fromChar('.'), .fromChar('.'), .fromChar('.'), .fromChar('.'), .fromChar('.'), .fromChar('.'), .fromChar('.'), .fromChar('.') },
        .{ .fromChar('.'), .fromChar('.'), .fromChar('.'), .fromChar('.'), .fromChar('.'), .fromChar('.'), .fromChar('.'), .fromChar('.') },
    },
    .turn = .white,
    .full_moves = 1,
    .half_moves = 0,
    .can_castle = .initFill(.init(.{
        .queen = true,
        .king = true,
    })),
    .en_passant = null,
};

pub const Move = struct {
    from: Position,
    to: Position,

    pub fn parse(str: []const u8) error{Invalid}!Move {
        if (str.len != 4) return error.Invalid;

        return .{
            .from = try .fromStringFalible(str[0..2].*),
            .to = try .fromStringFalible(str[2..4].*),
        };
    }

    const Iterator = struct {
        move: Move,
        diff: [2]u3,

        fn init(move: Move) Iterator {
            const from = move.from;
            const to = move.to;

            const file_diff: i3 = @intCast(std.math.clamp(to.file - @as(i4, from.file), -1, 1));
            const row_diff: i3 = @intCast(std.math.clamp(to.row - @as(i4, from.row), -1, 1));

            return .{
                .move = move,
                .diff = .{ @bitCast(file_diff), @bitCast(row_diff) },
            };
        }

        fn next(iter: *Iterator) ?Position {
            const from = iter.move.from;
            const to = iter.move.to;

            if (std.meta.eql(from, to)) return null;

            const next_pos: Position = .{
                .file = from.file +% iter.diff[0],
                .row = from.row +% iter.diff[1],
            };
            iter.move.from = next_pos;
            return next_pos;
        }
    };
};

pub const MovePromotion = struct {
    from: Position,
    to: Position,
    promotion: ?Piece.Type = null,

    pub fn parse(str: []const u8) error{Invalid}!MovePromotion {
        if (!(str.len == 4 or str.len == 5)) return error.Invalid;

        var move: MovePromotion = .{
            .from = try .fromStringFalible(str[0..2].*),
            .to = try .fromStringFalible(str[2..4].*),
        };

        if (str.len == 5) {
            move.promotion = (Piece.fromChar(str[4]) orelse return error.Invalid).type;
        }

        return move;
    }
};

pub const CastleSide = enum {
    king,
    queen,
};

const king_start_position: std.EnumArray(Side, Position) = .init(.{
    .white = .fromString("e1".*),
    .black = .fromString("e8".*),
});

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

pub fn get(board: *GameState, pos: Position) *?Piece {
    return &board.cells[7 - pos.row][pos.file];
}

pub fn getConst(board: *const GameState, pos: Position) ?Piece {
    return board.cells[7 - pos.row][pos.file];
}

pub const writeFen = @import("fen.zig").serialize;

pub const Side = enum(u1) {
    white,
    black,

    pub fn toChar(side: Side) u8 {
        return switch (side) {
            .white => 'w',
            .black => 'b',
        };
    }

    pub fn fromChar(char: u8) ?Side {
        return switch (char) {
            'w' => .white,
            'b' => .black,
            else => return null,
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

    pub fn forward(pos: Position, dist: u3, side: Side) Position {
        return .{
            .file = pos.file,
            .row = if (side == .white) pos.row + dist else pos.row - dist,
        };
    }
    pub fn forwardClamped(pos: Position, dist: u3, side: Side) Position {
        return .{
            .file = pos.file,
            .row = if (side == .white) pos.row +| dist else pos.row -| dist,
        };
    }
    pub fn backward(pos: Position, dist: u3, side: Side) Position {
        return pos.forward(dist, side.next());
    }
};

pub const Piece = packed struct {
    side: Side,
    type: Type,

    pub const Type = enum(u3) {
        pawn,
        bishop,
        knight,
        rook,
        queen,
        king,
    };

    pub fn fromChar(char: u8) ?Piece {
        const side: Side = if (std.ascii.isUpper(char)) .white else .black;
        const lower = std.ascii.toLower(char);
        const piece: Piece.Type = switch (lower) {
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
            .type = piece,
        };
    }

    pub fn toChar(piece_with_side: Piece) u8 {
        var piece: u8 = switch (piece_with_side.type) {
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

const pawns_start_row: std.EnumArray(Side, u3) = .init(.{
    .white = 1,
    .black = 6,
});

const pawns_promotion_raw: std.EnumArray(Side, u3) = .init(.{
    .white = 7,
    .black = 0,
});

const pawn_promotions: []const Piece.Type = &.{
    .bishop,
    .knight,
    .rook,
    .queen,
};

fn bishopMoves(pos: Position) [4]Position {
    const a = @min(pos.file, pos.row);
    const b = @min(7 - pos.file, 7 - pos.row);
    const c = @min(7 - pos.file, pos.row);
    const d = @min(pos.file, 7 - pos.row);
    return .{
        .{ .row = pos.row - a, .file = pos.file - a },
        .{ .row = pos.row + b, .file = pos.file + b },
        .{ .row = pos.row - c, .file = pos.file + c },
        .{ .row = pos.row + d, .file = pos.file - d },
    };
}
fn kingMoves(pos: Position) [8]Position {
    const a = @min(@min(pos.file, pos.row), 1);
    const b = @min(@min(7 - pos.file, 7 - pos.row), 1);
    const c = @min(@min(7 - pos.file, pos.row), 1);
    const d = @min(@min(pos.file, 7 - pos.row), 1);
    return .{
        .{ .row = pos.row - a, .file = pos.file - a },
        .{ .row = pos.row + b, .file = pos.file + b },
        .{ .row = pos.row - c, .file = pos.file + c },
        .{ .row = pos.row + d, .file = pos.file - d },

        .{ .row = pos.row, .file = pos.file +| 1 },
        .{ .row = pos.row, .file = pos.file -| 1 },
        .{ .row = pos.row +| 1, .file = pos.file },
        .{ .row = pos.row -| 1, .file = pos.file },
    };
}

fn rookMoves(pos: Position) [4]Position {
    return .{
        .{ .row = pos.row, .file = 0 },
        .{ .row = pos.row, .file = 7 },
        .{ .row = 0, .file = pos.file },
        .{ .row = 7, .file = pos.file },
    };
}

pub fn movesRaw(state: *const GameState, buffer: *[GameState.max_moves_from_position]Move) []Move {
    var list: std.ArrayList(Move) = .initBuffer(buffer);
    const turn = state.turn;

    for (0..8) |h| {
        for (0..8) |w| {
            const pos: Position = .{ .file = @intCast(w), .row = @intCast(h) };
            const piece = state.getConst(pos) orelse continue;
            if (piece.side != turn) continue;

            var positions_buffer: [8]Position = undefined;
            var positions: std.ArrayList(Position) = .initBuffer(&positions_buffer);
            switch (piece.type) {
                .rook => positions.appendSliceAssumeCapacity(&rookMoves(pos)),
                .bishop => positions.appendSliceAssumeCapacity(&bishopMoves(pos)),
                .queen => {
                    positions.appendSliceAssumeCapacity(&rookMoves(pos));
                    positions.appendSliceAssumeCapacity(&bishopMoves(pos));
                },
                .king => {
                    positions.appendSliceAssumeCapacity(&kingMoves(pos));
                    var iter = state.can_castle.get(turn).iterator();
                    while (iter.next()) |castle_side| {
                        std.debug.assert(std.meta.eql(king_start_position.get(turn), pos));
                        const castle_move = castle_squares.get(turn).get(castle_side);
                        std.debug.assert(state.getConst(castle_move.rook.from).?.type == .rook);
                        std.debug.assert(state.getConst(castle_move.rook.from).?.side == turn);

                        var move_iter: Move.Iterator = .init(castle_move.rook);
                        while (move_iter.next()) |move_pos| {
                            if (state.getConst(move_pos) != null) {
                                break;
                            }
                        } else {
                            list.appendAssumeCapacity(.{
                                .from = pos,
                                .to = castle_squares.get(turn).get(castle_side).king_destination,
                            });
                        }
                    }
                },
                .pawn => {
                    // move forward.
                    var move: Move.Iterator = .init(.{ .from = pos, .to = pos.forwardClamped(if (pos.row == pawns_start_row.get(turn)) 2 else 1, turn) });
                    while (move.next()) |moved_pos| {
                        if (state.getConst(moved_pos) != null) break;

                        list.appendAssumeCapacity(.{
                            .from = pos,
                            .to = moved_pos,
                        });
                    }

                    const next_raw = pos.forward(1, turn);
                    for ([2]error{Overflow}!u3{
                        std.math.add(u3, next_raw.file, 1),
                        std.math.sub(u3, next_raw.file, 1),
                    }) |file| {
                        const eat_target: Position = .{
                            .file = file catch continue,
                            .row = next_raw.row,
                        };
                        if (state.getConst(eat_target)) |target_piece| {
                            if (target_piece.side != turn) {
                                list.appendAssumeCapacity(.{ .from = pos, .to = eat_target });
                                // prevent possition from been added twice.
                                continue;
                            }
                        }
                        if (state.en_passant) |en_passant| {
                            if (std.meta.eql(en_passant, eat_target)) {
                                list.appendAssumeCapacity(.{ .from = pos, .to = eat_target });
                            }
                        }
                    }

                    continue;
                },
                .knight => {
                    for ([_][2]error{Overflow}!u3{
                        .{ std.math.add(u3, pos.file, 1), std.math.add(u3, pos.row, 2) },
                        .{ std.math.add(u3, pos.file, 1), std.math.sub(u3, pos.row, 2) },
                        .{ std.math.add(u3, pos.file, 2), std.math.add(u3, pos.row, 1) },
                        .{ std.math.add(u3, pos.file, 2), std.math.sub(u3, pos.row, 1) },
                        .{ std.math.sub(u3, pos.file, 1), std.math.add(u3, pos.row, 2) },
                        .{ std.math.sub(u3, pos.file, 1), std.math.sub(u3, pos.row, 2) },
                        .{ std.math.sub(u3, pos.file, 2), std.math.add(u3, pos.row, 1) },
                        .{ std.math.sub(u3, pos.file, 2), std.math.sub(u3, pos.row, 1) },
                    }) |dest| {
                        const moved_pos: Position = .{ .file = dest[0] catch continue, .row = dest[1] catch continue };
                        if (state.getConst(moved_pos)) |target_piece| {
                            if (target_piece.side == turn) {
                                continue;
                            }
                        }
                        list.appendAssumeCapacity(.{
                            .from = pos,
                            .to = moved_pos,
                        });
                    }
                    continue;
                },
            }
            for (positions.items) |far| {
                var move: Move.Iterator = .init(.{ .from = pos, .to = far });
                while (move.next()) |moved_pos| {
                    if (state.getConst(moved_pos)) |target_piece| {
                        if (target_piece.side == turn) {
                            break;
                        }
                    }

                    list.appendAssumeCapacity(.{
                        .from = pos,
                        .to = moved_pos,
                    });
                }
            }
        }
    }
    return list.items;
}

pub fn applyMove(state: *const GameState, move: MovePromotion) GameState {
    const turn = state.turn;
    const from = state.getConst(move.from) orelse unreachable;
    const to = state.getConst(move.to);

    std.debug.assert(from.side == state.turn);
    if (to) |t| {
        std.debug.assert(t.side != from.side);
    }

    const half_moves =
        if (to != null or from.type == .pawn)
            0
        else
            state.half_moves + 1;

    const full_moves =
        if (state.turn == .black)
            state.full_moves + 1
        else
            state.full_moves;

    const new_en_passant: ?Position = en: {
        if (from.type == .pawn) {
            if (pawns_start_row.get(turn) == move.from.row) {
                break :en move.from.forward(1, turn);
            }
        }
        break :en null;
    };

    const new_can_castle: @FieldType(GameState, "can_castle") = if (std.meta.eql(
        state.can_castle,
        @FieldType(GameState, "can_castle").initFill(.initEmpty()),
    ))
        .initFill(.initEmpty())
    else if (from.type == .king)
        .initFill(.initEmpty())
    else if (from.type == .rook) can: {
        var can_castle_copy = state.can_castle;
        var iter = can_castle_copy.get(turn).iterator();
        while (iter.next()) |castle_side| {
            if (std.meta.eql(castle_squares.get(turn).get(castle_side).rook.from, move.from)) {
                can_castle_copy.getPtr(turn).remove(castle_side);
            }
        }
        break :can can_castle_copy;
    } else state.can_castle;

    var copy: GameState = .{
        .turn = state.turn.next(),
        .full_moves = full_moves,
        .cells = state.cells,
        .half_moves = half_moves,
        .can_castle = new_can_castle,
        .en_passant = new_en_passant,
    };

    copy.get(move.to).* = if (from.type == .pawn and pawns_promotion_raw.get(turn) == move.to.row)
        .{
            .side = from.side,
            .type = move.promotion.?,
        }
    else blk: {
        std.debug.assert(move.promotion == null);
        break :blk from;
    };
    copy.get(move.from).* = null;

    if (from.type == .king) {
        var iter = state.can_castle.get(turn).iterator();
        while (iter.next()) |castle_side| {
            const castle_info = castle_squares.get(turn).get(castle_side);
            if (!std.meta.eql(castle_info.king_destination, move.to)) continue;

            std.debug.assert(copy.getConst(castle_info.rook.from).?.type == .rook);
            copy.get(castle_info.rook.from).* = null;
            copy.get(castle_info.rook.to).* = .{
                .side = turn,
                .type = .rook,
            };
        }
    }
    if (state.en_passant) |old_en_passant| {
        if (std.meta.eql(move.to, old_en_passant) and from.type == .pawn) {
            const en_passant_target = copy.get(old_en_passant.backward(1, state.turn));
            std.debug.assert(en_passant_target.*.?.type == .pawn);
            en_passant_target.* = null;
        }
    }

    return copy;
}

pub fn validMoves(state: *const GameState, buffer: *[GameState.max_moves_from_position]Move) []Move {
    var raw_moves: std.ArrayList(Move) = .fromOwnedSlice(state.movesRaw(buffer));
    var index: usize = 0;
    moves: while (index < raw_moves.items.len) {
        const move = raw_moves.items[index];
        // We don't really care which figure we promote to since it has no affect on if king would be targeted.
        // So we choose knight because its cool like that.
        const promote_move: MovePromotion = .{
            .from = move.from,
            .promotion = if (state.getConst(move.from).?.type == .pawn and pawns_promotion_raw.get(state.turn) == move.to.row) .knight else null,
            .to = move.to,
        };
        const next_state = state.applyMove(promote_move);

        var raw_moves_buffer: [max_moves_from_position]Move = undefined;
        for (next_state.movesRaw(&raw_moves_buffer)) |next_moves| {
            if (next_state.getConst(next_moves.to)) |target| {
                if (target.type == .king) {
                    _ = raw_moves.swapRemove(index);
                    continue :moves;
                }
            }
        }

        index += 1;
    }
    return raw_moves.items;
}

const Result = enum {
    playing,
    /// No moves on player's turn and king is in check.
    checkmate,
    /// No moves on player's turn but king is not in check.
    stalemate,
    /// 50 full moves without any captures or pawn movments.
    fifty_move_rule,
    /// Same state releated 3 times.
    /// TODO: actually implement.
    three_fold_repetition,
};

pub fn result(state: *const GameState) Result {
    if (state.half_moves >= 100) {
        return .fifty_move_rule;
    }
    var buffer: [max_moves_from_position]Move = undefined;
    if (state.validMoves(&buffer).len > 0) {
        return .playing;
    }
    var copy = state.*;
    copy.turn = copy.turn.next();

    for (copy.movesRaw(&buffer)) |move| {
        if (copy.getConst(move.to)) |target| {
            if (target.type == .king) {
                return .checkmate;
            }
        }
    }

    return .stalemate;
}

test "Checkmate detection correctness" {
    var game = try GameState.parse("7k/6Q1/5K2/8/8/8/8/8 b - - 0 1");

    const res = game.result();
    try std.testing.expectEqual(res, .checkmate);

    game = try GameState.parse("8/8/8/8/8/6rk/8/7K w - - 0 1");

    const res2 = game.result();
    try std.testing.expectEqual(res2, .stalemate);

    game = try GameState.parse("8/8/8/8/8/6kr/8/7K w - - 0 1");

    const res3 = game.result();
    try std.testing.expectEqual(res3, .playing);
}

test "Moves that leave king in check are invalid" {
    var buffer: [GameState.max_moves_from_position]Move = undefined;

    // Any move of the knight will expose the king so it should be in valid moves.
    var game = try GameState.parse("4r3/8/8/8/8/8/4N3/4K3 w - - 0 1");

    const moves = game.validMoves(&buffer);
    for (moves) |v| {
        try std.testing.expectEqual(Piece.Type.king, game.getConst(v.from).?.type);
    }
}

test "Castle availability is remove after king or rock move" {
    const starting: GameState = try .parse("8/8/8/8/8/8/8/R3K2R w KQ - 0 1");
    const king_moved = starting.applyMove(try .parse("e1c1"));

    try std.testing.expectEqual(false, king_moved.can_castle.get(.white).contains(.king));
    try std.testing.expectEqual(false, king_moved.can_castle.get(.white).contains(.queen));

    var rook_moved = starting.applyMove(try .parse("a1a7"));

    try std.testing.expectEqual(true, rook_moved.can_castle.get(.white).contains(.king));
    try std.testing.expectEqual(false, rook_moved.can_castle.get(.white).contains(.queen));

    rook_moved.turn = .white;
    const over_rook_moved = rook_moved.applyMove(try .parse("h1h7"));

    try std.testing.expectEqual(false, over_rook_moved.can_castle.get(.white).contains(.king));
    try std.testing.expectEqual(false, over_rook_moved.can_castle.get(.white).contains(.queen));
    // try std.testing.expect(containsMove(game.movesRaw(&buffer), try Move.parse("e1g1")));
}

test "Castling moves king and rook correctly" {
    // Starting position with both rooks and king
    var game = try GameState.parse("8/8/8/8/8/8/8/R3K2R w KQ - 0 1");

    // Apply kingside castling (white e1 → g1)
    var after_castle = game.applyMove(try .parse("e1g1"));

    // Check king position
    const king = after_castle.getConst(.fromString("g1".*));
    try std.testing.expect(king.? == Piece{ .side = .white, .type = .king });

    // Check rook position
    const rook = after_castle.getConst(.fromString("f1".*));
    try std.testing.expect(rook.? == Piece{ .side = .white, .type = .rook });

    // Check old positions are empty
    try std.testing.expect(after_castle.getConst(.fromString("e1".*)) == null);
    try std.testing.expect(after_castle.getConst(.fromString("h1".*)) == null);

    // Now queenside castling
    game = try GameState.parse("8/8/8/8/8/8/8/R3K2R w KQ - 0 1");
    after_castle = game.applyMove(try .parse("e1c1"));

    // King should be on c1
    const king_q = after_castle.getConst(.fromString("c1".*));
    try std.testing.expect(king_q.? == Piece{ .side = .white, .type = .king });

    // Rook should be on d1
    const rook_q = after_castle.getConst(.fromString("d1".*));
    try std.testing.expect(rook_q.? == Piece{ .side = .white, .type = .rook });

    // Old positions should be empty
    try std.testing.expect(after_castle.getConst(.fromString("a1".*)) == null);
    try std.testing.expect(after_castle.getConst(.fromString("e1".*)) == null);
}

test "Halfmove and fullmove counters update correctly" {
    // 1. Start a fresh game
    var game: GameState = .init;
    try std.testing.expectEqual(0, game.half_moves);
    try std.testing.expectEqual(1, game.full_moves); // starting at move 1

    // 2. White pawn moves (reset halfmove)
    game = game.applyMove(try .parse("e2e4"));
    try std.testing.expectEqual(0, game.half_moves); // pawn move resets
    try std.testing.expectEqual(1, game.full_moves); // still white->black, fullmove unchanged

    // 3. Black pawn moves (reset halfmove)
    game = game.applyMove(try .parse("e7e5"));
    try std.testing.expectEqual(0, game.half_moves); // pawn move resets
    try std.testing.expectEqual(2, game.full_moves); // fullmove increments after black

    // 4. White knight moves (halfmove increment)
    game = game.applyMove(try .parse("g1f3"));
    try std.testing.expectEqual(1, game.half_moves); // no pawn move or capture → +1
    try std.testing.expectEqual(2, game.full_moves); // still same fullmove

    // 5. Black knight moves (halfmove increment + fullmove increment)
    game = game.applyMove(try .parse("b8c6"));
    try std.testing.expectEqual(2, game.half_moves); // still no pawn move or capture → +1
    try std.testing.expectEqual(3, game.full_moves); // increment after black

    // White captures black pawn
    game = game.applyMove(try .parse("f3e5"));
    try std.testing.expectEqual(0, game.half_moves); // reset after capture
    try std.testing.expectEqual(3, game.full_moves); // reset after capture

}

test {
    const state: GameState = .init;
    const new = state.applyMove(try .parse("e2e4"));
    try std.testing.expectEqual(Piece{ .side = .white, .type = .pawn }, new.getConst(.fromString("e4".*)).?);
}

test "Number of moves in starting position is 20" {
    var game: GameState = .init;
    var buffer: [GameState.max_moves_from_position]Move = undefined;
    try std.testing.expectEqual(20, game.movesRaw(&buffer).len);

    // Game is symmetrical doesn't matter which side goes first.
    game.turn = .black;
    try std.testing.expectEqual(20, game.movesRaw(&buffer).len);
}

test "King in center has 8 moves" {
    var game = try GameState.parse("8/8/8/3K4/8/8/8/8 w - - 0 1");
    var buffer: [GameState.max_moves_from_position]Move = undefined;
    try std.testing.expectEqual(8, game.movesRaw(&buffer).len);

    game.turn = .black;
    try std.testing.expectEqual(0, game.movesRaw(&buffer).len);
}

test "King in corner has 3 moves" {
    var game = try GameState.parse("8/8/8/8/8/8/8/K7 w - - 0 1");
    var buffer: [GameState.max_moves_from_position]Move = undefined;
    try std.testing.expectEqual(3, game.movesRaw(&buffer).len);
}

pub fn containsMove(moves: []const Move, move: Move) bool {
    for (moves) |move_in_list| {
        if (std.meta.eql(move_in_list, move))
            return true;
    }
    return false;
}

test "King castling" {
    var game = try GameState.parse("8/8/8/8/8/8/8/R3K2R w KQ - 0 1");
    var buffer: [GameState.max_moves_from_position]Move = undefined;

    try std.testing.expect(containsMove(game.movesRaw(&buffer), try Move.parse("e1c1")));
    try std.testing.expect(containsMove(game.movesRaw(&buffer), try Move.parse("e1g1")));
}

test "Castling is not avalible" {
    var game = try GameState.parse("8/8/8/8/8/8/8/R3K2R w - - 0 1");
    var buffer: [GameState.max_moves_from_position]Move = undefined;
    try std.testing.expect(!containsMove(game.movesRaw(&buffer), try Move.parse("e1c1")));
    try std.testing.expect(!containsMove(game.movesRaw(&buffer), try Move.parse("e1g1")));
}

test "Castling is abstructed by other pieces" {
    var game = try GameState.parse("8/8/8/8/8/8/8/RB2K2R w KQ - 0 1");
    var buffer: [GameState.max_moves_from_position]Move = undefined;
    try std.testing.expect(!containsMove(game.movesRaw(&buffer), try Move.parse("e1c1")));
    try std.testing.expect(containsMove(game.movesRaw(&buffer), try Move.parse("e1g1")));
}

test "Knight in center has 8 moves" {
    var game = try GameState.parse("8/8/8/3N4/8/8/8/8 w - - 0 1");
    var buffer: [GameState.max_moves_from_position]Move = undefined;
    try std.testing.expectEqual(8, game.movesRaw(&buffer).len);
}

test "Knight in corner has 2 moves" {
    var game = try GameState.parse("8/8/8/8/8/8/8/N7 w - - 0 1");
    var buffer: [GameState.max_moves_from_position]Move = undefined;
    try std.testing.expectEqual(2, game.movesRaw(&buffer).len);
}

test "Knight on edge has 4 moves" {
    var game = try GameState.parse("8/8/8/8/N7/8/8/8 w - - 0 1");
    var buffer: [GameState.max_moves_from_position]Move = undefined;
    try std.testing.expectEqual(4, game.movesRaw(&buffer).len);
}

test "Rook has 14 moves from any position on empty board" {
    var buffer: [GameState.max_moves_from_position]Move = undefined;

    for (0..8) |row| {
        for (0..8) |file| {
            var game: GameState = .empty;
            game.get(.{ .file = @intCast(file), .row = @intCast(row) }).* = .{ .type = .rook, .side = .white };
            try std.testing.expectEqual(14, game.movesRaw(&buffer).len);
        }
    }
}

test "Bishop move count is always between 7 and 13" {
    var buffer: [GameState.max_moves_from_position]Move = undefined;

    for (0..8) |urow| {
        for (0..8) |ufile| {
            const file: u3 = @intCast(ufile);
            const row: u3 = @intCast(urow);

            var game: GameState = .empty;
            game.get(.{ .file = file, .row = row }).* = .{ .type = .bishop, .side = .white };

            const count = game.movesRaw(&buffer).len;

            const two_distances_from_center = @min(
                7 - @abs(7 - @as(i5, row) * 2),
                7 - @abs(7 - @as(i5, file) * 2),
            );
            try std.testing.expectEqual(7 + two_distances_from_center, count);
        }
    }
}

test "If no pieces 0 moves" {
    var game: GameState = .empty;
    var buffer: [GameState.max_moves_from_position]Move = undefined;

    // Game is symmetrical doesn't matter which side goes first.
    try std.testing.expectEqual(0, game.movesRaw(&buffer).len);
    game.turn = .black;
    try std.testing.expectEqual(0, game.movesRaw(&buffer).len);
}

test "Pawn on starting rank has 2 moves" {
    var game = try GameState.parse("8/8/8/8/8/8/3P4/8 w - - 0 1");
    var buffer: [GameState.max_moves_from_position]Move = undefined;

    try std.testing.expectEqual(2, game.movesRaw(&buffer).len);
}

test "Pawn on non starting rank has 1 moves" {
    var game = try GameState.parse("8/8/8/8/8/3P4/8/8 w - - 0 1");
    var buffer: [GameState.max_moves_from_position]Move = undefined;

    try std.testing.expectEqual(1, game.movesRaw(&buffer).len);
}

test "Pawn blocked in front has no moves" {
    var game = try GameState.parse("8/8/8/8/3p4/3P4/8/8 w - - 0 1");
    var buffer: [GameState.max_moves_from_position]Move = undefined;

    try std.testing.expectEqual(0, game.movesRaw(&buffer).len);
}

test "Pawn blocked two moves ahead" {
    var game = try GameState.parse("8/8/8/8/3p4/8/3P4/8 w - - 0 1");
    var buffer: [GameState.max_moves_from_position]Move = undefined;

    try std.testing.expectEqual(1, game.movesRaw(&buffer).len);
}

test "Pawn eats to the side" {
    var buffer: [GameState.max_moves_from_position]Move = undefined;

    // eatable piece to the left and path forward or double forward.
    var white = try GameState.parse("8/8/8/8/8/2p5/3P4/8 w - - 0 1");
    try std.testing.expectEqual(3, white.movesRaw(&buffer).len);

    // eatable piece to the left and right and double pass.
    white = try GameState.parse("8/8/8/8/8/2p1p3/3P4/8 w - - 0 1");
    try std.testing.expectEqual(4, white.movesRaw(&buffer).len);

    // eatable piece to the left and right and no pass forward.
    white = try GameState.parse("8/8/8/8/8/2ppp3/3P4/8 w - - 0 1");
    try std.testing.expectEqual(2, white.movesRaw(&buffer).len);
}

test "Pawn en passant" {
    var buffer: [GameState.max_moves_from_position]Move = undefined;

    // white peace en passants piece to the left.
    var white = try GameState.parse("8/8/8/3pP3/8/8/8/8 w - d6 0 1");
    try std.testing.expectEqual(2, white.movesRaw(&buffer).len);

    // white peace en passants piece to the left but piece is block by black pi
    white = try GameState.parse("8/8/8/3pP3/8/8/8/8 w - d6 0 1");
    try std.testing.expectEqual(2, white.movesRaw(&buffer).len);
}

test "Pawn promotion" {
    var buffer: [GameState.max_moves_from_position]Move = undefined;
    const game = try GameState.parse("8/7P/8/8/8/8/8/8 w - - 0 1"); // white pawn on h7
    const raw_moves = game.movesRaw(&buffer);
    // Promotion is not counted as separate move.
    try std.testing.expect(raw_moves.len == 1);

    inline for (pawn_promotions) |piece| {
        const piece_str = &[_]u8{Piece.toChar(.{ .type = piece, .side = .white })};

        const promoted = game.applyMove(try .parse("h7h8" ++ piece_str));

        const expected = try GameState.parse("7" ++ piece_str ++ "/8/8/8/8/8/8/8 b - - 0 1");
        try std.testing.expectEqual(expected, promoted);
    }
}
