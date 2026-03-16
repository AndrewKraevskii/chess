const std = @import("std");
const Sse = @import("Sse.zig");
const Chess = @import("Chess");
const Server = @import("Server.zig");
const Io = std.Io;
const log = std.log.scoped(.server);

gpa: std.mem.Allocator,
io: Io,
assets_dir: Io.Dir,

/// Protects rooms.
mutex: Io.Mutex,
/// Protects rooms.
rooms_changed: Io.Condition,
rooms: std.AutoArrayHashMapUnmanaged(Room.Id, *Room),
room_alloc: std.heap.MemoryPool(Room),

last_room_id: u32,

const Room = struct {
    // Protects
    mutex: Io.Mutex,
    condition: Io.Condition,
    chess: Chess,

    const Id = enum(u32) {
        _,

        pub fn parse(str: []const u8) !Id {
            return @enumFromInt(try std.fmt.parseInt(u32, str, 10));
        }
    };
};

pub fn init(io: Io, gpa: std.mem.Allocator, assets_dir: Io.Dir) !Server {
    return .{
        .io = io,
        .gpa = gpa,
        .assets_dir = assets_dir,
        .rooms = .empty,
        .last_room_id = 0,
        .mutex = .init,
        .rooms_changed = .init,
        .room_alloc = .empty,
    };
}

pub fn deinit(server: *Server) void {
    std.debug.assert(server.mutex.state.raw == .unlocked);
    server.room_alloc.deinit(server.gpa);
    server.rooms.deinit(server.gpa);
}

pub fn start(server: *Server, address: std.Io.net.IpAddress) !void {
    const io = server.io;

    var server_tcp = try address.listen(io, .{
        .reuse_address = true,
    });
    defer server_tcp.deinit(io);

    var group: Io.Group = .init;
    defer group.cancel(io);

    while (server_tcp.accept(io)) |stream| {
        try group.concurrent(io, accept, .{
            server, stream,
        });
    } else |e| {
        log.err("error: {t}", .{e});
        return error.AcceptFailed;
    }
}

fn accept(server: *Server, stream: Io.net.Stream) Io.Cancelable!void {
    const io = server.io;

    defer stream.close(io);
    var writer_buffer: [0x1000]u8 = undefined;
    var writer = stream.writer(io, &writer_buffer);
    var reader_buffer: [0x1000]u8 = undefined;
    var reader = stream.reader(io, &reader_buffer);

    var http_server = std.http.Server.init(&reader.interface, &writer.interface);
    var req = http_server.receiveHead() catch |e| {
        log.err("failed to recieve http header: {t}", .{e});
        return;
    };

    server.serverRequest(&req) catch |err| switch (err) {
        else => {
            log.err("failed to serve '{s}': {t}", .{ req.head.target, err });
        },
    };
}

fn serverRequest(server: *Server, req: *std.http.Server.Request) !void {
    const gpa = server.gpa;

    var rest = req.head.target;
    const path, rest = std.mem.cutScalar(u8, rest, '?') orelse .{ rest, "" };
    const encoded_query, rest = std.mem.cutScalar(u8, rest, '#') orelse .{ rest, "" };

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const prefixed_query = std.Uri.percentDecodeInPlace(try arena.allocator().dupe(u8, encoded_query));
    std.mem.replaceScalar(u8, prefixed_query, '+', ' ');

    log.debug("query: '{s}' {s}'", .{ path, prefixed_query });

    if (std.mem.eql(u8, path, "/")) try server.serveStaticFile(req, "index.html", .@"text/html");
    if (std.mem.eql(u8, path, "/reset.css")) try server.serveStaticFile(req, "reset.css", .@"text/css");
    if (std.mem.eql(u8, path, "/rooms")) try server.serveRooms(req);
    if (std.mem.eql(u8, path, "/create_room")) try server.createRoom(req);
    if (std.mem.cutPrefix(u8, path, "/room/")) |id| try server.serveRoom(req, id);
    if (std.mem.cutPrefix(u8, path, "/board/move/")) |id| try server.makeMove(req, id, prefixed_query);
    if (std.mem.cutPrefix(u8, path, "/board/")) |id| try server.getBoard(req, id);
}

const ContentType = enum {
    @"text/html",
    @"application/javascript",
    @"text/css",
    @"text/plain",
};

fn getRoom(server: *Server, id: Room.Id) !?*Room {
    try server.mutex.lock(server.io);
    defer server.mutex.unlock(server.io);
    return server.rooms.get(id);
}
fn serveRoom(server: *Server, req: *std.http.Server.Request, room_id_str: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(server.gpa);
    defer arena.deinit();

    const io = server.io;
    const id: Room.Id = try .parse(room_id_str);
    {
        if (try server.getRoom(id) == null) {
            log.err("room not found", .{});
            return try redirect(req, "/");
        }
    }

    const templated_page = try server.assets_dir.readFileAlloc(io, "board.html", arena.allocator(), .limited(1000 * 1000));

    const responce = try std.mem.replaceOwned(u8, arena.allocator(), templated_page, "#big_text_room_id", try std.fmt.allocPrint(arena.allocator(), "{d}", .{@intFromEnum(id)}));
    try req.respond(responce, .{
        .extra_headers = &.{
            .{ .name = "Content-Type", .value = @tagName(ContentType.@"text/html") },
        },
    });
}

fn redirect(req: *std.http.Server.Request, dest: []const u8) !void {
    try req.respond("", .{
        .status = .see_other,
        .extra_headers = &.{
            .{ .name = "Location", .value = dest },
        },
    });
}

fn newId(server: *Server) Room.Id {
    return @enumFromInt(@atomicRmw(u32, @as(*u32, @ptrCast(&server.last_room_id)), .Add, 1, .seq_cst));
}

fn createRoom(server: *Server, req: *std.http.Server.Request) !void {
    const new_id = server.newId();

    const room = room: {
        try server.mutex.lock(server.io);
        defer server.mutex.unlock(server.io);
        try server.rooms.ensureUnusedCapacity(server.gpa, 1);
        const room = try server.room_alloc.create(server.gpa);
        server.rooms.putAssumeCapacity(
            new_id,
            room,
        );
        break :room room;
    };
    room.* = .{
        .condition = .init,
        .mutex = .init,
        .chess = .init,
    };
    try room.chess.setPosition(server.gpa, .init);
    server.notifyRooms();
    try req.respond("", .{});
}

fn notifyRooms(server: *Server) void {
    server.rooms_changed.broadcast(server.io);
}

fn serveRooms(
    server: *Server,
    req: *std.http.Server.Request,
) !void {
    const io = server.io;

    var respond_buffer: [0x1000]u8 = undefined;
    var responce = try req.respondStreaming(
        &respond_buffer,
        Sse.std_http_options,
    );
    var sse_buffer: [0x1000]u8 = undefined;

    try server.mutex.lock(io);
    defer server.mutex.unlock(io);
    while (true) {
        var sse: Sse = .init(&responce.writer, &sse_buffer);
        try server.sseSendRooms(&sse);
        try responce.flush();

        try server.rooms_changed.wait(io, &server.mutex);
    }
}

fn sseSendRooms(server: *Server, sse: *Sse) !void {
    try sse.beginEvent(.datastar_patch_elements, .{});
    try sse.writer.writeAll("<ul id='rooms'>");
    for (server.rooms.keys(), server.rooms.values()) |room_id, room| {
        _ = room;
        try sse.writer.print("<li>Room - {d} <a href='/room/{d}'>Join</a>", .{ room_id, room_id });
    }
    try sse.writer.writeAll("</ul>");
    try sse.endEvent();
}

fn serveStaticFile(
    server: *Server,
    req: *std.http.Server.Request,
    file_path: []const u8,
    content_type: ContentType,
) !void {
    const io = server.io;
    const asset = try server.assets_dir.openFile(io, file_path, .{});
    defer asset.close(io);

    const len = try asset.length(io);
    var respond_buffer: [0x1000]u8 = undefined;
    var responce = try req.respondStreaming(
        &respond_buffer,
        .{
            .content_length = len,
            .respond_options = .{
                .extra_headers = &.{
                    .{ .name = "Content-Type", .value = @tagName(content_type) },
                },
            },
        },
    );

    var reader_buffer: [0x1000]u8 = undefined;
    var reader = asset.readerStreaming(io, &reader_buffer);
    _ = try reader.interface.streamRemaining(&responce.writer);
    try responce.end();
}

fn parseSignals(arena: std.mem.Allocator, Signals: type, query: []const u8) !Signals {
    return try std.json.parseFromSliceLeaky(Signals, arena, std.mem.cutPrefix(u8, query, "datastar=") orelse return error.NoDatastarPrefix, .{ .ignore_unknown_fields = true });
}

fn makeMove(server: *Server, req: *std.http.Server.Request, room_id_str: []const u8, query: []const u8) !void {
    const io = server.io;
    const gpa = server.gpa;
    log.info("make a move", .{});
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const room_id: Room.Id = try .parse(room_id_str);
    const room = (try server.getRoom(room_id)) orelse return try redirect(req, "/");
    const Signals = struct {
        from: []const u8,
        to: []const u8,
    };
    const signals: Signals = try parseSignals(arena.allocator(), Signals, query);
    log.info("in room: {d}", .{@intFromEnum(room_id)});

    apply_move: {
        try room.mutex.lock(io);
        defer room.mutex.unlock(io);

        const board = room.chess.activeBoard() orelse break :apply_move;

        const move: Chess.Board.Move = try .parse(&(signals.from[0..2].* ++ signals.to[0..2].*));
        const promotion: ?Chess.Board.Piece.Type = if (try board.isPromotionFallible(move)) .queen else null;

        _ = board.applyMoveFallible(.{ .from = move.from, .to = move.to, .promotion = promotion }) catch break :apply_move;
        try room.chess.setNext(gpa, .{ .from = move.from, .to = move.to, .promotion = promotion });
        log.info("moved", .{});
    }
    room.condition.broadcast(io);

    try req.respond("", .{});
    log.info("responded 200", .{});
}

fn getBoard(server: *Server, req: *std.http.Server.Request, room_id_str: []const u8) !void {
    const io = server.io;

    var sse_buffer: [0x1000]u8 = undefined;
    var buffer: [0x1000]u8 = undefined;
    var responce = try req.respondStreaming(&buffer, Sse.std_http_options);
    var sse: Sse = .init(&responce.writer, &sse_buffer);

    const room_id: Room.Id = try .parse(room_id_str);
    const room = (try server.getRoom(room_id)) orelse return try redirect(req, "/");

    var position: Chess.Position = board: {
        try room.mutex.lock(io);
        defer room.mutex.unlock(io);
        break :board room.chess.activePosition() orelse .init;
    };
    var move_id: u64 = 0;
    while (true) : (move_id += 1) {
        log.debug("start sending board", .{});
        if (position.move) |move| update_move_source: {
            const piece_char: u8 = blk: {
                const piece = position.board.getConst(move.to) orelse break :update_move_source;
                break :blk piece.toChar();
            };
            try sse.beginEvent(.datastar_patch_elements, .{});
            try sse.writer.print(
                \\<c-piece id='{s}' style='view-transition-name: moved_piece-{d}'>{c}
            , .{
                &move.from.serialize(),
                move_id,
                piece_char,
            });
            try sse.writer.writeAll(
                \\</c-piece>
            );
            try sse.endEvent();
            log.debug("sended pre view transition update", .{});
        }

        {
            try sse.beginEvent(.datastar_patch_elements, .{
                .use_view_transition = true,
            });
            try sse.writer.print(
                \\<c-board id='main-board' data-on:click='
                \\(() => {{
                \\  const piece = evt.target.closest(`c-piece`);
                \\  const move  = evt.target.closest(`c-move`);
                \\  if (move) {{
                \\    $from = move.getAttribute(`from`);
                \\    $to   = move.getAttribute(`to`);
                \\    @get(`/board/move/{d}`);
                \\  }} else if (piece) {{
                \\    $selected = piece.id;
                \\  }}
                \\}})()'>
            , .{
                @intFromEnum(room_id),
            });
            var moves_buffer: [Chess.Board.max_moves_from_position]Chess.Board.Move = undefined;
            const moves = position.board.validMoves(&moves_buffer);
            for (moves) |move| {
                try sse.writer.print("<c-move from='{s}' to='{s}' data-show='$selected==`{s}`'>🟢</c-move>", .{
                    move.from.serialize(),
                    move.to.serialize(),
                    move.from.serialize(),
                });
            }
            for (0..8) |row_index| {
                for (0..8) |column_index| {
                    const pos: Chess.Board.Position = .{ .file = @intCast(column_index), .row = @intCast(row_index) };
                    const piece_char: u8 = blk: {
                        const piece = position.board.getConst(pos) orelse continue;
                        break :blk piece.toChar();
                    };

                    const is_move_destination = if (position.move) |move| std.meta.eql(move.to, pos) else false;

                    try sse.writer.print(
                        \\<c-piece id='{s}'
                    , .{
                        &pos.serialize(),
                    });
                    if (is_move_destination) try sse.writer.print("style='view-transition-name: moved_piece-{d}'", .{move_id});
                    try sse.writer.print(
                        \\>{c}
                    , .{piece_char});
                    try sse.writer.writeAll(
                        \\</c-piece>
                    );
                }
            }
            try sse.writer.writeAll("</c-board>");
            try sse.endEvent();
            log.debug("sended board", .{});
        }
        {
            try sse.beginEvent(.datastar_patch_elements, .{});
            try sse.writer.print("<span id='fen'>{f}</span>", .{position.board});
            try sse.endEvent();
            log.debug("sended fen", .{});
        }
        try responce.flush();
        log.debug("sended flushed", .{});

        try room.mutex.lock(io);
        defer room.mutex.unlock(io);
        try room.condition.wait(io, &room.mutex);
        std.log.info("woke up to draw board", .{});

        position = room.chess.activePosition() orelse .init;
    }
    try responce.endChunked(.{});
}

// pub fn setboard(req: *std.http.Server.Request, options: Options) !void {
//     _ = req;
//     try options.game.mutex.lock(options.io);
//     defer options.game.mutex.unlock(options.io);

//     std.log.debug("signals: {f}", .{std.json.fmt(options.query, .{ .whitespace = .indent_1 })});
//     const recieved_board = Chess.Board.parse(options.query.fen orelse return) catch {
//         std.log.err("Incorrect fen string", .{});
//         return;
//     };

//     try options.game.chess.setPosition(options.gpa, recieved_board);
//     std.log.debug("Setting board to {f}", .{recieved_board});
//     options.game.condition.broadcast(options.io);
// }
