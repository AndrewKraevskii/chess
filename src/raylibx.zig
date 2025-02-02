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

pub fn getRectangleCenter(rect: rl.Rectangle) rl.Vector2 {
    return .{
        .x = rect.x + rect.width / 2,
        .y = rect.y + rect.height / 2,
    };
}

pub fn screenSquare() rl.Rectangle {
    const side_length = @min(getScreenHeightf(), getScreenWidthf());
    return .{
        .x = (getScreenWidthf() - side_length) / 2,
        .y = (getScreenHeightf() - side_length) / 2,
        .width = side_length,
        .height = side_length,
    };
}
