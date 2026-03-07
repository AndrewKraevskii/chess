const std = @import("std");
const Sse = @This();
const Writer = std.Io.Writer;

body_writer: *Writer,
writer: Writer,
state: enum {
    nothing,
    started_event,
    writing_event,
},

pub const Type = enum {
    datastar_patch_elements,
    datastar_patch_signals,

    pub fn cebab(t: Type) []const u8 {
        return switch (t) {
            .datastar_patch_elements => "datastar-patch-elements",
            .datastar_patch_signals => "datastar-patch-signals",
        };
    }
};
pub const std_http_options: std.http.Server.Request.RespondStreamingOptions = .{
    .respond_options = .{
        .extra_headers = &.{
            .{ .name = "cache-control", .value = "no-cache" },
            .{ .name = "content-type", .value = "text/event-stream" },
            .{ .name = "connection", .value = "keep-alive" },
        },
        .transfer_encoding = .chunked,
    },
};

pub fn init(write: *Writer, buffer: []u8) Sse {
    return .{
        .body_writer = write,
        .writer = .{
            .buffer = buffer,
            .vtable = &.{
                .drain = drain,
            },
        },
        .state = .nothing,
    };
}
pub const EventOptions = struct {
    use_view_transition: bool = false,
};

pub fn beginEvent(sse: *Sse, event_type: Type, options: EventOptions) !void {
    std.debug.assert(sse.state == .nothing);
    try sse.body_writer.print(
        "event: {s}\n",
        .{event_type.cebab()},
    );
    if (options.use_view_transition) {
        try sse.body_writer.writeAll(
            "data: useViewTransition true\n",
        );
    }
    sse.state = .started_event;
}
const start_of_element_patch = "\ndata: elements ";

fn writeSseFormatedString(writer: *Writer, text: []const u8) !usize {
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

fn drain(w: *Writer, data: []const []const u8, splat: usize) error{WriteFailed}!usize {
    const sse: *Sse = @fieldParentPtr("writer", w);
    if (sse.state == .started_event) {
        try sse.body_writer.writeAll(start_of_element_patch[1..]);
        sse.state = .writing_event;
    }
    var count: usize = 0;
    count += try writeSseFormatedString(sse.body_writer, w.buffered());
    w.end = 0;
    for (data[0 .. data.len - 1]) |datum| {
        count += try writeSseFormatedString(sse.body_writer, datum);
    }
    for (0..splat) |_| {
        count += try writeSseFormatedString(sse.body_writer, data[data.len - 1]);
    }

    return count;
}

pub fn endEvent(s: *Sse) !void {
    std.debug.assert(s.state != .nothing);
    try s.writer.flush();
    try s.body_writer.writeAll("\n\n");
    try s.body_writer.flush();
    s.state = .nothing;
}

test Sse {
    {
        var allocating: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer allocating.deinit();
        var buffer: [0x1000]u8 = undefined;
        var sse: Sse = .init(&allocating.writer, &buffer);
        try sse.beginEvent(.datastar_patch_elements, .{});

        try sse.writer.writeAll(
            \\<div>
            \\    <div></div>
            \\</div>
        );
        try sse.endEvent();

        try std.testing.expectEqualStrings(
            \\event: datastar-patch-elements
            \\data: elements <div>
            \\data: elements     <div></div>
            \\data: elements </div>
            \\
            \\
        , allocating.writer.buffered());
    }
    {
        var allocating: std.Io.Writer.Allocating = .init(std.testing.allocator);
        defer allocating.deinit();
        var buffer: [0x1000]u8 = undefined;
        var sse: Sse = .init(&allocating.writer, &buffer);
        try sse.beginEvent(.datastar_patch_elements, .{ .use_view_transition = true });

        try sse.writer.writeAll(
            \\<div>
            \\    <div></div>
            \\</div>
        );
        try sse.endEvent();

        try std.testing.expectEqualStrings(
            \\event: datastar-patch-elements
            \\data: useViewTransition true
            \\data: elements <div>
            \\data: elements     <div></div>
            \\data: elements </div>
            \\
            \\
        , allocating.writer.buffered());
    }
}
