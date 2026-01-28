const std = @import("std");
const Io = std.Io;

const gui = @import("raygui");
const rl = @import("raylib");

const fen = @import("fen.zig");
const GameState = @import("GameState.zig");
const rlx = @import("raylibx.zig");
const Uci = @import("Uci.zig");

const log = std.log.scoped(.main);

pub const std_options: std.Options = .{
    .log_scope_levels = &.{.{
        .scope = .uci2,
        .level = .err,
    }},
};

const PlayMode = enum {
    eve,
    pve,
    pvp,
};

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

fn rectFromPositionAndSize(pos: rl.Vector2, size: rl.Vector2) rl.Rectangle {
    return .{
        .x = pos.x,
        .y = pos.y,
        .width = size.x,
        .height = size.y,
    };
}

fn drawPiece(piece: GameState.Piece, dest: rl.Rectangle, style: GameStateDisplayStyle) void {
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

const GameStateDisplayStyle = struct {
    font: rl.Font,
    padding: f32,
    atlas: rl.Texture,
    white_square_color: rl.Color,
    black_square_color: rl.Color,
    selected_square_color: rl.Color,
    hovered_square_color: rl.Color,
    border_color: rl.Color,
};

const Selection = struct {
    hovered_square: ?GameState.Position,
    selected_square: ?GameState.Position,

    pub const @"null": Selection = .{
        .hovered_square = null,
        .selected_square = null,
    };
};

fn drawGameState(board: GameState, dest: rl.Rectangle, selection: Selection, style: GameStateDisplayStyle) void {
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
    piece: GameState.Piece,
    move: GameState.MovePromotion,
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

pub fn History(comptime Item: type) type {
    return struct {
        events: std.ArrayList(Item),
        undone: usize,

        pub fn init(gpa: std.mem.Allocator, capacity: usize) !@This() {
            return .{
                .events = try .initCapacity(gpa, capacity),
                .undone = 0,
            };
        }
        pub fn deinit(h: *@This(), gpa: std.mem.Allocator) void {
            h.events.deinit(gpa);
        }

        pub fn undo(history: *@This()) ?Item {
            std.debug.assert(history.undone <= history.events.items.len);
            if (history.undone == history.events.items.len) {
                return null;
            }
            history.undone += 1;

            return history.events.items[history.events.items.len - history.undone];
        }

        pub fn redo(history: *@This()) ?Item {
            if (history.undone == 0) return null;
            const event_to_redo = history.events.items[history.events.items.len - history.undone];
            history.undone -= 1;
            return event_to_redo;
        }

        pub fn addHistoryEntry(
            history: *@This(),
            entry: Item,
        ) !void {
            if (history.undone != 0) {
                history.events.shrinkRetainingCapacity(history.events.items.len - history.undone);
                history.undone = 0;
            }

            try history.events.appendBounded(
                entry,
            );
        }
    };
}

var animation_speed: f32 = 10;

pub fn doChess(uci: *Uci, random: std.Random, starting_pos: ?[]const u8, io: Io, gpa: std.mem.Allocator, style: GameStateDisplayStyle, play_mode: PlayMode) !enum { white_won, black_won, draw } {
    _ = io; // autofix
    var history: History(GameState) = try .init(gpa, 0x200);
    defer history.deinit(gpa);

    const starting_board: GameState = if (starting_pos) |f| try .parse(f) else .init;

    var board: GameState = starting_board;

    var engine_async_move: ?*Uci.MovePromise = null;

    var animation: ?Animation = null;
    var paused: bool = false;

    var whose_turn: union(enum) {
        engine,
        player: Selection,

        fn switchTurn(whose_turn: *@This()) void {
            whose_turn.* = switch (whose_turn.*) {
                .engine => .{
                    .player = .{
                        .hovered_square = null,
                        .selected_square = null,
                    },
                },
                .player => .engine,
            };
        }
    } = switch (play_mode) {
        .eve => .engine,
        .pvp => .{ .player = .null },
        .pve => if (random.boolean()) .{ .player = .null } else .engine,
    };

    while (!rl.windowShouldClose()) {
        var moves_buffer: [GameState.max_moves_from_position]GameState.Move = undefined;
        const moves = board.validMoves(&moves_buffer);

        switch (board.result()) {
            .playing => {},
            .checkmate => return switch (board.turn.next()) {
                .black => .black_won,
                .white => .white_won,
            },
            .stalemate => return .draw,
            .fifty_move_rule => return .draw,
            .three_fold_repetition => return .draw,
        }

        if (rl.isKeyPressed(.space)) {
            paused = !paused;
        }

        if (!paused) {
            if (animation) |*anim| { // update
                if (anim.progress >= 1) {
                    board = board.applyMove(anim.move);
                    switch (play_mode) {
                        .pve => whose_turn.switchTurn(),
                        .pvp => {},
                        .eve => {},
                    }
                    if (play_mode == .pve) {} else {}
                    animation = null;
                } else {
                    anim.progress += rl.getFrameTime() * animation_speed;
                }
            } else switch (whose_turn) {
                .engine => if (engine_async_move) |state| {
                    if (state.get()) |result| {
                        if (result) |m| {
                            animation = .{
                                .piece = board.get(m.from).*.?,
                                .move = m,
                                .progress = 0,
                            };
                            engine_async_move = null;
                        } else |_| {
                            return switch (board.turn.next()) {
                                .white => .white_won,
                                .black => .black_won,
                            };
                        }
                    }
                } else {
                    try uci.setPosition(board);
                    try uci.go(.{ .depth = @max(1, random.int(u3)) });
                    engine_async_move = uci.getMoveAsync();
                },
                .player => |*p| player: {
                    if (rl.isKeyPressed(.u)) undo: {
                        board = history.undo() orelse break :undo;
                        break :player;
                    }
                    if (rl.isKeyPressed(.r)) redo: {
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

                    if (rl.isMouseButtonPressed(.left)) {
                        if (p.selected_square) |selected| {
                            if (std.meta.eql(selected, p.hovered_square.?)) {
                                p.selected_square = null;
                            } else {
                                if (board.get(p.hovered_square.?).*) |piece| {
                                    if (piece.side == board.turn) {
                                        std.debug.print("select different\n", .{});
                                        p.selected_square = p.hovered_square;
                                        break :player;
                                    }
                                }
                                if (GameState.containsMove(moves, .{ .from = selected, .to = p.hovered_square.? })) {
                                    animation = .{
                                        .piece = board.get(selected).*.?,
                                        .move = .{ .from = selected, .to = p.hovered_square.? },
                                        .progress = 0,
                                    };
                                    p.* = .null;
                                    try history.addHistoryEntry(board);
                                }
                            }
                        } else {
                            if (board.get(p.hovered_square.?).*) |piece| {
                                if (piece.side == board.turn) {
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
                drawGameState(
                    board_to_draw,
                    rlx.screenSquare(),
                    if (whose_turn == .player) whose_turn.player else .{ .hovered_square = null, .selected_square = null },
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
                drawGameState(board, rlx.screenSquare(), if (whose_turn == .player) whose_turn.player else .null, style);
                if (whose_turn == .player) {
                    if (whose_turn.player.selected_square) |selected_square| {
                        for (0..8) |y| {
                            for (0..8) |x| {
                                if (GameState.containsMove(moves, .{ .from = selected_square, .to = .{ .file = @intCast(x), .row = @intCast(7 - y) } })) {
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
            } // gui
            {
                _ = gui.slider(.{
                    .x = 0,
                    .y = 0,
                    .width = 100,
                    .height = 10,
                }, "Speed", "", &animation_speed, 0.01, 30);
            }
        }
    }
    return error.WindowShouldClose;
}

fn selectMode() error{WindowShouldClose}!PlayMode {
    while (!rl.windowShouldClose()) {
        rl.beginDrawing();
        defer rl.endDrawing();

        rl.clearBackground(.black);

        const center = rlx.getScreenCenter();
        var rect: rl.Rectangle = .{
            .x = center.x - 50,
            .y = center.y - 20 - 30,
            .width = 100,
            .height = 40,
        };

        if (gui.button(rect, "PVP")) {
            return .pvp;
        }
        rect.y += 50;
        if (gui.button(rect, "PVE")) {
            return .pve;
        }
        rect.y += 50;
        if (gui.button(rect, "EVE")) {
            return .eve;
        }
    }

    return error.WindowShouldClose;
}

pub fn main(init: std.process.Init) !void {
    const program_arena = init.arena.allocator();
    const arena = program_arena;
    const io = init.io;

    const self_path = try std.process.executableDirPathAlloc(io, arena);
    const engine_path = try std.fs.path.join(arena, &.{ self_path, "stockfish" });

    var random = std.Random.DefaultPrng.init(0);

    var args = try init.minimal.args.iterateAllocator(arena);
    const program_name = args.next() orelse @panic("No program name passed");
    _ = program_name;

    const mode_args: ?PlayMode = if (args.next()) |mode_text| blk: {
        if (std.meta.stringToEnum(PlayMode, mode_text)) |mode| {
            break :blk mode;
        }
        log.err("Expected one of eve,pvp,pve", .{});
        return;
    } else null;

    const fen_string = args.next();

    log.debug("{s}", .{engine_path});
    rl.setConfigFlags(.{
        .window_resizable = true,
    });
    rl.setTraceLogLevel(.none);

    rl.initWindow(1000, 1000, "Chess");
    defer rl.closeWindow();

    const image = try rl.loadImageFromMemory(".png", @embedFile("chess_figures"));
    const chess_figures = try rl.loadTextureFromImage(image);
    defer chess_figures.unload();
    const style: GameStateDisplayStyle = .{
        .font = try rl.getFontDefault(),
        .padding = 4,
        .white_square_color = .white,
        .black_square_color = .black,
        .selected_square_color = .yellow,
        .hovered_square_color = .lime,
        .atlas = chess_figures,
        .border_color = .blue,
    };

    const mode = mode_args orelse selectMode() catch return;
    var uci_read_buffer: [0x1000]u8 = undefined;
    var uci_write_buffer: [0x1000]u8 = undefined;

    while (!rl.windowShouldClose()) {
        var uci = try Uci.connect(io, &uci_read_buffer, &uci_write_buffer, engine_path);
        defer {
            log.info("Exiting game loop", .{});
            uci.quit() catch |e| {
                log.err("can't deinit engine: {s}", .{@errorName(e)});
            };
        }

        const result = doChess(
            &uci,
            random.random(),
            fen_string,
            io,
            program_arena,
            style,
            mode,
        ) catch |e| switch (e) {
            error.WindowShouldClose => break,
            else => |other| return other,
        };
        log.info("End of game {s}", .{@tagName(result)});
        const text = switch (result) {
            .draw => "draw",
            .white_won => "white won",
            .black_won => "black won",
        };

        const font_size = 50;
        const width = rl.measureText(text, font_size);
        const text_pos = rlx.getScreenCenter().subtract(.init(@floatFromInt(@divFloor(width, 2)), @floatFromInt(@divFloor(font_size, 2))));
        draw_winner: {
            rl.beginDrawing();
            defer rl.endDrawing();
            rl.drawText(text, @intFromFloat(text_pos.x), @intFromFloat(text_pos.y), font_size, .red);
            const side: GameState.Side = switch (result) {
                .draw => break :draw_winner,
                .white_won => .white,
                .black_won => .black,
            };
            const icon_side = font_size;
            drawPiece(.{ .side = side, .type = .king }, .{ .x = text_pos.x - icon_side, .y = text_pos.y, .width = icon_side, .height = icon_side }, style);
        }
        try io.sleep(.fromSeconds(1), .awake);
    }
}

test {
    _ = @import("Uci.zig");
    _ = @import("uci2.zig");
    _ = @import("GameState.zig");
}
