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
    selected_square_color: rl.Color,
    hovered_square_color: rl.Color,
    border_color: rl.Color,
};

const Selection = struct {
    hovered_square: ?ChessBoard.Position,
    selected_square: ?ChessBoard.Position,

    pub const @"null": Selection = .{
        .hovered_square = null,
        .selected_square = null,
    };
};

fn drawChessBoard(board: ChessBoard, dest: rl.Rectangle, selection: Selection, style: ChessBoardDisplayStyle) void {
    const cell_size = dest.width / 8;
    var y: f32 = dest.y;
    var parity: u1 = 1;
    rl.drawRectangleRec(dest, style.border_color);
    for (board.cells, 0..) |row, row_index| {
        defer y += cell_size;
        defer parity +%= 1;
        var x: f32 = dest.x;
        for (row, 0..) |cell, file| {
            defer x += cell_size;
            defer parity +%= 1;
            const top_left_pos: rl.Vector2 = .init(x, y);

            const this_square_hovered = if (selection.hovered_square) |pos| std.meta.eql(pos, .{
                .row = @intCast(7 - row_index),
                .file = @intCast(file),
            }) else false;
            const this_square_selected = if (selection.selected_square) |pos| std.meta.eql(pos, .{
                .row = @intCast(7 - row_index),
                .file = @intCast(file),
            }) else false;

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

pub fn History(comptime Item: type, comptime Size: usize) type {
    return struct {
        events: std.BoundedArray(Item, Size) = .{},
        undone: usize = 0,

        pub fn undo(history: *@This()) ?Item {
            std.debug.assert(history.undone <= history.events.len);
            if (history.undone == history.events.len) {
                return null;
            }
            history.undone += 1;

            return history.events.get(history.events.len - history.undone);
        }

        pub fn redo(history: *@This()) ?Item {
            if (history.undone == 0) return null;
            const event_to_redo = history.events.get(history.events.len - history.undone);
            history.undone -= 1;
            return event_to_redo;
        }

        pub fn addHistoryEntry(
            history: *@This(),
            entry: Item,
        ) !void {
            if (history.undone != 0) {
                history.events.resize(history.events.len - history.undone) catch unreachable;
                history.undone = 0;
            }

            try history.events.append(
                entry,
            );
        }
    };
}

pub fn doChess(uci: *Uci) !void {
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
        .selected_square_color = .yellow,
        .hovered_square_color = .lime,
        .atlas = chess_figures,
        .border_color = .blue,
    };
    var animation_speed: f32 = 1;

    // var history: std.BoundedArray(ChessBoard, 0x200) = .{};
    // var undone: usize = 0;
    var history: History(ChessBoard, 0x200) = .{};
    var board: ChessBoard = .init;

    var engine_async_move: ?*Uci.MovePromise = null;

    var animation: ?Animation = null;
    var paused: bool = false;

    var whos_turn: union(enum) {
        engine,
        player: Selection,

        fn switchTurn(whos_turn: *@This()) void {
            whos_turn.* = switch (whos_turn.*) {
                .engine => .{
                    .player = .{
                        .hovered_square = null,
                        .selected_square = null,
                    },
                },
                .player => .engine,
            };
        }
    } = .engine;

    while (!rl.windowShouldClose()) {
        if (rl.isKeyPressed(.key_space)) {
            paused = !paused;
        }

        if (!paused) {
            if (animation) |*anim| { // update
                if (anim.progress >= 1) {
                    board.applyMove(anim.move);
                    whos_turn.switchTurn();
                    animation = null;
                } else {
                    anim.progress += rl.getFrameTime() * animation_speed;
                }
            } else switch (whos_turn) {
                .engine => if (engine_async_move) |state| {
                    if (state.get()) |result| {
                        if (result) |m| {
                            animation = .{
                                .piece = board.get(m.from).*.?,
                                .move = m,
                                .progress = 0,
                            };
                            engine_async_move = null;
                        }
                    } else |_| {
                        std.log.info("End of game {s} won", .{@tagName(board.turn.next())});
                        break;
                    }
                } else {
                    try uci.setPosition(board);
                    try uci.go(.{ .depth = 1 });
                    engine_async_move = try uci.getMoveAsync();
                },
                .player => |*p| player: {
                    if (rl.isKeyPressed(.key_u)) undo: {
                        board = history.undo() orelse break :undo;
                        break :player;
                    }
                    if (rl.isKeyPressed(.key_r)) redo: {
                        board = history.redo() orelse break :redo;
                        break :player;
                    }

                    const mouse_pos = rl.getMousePosition();
                    if (!rl.checkCollisionPointRec(mouse_pos, rlx.screenSquare())) break :player;
                    const normalized = rlx.normalizeInRectangle(rlx.screenSquare(), mouse_pos);
                    const coords = normalized.scale(8);
                    const x: u3 = @intFromFloat(coords.x);
                    const y: u3 = @intFromFloat(coords.y);

                    p.hovered_square = .{
                        .file = x,
                        .row = 7 - y,
                    };

                    if (rl.isMouseButtonPressed(.mouse_button_left)) {
                        if (p.selected_square) |selected| {
                            if (!std.meta.eql(selected, p.hovered_square.?)) {
                                if (board.get(p.hovered_square.?).*) |piece| {
                                    if (piece.side == .black) {
                                        p.selected_square = p.hovered_square;
                                        break :player;
                                    }
                                }
                                if (board.isMovePossible(selected, p.hovered_square.?)) {
                                    animation = .{
                                        .piece = board.get(selected).*.?,
                                        .move = .{ .from = selected, .to = p.hovered_square.? },
                                        .progress = 0,
                                    };
                                    try history.addHistoryEntry(board);
                                }
                            } else {
                                p.selected_square = null;
                            }
                        } else {
                            if (board.get(p.hovered_square.?).*) |piece| {
                                if (piece.side == .black) {
                                    p.selected_square = p.hovered_square;
                                }
                            }
                        }
                    }
                },
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
                    if (whos_turn == .player) whos_turn.player else .{ .hovered_square = null, .selected_square = null },
                    style,
                );
                drawPiece(
                    anim.piece,
                    rectFromPositionAndSize(
                        anim.position().scale(side_length).addValue((style.padding - side_length) / 2).add(center),
                        .init(cell_size - style.padding, cell_size - style.padding),
                    ),
                    style,
                );
            } else {
                drawChessBoard(board, rlx.screenSquare(), if (whos_turn == .player) whos_turn.player else .null, style);
                if (whos_turn == .player) {
                    if (whos_turn.player.selected_square) |selected_square| {
                        for (0..8) |y| {
                            for (0..8) |x| {
                                if (board.isMovePossible(selected_square, .{ .file = @intCast(x), .row = @intCast(7 - y) })) {
                                    const posf: rl.Vector2 = .init(@floatFromInt(x), @floatFromInt(y));
                                    rl.drawCircleV(
                                        posf.scale(side_length / 8).addValue((style.padding - side_length) / 2 + cell_size / 2).add(center),
                                        10,
                                        .green,
                                    );
                                }
                            }
                        }
                    }
                }
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
        &uci,
    );
}

test {
    _ = @import("Uci.zig");
}
