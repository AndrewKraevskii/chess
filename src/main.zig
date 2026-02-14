const std = @import("std");
const Io = std.Io;

const gui = @import("raygui");
const rl = @import("raylib");

const fen = @import("fen.zig");
const GameState = @import("GameState.zig");
const Chess = @import("Chess.zig");
const renderer = @import("renderer.zig");
const DisplayStyle = renderer.DisplayStyle;
const rlx = @import("raylibx.zig");
const Uci = @import("Uci.zig");

const log = std.log.scoped(.main);

pub const std_options: std.Options = .{
    .log_scope_levels = &.{.{
        .scope = .uci2,
        .level = .err,
    }},
    .log_level = .warn,
};

const PlayMode = enum {
    eve,
    pve,
    pvp,
};

const PlayerType = enum {
    engine,
    player,
};

pub fn doChess(uci: *Uci, queue: *Io.Queue(GameState.MovePromotion), random: std.Random, starting_pos: ?[]const u8, io: Io, gpa: std.mem.Allocator, style: DisplayStyle, play_mode: PlayMode) !enum { white_won, black_won, draw } {
    _ = random;
    var animation_speed: f32 = 10;

    var chess: Chess = chess: {
        var chess: Chess = .init;
        const starting_board: GameState = if (starting_pos) |f| try .parse(f) else .init;
        try chess.setPosition(gpa, starting_board);
        break :chess chess;
    };

    var asked_engine = false;

    var animation: ?renderer.Animation = null;
    var paused: bool = false;

    const players: std.EnumArray(GameState.Side, PlayerType) = switch (play_mode) {
        .eve => .initFill(.engine),
        .pvp => .initFill(.player),
        .pve => .init(.{
            .white = .player,
            .black = .engine,
        }),
    };

    var selection: ?GameState.Position = null;

    var frame_arena: std.heap.ArenaAllocator = .init(gpa);

    while (!rl.windowShouldClose()) {
        _ = frame_arena.reset(.retain_capacity);

        var turn_style: DisplayStyle = style;
        const board = chess.activeBoard().?;
        const turn = board.turn;

        turn_style.board_orientation = switch (play_mode) {
            .pvp => switch (turn) {
                .black => .black_bottom,
                .white => .white_bottom,
            },
            .eve => .white_bottom,
            .pve => switch (players.get(.black)) {
                .player => .black_bottom,
                .engine => .white_bottom,
            },
        };
        var moves_buffer: [GameState.max_moves_from_position]GameState.Move = undefined;
        const moves = board.validMoves(&moves_buffer);

        const whose_turn = players.get(board.turn);

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
                    try chess.setNext(gpa, board.applyMove(anim.move));
                    if (play_mode == .pve) {} else {}
                    animation = null;
                } else {
                    anim.progress += rl.getFrameTime() * animation_speed;
                }
            } else switch (whose_turn) {
                .engine => if (asked_engine) {
                    var result: [1]GameState.MovePromotion = undefined;
                    if (queue.get(io, &result, 0)) |n| {
                        if (n == 1) {
                            animation = .{
                                .piece = board.getConst(result[0].from).?,
                                .move = result[0],
                                .progress = 0,
                            };
                            asked_engine = false;
                        }
                    } else |e| return e;
                } else {
                    try uci.setPosition(board);
                    try uci.go(.{
                        .depth = 1,
                    });
                    uci.getMoveAsync(io, queue);
                    asked_engine = true;
                },
                .player => player: {
                    if (rl.isKeyPressed(.u)) {
                        chess.undo();
                        if (play_mode == .pve)
                            chess.undo();
                        break :player;
                    }

                    if (rl.isKeyPressed(.r)) {
                        chess.redo();
                        if (play_mode == .pve)
                            chess.redo();
                        break :player;
                    }

                    const mouse_pos = rl.getMousePosition();
                    if (!rl.checkCollisionPointRec(mouse_pos, rlx.screenSquare())) break :player;
                    const normalized = rlx.normalizeInRectangle(rlx.screenSquare(), mouse_pos);
                    const coords = normalized.scale(8);
                    const x: u3 = @intFromFloat(coords.x);
                    const y: u3 = @intFromFloat(coords.y);

                    const hovered_square: GameState.Position = turn_style.board_orientation.pos(.{
                        .file = x,
                        .row = y,
                    });

                    if (rl.isMouseButtonPressed(.left)) {
                        if (selection) |selected| {
                            if (std.meta.eql(selected, hovered_square)) {
                                selection = null;
                            } else {
                                if (board.getConst(hovered_square)) |piece| {
                                    if (piece.side == board.turn) {
                                        std.debug.print("select different\n", .{});
                                        selection = hovered_square;
                                        break :player;
                                    }
                                }
                                const move: GameState.Move = .{ .from = selected, .to = hovered_square };
                                if (GameState.containsMove(
                                    moves,
                                    move,
                                )) {
                                    log.info("there is selected", .{});
                                    animation = .{
                                        .piece = board.getConst(selected).?,
                                        .move = .{
                                            .from = move.from,
                                            .to = move.to,
                                            .promotion = if (board.isPromotion(move)) .queen else null,
                                        },
                                        .progress = 0,
                                    };
                                    selection = null;
                                } else {
                                    log.info("nope", .{});
                                }
                            }
                        } else {
                            if (board.getConst(hovered_square)) |piece| {
                                if (piece.side == board.turn) {
                                    selection = hovered_square;
                                }
                            }
                        }
                    }
                },
            }
        }
        // board
        const hovered_square: ?GameState.Position = hovered: {
            const mouse_pos = rl.getMousePosition();
            if (!rl.checkCollisionPointRec(mouse_pos, rlx.screenSquare())) break :hovered null;
            const normalized = rlx.normalizeInRectangle(rlx.screenSquare(), mouse_pos);
            const coords = normalized.scale(8);
            break :hovered turn_style.board_orientation.pos(.{ .file = @intFromFloat(coords.x), .row = @as(u3, @intFromFloat(coords.y)) });
        };
        renderer.render(chess.activeBoard().?, animation, turn_style, .{
            .selected_square = selection,
            .hovered_square = hovered_square,
        }, moves);

        { // gui
            _ = gui.slider(.{
                .x = 0,
                .y = 0,
                .width = 100,
                .height = 10,
            }, "Speed", "", &animation_speed, 0.01, 30);
            _ = gui.label(.{
                .x = 0,
                .y = 10,
                .width = 200,
                .height = 10,
            }, uci.id.name orelse "");
            _ = gui.label(.{
                .x = 0,
                .y = 20,
                .width = 200,
                .height = 10,
            }, uci.id.author orelse "");
            var pos: f32 = 20;
            for (uci.options.keys(), uci.options.values()) |key, value| {
                pos += 10;
                switch (value) {
                    .button => {
                        if (gui.button(.{
                            .x = 0,
                            .y = pos,
                            .width = 200,
                            .height = 10,
                        }, key)) {
                            try uci.send(.{ .set_option = "A," });
                        }
                    },
                    .check => |check| {
                        var b = check.default;
                        _ = gui.checkBox(.{
                            .x = 0,
                            .y = pos,
                            .width = 10,
                            .height = 10,
                        }, key, &b);
                    },
                    .combo => |combo| {
                        const string = try std.mem.joinZ(frame_arena.allocator(), ";", combo.@"var");
                        var b: bool = false;
                        _ = gui.checkBox(.{
                            .x = 0,
                            .y = pos,
                            .width = 10,
                            .height = 10,
                        }, string, &b);
                    },
                    .string => |str| {
                        _ = gui.label(.{
                            .x = 0,
                            .y = pos,
                            .width = 100,
                            .height = 10,
                        }, str.default);
                    },
                    .spin => |spin| {
                        var a: f32 = @floatFromInt(spin.default);
                        _ = gui.slider(.{
                            .x = 0,
                            .y = pos,
                            .width = 100,
                            .height = 10,
                        }, key, "", &a, @floatFromInt(spin.min), @floatFromInt(spin.max));
                    },
                }
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

    rl.setConfigFlags(.{
        .vsync_hint = true,
    });
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
    const style: DisplayStyle = .{
        .board_orientation = .white_bottom,
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
        var uci = try Uci.connect(io, arena, &uci_read_buffer, &uci_write_buffer, engine_path);
        defer {
            std.process.cleanExit(io);
            log.info("Exiting game loop", .{});
            uci.quit(arena) catch |e| {
                log.err("can't deinit engine: {s}", .{@errorName(e)});
            };
        }
        var buffer: [1]GameState.MovePromotion = undefined;

        var engine_async_move: Io.Queue(GameState.MovePromotion) = .init(&buffer);
        defer engine_async_move.close(io);

        const result = doChess(
            &uci,
            &engine_async_move,
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
            renderer.drawPiece(.{ .side = side, .type = .king }, .{ .x = text_pos.x - icon_side, .y = text_pos.y, .width = icon_side, .height = icon_side }, style);
        }
        try io.sleep(.fromSeconds(1), .awake);
    }
}

test {
    _ = @import("Uci.zig");
    _ = @import("GameState.zig");
    _ = @import("Chess.zig");
}
