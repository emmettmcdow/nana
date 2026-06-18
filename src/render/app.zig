//! This is your playground — the immediate-mode frame callback.
//!
//! `frame` is called once per display refresh with a `Canvas` to draw into and an
//! `Input` snapshot for this frame. Redraw the whole scene every call. Everything
//! you see on screen happens here; edit freely and rebuild the framework to iterate.
//!
//! Primitives available on `canvas`:
//!   canvas.clear(Color)
//!   canvas.fillRect(Rect, Color)
//!   canvas.drawText(utf8, x, y, font_size, Color) -> Size
//!   canvas.measureText(utf8, font_size) -> Size

const geom = @import("geom.zig");
const Canvas = @import("canvas.zig").Canvas;
const Input = @import("input.zig").Input;
const std = @import("std");
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

const Color = geom.Color;

pub const AppState = struct {
    gap_buf: []u8,
    buf_len: usize = 0,
    cursor_i: usize = 0,
};

pub fn frame(canvas: *Canvas, in: Input, state: *AppState) void {
    // Background.
    canvas.clear(Color.rgb(0.12, 0.12, 0.14));

    // A little panel.
    canvas.fillRect(.{ .x = 40, .y = 40, .w = 360, .h = 96 }, Color.rgb(0.20, 0.20, 0.24));

    // Headline + hint.
    _ = canvas.drawText("hello, nana", 56, 60, 28, Color.white);
    _ = canvas.drawText("edit src/render/app.zig to iterate", 56, 104, 13, Color.rgb(0.62, 0.62, 0.72));

    handleInput(in, state);
    _ = canvas.drawText(state.gap_buf[0..state.buf_len], 56, 168, 20, Color.rgb(0.95, 0.82, 0.40));

    // A box that follows the cursor (turns warm while the button is held).
    const s: f64 = 18;
    const box_color = if (in.mouse_down) Color.rgb(0.92, 0.42, 0.42) else Color.rgb(0.40, 0.72, 0.92);
    canvas.fillRect(.{ .x = in.mouse.x - s / 2, .y = in.mouse.y - s / 2, .w = s, .h = s }, box_color);
}

fn handleInput(in: Input, state: *AppState) void {
    if (in.text.len > 0) {
        @memcpy(state.gap_buf[state.cursor_i .. state.cursor_i + in.text.len], in.text);
        state.cursor_i += in.text.len;
        state.buf_len += 1;
    }
}

test "handleInput hello" {
    var buf: [20]u8 = undefined;
    var state = AppState{ .gap_buf = &buf };

    handleInput(.{ .text = "h" }, &state);
    handleInput(.{ .text = "e" }, &state);
    handleInput(.{ .text = "l" }, &state);
    handleInput(.{ .text = "l" }, &state);
    handleInput(.{ .text = "o" }, &state);

    try expectEqual(5, state.buf_len);
    try expectEqual(5, state.cursor_i);
    try expectEqualStrings("hello", state.gap_buf[0..state.buf_len]);
}
