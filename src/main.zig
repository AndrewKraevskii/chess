const std = @import("std");
const rl = @import("raylib");
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

fn drawPiece(@"type": ChessBoard.PieceWithSide, pos: rl.Vector2, size: rl.Vector2, atlas: rl.Texture) void {
    atlas.drawPro(
        .{
            .x = pieceIndexInAtlas(@"type".piece) * 16,
            .y = 0,
            .width = 16,
            .height = 16,
        },
        rectFromPositionAndSize(
            pos,
            size,
        ),
        .init(0, 0),
        0,
        if (@"type".side == .white) .white else .yellow,
    );
}

fn drawChessBoard(board: ChessBoard, center: rl.Vector2, size: f32, padding: f32, atlas: rl.Texture) void {
    const cell_size = size / 8;
    var y: f32 = center.y - size / 2;
    var parity: u1 = 0;
    for (board.cells) |row| {
        defer y += cell_size;
        defer parity +%= 1;
        var x: f32 = center.x - size / 2;
        for (row) |cell| {
            defer x += cell_size;
            defer parity +%= 1;
            const top_left_pos: rl.Vector2 = .init(x, y);

            if (cell) |piece_with_side| {
                drawPiece(
                    piece_with_side,
                    top_left_pos.addValue(padding),
                    .init(cell_size - padding, cell_size - padding),
                    atlas,
                );
            } else {
                rl.drawRectangleV(
                    top_left_pos.addValue(padding),
                    .init(cell_size - padding, cell_size - padding),
                    if (parity == 0) .black else .white,
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
        const t = if (x < 0.5) 4 * x * x * x else 1 - std.math.pow(f32, -2 * x + 2, 3) / 2;

        const from_row_f: f32 = @floatFromInt(anim.move.from.row);
        const from_file_f: f32 = @floatFromInt(anim.move.from.file);
        const to_row_f: f32 = @floatFromInt(anim.move.to.row);
        const to_file_f: f32 = @floatFromInt(anim.move.to.file);

        const result_row = std.math.lerp(from_row_f, to_row_f, t);
        const result_file = std.math.lerp(from_file_f, to_file_f, t);
        return .{
            .y = 7 - result_row,
            .x = result_file,
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

    var board: ChessBoard = .init;
    var move: ?*Uci.Promise(ChessBoard.Move) = null;
    var animation: ?Animation = null;
    while (!rl.windowShouldClose()) {
        if (animation) |*anim| {
            if (anim.progress >= 1) {
                board.applyMove(anim.move);
                animation = null;
            } else {
                anim.progress += rl.getFrameTime();
            }
        } else if (move) |state| {
            if (state.get()) |result| {
                animation = Animation{
                    .piece = board.get(result.from).*.?,
                    .move = result,
                    .progress = 0,
                };
                move = null;
            }
        } else {
            try uci.setPosition(board);
            try uci.go(9);
            move = uci.getMoveAsync() catch |e| {
                if (e == error.EndOfGame) {
                    std.log.info("End of game {s} won", .{@tagName(board.turn.next())});
                    break;
                }
                continue;
            };
        }
        {
            rl.beginDrawing();
            defer rl.endDrawing();
            rl.clearBackground(.black);

            const padding = 10;
            const side_length = @min(rlx.getScreenHeightf(), rlx.getScreenWidthf());
            const cell_size = side_length / 8;
            const center = rlx.getScreenCenter();
            if (animation) |anim| {
                var board_to_draw = board;
                board_to_draw.get(anim.move.from).* = null;
                drawChessBoard(board_to_draw, center, side_length, padding, chess_figures);
                drawPiece(
                    anim.piece,
                    anim.position().scale(cell_size).addValue(padding),
                    .init(cell_size - padding, cell_size - padding),
                    chess_figures,
                );
            } else {
                drawChessBoard(board, center, side_length, padding, chess_figures);
            }
            rl.drawFPS(0, 0);
        }
    }
}

/// I need it since sometimes program freezes my desktop manager and I can't kill it.
const WatchDog = struct {
    pub fn watch() void {
        std.time.sleep(std.time.ns_per_s * 10);
        std.log.info("watchdog closes application due to timeout", .{});
        std.process.exit(0);
    }
};

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer _ = arena.deinit();
    const alloc = arena.allocator();

    // const thread = try std.Thread.spawn(.{}, WatchDog.watch, .{});
    // thread.detach();

    var uci = try Uci.connect(alloc);
    defer uci.deinit() catch |e| {
        std.log.err("can't deinit engine: {s}", .{@errorName(e)});
    };
    try doChess(
        alloc,
        &uci,
    );
}
