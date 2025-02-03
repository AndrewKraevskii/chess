const std = @import("std");
const rl = @import("raylib");
const gui = @import("raygui");
const ChessBoard = @import("ChessBoard.zig");
const rlx = @import("raylibx.zig");
const Uci = @import("Uci.zig");

fn pieceIndexInAtlas(piece: ChessBoard.Piece) f32 {
    return switch (piece) {
        .pawn => 0,
        .rook => 1,
        .knight => 2,
        .bishop => 3,
        .queen => 4,
        .king => 5,
    };
}

fn rectFromPositionAndSize(pos: rl.Vector2, size: rl.Vector2) rl.Rectangle {
    return .{
        .x = pos.x,
        .y = pos.y,
        .width = size.x,
        .height = size.y,
    };
}

fn drawPiece(@"type": ChessBoard.PieceWithSide, dest: rl.Rectangle, style: ChessBoardDisplayStyle) void {
    style.atlas.drawPro(
        .{
            .x = pieceIndexInAtlas(@"type".piece) * 16,
            .y = 0,
            .width = 16,
            .height = 16,
        },
        dest,
        .init(0, 0),
        0,
        if (@"type".side == .white) .white else .yellow,
    );
}

const ChessBoardDisplayStyle = struct {
    padding: f32,
    atlas: rl.Texture,
    white_square_color: rl.Color,
    black_square_color: rl.Color,
    border_color: rl.Color,
};

fn drawChessBoard(board: ChessBoard, dest: rl.Rectangle, style: ChessBoardDisplayStyle) void {
    const cell_size = dest.width / 8;
    var y: f32 = dest.y;
    var parity: u1 = 1;
    rl.drawRectangleRec(dest, style.border_color);
    for (board.cells) |row| {
        defer y += cell_size;
        defer parity +%= 1;
        var x: f32 = dest.x;
        for (row) |cell| {
            defer x += cell_size;
            defer parity +%= 1;
            const top_left_pos: rl.Vector2 = .init(x, y);

            rl.drawRectangleV(
                top_left_pos.addValue(style.padding / 2),
                .init(cell_size - style.padding, cell_size - style.padding),
                if (parity == 0) style.black_square_color else style.white_square_color,
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

const Animation = struct {
    piece: ChessBoard.PieceWithSide,
    move: ChessBoard.Move,
    // range [0;1]
    progress: f32,

    pub fn position(anim: @This()) rl.Vector2 {
        // const t = anim.progress;
        const x = anim.progress;
        const t = @import("easing.zig").easeInOutCubic(x);

        const from_row_f: f32 = @floatFromInt(anim.move.from.row);
        const from_file_f: f32 = @floatFromInt(anim.move.from.file);
        const to_row_f: f32 = @floatFromInt(anim.move.to.row);
        const to_file_f: f32 = @floatFromInt(anim.move.to.file);

        const result_row = std.math.lerp(from_row_f, to_row_f, t);
        const result_file = std.math.lerp(from_file_f, to_file_f, t);
        return .{
            .y = (7 - result_row) / 8,
            .x = (result_file) / 8,
        };
    }
};

pub fn doChess(_: std.mem.Allocator, uci: *Uci) !void {
    rl.setConfigFlags(.{
        .window_resizable = true,
    });
    rl.setTraceLogLevel(.log_none);

    rl.initWindow(1000, 1000, "Chess");
    defer rl.closeWindow();

    const chess_figures = rl.loadTexture("assets/chess_figures.png");
    defer chess_figures.unload();

    const style: ChessBoardDisplayStyle = .{
        .padding = 4,
        .white_square_color = .white,
        .black_square_color = .black,
        .atlas = chess_figures,
        .border_color = .blue,
    };
    var board: ChessBoard = .init;
    var move: ?*Uci.MovePromise = null;
    var animation_speed: f32 = 0.1;
    var animation: ?Animation = null;

    var paused: bool = false;

    while (!rl.windowShouldClose()) {
        if (rl.isKeyPressed(.key_space)) {
            paused = !paused;
        }

        if (!paused) {
            if (animation) |*anim| { // update
                if (anim.progress >= 1) {
                    board.applyMove(anim.move);
                    animation = null;
                } else {
                    anim.progress += rl.getFrameTime() * animation_speed;
                }
            } else if (move) |state| {
                if (state.get()) |result| {
                    if (result) |m| {
                        animation = Animation{
                            .piece = board.get(m.from).*.?,
                            .move = m,
                            .progress = 0,
                        };
                        move = null;
                    }
                } else |_| {
                    std.log.info("End of game {s} won", .{@tagName(board.turn.next())});
                    break;
                }
            } else {
                try uci.setPosition(board);
                try uci.go(.{ .depth = 4 });
                move = try uci.getMoveAsync();
            }
        }
        { // draw
            rl.beginDrawing();
            defer rl.endDrawing();
            rl.clearBackground(.black);

            const side_length = @min(rlx.getScreenHeightf(), rlx.getScreenWidthf());
            const cell_size = side_length / 8;
            const center = rlx.getScreenCenter();
            if (animation) |anim| {
                var board_to_draw = board;
                board_to_draw.get(anim.move.from).* = null;
                drawChessBoard(
                    board_to_draw,
                    rlx.screenSquare(),
                    style,
                );
                drawPiece(
                    anim.piece,
                    rectFromPositionAndSize(
                        anim.position().scale(side_length).addValue(style.padding / 2).add(center).subtractValue(side_length / 2),
                        .init(cell_size - style.padding, cell_size - style.padding),
                    ),
                    style,
                );
            } else {
                drawChessBoard(board, rlx.screenSquare(), style);
            }
            // gui
            {
                _ = gui.guiSlider(.{
                    .x = 0,
                    .y = 0,
                    .width = 100,
                    .height = 10,
                }, "Speed", "", &animation_speed, 0.01, 10);
            }
        }
    }
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer _ = arena.deinit();
    const alloc = arena.allocator();

    const self_path = try std.fs.selfExeDirPathAlloc(alloc);
    const engine_path = try std.fs.path.join(alloc, &.{ self_path, "stockfish" });

    std.log.debug("{s}", .{engine_path});
    var uci = try Uci.connect(alloc, engine_path);
    defer uci.close() catch |e| {
        std.log.err("can't deinit engine: {s}", .{@errorName(e)});
    };
    try doChess(
        alloc,
        &uci,
    );
}

test {
    _ = @import("Uci.zig");
}
