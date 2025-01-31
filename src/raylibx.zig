const rl = @import("raylib");

pub fn getScreenCenter() rl.Vector2 {
    return .{
        .x = @as(f32, @floatFromInt(rl.getScreenWidth())) / 2,
        .y = @as(f32, @floatFromInt(rl.getScreenHeight())) / 2,
    };
}

pub fn getScreenHeightf() f32 {
    return @floatFromInt(rl.getScreenHeight());
}

pub fn getScreenWidthf() f32 {
    return @floatFromInt(rl.getScreenWidth());
}
