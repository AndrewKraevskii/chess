//! Represents history of position changes.
//! Uses that to
//! - check for freefold repetition
//! - undo/redo tree

const std = @import("std");

pub const Board = @import("Chess/Board.zig");
const Chess = @This();

pub const Position = struct {
    board: Board,
    /// Move from which this board happened
    move: ?Board.MovePromotion,
    previous: Id.Optional,

    pub const init: Position = .{
        .previous = .none,
        .board = .init,
        .move = null,
    };

    pub const Id = enum(u32) {
        _,

        pub const Optional = enum(u32) {
            none = std.math.maxInt(u32),

            _,

            pub fn unwrap(o: Optional) ?Id {
                return if (o == .none)
                    null
                else
                    @enumFromInt(@intFromEnum(o));
            }
        };

        pub fn toOptional(i: Id) Optional {
            const result: Optional = @enumFromInt(@intFromEnum(i));
            std.debug.assert(result != .none);
            return result;
        }
    };
};

positions: std.AutoArrayHashMapUnmanaged(Position, void),
current_position: Position.Id.Optional,

pub const init: Chess = .{
    .positions = .empty,
    .current_position = .none,
};

pub fn setPosition(chess: *Chess, gpa: std.mem.Allocator, board: Board) error{OutOfMemory}!void {
    const position: Position = .{
        .move = null,
        .board = board,
        .previous = .none,
    };
    const gop = try chess.positions.getOrPut(gpa, position);
    chess.current_position = @enumFromInt(gop.index);
    if (gop.found_existing) {
        return;
    }
    gop.key_ptr.* = position;
}

pub fn deinit(chess: *Chess, gpa: std.mem.Allocator) void {
    chess.positions.deinit(gpa);
}

pub fn activeBoard(chess: Chess) ?Board {
    const id = chess.current_position.unwrap() orelse return null;
    const board = &chess.positions.keys()[@intFromEnum(id)];

    return board.board;
}

pub fn activePosition(chess: Chess) ?Chess.Position {
    const id = chess.current_position.unwrap() orelse return null;
    const board = &chess.positions.keys()[@intFromEnum(id)];

    return board.*;
}

pub fn undo(chess: *Chess) void {
    const id = chess.current_position.unwrap() orelse return;
    chess.current_position = (chess.positions.keys()[@intFromEnum(id)].previous.unwrap() orelse return).toOptional();
}

pub fn redo(chess: *Chess) void {
    const id = chess.current_position.unwrap() orelse return;
    for (chess.positions.keys()[@intFromEnum(id)..], @intFromEnum(id)..) |pos, index| {
        if (pos.previous.unwrap()) |prev| {
            if (prev == id) {
                chess.current_position = @enumFromInt(index);
            }
        }
    }
}

pub fn setNext(chess: *Chess, gpa: std.mem.Allocator, move: Board.MovePromotion) error{OutOfMemory}!void {
    const new_state = chess.activeBoard().?.applyMove(move);
    const position: Position = .{
        .board = new_state,
        .previous = chess.current_position,
        .move = move,
    };
    const gop = try chess.positions.getOrPut(gpa, position);
    chess.current_position = @enumFromInt(gop.index);
    if (gop.found_existing) {
        return;
    }
    gop.key_ptr.* = position;
}

test Chess {
    var chess: Chess = .init;
    defer chess.deinit(std.testing.allocator);

    const gpa = std.testing.allocator;

    var random_state: std.Random.DefaultPrng = .init(0);
    const random = random_state.random();

    for (0..100) |_| {
        try chess.setPosition(
            gpa,
            .init,
        );
        while (true) {
            const board = chess.activeBoard() orelse break;
            switch (board.result()) {
                .playing => {},
                else => break,
            }
            var buffer: [Board.max_moves_from_position]Board.Move = undefined;
            const moves = board.validMoves(&buffer);
            if (moves.len == 0) break;
            const move = moves[random.intRangeLessThan(usize, 0, moves.len)];
            const promotion: ?Board.Piece.Type = if (board.isPromotion(move)) .queen else null;
            try chess.setNext(gpa, board.applyMove(.{ .from = move.from, .to = move.to, .promotion = promotion }));
        }
    }
}
