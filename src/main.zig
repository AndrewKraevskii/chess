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
                atlas.drawPro(
                    .{
                        .x = pieceIndexInAtlas(piece_with_side.piece) * 16,
                        .y = 0,
                        .width = 16,
                        .height = 16,
                    },
                    rectFromPositionAndSize(
                        top_left_pos.addValue(padding),
                        .init(cell_size - padding, cell_size - padding),
                    ),
                    .init(0, 0),
                    0,
                    if (piece_with_side.side == .white) .white else .yellow,
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
    var timer = try std.time.Timer.start();
    while (!rl.windowShouldClose()) {
        {
            rl.beginDrawing();
            defer rl.endDrawing();
            rl.clearBackground(.black);

            const padding = 10;
            const side_length = @min(rlx.getScreenHeightf(), rlx.getScreenWidthf());
            drawChessBoard(board, rlx.getScreenCenter(), side_length, padding, chess_figures);
        }
        if (timer.read() > std.time.ns_per_s * 1) {
            timer.reset();
            try uci.setPosition(board);
            try uci.go(5);
            const move = uci.getMove() catch |e| {
                if (e == error.EndOfGame) {
                    std.log.info("End of game {s} won", .{@tagName(board.turn.next())});
                    break;
                }
                continue;
            };
            board.applyMove(move);
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
