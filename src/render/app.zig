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
const mod_shift = input.mod_shift;

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

const TEXT_COLOR: Color = Color.rgb(0.95, 0.82, 0.40);
const HIGHLIGHT_COLOR: Color = .{ .r = TEXT_COLOR.r, .g = TEXT_COLOR.g, .b = TEXT_COLOR.b, .a = 0.25 };

pub const AppState = struct {
    gap_buf: []u8,
    text_len: usize = 0,
    cursor_i: usize = 0,
    gap_end: usize = 0,
    /// Index of the top visible rendered line — how far down the view is scrolled.
    window_offset: usize = 0,
    selection_anchor: ?usize = null,
    mouse_was_down: bool = false,

    pub fn init(gap_buf: []u8) AppState {
        return .{ .gap_buf = gap_buf, .gap_end = gap_buf.len };
    }
    fn assertInvariant(self: AppState) void {
        assert(self.text_len == self.cursor_i + (self.gap_buf.len - self.gap_end));
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

    { // debug
        var buf: [64]u8 = undefined;
        const font_size: f64 = 24.0;
        _ = canvas.drawText(
            std.fmt.bufPrint(&buf, "mouse: ({d}, {d})", .{
                @as(i64, @intFromFloat(in.mouse.x)),
                @as(i64, @intFromFloat(in.mouse.y)),
            }) catch unreachable,
            0,
            canvas.size.h - font_size,
            font_size,
            TEXT_COLOR,
        );
    }

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
        .line_h = canvas.measureText("M", FONT_SIZE).h,
        .ctx = canvas,
        .widthFn = measureWithCanvas,
    };

    { // Calculate the displayed text and handle inputs
        const shown = splitLines(condenseGapBuf(scratch.?, state.*), line_scratch.?, measurer);
        try handleInput(allocator, in, state, shown, measurer);
    }

    { // Render pass
        const lines = splitLines(condenseGapBuf(scratch.?, state.*), line_scratch.?, measurer);
        const text_x: f64 = MARGIN_PX;
        const line_h = measurer.line_h;
        const visible_lines: usize = if (line_h > 0) @intFromFloat(canvas.size.h / line_h) else lines.len;
        state.window_offset = scrollToCursor(state.window_offset, cursorLine(lines, state.cursor_i), visible_lines);

        const top = @min(state.window_offset, lines.len);
        const bottom = @min(top + visible_lines, lines.len);
        var text_y: f64 = MARGIN_PX;
        var caret_drawn = false;
        for (lines[top..bottom]) |line| {
            { // selection rendering
                const cursor_in_line = state.cursor_i >= line.start and state.cursor_i <= line.start + line.text.len;
                const anchor_in_line = state.selection_anchor != null and state.selection_anchor.? >= line.start and state.selection_anchor.? <= line.start + line.text.len;
                if (cursor_in_line and !caret_drawn) {
                    // At a soft-wrap boundary the cursor offset matches both the end
                    // of one line and the start of the next; prefer the earlier line.
                    const caret_offset = state.cursor_i - line.start;
                    const caret_x = text_x + canvas.measureText(line.text[0..caret_offset], FONT_SIZE).w;
                    canvas.fillRect(.{ .x = caret_x, .y = text_y, .w = 2, .h = line_h }, Color.white);
                    caret_drawn = true;
                }
                if (cursor_in_line and anchor_in_line) {
                    if (state.selection_anchor) |anchor| {
                        const anchor_offset: usize = anchor - line.start;
                        const caret_offset = state.cursor_i - line.start;
                        const caret_x = text_x + canvas.measureText(line.text[0..caret_offset], FONT_SIZE).w;
                        var box_start_x: f64 = undefined;
                        var selection_w: f64 = undefined;
                        if (anchor_offset < caret_offset) {
                            selection_w = canvas.measureText(line.text[anchor_offset..caret_offset], FONT_SIZE).w;
                            box_start_x = caret_x - selection_w;
                        } else {
                            selection_w = canvas.measureText(line.text[caret_offset..anchor_offset], FONT_SIZE).w;
                            box_start_x = caret_x;
                        }
                        canvas.fillRect(.{ .x = box_start_x, .y = text_y, .w = selection_w, .h = line_h }, HIGHLIGHT_COLOR);
                    } else unreachable;
                } else if (cursor_in_line and state.selection_anchor != null) {
                    // Selection anchor is on another line
                    if (state.selection_anchor.? < state.cursor_i) {
                        const caret_offset = state.cursor_i - line.start;
                        const selection_w: f64 = canvas.measureText(line.text[0..caret_offset], FONT_SIZE).w;
                        canvas.fillRect(.{ .x = text_x, .y = text_y, .w = selection_w, .h = line_h }, HIGHLIGHT_COLOR);
                    } else {
                        const caret_offset = state.cursor_i - line.start;
                        const selection_w: f64 = canvas.measureText(line.text[caret_offset..line.text.len], FONT_SIZE).w;
                        const caret_x = text_x + canvas.measureText(line.text[0..caret_offset], FONT_SIZE).w;
                        canvas.fillRect(.{ .x = caret_x, .y = text_y, .w = selection_w, .h = line_h }, HIGHLIGHT_COLOR);
                    }
                } else if (anchor_in_line) {
                    // Cursor is on another line
                    if (state.selection_anchor.? < state.cursor_i) {
                        const anchor_offset = state.selection_anchor.? - line.start;
                        const selection_w: f64 = canvas.measureText(line.text[anchor_offset..line.text.len], FONT_SIZE).w;
                        const anchor_x = text_x + canvas.measureText(line.text[0..anchor_offset], FONT_SIZE).w;
                        canvas.fillRect(.{ .x = anchor_x, .y = text_y, .w = selection_w, .h = line_h }, HIGHLIGHT_COLOR);
                    } else {
                        const anchor_offset = state.selection_anchor.? - line.start;
                        const selection_w: f64 = canvas.measureText(line.text[0..anchor_offset], FONT_SIZE).w;
                        canvas.fillRect(.{ .x = text_x, .y = text_y, .w = selection_w, .h = line_h }, HIGHLIGHT_COLOR);
                    }
                } else if (state.selection_anchor != null and
                    line.start > @min(state.selection_anchor.?, state.cursor_i) and
                    (line.start + line.text.len) < @max(state.selection_anchor.?, state.cursor_i))
                {
                    // Line is between the anchor and cursor
                    const selection_w: f64 = canvas.measureText(line.text[0..line.text.len], FONT_SIZE).w;
                    canvas.fillRect(.{ .x = text_x, .y = text_y, .w = selection_w, .h = line_h }, HIGHLIGHT_COLOR);
                }
            }
            _ = canvas.drawText(line.text, text_x, text_y, FONT_SIZE, TEXT_COLOR);
            text_y += line_h;
        }
    }
}

const Measurer = struct {
    content_w: f64,
    line_h: f64,
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

fn handleInput(allocator: std.mem.Allocator, in: Input, state: *AppState, lines: []const Line, measurer: Measurer) !void {
    state.assertInvariant();
    var cursor_target: ?usize = null;
    if (in.mouse_down) {
        const mouse_offset: usize = cursor: { // point to offset
            var lineno: usize = lines.len - 1;
            var curr_y: f64 = MARGIN_PX;
            for (state.window_offset..lines.len) |i| {
                if (in.mouse.y < curr_y + measurer.line_h) {
                    lineno = i;
                    break;
                }
                curr_y += measurer.line_h;
            }
            var col: usize = lines[lineno].text.len;
            var curr_x: f64 = MARGIN_PX;
            for (0..lines[lineno].text.len) |i| {
                const char_width = measurer.width(lines[lineno].text[i .. i + 1]);
                if (in.mouse.x < curr_x + (char_width / 2.0)) {
                    col = i;
                    break;
                }
                curr_x += char_width;
            }
            break :cursor lines[lineno].start + col;
        };
        if (state.mouse_was_down) {
            cursor_target = mouse_offset;
        } else {
            state.mouse_was_down = true;
            state.selection_anchor = mouse_offset;
            cursor_target = mouse_offset;
        }
    } else if (!in.mouse_down and state.mouse_was_down) { // Click release
        state.mouse_was_down = false;
        // A click (press+release without moving) leaves an empty selection;
        // collapse it so only a real drag keeps the anchor.
        if (state.selection_anchor == state.cursor_i) state.selection_anchor = null;
    } else if (in.backspaces != 0) {
        if (state.selection_anchor) |anchor| {
            if (state.cursor_i > anchor) {
                // Selection is in the before-cursor region; drop it by moving the
                // cursor back to the anchor (extends the gap leftward).
                const backspaces = state.cursor_i - anchor;
                state.cursor_i = anchor;
                state.text_len -= backspaces;
            } else {
                // Selection is in the tail; drop it by advancing the gap end past it.
                const backspaces = anchor - state.cursor_i;
                state.gap_end += backspaces;
                state.text_len -= backspaces;
            }
            state.selection_anchor = null;
        } else {
            const backspaces = @min(state.cursor_i, in.backspaces);
            state.cursor_i -= backspaces;
            state.text_len -= backspaces;
        }
    } else if ((in.lefts | in.rights | in.ups | in.downs) != 0) {
        const horz_pressed = (in.lefts | in.rights) != 0;
        const vert_pressed = (in.ups | in.downs) != 0;
        const shift_pressed = (in.modifiers & mod_shift) != 0;
        const has_anchor = state.selection_anchor != null;

        if (shift_pressed and !has_anchor) {
            state.selection_anchor = state.cursor_i;
        }

        cursor_target = if (has_anchor and horz_pressed and !shift_pressed) collapse: {
            defer state.selection_anchor = null;
            if (in.lefts != 0) {
                break :collapse @min(state.cursor_i, state.selection_anchor.?);
            } else {
                assert(in.rights != 0);
                break :collapse @max(state.cursor_i, state.selection_anchor.?);
            }
        } else if (horz_pressed) leftright: {
            const cursor: i64 = @intCast(state.cursor_i);
            const raw_movement: i64 = @as(i64, in.rights) - @as(i64, in.lefts);
            const delta: i64 = std.math.clamp(
                raw_movement,
                -cursor,
                @as(i64, @intCast(state.text_len)) - cursor,
            );

            break :leftright @as(usize, @intCast(@as(i64, @intCast(state.cursor_i)) + delta));
        } else updown: {
            assert(vert_pressed);
            if (!shift_pressed and state.selection_anchor != null) state.selection_anchor = null;
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

            break :updown lines[new_line].start + new_col;
        };
    } else if (in.text.len > 0) {
        if (state.selection_anchor) |anchor| {
            if (anchor > state.cursor_i) {
                // Selection is in the tail; drop it by advancing the gap end past it.
                const removed = anchor - state.cursor_i;
                state.gap_end += removed;
                state.text_len -= removed;
            } else {
                // Selection is in the before-cursor region; drop it by moving the
                // cursor back to the anchor (extends the gap leftward).
                state.text_len -= state.cursor_i - anchor;
                state.cursor_i = anchor;
            }
            state.selection_anchor = null;
        }
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
        // Insert only real document content; drop control/non-printable bytes
        for (in.text) |byte| {
            const is_control_byte = (byte < 0x20 and byte != '\n') or byte == 0x7f;
            if (is_control_byte) continue;
            state.gap_buf[state.cursor_i] = byte;
            state.cursor_i += 1;
            state.text_len += 1;
        }
    }
    if (cursor_target) |target| { // Move the cursor and adjust the gap buf
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
}

fn condenseGapBuf(buf: []u8, state: AppState) []u8 {
    state.assertInvariant();
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
    return .{ .content_w = content_w, .line_h = 1, .ctx = &fake_ctx, .widthFn = fakeWidth };
}

/// Drive `handleInput` the way `frame` does, but with the fake measurer
fn feed(state: *AppState, in: Input) !void {
    var doc_buf: [1024]u8 = undefined;
    var line_buf: [256]Line = undefined;
    const measurer = testMeasurer(1_000_000);
    const doc = condenseGapBuf(&doc_buf, state.*);
    const lines = splitLines(doc, &line_buf, measurer);
    try handleInput(testing_allocator, in, state, lines, measurer);
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

test "handleInput type at end of line in middle of document" {
    var buf: [20]u8 = undefined;
    var state = AppState.init(&buf);

    try feed(&state, .{ .text = "abc\ndef\nghi" });
    try expectTextContentsEquals("abc\ndef\nghi", state);
    try feed(&state, .{ .ups = 1 });
    try feed(&state, .{ .text = "X" });
    try expectTextContentsEquals("abc\ndefX\nghi", state);
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
        var state = AppState.init(try testing_allocator.alloc(u8, 1));
        try feed(&state, .{ .text = "hello" });
        try expectTextContentsEquals("hello", state);
        testing_allocator.free(state.gap_buf);
    }
    { // Cursor at beginning
        var state = AppState.init(try testing_allocator.alloc(u8, 1));
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
        var state = AppState.init(try testing_allocator.alloc(u8, 1));
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
    try handleInput(testing_allocator, .{ .ups = 1 }, &state, &lines, testMeasurer(1_000_000));

    // Cursor sat at the end of the 2nd visual line ⇒ lands at the end of the 1st
    // (offset 3), between 'c' and 'd'.
    try feed(&state, .{ .text = "X" });
    try expectTextContentsEquals("abcXdef", state);
}

test "selection: plain movement never creates a selection" {
    var buf: [20]u8 = undefined;
    var state = AppState.init(&buf);
    try feed(&state, .{ .text = "abc" });

    try feed(&state, .{ .lefts = 1 });
    try expectEqual(@as(?usize, null), state.selection_anchor);
    try expectEqual(2, state.cursor_i);
}

test "selection: shift+right starts and extends a selection" {
    var buf: [20]u8 = undefined;
    var state = AppState.init(&buf);
    try feed(&state, .{ .text = "abc" });
    try feed(&state, .{ .lefts = 3 }); // cursor at 0

    try feed(&state, .{ .rights = 1, .modifiers = mod_shift });
    try expectEqual(@as(?usize, 0), state.selection_anchor);
    try expectEqual(1, state.cursor_i);

    try feed(&state, .{ .rights = 1, .modifiers = mod_shift });
    try expectEqual(@as(?usize, 0), state.selection_anchor); // anchor stays put
    try expectEqual(2, state.cursor_i); // range [0,2] = "ab"
}

test "selection: shift+left extends leftward (anchor right of cursor)" {
    var buf: [20]u8 = undefined;
    var state = AppState.init(&buf);
    try feed(&state, .{ .text = "abc" }); // cursor at 3

    try feed(&state, .{ .lefts = 2, .modifiers = mod_shift });
    try expectEqual(@as(?usize, 3), state.selection_anchor);
    try expectEqual(1, state.cursor_i); // range [1,3] = "bc"
}

test "selection: a plain right collapses to the right edge" {
    var buf: [20]u8 = undefined;
    var state = AppState.init(&buf);
    try feed(&state, .{ .text = "abc" });
    try feed(&state, .{ .lefts = 3 }); // cursor 0
    try feed(&state, .{ .rights = 2, .modifiers = mod_shift }); // range [0,2]

    try feed(&state, .{ .rights = 1 }); // plain
    try expectEqual(@as(?usize, null), state.selection_anchor);
    try expectEqual(2, state.cursor_i); // right edge, no extra step
}

test "selection: a plain left collapses to the left edge" {
    var buf: [20]u8 = undefined;
    var state = AppState.init(&buf);
    try feed(&state, .{ .text = "abc" }); // cursor 3
    try feed(&state, .{ .lefts = 2, .modifiers = mod_shift }); // range [1,3], cursor 1

    try feed(&state, .{ .lefts = 1 }); // plain
    try expectEqual(@as(?usize, null), state.selection_anchor);
    try expectEqual(1, state.cursor_i); // left edge, no extra step
}

test "selection: typing replaces the selected range" {
    var buf: [20]u8 = undefined;
    var state = AppState.init(&buf);
    try feed(&state, .{ .text = "abc" });
    try feed(&state, .{ .lefts = 3 }); // cursor 0
    try feed(&state, .{ .rights = 2, .modifiers = mod_shift }); // select "ab"

    try feed(&state, .{ .text = "X" });
    try expectTextContentsEquals("Xc", state);
    try expectEqual(@as(?usize, null), state.selection_anchor);
    try expectEqual(1, state.cursor_i); // after inserted "X"
}

test "selection: backspace deletes the selected range" {
    var buf: [20]u8 = undefined;
    var state = AppState.init(&buf);
    try feed(&state, .{ .text = "abc" });
    try feed(&state, .{ .lefts = 3 }); // cursor 0
    try feed(&state, .{ .rights = 2, .modifiers = mod_shift }); // select "ab"

    try feed(&state, .{ .backspaces = 1 });
    try expectTextContentsEquals("c", state);
    try expectEqual(@as(?usize, null), state.selection_anchor);
    try expectEqual(0, state.cursor_i);
}

test "selection: backspace deletes a leftward selection too" {
    var buf: [20]u8 = undefined;
    var state = AppState.init(&buf);
    try feed(&state, .{ .text = "abc" }); // cursor 3
    try feed(&state, .{ .lefts = 2, .modifiers = mod_shift }); // select "bc": anchor 3, cursor 1

    try feed(&state, .{ .backspaces = 1 });
    try expectTextContentsEquals("a", state);
    try expectEqual(@as(?usize, null), state.selection_anchor);
    try expectEqual(1, state.cursor_i); // range start
}

test "selection: shift+down extends across lines" {
    var buf: [20]u8 = undefined;
    var state = AppState.init(&buf);
    try feed(&state, .{ .text = "ab\ncd" }); // cursor at end (5)
    try feed(&state, .{ .lefts = 5 }); // cursor 0

    try feed(&state, .{ .downs = 1, .modifiers = mod_shift });
    try expectEqual(@as(?usize, 0), state.selection_anchor);
    try expectEqual(3, state.cursor_i); // down one line from col 0 ⇒ offset 3
}

test "selection: plain up/down resets the anchor" {
    var buf: [20]u8 = undefined;
    var state = AppState.init(&buf);
    try feed(&state, .{ .text = "ab\ncd" });
    try feed(&state, .{ .lefts = 5 }); // cursor 0

    // shift+down selects; a plain down clears the anchor.
    try feed(&state, .{ .downs = 1, .modifiers = mod_shift });
    try expectEqual(@as(?usize, 0), state.selection_anchor);
    try feed(&state, .{ .downs = 1 });
    try expectEqual(@as(?usize, null), state.selection_anchor);

    // shift+up selects again; a plain up clears the anchor.
    try feed(&state, .{ .ups = 1, .modifiers = mod_shift });
    try expectEqual(@as(?usize, 3), state.selection_anchor);
    try feed(&state, .{ .ups = 1 });
    try expectEqual(@as(?usize, null), state.selection_anchor);
}

test "selection: backspace on a leftward selection keeps trailing text" {
    var buf: [20]u8 = undefined;
    var state = AppState.init(&buf);
    try feed(&state, .{ .text = "abcde" });
    try feed(&state, .{ .lefts = 2 }); // cursor at 3, trailing "de" after it

    // Select "bc" leftward: anchor 3 (right edge), cursor 1 (left edge).
    try feed(&state, .{ .lefts = 2, .modifiers = mod_shift });
    try expectEqual(@as(?usize, 3), state.selection_anchor);
    try expectEqual(1, state.cursor_i);

    try feed(&state, .{ .backspaces = 1 });
    try expectTextContentsEquals("ade", state); // "bc" gone, "de" preserved
    try expectEqual(@as(?usize, null), state.selection_anchor);
    try expectEqual(1, state.cursor_i);
}

test "selection: typing over a leftward selection keeps trailing text" {
    var buf: [20]u8 = undefined;
    var state = AppState.init(&buf);
    try feed(&state, .{ .text = "abcde" });
    try feed(&state, .{ .lefts = 2 }); // cursor at 3, trailing "de" after it

    // Select "bc" leftward: anchor 3 (right edge), cursor 1 (left edge).
    try feed(&state, .{ .lefts = 2, .modifiers = mod_shift });

    try feed(&state, .{ .text = "X" });
    try expectTextContentsEquals("aXde", state); // "bc" replaced, "de" preserved
    try expectEqual(@as(?usize, null), state.selection_anchor);
    try expectEqual(2, state.cursor_i); // after inserted "X"
}

test "selection: shift+up selection then backspace keeps trailing text" {
    var buf: [20]u8 = undefined;
    var state = AppState.init(&buf);
    try feed(&state, .{ .text = "ab\ncd\nef" }); // cursor at end (8)
    try feed(&state, .{ .ups = 1 }); // cursor on the "cd" line (offset 5)

    // shift+up makes an upward (leftward) selection with "ef" trailing after it.
    try feed(&state, .{ .ups = 1, .modifiers = mod_shift });
    try feed(&state, .{ .backspaces = 1 });
    try expectTextContentsEquals("ab\nef", state);
    try expectEqual(@as(?usize, null), state.selection_anchor);
}

test "handleInput ignores non-alphanumeric input we don't define" {
    var buf: [20]u8 = undefined;
    var state = AppState.init(&buf);

    // Keys we don't explicitly handle (escape, forward-delete, NUL, bell) arrive
    // through `in.text` as control characters and must not be inserted into the
    // document. (Characters we do support — letters, digits, punctuation, '\n' —
    // are covered by the other handleInput tests.)
    try feed(&state, .{ .text = "\x1b" }); // escape
    try feed(&state, .{ .text = "\x7f" }); // forward delete
    try feed(&state, .{ .text = "\x00" }); // NUL
    try feed(&state, .{ .text = "\x07" }); // bell

    try expectEqual(0, state.text_len);
    try expectTextContentsEquals("", state);
}

// ─── Mouse selection (NOT YET IMPLEMENTED — these define the contract) ────────
//
// handleInput ignores the mouse today, so these are red until hit-testing lands.
//
// Coordinate model (matches the render pass + `testMeasurer`): text origin is
// (MARGIN_PX, MARGIN_PX); `fakeWidth` is 1 unit per byte and `line_h` is 1, so for
// a click at (x, y):
//   column = clamp(x - MARGIN_PX, 0, line.text.len)
//   line   = window_offset + (y - MARGIN_PX) / line_h     (clamped to last line)
//   offset = line.start + column
//
// Interaction model (standard editor behaviour):
//   * Press (button transitions to down): caret moves to the hit offset and a
//     fresh selection is anchored there.
//   * Drag (button held, pointer moved): caret follows the pointer; the anchor
//     stays at the press offset, so the selection spans [press, current].
//   * Click (press then release without moving): the empty selection collapses —
//     `selection_anchor` becomes null and the caret sits at the click offset.
// The tests assert the observable state after a complete gesture, not mid-drag.

const X0 = MARGIN_PX; // x of column 0
const Y0 = MARGIN_PX; // y of the first visible line (line_h == 1 under testMeasurer)

test "mouse: drag selects a range" {
    var buf: [20]u8 = undefined;
    var state = AppState.init(&buf);
    try feed(&state, .{ .text = "abcde" });

    try feed(&state, .{ .mouse = .{ .x = X0 + 1, .y = Y0 }, .mouse_down = true }); // press at offset 1
    try expectEqual(@as(?usize, 1), state.selection_anchor);
    try expectEqual(1, state.cursor_i);

    try feed(&state, .{ .mouse = .{ .x = X0 + 4, .y = Y0 }, .mouse_down = true }); // drag to offset 4
    try expectEqual(@as(?usize, 1), state.selection_anchor);
    try expectEqual(4, state.cursor_i);

    try feed(&state, .{ .mouse = .{ .x = X0 + 4, .y = Y0 }, .mouse_down = false }); // release
    try expectEqual(@as(?usize, 1), state.selection_anchor);
    try expectEqual(4, state.cursor_i);
}

test "mouse: a click places the caret and clears the selection" {
    var buf: [20]u8 = undefined;
    var state = AppState.init(&buf);
    try feed(&state, .{ .text = "abcde" });
    try feed(&state, .{ .lefts = 2, .modifiers = mod_shift }); // keyboard-select [3,5]

    try feed(&state, .{ .mouse = .{ .x = X0 + 1, .y = Y0 }, .mouse_down = true }); // click offset 1
    try feed(&state, .{ .mouse = .{ .x = X0 + 1, .y = Y0 }, .mouse_down = false });

    try expectEqual(@as(?usize, null), state.selection_anchor);
    try expectEqual(1, state.cursor_i);
}

test "mouse: a click lands on the correct line in a multi-line document" {
    var buf: [20]u8 = undefined;
    var state = AppState.init(&buf);
    try feed(&state, .{ .text = "ab\ncd" }); // lines: {0,"ab"}, {3,"cd"}

    // Click column 1 of the second visual line → offset 4 (between 'c' and 'd').
    try feed(&state, .{ .mouse = .{ .x = X0 + 1, .y = Y0 + 1 }, .mouse_down = true });
    try feed(&state, .{ .mouse = .{ .x = X0 + 1, .y = Y0 + 1 }, .mouse_down = false });

    try expectEqual(@as(?usize, null), state.selection_anchor);
    try expectEqual(4, state.cursor_i);
}

test "mouse: a fresh click discards a prior mouse selection" {
    var buf: [20]u8 = undefined;
    var state = AppState.init(&buf);
    try feed(&state, .{ .text = "abcde" });

    // Drag-select [1,4].
    try feed(&state, .{ .mouse = .{ .x = X0 + 1, .y = Y0 }, .mouse_down = true });
    try feed(&state, .{ .mouse = .{ .x = X0 + 4, .y = Y0 }, .mouse_down = true });
    try feed(&state, .{ .mouse = .{ .x = X0 + 4, .y = Y0 }, .mouse_down = false });

    // A new click elsewhere must start over, not extend from the old anchor.
    try feed(&state, .{ .mouse = .{ .x = X0, .y = Y0 }, .mouse_down = true }); // click offset 0
    try feed(&state, .{ .mouse = .{ .x = X0, .y = Y0 }, .mouse_down = false });

    try expectEqual(@as(?usize, null), state.selection_anchor);
    try expectEqual(0, state.cursor_i);
}

test "mouse: caret tracks the pointer while held, anchor stays put" {
    var buf: [20]u8 = undefined;
    var state = AppState.init(&buf);
    try feed(&state, .{ .text = "abcde" });

    try feed(&state, .{ .mouse = .{ .x = X0 + 1, .y = Y0 }, .mouse_down = true }); // press at offset 1
    try expectEqual(@as(?usize, 1), state.selection_anchor);

    // Caret follows the pointer across several held frames; the anchor never moves,
    // and the selection can flip to the left of the anchor.
    try feed(&state, .{ .mouse = .{ .x = X0 + 4, .y = Y0 }, .mouse_down = true });
    try expectEqual(@as(?usize, 1), state.selection_anchor);
    try expectEqual(4, state.cursor_i);

    try feed(&state, .{ .mouse = .{ .x = X0, .y = Y0 }, .mouse_down = true });
    try expectEqual(@as(?usize, 1), state.selection_anchor);
    try expectEqual(0, state.cursor_i); // selection now [0,1], anchor still 1

    try feed(&state, .{ .mouse = .{ .x = X0 + 3, .y = Y0 }, .mouse_down = true });
    try expectEqual(@as(?usize, 1), state.selection_anchor);
    try expectEqual(3, state.cursor_i);
}

test "mouse: clicks outside the text clamp to the nearest row and column" {
    var buf: [20]u8 = undefined;
    var state = AppState.init(&buf);
    try feed(&state, .{ .text = "ab\ncd" }); // lines: {0,"ab"}, {3,"cd"}

    const Click = struct { x: f64, y: f64, want: usize };
    const cases = [_]Click{
        .{ .x = X0 + 999, .y = Y0 + 999, .want = 5 }, // below + right → end of last line
        .{ .x = X0 - 999, .y = Y0 - 999, .want = 0 }, // above + left  → start of first line
        .{ .x = X0 - 999, .y = Y0 + 1, .want = 3 }, // left of line 2  → its column 0
        .{ .x = X0 + 999, .y = Y0, .want = 2 }, // right of line 1     → its last column
    };
    for (cases) |c| {
        try feed(&state, .{ .mouse = .{ .x = c.x, .y = c.y }, .mouse_down = true });
        try feed(&state, .{ .mouse = .{ .x = c.x, .y = c.y }, .mouse_down = false });
        try expectEqual(c.want, state.cursor_i);
    }
}
