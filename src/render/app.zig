//! This is your playground — the immediate-mode frame callback.
//!
//! `frame` is called once per display refresh with a `Canvas` to draw into and an
//! `Input` snapshot for this frame. Redraw the whole scene every call. Everything
//! you see on screen happens here; edit freely and rebuild the framework to iterate.
//!
//! Primitives available on `canvas`:
//!   canvas.clear(Color)
//!   canvas.fillRect(Rect, Color)
//!   canvas.drawText(utf8, x, y, FONT_SIZE, Color) -> Size
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

const BASE_LINE_SCRATCH_SIZE = 1024; // max rendered lines before regrow
var line_scratch: ?[]Line = null;

const FONT_SIZE: f64 = 200;
const MARGIN_PX: f64 = 100;

pub const AppState = struct {
    gap_buf: []u8,
    text_len: usize = 0,
    cursor_i: usize = 0,
    gap_end: usize = 0,
    /// Index of the top visible rendered line — how far down the view is scrolled.
    window_offset: usize = 0,

    pub fn init(gap_buf: []u8) AppState {
        return .{ .gap_buf = gap_buf, .gap_end = gap_buf.len };
    }
};

const Line = struct {
    /// byte offset relative to the start of the document
    start: usize,
    text: []const u8,
};

pub fn frame(allocator: std.mem.Allocator, canvas: *Canvas, in: Input, state: *AppState) !void {
    // Background.
    canvas.clear(Color.rgb(0.12, 0.12, 0.14));

    { // scratch setup
        if (scratch == null) {
            scratch = try allocator.alloc(u8, BASE_SCRATCH_SIZE);
        }
        if (scratch.?.len <= state.text_len) {
            defer allocator.free(scratch.?);
            scratch = try allocator.alloc(u8, scratch.?.len << 1);
        }
        if (line_scratch == null) {
            line_scratch = try allocator.alloc(Line, BASE_LINE_SCRATCH_SIZE);
        }
        if (line_scratch.?.len <= state.text_len) {
            defer allocator.free(line_scratch.?);
            line_scratch = try allocator.alloc(Line, line_scratch.?.len << 1);
        }
    }
    const measurer = Measurer{
        .content_w = canvas.size.w - (MARGIN_PX * 2),
        .ctx = canvas,
        .widthFn = measureWithCanvas,
    };

    { // Calculate the displayed text and handle inputs
        const shown = splitLines(condenseGapBuf(scratch.?, state.*), line_scratch.?, measurer);
        try handleInput(allocator, in, state, shown);
    }

    { // Render pass
        const lines = splitLines(condenseGapBuf(scratch.?, state.*), line_scratch.?, measurer);
        const text_x: f64 = MARGIN_PX;
        const line_h = canvas.measureText("M", FONT_SIZE).h;
        const visible_lines: usize = if (line_h > 0) @intFromFloat(canvas.size.h / line_h) else lines.len;
        state.window_offset = scrollToCursor(state.window_offset, cursorLine(lines, state.cursor_i), visible_lines);

        const top = @min(state.window_offset, lines.len);
        const bottom = @min(top + visible_lines, lines.len);
        var text_y: f64 = 168;
        var caret_drawn = false;
        for (lines[top..bottom]) |line| {
            _ = canvas.drawText(line.text, text_x, text_y, FONT_SIZE, Color.rgb(0.95, 0.82, 0.40));
            // At a soft-wrap boundary the cursor offset matches both the end of one
            // line and the start of the next; prefer the earlier line.
            if (!caret_drawn and state.cursor_i >= line.start and state.cursor_i <= line.start + line.text.len) {
                const caret_offset = state.cursor_i - line.start;
                const caret_x = text_x + canvas.measureText(line.text[0..caret_offset], FONT_SIZE).w;
                canvas.fillRect(.{ .x = caret_x, .y = text_y, .w = 2, .h = line_h }, Color.white);
                caret_drawn = true;
            }
            text_y += line_h;
        }
    }
}

const Measurer = struct {
    content_w: f64,
    ctx: *anyopaque,
    widthFn: *const fn (ctx: *anyopaque, text: []const u8) f64,

    fn width(self: Measurer, text: []const u8) f64 {
        return self.widthFn(self.ctx, text);
    }
};

fn measureWithCanvas(ctx: *anyopaque, text: []const u8) f64 {
    const canvas: *Canvas = @ptrCast(@alignCast(ctx));
    return canvas.measureText(text, FONT_SIZE).w;
}

/// Split `full_text` into rendered lines: hard breaks on '\n', soft wraps when a
/// run would reach `m.content_w`. Lines are written into `out` and a sub-slice of
/// it is returned. Each `Line.text` aliases `full_text`.
fn splitLines(full_text: []const u8, out: []Line, m: Measurer) []Line {
    var lineno: usize = 0;
    var logical_start: usize = 0;
    var line_splitter = std.mem.SplitIterator(u8, .any){
        .index = 0,
        .buffer = full_text,
        .delimiter = "\n",
    };
    while (line_splitter.next()) |logical_line| {
        var rendered_line_start_i: usize = 0;
        rendered_line_splitter: while (true) {
            var end = logical_line.len;
            var rendered_line = logical_line[rendered_line_start_i..end];
            while (m.width(rendered_line) >= m.content_w) {
                assert(end > rendered_line_start_i);
                end -= 1;
                rendered_line = logical_line[rendered_line_start_i..end];
            }
            out[lineno] = .{
                .start = logical_start + rendered_line_start_i,
                .text = rendered_line,
            };
            lineno += 1;
            rendered_line_start_i += rendered_line.len;
            if (rendered_line_start_i >= logical_line.len) break :rendered_line_splitter;
        }
        logical_start += logical_line.len + 1; // +1 for the '\n' the splitter consumed.
    }
    return out[0..lineno];
}

/// Index of the rendered line containing `cursor_i`. At a soft-wrap boundary the
/// offset matches two lines; the later one wins (consistent with up/down).
fn cursorLine(lines: []const Line, cursor_i: usize) usize {
    var result: usize = 0;
    for (lines, 0..) |line, i| {
        if (cursor_i >= line.start and cursor_i <= line.start + line.text.len) result = i;
    }
    return result;
}

/// Scroll the view just enough to keep `cursor_line` inside a viewport that is
/// `visible_lines` tall, given the current top line `window_offset`. Returns the
/// new top line.
fn scrollToCursor(window_offset: usize, cursor_line: usize, visible_lines: usize) usize {
    if (cursor_line < window_offset) return cursor_line; // above the viewport
    if (visible_lines > 0 and cursor_line >= window_offset + visible_lines) {
        return cursor_line - visible_lines + 1; // below the viewport
    }
    return window_offset; // already visible
}

fn handleInput(allocator: std.mem.Allocator, in: Input, state: *AppState, lines: []const Line) !void {
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

        const target: i64 = @as(i64, @intCast(state.cursor_i)) + delta;
        moveCursorTo(state, @intCast(target));
    } else if (in.ups != 0 or in.downs != 0) {
        const cursor_line = cursorLine(lines, state.cursor_i);
        const cursor_col = state.cursor_i - lines[cursor_line].start;

        const raw_new_line: i64 = @as(i64, @intCast(cursor_line)) - @as(i64, in.ups) + @as(i64, in.downs);
        const new_line: usize = @intCast(std.math.clamp(raw_new_line, 0, @as(i64, @intCast(lines.len - 1))));
        // Stackless preferred column: if the cursor sits at the end of its line,
        // stick to the end of the target line; otherwise keep the same column
        // (clamped to the target line's length).
        const at_line_end = cursor_col == lines[cursor_line].text.len;
        const new_col: usize = if (at_line_end)
            lines[new_line].text.len
        else
            @min(cursor_col, lines[new_line].text.len);

        moveCursorTo(state, lines[new_line].start + new_col);
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

/// Move the cursor to logical text position `target`, shuffling bytes through
/// the gap so the gap-buffer invariant holds: text before the cursor lives at
/// `[0..cursor_i]`, text after it at `[gap_end..]`.
fn moveCursorTo(state: *AppState, target: usize) void {
    if (target > state.cursor_i) {
        // abc|def => abcd|ef : dest (cursor) precedes src (gap_end), copy front-to-back.
        const n = target - state.cursor_i;
        std.mem.copyForwards(
            u8,
            state.gap_buf[state.cursor_i .. state.cursor_i + n],
            state.gap_buf[state.gap_end .. state.gap_end + n],
        );
        state.cursor_i += n;
        state.gap_end += n;
    } else if (target < state.cursor_i) {
        // abc|def => ab|cdef : dest (gap_end) follows src (cursor), copy back-to-front.
        const n = state.cursor_i - target;
        std.mem.copyBackwards(
            u8,
            state.gap_buf[state.gap_end - n .. state.gap_end],
            state.gap_buf[state.cursor_i - n .. state.cursor_i],
        );
        state.cursor_i -= n;
        state.gap_end -= n;
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

var fake_ctx: u8 = 0;

fn fakeWidth(_: *anyopaque, text: []const u8) f64 {
    return @floatFromInt(text.len);
}

fn testMeasurer(content_w: f64) Measurer {
    return .{ .content_w = content_w, .ctx = &fake_ctx, .widthFn = fakeWidth };
}

/// Drive `handleInput` the way `frame` does, but with the fake measurer
fn feed(state: *AppState, in: Input) !void {
    var doc_buf: [1024]u8 = undefined;
    var line_buf: [256]Line = undefined;
    const doc = condenseGapBuf(&doc_buf, state.*);
    const lines = splitLines(doc, &line_buf, testMeasurer(1_000_000));
    try handleInput(testing_allocator, in, state, lines);
}

test "splitLines breaks on newlines" {
    var out: [8]Line = undefined;
    const lines = splitLines("ab\ncd", &out, testMeasurer(1_000_000));

    try expectEqual(2, lines.len);
    try expectEqual(0, lines[0].start);
    try expectEqualStrings("ab", lines[0].text);
    try expectEqual(3, lines[1].start);
    try expectEqualStrings("cd", lines[1].text);
}

test "splitLines soft-wraps a run wider than content_w" {
    var out: [8]Line = undefined;
    // fakeWidth == byte count; content_w 4 ⇒ at most 3 bytes per line.
    const lines = splitLines("abcdef", &out, testMeasurer(4));

    try expectEqual(2, lines.len);
    try expectEqual(0, lines[0].start);
    try expectEqualStrings("abc", lines[0].text);
    try expectEqual(3, lines[1].start);
    try expectEqualStrings("def", lines[1].text);
}

test "splitLines start offsets account for newlines across wraps" {
    var out: [8]Line = undefined;
    // "abcd\nef": first logical line wraps (3 per line), then a hard break.
    const lines = splitLines("abcd\nef", &out, testMeasurer(4));

    try expectEqual(3, lines.len);
    try expectEqual(0, lines[0].start);
    try expectEqualStrings("abc", lines[0].text);
    try expectEqual(3, lines[1].start);
    try expectEqualStrings("d", lines[1].text);
    try expectEqual(5, lines[2].start); // past the 'd' (4) and the '\n' (5)
    try expectEqualStrings("ef", lines[2].text);
}

test "scrollToCursor scrolls down to reveal a cursor below the viewport" {
    // 3-tall viewport at the top (offset 0); cursor on line 5 is off the bottom.
    // Top line shifts so line 5 is the last visible: 5 - 3 + 1 = 3.
    try expectEqual(3, scrollToCursor(0, 5, 3));
}

test "scrollToCursor scrolls up to reveal a cursor above the viewport" {
    // Scrolled to line 4 (showing 4..6); cursor on line 1 is above ⇒ top = 1.
    try expectEqual(1, scrollToCursor(4, 1, 3));
}

test "scrollToCursor leaves the offset alone when the cursor is already visible" {
    // Showing lines 2..4; cursor on line 3 is within ⇒ unchanged.
    try expectEqual(2, scrollToCursor(2, 3, 3));
}

test "handleInput hello" {
    var buf: [20]u8 = undefined;
    var state = AppState.init(&buf);

    try feed(&state, .{ .text = "h" });
    try feed(&state, .{ .text = "e" });
    try feed(&state, .{ .text = "l" });
    try feed(&state, .{ .text = "l" });
    try feed(&state, .{ .text = "o" });

    try expectTextContentsEquals("hello", state);
}

test "handleInput backspace deletes the char before the cursor" {
    var buf: [20]u8 = undefined;
    var state = AppState.init(&buf);

    try feed(&state, .{ .text = "h" });
    try feed(&state, .{ .text = "i" });
    try feed(&state, .{ .backspaces = 1 });

    try expectTextContentsEquals("h", state);
}

test "handleInput backspace on empty buffer is a no-op" {
    var buf: [20]u8 = undefined;
    var state = AppState.init(&buf);

    try feed(&state, .{ .backspaces = 3 });

    try expectEqual(0, state.text_len);
    try expectEqual(0, state.cursor_i);
}

test "handleInput move cursor left and right" {
    var buf: [20]u8 = undefined;
    var state = AppState.init(&buf);

    try feed(&state, .{ .text = "b" });
    try feed(&state, .{ .text = "d" });
    // bd
    try feed(&state, .{ .lefts = 1 });
    try feed(&state, .{ .text = "c" });
    // bcd
    try feed(&state, .{ .lefts = 2 });
    try feed(&state, .{ .text = "a" });
    // abcd
    try feed(&state, .{ .rights = 5000 });
    try feed(&state, .{ .text = "e" });
    //abcde

    try expectTextContentsEquals("abcde", state);
}

test "handleInput grow buffer" {
    { // Cursor at end
        var state = AppState{ .gap_buf = try testing_allocator.alloc(u8, 1) };
        try feed(&state, .{ .text = "hello" });
        try expectTextContentsEquals("hello", state);
        testing_allocator.free(state.gap_buf);
    }
    { // Cursor at beginning
        var state = AppState{ .gap_buf = try testing_allocator.alloc(u8, 1) };
        try feed(&state, .{ .text = "o" });
        try feed(&state, .{ .lefts = 1 });
        try feed(&state, .{ .text = "l" });
        try feed(&state, .{ .lefts = 1 });
        try feed(&state, .{ .text = "l" });
        try feed(&state, .{ .lefts = 1 });
        try feed(&state, .{ .text = "e" });
        try feed(&state, .{ .lefts = 1 });
        try feed(&state, .{ .text = "h" });
        try feed(&state, .{ .lefts = 1 });
        try expectTextContentsEquals("hello", state);
        testing_allocator.free(state.gap_buf);
    }
    { // Cursor in middle
        var state = AppState{ .gap_buf = try testing_allocator.alloc(u8, 1) };
        try feed(&state, .{ .text = "[]" }); // Size is now 4
        try feed(&state, .{ .lefts = 1 });
        try feed(&state, .{ .text = "123" }); // Size is now 8
        try expectTextContentsEquals("[123]", state);
        testing_allocator.free(state.gap_buf);
    }
}

test "handleInput up-down cursor" {
    var buf: [20]u8 = undefined;
    var state = AppState.init(&buf);

    try feed(&state, .{ .text = "1\n" });
    try feed(&state, .{ .downs = 1 });
    try feed(&state, .{ .text = "3" });
    try feed(&state, .{ .ups = 1 });
    try feed(&state, .{ .text = "2" });
    try feed(&state, .{ .downs = 1 });
    try feed(&state, .{ .text = "4" });
    try expectTextContentsEquals("12\n34", state);
}

test "handleInput up-down cursor preferred column" {
    var buf: [20]u8 = undefined;
    var state = AppState.init(&buf);

    try feed(&state, .{ .text = "1234\n123\n12\n1" });
    try feed(&state, .{ .ups = 100 });
    try feed(&state, .{ .rights = 100 });
    try feed(&state, .{ .downs = 100 });
    try feed(&state, .{ .ups = 100 });
    try feed(&state, .{ .text = "5" });
    try expectTextContentsEquals("12345\n123\n12\n1", state);
}

test "handleInput up across a soft-wrapped line" {
    var buf: [20]u8 = undefined;
    var state = AppState.init(&buf);

    try feed(&state, .{ .text = "abcdef" }); // cursor at end (offset 6)

    // "abcdef" laid out as two soft-wrapped visual lines (no '\n' between them).
    // Hand-built, so this navigation is exercised with zero font dependency — only
    // `start`/`text.len` matter to the up/down logic.
    const lines = [_]Line{
        .{ .start = 0, .text = "abc" },
        .{ .start = 3, .text = "def" },
    };
    try handleInput(testing_allocator, .{ .ups = 1 }, &state, &lines);

    // Cursor sat at the end of the 2nd visual line ⇒ lands at the end of the 1st
    // (offset 3), between 'c' and 'd'.
    try feed(&state, .{ .text = "X" });
    try expectTextContentsEquals("abcXdef", state);
}
