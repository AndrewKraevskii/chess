const std = @import("std");

/// An `ArrayHashMapUnmanaged` with strings as keys.
pub fn StringArrayHashMapUnmanaged(comptime V: type) type {
    return std.ArrayHashMapUnmanaged([:0]const u8, V, StringContext, true);
}

pub const StringContext = struct {
    pub fn hash(self: @This(), s: [:0]const u8) u32 {
        _ = self;
        return hashString(s);
    }
    pub fn eql(self: @This(), a: [:0]const u8, b: [:0]const u8, b_index: usize) bool {
        _ = self;
        _ = b_index;
        return eqlString(a, b);
    }
};

pub fn eqlString(a: [:0]const u8, b: [:0]const u8) bool {
    return std.mem.eql(u8, a, b);
}

pub fn hashString(s: [:0]const u8) u32 {
    return @truncate(std.hash.Wyhash.hash(0, s));
}
