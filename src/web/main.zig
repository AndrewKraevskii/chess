const std = @import("std");
const Io = std.Io;
const Chess = @import("Chess");

const Options = struct {
    io: Io,
    query: Signals,
    arena: std.mem.Allocator,
    gpa: std.mem.Allocator,
    game: *State,
};

const Args = struct {
    address: std.Io.net.IpAddress,

    const default: Args = .{
        .address = std.Io.net.IpAddress.parse("0.0.0.0", 8080) catch unreachable,
    };
};

pub fn parseArgs(process_args: std.process.Args, arena: std.mem.Allocator) !Args {
    const slice = try process_args.toSlice(arena);

    var args: Args = .default;
    for (slice) |arg| {
        if (std.mem.cutPrefix(u8, arg, "--listen=")) |address| {
            args.address = try std.Io.net.IpAddress.parseLiteral(address);
        }
    }
    return args;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    const args = try parseArgs(init.minimal.args, init.arena.allocator());
    std.log.info("Listening on {f}", .{args.address});
    var server = try args.address.listen(io, .{
        .reuse_address = true,
    });
    defer server.deinit(io);

    var state: State = .{
        .io = init.io,
        .chess = .init,
        .mutex = .init,
        .condition = .init,
        .update_interval = null,
    };
    try state.chess.setPosition(init.gpa, .init);
    var group: std.Io.Group = .init;
    try group.concurrent(io, updateBoard, .{ init.gpa, &state });
    while (server.accept(io)) |stream| {
        group.async(io, handleInfalible, .{
            io,     init.gpa,
            stream, &state,
        });
    } else |e| {
        std.log.err("error: {t}", .{e});
    }
}
fn updateBoard(gpa: std.mem.Allocator, state: *State) !void {
    var random: std.Random.DefaultPrng = .init(0);
    while (true) {
        const sleep_time = sleep_time: {
            try state.mutex.lock(state.io);
            defer state.mutex.unlock(state.io);

            var b: Chess.Board = state.chess.activeBoard() orelse .init;
            var moves_buffer: [Chess.Board.max_moves_from_position]Chess.Board.Move = undefined;
            const moves = moves: {
                const moves = b.validMoves(&moves_buffer);
                if (moves.len == 0) state.chess.setPosition(gpa, .init) catch @panic("OOM");
                b = state.chess.activeBoard().?;
                const new_moves = b.validMoves(&moves_buffer);
                break :moves new_moves;
            };
            const move = moves[random.random().uintLessThan(usize, moves.len)];
            const promotion: ?Chess.Board.Piece.Type = if (b.isPromotion(move)) .queen else null;
            const next_board = b.applyMove(.{ .from = move.from, .to = move.to, .promotion = promotion });
            state.chess.setNext(gpa, next_board) catch @panic("OOM");
            break :sleep_time state.update_interval;
        };
        state.condition.broadcast(state.io);
        if (sleep_time == null) return;
        try state.io.sleep(sleep_time.?, .awake);
    }
}

fn handleInfalible(io: Io, gpa: std.mem.Allocator, stream: std.Io.net.Stream, server: *State) Io.Cancelable!void {
    defer stream.close(io);
    var writer_buffer: [0x1000]u8 = undefined;
    var writer = stream.writer(io, &writer_buffer);
    var reader_buffer: [0x1000]u8 = undefined;
    var reader = stream.reader(io, &reader_buffer);
    handle(io, gpa, server, &writer.interface, &reader.interface) catch |e| switch (e) {
        else => {
            if (writer.err) |err| {
                if (err == error.SocketUnconnected) {
                    std.log.err("Client disconnected: {t}", .{err});
                }
            }
        },
    };
}

const Responce = union(enum) {
    static: []const u8,
    handler: *const fn (options: Options) anyerror!void,
};

fn parseTarget(slice: []const u8) struct {
    path: []const u8,
    query: []const u8,
} {
    var rest = slice;
    const path, rest = std.mem.cutScalar(u8, rest, '?') orelse .{ rest, "" };
    const encoded_query, rest = std.mem.cutScalar(u8, rest, '#') orelse .{ rest, "" };
    return .{
        .path = path,
        .query = encoded_query,
    };
}
const State = struct {
    io: Io,
    // protects chess and update_interval
    mutex: std.Io.Mutex,
    chess: Chess,
    condition: std.Io.Condition,
    // null meants game is paused.
    update_interval: ?std.Io.Duration,
};

const Self = @This();

const Endpoints = struct {
    pub const @"/" = index;
    pub const @"/board" = getBoard;
    pub const @"/setboard" = setboard;
    pub const @"/move" = makeMove;

    pub const @"/reset.css" = reset_css;

    pub fn not_found(req: *std.http.Server.Request, options: Options) !void {
        _ = options;
        try redirect(req, .@"/");
    }
    pub fn reset_css(req: *std.http.Server.Request, _: Options) !void {
        try req.respond(@embedFile("reset.css"), .{});
    }
};

pub fn makeMove(req: *std.http.Server.Request, options: Options) !void {
    apply_move: {
        try options.game.mutex.lock(options.io);
        defer options.game.mutex.unlock(options.io);

        const board = options.game.chess.activeBoard() orelse break :apply_move;
        if (options.query.from == null or options.query.to == null) break :apply_move;

        const move: Chess.Board.Move = try .parse(&(options.query.from.?[0..2].* ++ options.query.to.?[0..2].*));
        const promotion: ?Chess.Board.Piece.Type = if (board.isPromotion(move)) .queen else null;

        const new_board = board.applyMoveFallible(.{ .from = move.from, .to = move.to, .promotion = promotion }) catch break :apply_move;
        try options.game.chess.setNext(
            options.gpa,
            new_board,
        );
        options.game.condition.broadcast(options.io);
    }
    try getBoard(req, options);
}

const Sse = struct {
    body_writer: std.http.BodyWriter,
    writer: std.Io.Writer,
    state: enum {
        nothing,
        started_event,
        writing_event,
    },

    const Type = enum {
        datastar_patch_elements,
        datastar_patch_signals,

        pub fn cebab(t: Type) []const u8 {
            return switch (t) {
                .datastar_patch_elements => "datastar-patch-elements",
                .datastar_patch_signals => "datastar-patch-signals",
            };
        }
    };

    pub fn start(req: *std.http.Server.Request, buffer: []u8, sse_buffer: []u8) !Sse {
        const streaming = try req.respondStreaming(buffer, .{
            .respond_options = .{
                .extra_headers = &.{
                    .{ .name = "cache-control", .value = "no-cache" },
                    .{ .name = "content-type", .value = "text/event-stream" },
                    .{ .name = "connection", .value = "keep-alive" },
                },
                .transfer_encoding = .chunked,
            },
        });
        return .{
            .body_writer = streaming,
            .writer = .{
                .buffer = sse_buffer,
                .vtable = &.{
                    .drain = drain,
                },
            },
            .state = .nothing,
        };
    }

    fn beginEvent(sse: *Sse, event_type: Type) !void {
        std.debug.assert(sse.state == .nothing);
        try sse.body_writer.writer.print(
            "event: {s}",
            .{event_type.cebab()},
        );
        sse.state = .started_event;
    }
    const start_of_element_patch = "\ndata: elements ";

    // TODO: name it something else
    fn putSseFormatedString(writer: *std.Io.Writer, text: []const u8) !usize {
        var lines = std.mem.splitScalar(u8, text, '\n');
        var count: usize = 0;
        while (lines.next()) |line| {
            try writer.writeAll(line);
            count += line.len;
            if (lines.peek() != null) {
                try writer.writeAll(start_of_element_patch);
                count += start_of_element_patch.len;
            }
        }
        return count;
    }

    fn drain(w: *Io.Writer, data: []const []const u8, splat: usize) error{WriteFailed}!usize {
        const sse: *Sse = @fieldParentPtr("writer", w);
        if (sse.state == .started_event) {
            try sse.body_writer.writer.writeAll(start_of_element_patch);
            sse.state = .writing_event;
        }
        var count: usize = 0;
        count += try putSseFormatedString(&sse.body_writer.writer, w.buffered());
        w.end = 0;
        for (data[0 .. data.len - 1]) |datum| {
            count += try putSseFormatedString(&sse.body_writer.writer, datum);
        }
        for (0..splat) |_| {
            count += try putSseFormatedString(&sse.body_writer.writer, data[data.len - 1]);
        }

        return count;
    }
    pub fn endEvent(s: *Sse) !void {
        std.debug.assert(s.state != .nothing);
        try s.writer.flush();
        try s.body_writer.writer.writeAll("\n\n");
        try s.body_writer.writer.flush();
        try s.body_writer.flush();
        s.state = .nothing;
    }

    pub fn end(s: *Sse) !void {
        std.debug.assert(s.state == .nothing);
        try s.body_writer.endChunked(.{});
    }
};

pub fn getBoard(req: *std.http.Server.Request, options: Options) !void {
    var sse_buffer: [0x1000]u8 = undefined;
    var buffer: [0x1000]u8 = undefined;
    var sse: Sse = try .start(req, &buffer, &sse_buffer);

    var b: Chess.Board = board: {
        try options.game.mutex.lock(options.io);
        defer options.game.mutex.unlock(options.io);
        break :board options.game.chess.activeBoard() orelse .init;
    };
    while (true) {
        try sse.beginEvent(.datastar_patch_elements);
        try sse.writer.writeAll("<c-board id='main-board' data-on:click='$selected = (evt.target.tagName == `C-PIECE`) ? evt.target.id : (()=>{$from=evt.target.getAttribute(`from`);$to=evt.target.getAttribute(`to`);@get(`/move`)})()'>");
        for (0..8) |row_index| {
            for (0..8) |column_index| {
                const pos: Chess.Board.Position = .{ .file = @intCast(column_index), .row = @intCast(row_index) };
                const piece_char: u8 = blk: {
                    const piece = b.getConst(pos) orelse continue;
                    break :blk piece.toChar();
                };

                try sse.writer.print(
                    \\<c-piece id='{s}'>{c}
                , .{
                    &pos.serialize(),
                    piece_char,
                });
                try sse.writer.writeAll(
                    \\</c-piece>
                );
            }
        }
        var moves_buffer: [Chess.Board.max_moves_from_position]Chess.Board.Move = undefined;
        const moves = b.validMoves(&moves_buffer);
        for (moves) |move| {
            try sse.writer.print("<c-move from='{s}' to='{s}' data-show='$selected==`{s}`'>🟢</c-move>", .{
                move.from.serialize(),
                move.to.serialize(),
                move.from.serialize(),
            });
        }
        try sse.writer.writeAll("</c-board>");
        try sse.endEvent();

        try sse.beginEvent(.datastar_patch_elements);
        try sse.writer.print("<span id='fen'>{f}</span>", .{b});
        try sse.endEvent();

        try options.game.mutex.lock(options.io);
        defer options.game.mutex.unlock(options.io);
        try options.game.condition.wait(options.io, &options.game.mutex);

        b = options.game.chess.activeBoard() orelse .init;
    }
    try sse.end();
}

pub fn setboard(req: *std.http.Server.Request, options: Options) !void {
    _ = req;
    try options.game.mutex.lock(options.io);
    defer options.game.mutex.unlock(options.io);

    std.log.debug("signals: {f}", .{std.json.fmt(options.query, .{ .whitespace = .indent_1 })});
    const recieved_board = Chess.Board.parse(options.query.fen orelse return) catch {
        std.log.err("Incorrect fen string", .{});
        return;
    };

    try options.game.chess.setPosition(options.gpa, recieved_board);
    std.log.debug("Setting board to {f}", .{recieved_board});
    options.game.condition.broadcast(options.io);
}

pub fn redirect(req: *std.http.Server.Request, endpoint: std.meta.DeclEnum(Endpoints)) !void {
    try req.respond(@embedFile("index.html"), .{
        .extra_headers = &.{
            .{ .name = "Location", .value = @tagName(endpoint) },
        },
    });
}

pub fn index(req: *std.http.Server.Request, options: Options) !void {
    _ = options;
    try req.respond(@embedFile("index.html"), .{});
}

const Signals = struct {
    fen: ?[]const u8 = null,
    from: ?[]const u8 = null,
    to: ?[]const u8 = null,

    const default: Signals = .{};
};

fn handle(io: Io, gpa: std.mem.Allocator, state: *State, writer: *std.Io.Writer, reader: *std.Io.Reader) !void {
    var http_server = std.http.Server.init(reader, writer);
    var req = try http_server.receiveHead();
    var rest = req.head.target;
    const path, rest = std.mem.cutScalar(u8, rest, '?') orelse .{ rest, "" };
    const encoded_query, rest = std.mem.cutScalar(u8, rest, '#') orelse .{ rest, "" };

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    std.log.debug("query: '{s}'", .{encoded_query});
    const prefixed_query = std.Uri.percentDecodeInPlace(try arena.allocator().dupe(u8, encoded_query));
    std.mem.replaceScalar(u8, prefixed_query, '+', ' ');
    const query = std.mem.cutPrefix(u8, prefixed_query, "datastar=") orelse prefixed_query;
    std.log.debug("query: '{s}'", .{query});

    const path_without_slash_at_the_end = std.mem.trimEnd(u8, path, "/");
    const endpoint: std.meta.DeclEnum(Endpoints) = std.meta.stringToEnum(std.meta.DeclEnum(Endpoints), path_without_slash_at_the_end) orelse blk: {
        std.log.err("Attempt to load from: {s}", .{path_without_slash_at_the_end});
        break :blk .not_found;
    };
    switch (endpoint) {
        inline else => |cendpoint| {
            if (cendpoint != .not_found)
                std.log.info("Calling {t}", .{cendpoint});

            try @field(Endpoints, @tagName(cendpoint))(&req, .{
                .arena = arena.allocator(),
                .io = io,
                .query = std.json.parseFromSliceLeaky(Signals, arena.allocator(), query, .{ .ignore_unknown_fields = true }) catch .default,
                .game = state,
                .gpa = gpa,
            });
        },
    }
}
