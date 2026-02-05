const std = @import("std");

const rl = @import("raylib");
const rlx = @import("raylibx.zig");
const log = std.log.scoped(.renderer);

const GameState = @import("GameState.zig");

fn pieceIndexInAtlas(piece: GameState.Piece.Type) f32 {
    return switch (piece) {
        .pawn => 0,
        .rook => 1,
        .knight => 2,
        .bishop => 3,
        .queen => 4,
        .king => 5,
    };
}

pub fn rectFromPositionAndSize(pos: rl.Vector2, size: rl.Vector2) rl.Rectangle {
    return .{
        .x = pos.x,
        .y = pos.y,
        .width = size.x,
        .height = size.y,
    };
}

pub fn drawPiece(piece: GameState.Piece, dest: rl.Rectangle, style: DisplayStyle) void {
    style.atlas.drawPro(
        .{
            .x = pieceIndexInAtlas(piece.type) * 16,
            .y = 0,
            .width = 16,
            .height = 16,
        },
        dest,
        .init(0, 0),
        0,
        if (piece.side == .white) .white else .yellow,
    );
}

pub const BoardOrientation = enum {
    // active_bottom,
    white_bottom,
    black_bottom,

    pub fn fromInts(o: BoardOrientation, x: usize, y: usize) GameState.Position {
        return o.pos(.{ .row = @intCast(y), .file = @intCast(x) });
    }

    pub fn pos(o: BoardOrientation, p: GameState.Position) GameState.Position {
        return .{
            .file = p.file,
            .row = switch (o) {
                .black_bottom => p.row,
                .white_bottom => 7 - p.row,
            },
        };
    }
};

pub const DisplayStyle = struct {
    board_orientation: BoardOrientation,
    font: rl.Font,
    padding: f32,
    atlas: rl.Texture,
    white_square_color: rl.Color,
    black_square_color: rl.Color,
    selected_square_color: rl.Color,
    hovered_square_color: rl.Color,
    border_color: rl.Color,
};

pub const Selection = struct {
    hovered_square: ?GameState.Position,
    selected_square: ?GameState.Position,

    pub const @"null": Selection = .{
        .hovered_square = null,
        .selected_square = null,
    };
};

pub fn drawGameState(board: GameState, dest: rl.Rectangle, selection: Selection, style: DisplayStyle) void {
    const cell_size = dest.width / 8;
    var y: f32 = dest.y;
    var parity: u1 = 1;
    rl.drawRectangleRec(dest, style.border_color);

    const hovered_square: ?GameState.Position = if (selection.hovered_square) |hovered_square| hovered_square else null;
    const selected_square: ?GameState.Position = if (selection.selected_square) |selected_square| selected_square else null;

    for (0..8) |row_index| {
        defer y += cell_size;
        defer parity +%= 1;
        var x: f32 = dest.x;
        for (0..8) |file| {
            const current_pos: GameState.Position = style.board_orientation.fromInts(file, row_index);
            const cell = board.getConst(current_pos);
            defer x += cell_size;
            defer parity +%= 1;
            const top_left_pos: rl.Vector2 = .init(x, y);

            const this_square_hovered = if (hovered_square) |pos| std.meta.eql(pos, current_pos) else false;
            const this_square_selected = if (selected_square) |pos| std.meta.eql(pos, current_pos) else false;

            rl.drawRectangleV(
                top_left_pos.addValue(style.padding / 2),
                .init(cell_size - style.padding, cell_size - style.padding),
                if (this_square_selected) style.selected_square_color else if (this_square_hovered) style.hovered_square_color else if (parity == 0) style.black_square_color else style.white_square_color,
            );

            if (cell) |piece_with_side| {
                drawPiece(
                    piece_with_side,
                    rectFromPositionAndSize(
                        top_left_pos.addValue(style.padding / 2),
                        .init(cell_size - style.padding, cell_size - style.padding),
                    ),
                    style,
                );
            }
        }
    }
}

pub const Animation = struct {
    piece: GameState.Piece,
    move: GameState.MovePromotion,
    // range [0;1]
    progress: f32,

    pub fn position(anim: @This(), board_orientation: BoardOrientation) rl.Vector2 {
        const x = anim.progress;
        const t = @import("easing.zig").easeInOutCubic(x);

        const from_row_f: f32 = @floatFromInt(anim.move.from.row);
        const from_file_f: f32 = @floatFromInt(anim.move.from.file);
        const to_row_f: f32 = @floatFromInt(anim.move.to.row);
        const to_file_f: f32 = @floatFromInt(anim.move.to.file);

        const result_row = std.math.lerp(from_row_f, to_row_f, t);
        const result_file = std.math.lerp(from_file_f, to_file_f, t);

        return .{
            .y = switch (board_orientation) {
                .black_bottom => result_row / 8,
                .white_bottom => (7 - result_row) / 8,
            },
            .x = result_file / 8,
        };
    }
};
pub fn drawBoardWithPieceMoving(board: GameState, anim: Animation, style: DisplayStyle) void {
    const side_length = @min(rlx.getScreenHeightf(), rlx.getScreenWidthf());
    const cell_size = side_length / 8;
    const center = rlx.getScreenCenter();
    var board_to_draw = board;

    board_to_draw.get(anim.move.from).* = null;

    drawGameState(
        board_to_draw,
        rlx.screenSquare(),
        .null,
        style,
    );
    drawPiece(
        anim.piece,
        rectFromPositionAndSize(
            anim.position(style.board_orientation).scale(side_length).addValue((style.padding - side_length) / 2).add(center),
            .init(cell_size - style.padding, cell_size - style.padding),
        ),
        style,
    );
}

pub fn drawSelections(style: DisplayStyle, selected: GameState.Position, moves: []GameState.Move) void {
    const side_length = @min(rlx.getScreenHeightf(), rlx.getScreenWidthf());
    const cell_size = side_length / 8;
    const center = rlx.getScreenCenter();

    for (moves) |move| {
        if (!std.meta.eql(move.from, selected)) continue;

        const posf: rl.Vector2 = .init(@floatFromInt(style.board_orientation.pos(move.to).file), @floatFromInt(style.board_orientation.pos(move.to).row));
        rl.drawCircleV(
            posf.scale(side_length / 8).addValue((style.padding - side_length) / 2 + cell_size / 2).add(center),
            10,
            .green,
        );
    }
}

pub fn render(
    board: GameState,
    animation: ?Animation,
    style: DisplayStyle,
    selected_square: Selection,
    moves: []GameState.Move,
) void { // draw
    rl.beginDrawing();
    defer rl.endDrawing();

    rl.clearBackground(.black);

    const side_length = @min(rlx.getScreenHeightf(), rlx.getScreenWidthf());
    const cell_size = side_length / 8;
    const center = rlx.getScreenCenter();

    if (animation) |anim| {
        drawBoardWithPieceMoving(board, anim, style);
    } else {
        drawGameState(board, rlx.screenSquare(), selected_square, style);
        if (selected_square.selected_square) |ss| {
            drawSelections(style, ss, moves);
        }
    }
    const font_size = cell_size * 0.3;
    {
        var x = center.x - cell_size * 4;
        for (0..8) |i| {
            defer x += cell_size;
            var text: [2:0]u8 = .{ @intCast(i + 'a'), 0 };
            rl.drawTextEx(style.font, &text, .init(x + style.padding, center.y + cell_size * 4 - font_size), font_size, 1, .red);
        }
    }
    {
        var y = center.y - cell_size * 4;
        for (0..8) |i| {
            defer y += cell_size;
            var text: [2:0]u8 = .{ @intCast(i + '1'), 0 };
            const size = rl.measureTextEx(style.font, &text, font_size, 1);
            rl.drawTextEx(style.font, &text, .init(center.x + cell_size * 4 - size.x * 1.5, y + style.padding), font_size, 1, .red);
        }
    }
}
