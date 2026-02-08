const std = @import("std");
const Reader = std.Io.Reader;
const Writer = std.Io.Writer;

const GameState = @import("GameState.zig");
const Move = GameState.MovePromotion;

const log = std.log.scoped(.uci2);

reader: *Reader,
writer: *Writer,

pub fn init(stdin: *Reader, stdout: *Writer) void {
    return .{
        .stdin = stdin,
        .stdout = stdout,
    };
}

pub const GoConfig = struct {
    // searchmoves: []const Move = &.{},
    // ponde: void = {},
    // wtime: void = {},
    // btime: void = {},
    // winc: void = {},
    // binc: void = {},
    // movestogo: void = {},
    depth: u8,
    // nodes: void = {},
    // mate: void = {},
    // movetime: void = {},
    // infinit: void = {},
};
