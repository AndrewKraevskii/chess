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

pub fn scaleRectangleFromCenter(rect: rl.Rectangle, scale: f32) rl.Rectangle {
    const center = getRectangleCenter(rect);
    return .{
        .x = (rect.x - center.x) * scale + center.x,
        .y = (rect.y - center.y) * scale + center.y,
        .width = rect.width * scale,
        .height = rect.height * scale,
    };
}

pub fn moveRectangle(rect: rl.Rectangle, vec: rl.Vector2) rl.Rectangle {
    return .{
        .x = rect.x + vec.x,
        .y = rect.y + vec.y,
        .width = rect.width,
        .height = rect.height,
    };
}

pub fn normalizeInRectangle(rect: rl.Rectangle, pos: rl.Vector2) rl.Vector2 {
    return pos.subtract(.init(rect.x, rect.y)).divide(.init(rect.width, rect.height));
}
