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
const input = @import("input.zig");
const std = @import("std");
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
const testing_allocator = std.testing.allocator;
const assert = std.debug.assert;

const Color = geom.Color;
const Input = input.Input;

/// Cursor/index math casts buffer offsets through signed types (see
/// `handleInput`'s left/right movement), so the buffer length must always be
/// indexable by a u32. Every growth is asserted against this bound.
const MAX_BUF_LEN: usize = std.math.maxInt(u32);

const BASE_SCRATCH_SIZE = 1024 * 1024; // 1MB
var scratch: ?[]u8 = null;

pub const AppState = struct {
    gap_buf: []u8,
    text_len: usize = 0,
    cursor_i: usize = 0,
    gap_end: usize = 0,

    pub fn init(gap_buf: []u8) AppState {
        return .{ .gap_buf = gap_buf, .gap_end = gap_buf.len };
    }
};

pub fn frame(allocator: std.mem.Allocator, canvas: *Canvas, in: Input, state: *AppState) !void {
    // Background.
    canvas.clear(Color.rgb(0.12, 0.12, 0.14));

    // A little panel.
    canvas.fillRect(.{ .x = 40, .y = 40, .w = 360, .h = 96 }, Color.rgb(0.20, 0.20, 0.24));

    // Headline + hint.
    _ = canvas.drawText("hello, nana", 56, 60, 28, Color.white);
    _ = canvas.drawText("edit src/render/app.zig to iterate", 56, 104, 13, Color.rgb(0.62, 0.62, 0.72));

    try handleInput(allocator, in, state);
    if (scratch == null) {
        scratch = try allocator.alloc(u8, BASE_SCRATCH_SIZE);
    }
    if (scratch.?.len <= state.text_len) {
        defer allocator.free(scratch.?);
        scratch = try allocator.alloc(u8, scratch.?.len << 1);
    }
    const text_x: f64 = 56;
    const text_y: f64 = 168;
    const font_size: f64 = 20;
    const condensed = condenseGapBuf(scratch.?, state.*);
    _ = canvas.drawText(condensed, text_x, text_y, font_size, Color.rgb(0.95, 0.82, 0.40));

    const caret_x = text_x + canvas.measureText(condensed[0..state.cursor_i], font_size).w;
    const line_h = canvas.measureText("M", font_size).h;
    canvas.fillRect(.{ .x = caret_x, .y = text_y, .w = 2, .h = line_h }, Color.white);

    // A box that follows the cursor (turns warm while the button is held).
    const s: f64 = 18;
    const box_color = if (in.mouse_down) Color.rgb(0.92, 0.42, 0.42) else Color.rgb(0.40, 0.72, 0.92);
    canvas.fillRect(.{ .x = in.mouse.x - s / 2, .y = in.mouse.y - s / 2, .w = s, .h = s }, box_color);
}

fn handleInput(allocator: std.mem.Allocator, in: Input, state: *AppState) !void {
    if (in.backspaces != 0) {
        const backspaces = @min(state.cursor_i, in.backspaces);
        state.cursor_i -= backspaces;
        state.text_len -= backspaces;
    } else if (in.lefts != 0 or in.rights != 0) {
        const cursor: i64 = @intCast(state.cursor_i);
        const raw_movement: i64 = @as(i64, in.rights) - @as(i64, in.lefts);
        const delta: i64 = std.math.clamp(
            raw_movement,
            -cursor,
            @as(i64, @intCast(state.text_len)) - cursor,
        );

        if (delta > 0) {
            // delta = 1, abc def => abcd ef
            const n: usize = @intCast(delta);
            // dest (cursor) precedes src (gap_end), so copy front-to-back.
            std.mem.copyForwards(
                u8,
                state.gap_buf[state.cursor_i .. state.cursor_i + n],
                state.gap_buf[state.gap_end .. state.gap_end + n],
            );
            state.cursor_i += n;
            state.gap_end += n;
        } else if (delta < 0) {
            // delta = -1, abc def => ab cdef
            const n: usize = @intCast(-delta);
            // dest (gap_end) follows src (cursor), so copy back-to-front.
            std.mem.copyBackwards(
                u8,
                state.gap_buf[state.gap_end - n .. state.gap_end],
                state.gap_buf[state.cursor_i - n .. state.cursor_i],
            );
            state.cursor_i -= n;
            state.gap_end -= n;
        }
    } else if (in.ups != 0 or in.downs != 0) {
        // TODO
    } else if (in.text.len > 0) {
        const new_text_len = state.text_len + in.text.len;
        if (new_text_len >= state.gap_buf.len) {
            // grow the underlying buffer
            var new_buf_len: usize = state.gap_buf.len;
            while (new_buf_len <= new_text_len) new_buf_len = new_buf_len << 1;

            assert(new_buf_len <= MAX_BUF_LEN);
            var new_buf = try allocator.alloc(u8, new_buf_len);

            if (state.cursor_i > 0) {
                @memcpy(new_buf[0..state.cursor_i], state.gap_buf[0..state.cursor_i]);
            }

            assert(state.gap_buf.len >= state.gap_end);
            const new_gap_end = new_buf_len - (state.gap_buf.len - state.gap_end);
            if (state.gap_end < state.gap_buf.len) {
                @memcpy(
                    new_buf[new_gap_end..new_buf_len],
                    state.gap_buf[state.gap_end..state.gap_buf.len],
                );
            }

            allocator.free(state.gap_buf);
            state.gap_buf = new_buf;
            state.gap_end = new_gap_end;
        }
        @memcpy(state.gap_buf[state.cursor_i .. state.cursor_i + in.text.len], in.text);
        state.cursor_i += in.text.len;
        state.text_len += in.text.len;
    }
}

fn condenseGapBuf(buf: []u8, state: AppState) []u8 {
    @memcpy(buf[0..state.cursor_i], state.gap_buf[0..state.cursor_i]);
    const tail_len = state.gap_buf.len - state.gap_end;
    if (tail_len > 0) {
        @memcpy(
            buf[state.cursor_i .. state.cursor_i + tail_len],
            state.gap_buf[state.gap_end..state.gap_buf.len],
        );
    }
    buf[state.text_len] = 0;

    return buf[0..state.text_len];
}

fn expectTextContentsEquals(expected: []const u8, state: AppState) !void {
    const buflen = 1024;
    var buf: [buflen]u8 = undefined;
    assert(buflen > state.text_len + 1);

    try expectEqualStrings(expected, condenseGapBuf(&buf, state));
}

test "handleInput hello" {
    var buf: [20]u8 = undefined;
    var state = AppState.init(&buf);

    try handleInput(testing_allocator, .{ .text = "h" }, &state);
    try handleInput(testing_allocator, .{ .text = "e" }, &state);
    try handleInput(testing_allocator, .{ .text = "l" }, &state);
    try handleInput(testing_allocator, .{ .text = "l" }, &state);
    try handleInput(testing_allocator, .{ .text = "o" }, &state);

    try expectTextContentsEquals("hello", state);
}

test "handleInput backspace deletes the char before the cursor" {
    var buf: [20]u8 = undefined;
    var state = AppState.init(&buf);

    try handleInput(testing_allocator, .{ .text = "h" }, &state);
    try handleInput(testing_allocator, .{ .text = "i" }, &state);
    try handleInput(testing_allocator, .{ .backspaces = 1 }, &state);

    try expectTextContentsEquals("h", state);
}

test "handleInput backspace on empty buffer is a no-op" {
    var buf: [20]u8 = undefined;
    var state = AppState.init(&buf);

    try handleInput(testing_allocator, .{ .backspaces = 3 }, &state);

    try expectEqual(0, state.text_len);
    try expectEqual(0, state.cursor_i);
}

test "handleInput move cursor left and right" {
    var buf: [20]u8 = undefined;
    var state = AppState.init(&buf);

    try handleInput(testing_allocator, .{ .text = "b" }, &state);
    try handleInput(testing_allocator, .{ .text = "d" }, &state);
    // bd
    try handleInput(testing_allocator, .{ .lefts = 1 }, &state);
    try handleInput(testing_allocator, .{ .text = "c" }, &state);
    // bcd
    try handleInput(testing_allocator, .{ .lefts = 2 }, &state);
    try handleInput(testing_allocator, .{ .text = "a" }, &state);
    // abcd
    try handleInput(testing_allocator, .{ .rights = 5000 }, &state);
    try handleInput(testing_allocator, .{ .text = "e" }, &state);
    //abcde

    try expectTextContentsEquals("abcde", state);
}

test "handleInput grow buffer" {
    { // Cursor at end
        var state = AppState{ .gap_buf = try testing_allocator.alloc(u8, 1) };
        try handleInput(testing_allocator, .{ .text = "hello" }, &state);
        std.debug.print("State: {}\n", .{state});
        try expectTextContentsEquals("hello", state);
        testing_allocator.free(state.gap_buf);
    }
    { // Cursor at beginning
        var state = AppState{ .gap_buf = try testing_allocator.alloc(u8, 1) };
        try handleInput(testing_allocator, .{ .text = "o" }, &state);
        try handleInput(testing_allocator, .{ .lefts = 1 }, &state);
        try handleInput(testing_allocator, .{ .text = "l" }, &state);
        try handleInput(testing_allocator, .{ .lefts = 1 }, &state);
        try handleInput(testing_allocator, .{ .text = "l" }, &state);
        try handleInput(testing_allocator, .{ .lefts = 1 }, &state);
        try handleInput(testing_allocator, .{ .text = "e" }, &state);
        try handleInput(testing_allocator, .{ .lefts = 1 }, &state);
        try handleInput(testing_allocator, .{ .text = "h" }, &state);
        try handleInput(testing_allocator, .{ .lefts = 1 }, &state);
        std.debug.print("State: {}\n", .{state});
        try expectTextContentsEquals("hello", state);
        testing_allocator.free(state.gap_buf);
    }
    { // Cursor in middle
        var state = AppState{ .gap_buf = try testing_allocator.alloc(u8, 1) };
        try handleInput(testing_allocator, .{ .text = "[]" }, &state); // Size is now 4
        try handleInput(testing_allocator, .{ .lefts = 1 }, &state);
        try handleInput(testing_allocator, .{ .text = "123" }, &state); // Size is now 8
        try expectTextContentsEquals("[123]", state);
        testing_allocator.free(state.gap_buf);
    }
}
