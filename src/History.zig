const std = @import("std");
const GameState = @import("GameState.zig");

events: std.ArrayList(GameState),
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

pub fn undo(history: *@This()) ?GameState {
    std.debug.assert(history.undone <= history.events.items.len);
    if (history.undone == history.events.items.len) {
        return null;
    }
    history.undone += 1;

    return history.events.items[history.events.items.len - history.undone];
}

pub fn redo(history: *@This()) ?GameState {
    if (history.undone == 0) return null;
    const event_to_redo = history.events.items[history.events.items.len - history.undone];
    history.undone -= 1;
    return event_to_redo;
}

pub fn addHistoryEntry(
    history: *@This(),
    entry: GameState,
) !void {
    if (history.undone != 0) {
        history.events.shrinkRetainingCapacity(history.events.items.len - history.undone);
        history.undone = 0;
    }

    try history.events.appendBounded(
        entry,
    );
}
