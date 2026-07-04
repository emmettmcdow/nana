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
const markdown = @import("markdown.zig");
const Markdown = markdown.Markdown;
const Token = markdown.Token;
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

// Persisted across frames so the token list isn't reallocated from scratch each
// refresh. `parse` frees and rebuilds its internal list on every call.
var md_parser: ?Markdown = null;

// The parser yields zero tokens for an empty document; the rest of the pipeline
// (splitLines, tokenAt) needs at least one, so fall back to this.
const EMPTY_DOC_TOKENS: []const Token = &.{.{ .tType = .PLAIN, .startI = 0, .endI = 0, .contents = "" }};

// Wall-clock duration of the previous `frame` call, used to report the FPS we
// would hit if Swift weren't capping us at 60. Displayed a frame late (the debug
// text is drawn before this frame's own time is known), which is fine at 60 Hz.
var last_frame_ns: u64 = 0;

const FONT_SIZE: f64 = 20;
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
    h: f64 = 0,
    w: f64 = 0,
};

pub fn frame(allocator: std.mem.Allocator, canvas: *Canvas, in: Input, state: *AppState) !void {
    // Time the whole frame so we can report the uncapped FPS. Recorded via defer
    // so it captures every path out of the function.
    var frame_timer = std.time.Timer.start() catch null;
    defer if (frame_timer) |*t| {
        last_frame_ns = t.read();
    };

    // Background.
    canvas.clear(Color.rgb(0.12, 0.12, 0.14));

    { // debug
        var buf: [96]u8 = undefined;
        const font_size: f64 = 24.0;
        // Uncapped FPS from the previous frame's duration (0 on the first frame).
        const fps: u64 = if (last_frame_ns > 0)
            @intFromFloat(1_000_000_000.0 / @as(f64, @floatFromInt(last_frame_ns)))
        else
            0;
        _ = canvas.drawText(
            std.fmt.bufPrint(&buf, "mouse: ({d}, {d})  |  FPS {d} (capped at 60)", .{
                @as(i64, @intFromFloat(in.mouse.x)),
                @as(i64, @intFromFloat(in.mouse.y)),
                fps,
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
        if (md_parser == null) {
            md_parser = Markdown.init(allocator);
        }
    }
    const measurer = Measurer{
        .content_w = canvas.size.w - (MARGIN_PX * 2),
        .ctx = canvas,
        .widthFn = widthWithCanvas,
        .heightFn = heightWithCanvas,
    };

    { // Calculate the displayed text and handle inputs
        const full_text = condenseGapBuf(scratch.?, state.*);
        const tokens = try tokenize(full_text);
        const lines = splitLines(full_text, tokens, line_scratch.?, measurer);
        try handleInput(allocator, in, state, lines, tokens, measurer);
    }

    { // Render pass
        const full_text = condenseGapBuf(scratch.?, state.*);
        const tokens = try tokenize(full_text);
        const lines = splitLines(full_text, tokens, line_scratch.?, measurer);
        const text_x: f64 = MARGIN_PX;

        const writable_text_area_h = canvas.size.h - (MARGIN_PX * 2);

        state.window_offset = scrollToCursor(lines, state.window_offset, cursorLine(lines, state.cursor_i), writable_text_area_h);

        const top = @min(state.window_offset, lines.len);
        var text_y: f64 = MARGIN_PX;
        var caret_drawn = false;
        for (lines[top..lines.len]) |line| {
            const line_h = line.h;
            const line_font_size = fontSizeAt(tokens, line.start);
            if (text_y + line_h >= writable_text_area_h) break;
            { // selection rendering
                const cursor_in_line = state.cursor_i >= line.start and state.cursor_i <= line.start + line.text.len;
                const anchor_in_line = state.selection_anchor != null and state.selection_anchor.? >= line.start and state.selection_anchor.? <= line.start + line.text.len;
                if (cursor_in_line and !caret_drawn) {
                    // At a soft-wrap boundary the cursor offset matches both the end
                    // of one line and the start of the next; prefer the earlier line.
                    const caret_offset = state.cursor_i - line.start;
                    const caret_x = text_x + measurer.width(line.text[0..caret_offset], tokens, line.start, line.start + caret_offset);
                    canvas.fillRect(.{ .x = caret_x, .y = text_y, .w = 2, .h = line_h }, Color.white);
                    caret_drawn = true;
                }
                if (cursor_in_line and anchor_in_line) {
                    if (state.selection_anchor) |anchor| {
                        const anchor_offset: usize = anchor - line.start;
                        const caret_offset = state.cursor_i - line.start;
                        const caret_x = text_x + measurer.width(line.text[0..caret_offset], tokens, line.start, line.start + caret_offset);
                        var box_start_x: f64 = undefined;
                        var selection_w: f64 = undefined;
                        if (anchor_offset < caret_offset) {
                            selection_w = measurer.width(line.text[anchor_offset..caret_offset], tokens, line.start + anchor_offset, line.start + caret_offset);
                            box_start_x = caret_x - selection_w;
                        } else {
                            selection_w = measurer.width(line.text[caret_offset..anchor_offset], tokens, line.start + caret_offset, line.start + anchor_offset);
                            box_start_x = caret_x;
                        }
                        canvas.fillRect(.{ .x = box_start_x, .y = text_y, .w = selection_w, .h = line_h }, HIGHLIGHT_COLOR);
                    } else unreachable;
                } else if (cursor_in_line and state.selection_anchor != null) {
                    // Selection anchor is on another line
                    if (state.selection_anchor.? < state.cursor_i) {
                        const caret_offset = state.cursor_i - line.start;
                        const selection_w: f64 = measurer.width(line.text[0..caret_offset], tokens, line.start, line.start + caret_offset);
                        canvas.fillRect(.{ .x = text_x, .y = text_y, .w = selection_w, .h = line_h }, HIGHLIGHT_COLOR);
                    } else {
                        const caret_offset = state.cursor_i - line.start;
                        const selection_w: f64 = measurer.width(line.text[caret_offset..line.text.len], tokens, line.start + caret_offset, line.start + line.text.len);
                        const caret_x = text_x + measurer.width(line.text[0..caret_offset], tokens, line.start, line.start + caret_offset);
                        canvas.fillRect(.{ .x = caret_x, .y = text_y, .w = selection_w, .h = line_h }, HIGHLIGHT_COLOR);
                    }
                } else if (anchor_in_line) {
                    // Cursor is on another line
                    if (state.selection_anchor.? < state.cursor_i) {
                        const anchor_offset = state.selection_anchor.? - line.start;
                        const selection_w: f64 = measurer.width(line.text[anchor_offset..line.text.len], tokens, line.start + anchor_offset, line.start + line.text.len);
                        const anchor_x = text_x + measurer.width(line.text[0..anchor_offset], tokens, line.start, line.start + anchor_offset);
                        canvas.fillRect(.{ .x = anchor_x, .y = text_y, .w = selection_w, .h = line_h }, HIGHLIGHT_COLOR);
                    } else {
                        const anchor_offset = state.selection_anchor.? - line.start;
                        const selection_w: f64 = measurer.width(line.text[0..anchor_offset], tokens, line.start, line.start + anchor_offset);
                        canvas.fillRect(.{ .x = text_x, .y = text_y, .w = selection_w, .h = line_h }, HIGHLIGHT_COLOR);
                    }
                } else if (state.selection_anchor != null and
                    line.start > @min(state.selection_anchor.?, state.cursor_i) and
                    (line.start + line.text.len) < @max(state.selection_anchor.?, state.cursor_i))
                {
                    // Line is between the anchor and cursor
                    const selection_w: f64 = measurer.width(line.text[0..line.text.len], tokens, line.start, line.start + line.text.len);
                    canvas.fillRect(.{ .x = text_x, .y = text_y, .w = selection_w, .h = line_h }, HIGHLIGHT_COLOR);
                }
            }
            _ = canvas.drawText(line.text, text_x, text_y, line_font_size, TEXT_COLOR);
            text_y += line_h;
        }
    }
}

const Measurer = struct {
    content_w: f64,
    ctx: *anyopaque,
    widthFn: *const fn (ctx: *anyopaque, text: []const u8, tokens: []const Token, start_i: usize, end_i: usize) f64,
    heightFn: *const fn (ctx: *anyopaque, text: []const u8, tokens: []const Token, start_i: usize, end_i: usize) f64,

    fn width(self: Measurer, text: []const u8, tokens: []const Token, start_i: usize, end_i: usize) f64 {
        return self.widthFn(self.ctx, text, tokens, start_i, end_i);
    }

    fn height(self: Measurer, text: []const u8, tokens: []const Token, start_i: usize, end_i: usize) f64 {
        return self.heightFn(self.ctx, text, tokens, start_i, end_i);
    }
};

/// Font-size multiplier for a markdown token, relative to the base `FONT_SIZE`.
/// Headers scale up by level; everything else renders at the base size.
fn sizeMultiplier(token: Token) f64 {
    return switch (token.tType) {
        .HEADER => switch (token.degree) {
            1 => 2.0,
            2 => 1.75,
            3 => 1.5,
            4 => 1.25,
            5 => 1.1,
            else => 1.0,
        },
        else => 1.0,
    };
}

/// The token whose source range [startI, endI) covers `i`; falls back to the
/// last token (e.g. for the caret position just past the end of the text).
fn tokenAt(tokens: []const Token, i: usize) Token {
    for (tokens) |t| {
        if (i >= t.startI and i < t.endI) return t;
    }
    return tokens[tokens.len - 1];
}

/// The base font size scaled for whichever token covers source offset `i`.
fn fontSizeAt(tokens: []const Token, i: usize) f64 {
    return FONT_SIZE * sizeMultiplier(tokenAt(tokens, i));
}

fn widthWithCanvas(ctx: *anyopaque, text: []const u8, tokens: []const Token, start_i: usize, end_i: usize) f64 {
    _ = end_i;
    const canvas: *Canvas = @ptrCast(@alignCast(ctx));
    return canvas.measureText(text, fontSizeAt(tokens, start_i)).w;
}

fn heightWithCanvas(ctx: *anyopaque, text: []const u8, tokens: []const Token, start_i: usize, end_i: usize) f64 {
    _ = end_i;
    const canvas: *Canvas = @ptrCast(@alignCast(ctx));
    // An empty line (e.g. a blank line after a trailing '\n') still occupies a
    // full row and needs a visible caret, so measure a placeholder glyph for its
    // height rather than the empty string, which measures to zero.
    const measured = if (text.len == 0) " " else text;
    return canvas.measureText(measured, fontSizeAt(tokens, start_i)).h;
}

/// Split `full_text` into rendered lines: hard breaks on '\n', soft wraps when a
/// run would reach `m.content_w`. Lines are written into `out` and a sub-slice of
/// it is returned. Each `Line.text` aliases `full_text`.
fn splitLines(full_text: []const u8, tokens: []const Token, out: []Line, m: Measurer) []Line {
    var lineno: usize = 0;
    out[lineno].start = 0;
    var last_token = tokens[0];
    for (tokens) |token| {
        last_token = token;
        for (token.contents, 0..) |c, token_off| {
            if (c == '\n') {
                out[lineno].text = full_text[out[lineno].start .. token.startI + token_off];
                lineno += 1;
                out[lineno].start = token.startI + token_off + 1;
                out[lineno].text = "";
                continue;
            }
            const text_including_new_char = full_text[out[lineno].start .. token.startI + token_off + 1];
            if (m.width(text_including_new_char, tokens, out[lineno].start, token.startI + token_off) >= m.content_w) {
                out[lineno].text = full_text[out[lineno].start .. token.startI + token_off];
                lineno += 1;
                out[lineno].start = token.startI + token_off;
                out[lineno].text = full_text[token.startI + token_off .. token.startI + token_off + 1];
                continue;
            }
        }
    }
    out[lineno].text = full_text[out[lineno].start .. last_token.startI + last_token.contents.len];
    lineno += 1;
    for (out[0..lineno]) |*line| {
        line.h = m.height(line.text, tokens, line.start, line.start + line.text.len);
        line.w = m.width(line.text, tokens, line.start, line.start + line.text.len);
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
/// `screen_h` pixels tall, given the current top line `window_offset`.
fn scrollToCursor(lines: []const Line, window_offset: usize, cursor_line: usize, screen_h: f64) usize {
    if (cursor_line < window_offset) return cursor_line; // above the viewport

    var stacked: f64 = 0;
    var i = window_offset;
    while (i <= cursor_line) : (i += 1) stacked += lines[i].h;
    if (stacked <= screen_h) return window_offset; // Already in view

    // Below the viewport
    stacked = lines[cursor_line].h;
    var top = cursor_line;
    while (top > 0 and stacked + lines[top - 1].h <= screen_h) {
        top -= 1;
        stacked += lines[top].h;
    }
    return top;
}

fn handleInput(
    allocator: std.mem.Allocator,
    in: Input,
    state: *AppState,
    lines: []const Line,
    tokens: []const Token,
    measurer: Measurer,
) !void {
    state.assertInvariant();
    var cursor_target: ?usize = null;
    if (in.mouse_down) {
        const mouse_offset: usize = cursor: { // point to offset
            var lineno: usize = lines.len - 1;
            var curr_y: f64 = MARGIN_PX;
            for (state.window_offset..lines.len) |i| {
                const line_h = measurer.height(lines[i].text, tokens, lines[i].start, lines[i].start + lines[i].text.len);
                if (in.mouse.y < curr_y + line_h) {
                    lineno = i;
                    break;
                }
                curr_y += line_h;
            }
            var col: usize = lines[lineno].text.len;
            var curr_x: f64 = MARGIN_PX;
            for (0..lines[lineno].text.len) |i| {
                const char_width = measurer.width(lines[lineno].text[i .. i + 1], tokens, lines[lineno].start + i, lines[lineno].start + i + 1);
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

fn fakeWidth(
    _: *anyopaque,
    text: []const u8,
    tokens: []const Token,
    start_i: usize,
    end_i: usize,
) f64 {
    _ = tokens;
    _ = start_i;
    _ = end_i;
    return @floatFromInt(text.len);
}

fn fakeHeight(
    _: *anyopaque,
    text: []const u8,
    tokens: []const Token,
    start_i: usize,
    end_i: usize,
) f64 {
    _ = tokens;
    _ = text;
    _ = start_i;
    _ = end_i;
    return 1;
}

fn testMeasurer(content_w: f64) Measurer {
    return .{
        .content_w = content_w,
        .ctx = &fake_ctx,
        .widthFn = fakeWidth,
        .heightFn = fakeHeight,
    };
}

fn plainTokenize(full_text: []const u8) Token {
    return Token{ .tType = .PLAIN, .startI = 0, .endI = full_text.len, .contents = full_text };
}

/// Parse `full_text` into markdown tokens via the persisted parser, falling back
/// to a single plain token for an empty document (which the parser returns none for).
fn tokenize(full_text: []const u8) ![]const Token {
    const parsed = try md_parser.?.parse(full_text);
    return if (parsed.len == 0) EMPTY_DOC_TOKENS else parsed;
}

/// Drive `handleInput` the way `frame` does, but with the fake measurer
fn feed(state: *AppState, in: Input) !void {
    var doc_buf: [1024]u8 = undefined;
    var line_buf: [256]Line = undefined;
    const measurer = testMeasurer(1_000_000);
    const doc = condenseGapBuf(&doc_buf, state.*);
    const tokens = &.{plainTokenize(doc)};
    const lines = splitLines(doc, tokens, &line_buf, measurer);
    try handleInput(testing_allocator, in, state, lines, tokens, measurer);
}

test "splitLines breaks on newlines" {
    var out: [8]Line = undefined;
    const text = "ab\ncd";
    const lines = splitLines(text, &.{plainTokenize(text)}, &out, testMeasurer(1_000_000));

    try expectEqual(2, lines.len);
    try expectEqual(0, lines[0].start);
    try expectEqualStrings("ab", lines[0].text);
    try expectEqual(3, lines[1].start);
    try expectEqualStrings("cd", lines[1].text);
}

test "splitLines deal with trailing newline" {
    var out: [8]Line = undefined;
    const text = "ab\n";
    const lines = splitLines(text, &.{plainTokenize(text)}, &out, testMeasurer(1_000_000));
    try expectEqual(2, lines.len);
    try expectEqual(0, lines[0].start);
    try expectEqualStrings("ab", lines[0].text);
    try expectEqual(3, lines[1].start);
    try expectEqualStrings("", lines[1].text);
}

test "splitLines soft-wraps a run wider than content_w" {
    var out: [8]Line = undefined;
    // fakeWidth == byte count; content_w 4 ⇒ at most 3 bytes per line.
    const text = "abcdef";
    const lines = splitLines(text, &.{plainTokenize(text)}, &out, testMeasurer(4));

    try expectEqual(2, lines.len);
    try expectEqual(0, lines[0].start);
    try expectEqualStrings("abc", lines[0].text);
    try expectEqual(3, lines[1].start);
    try expectEqualStrings("def", lines[1].text);
}

test "splitLines start offsets account for newlines across wraps" {
    var out: [8]Line = undefined;
    // "abcd\nef": first logical line wraps (3 per line), then a hard break.
    const text = "abcd\nef";
    const lines = splitLines(text, &.{plainTokenize(text)}, &out, testMeasurer(4));

    try expectEqual(3, lines.len);
    try expectEqual(0, lines[0].start);
    try expectEqualStrings("abc", lines[0].text);
    try expectEqual(3, lines[1].start);
    try expectEqualStrings("d", lines[1].text);
    try expectEqual(5, lines[2].start); // past the 'd' (4) and the '\n' (5)
    try expectEqualStrings("ef", lines[2].text);
}

test "splitLines handle multiple tokens" {
    var out: [8]Line = undefined;
    var parser = Markdown.init(testing_allocator);
    defer parser.deinit();

    const contents: []const u8 = "foo**bar**baz";
    const tokens = try parser.parse(contents);
    const lines = splitLines(contents, tokens, &out, testMeasurer(1_000_000));

    try expectEqual(1, lines.len);
    const line = lines[0];
    try expectEqualStrings(contents, line.text);
}

test "splitLines output dimensions" {
    var out: [8]Line = undefined;
    const text = "1\n12\n123";
    const lines = splitLines(text, &.{plainTokenize(text)}, &out, testMeasurer(4));

    try expectEqual(3, lines.len);
    try expectEqual(1, lines[0].h);
    try expectEqual(1, lines[0].w);
    try expectEqual(1, lines[1].h);
    try expectEqual(2, lines[1].w);
    try expectEqual(1, lines[2].h);
    try expectEqual(3, lines[2].w);
}

/// `n` unit-height lines, for exercising scrollToCursor's line-count logic
/// independent of measured heights.
fn unitLines(comptime n: usize) [n]Line {
    var lines: [n]Line = undefined;
    for (&lines, 0..) |*line, i| line.* = .{ .start = i, .text = "", .h = 1, .w = 0 };
    return lines;
}

test "scrollToCursor scrolls down to reveal a cursor below the viewport" {
    // 3px-tall viewport at the top (offset 0) with unit-height lines; cursor on
    // line 5 is off the bottom. Top shifts so line 5 is last visible: 5 - 3 + 1 = 3.
    var lines = unitLines(6);
    try expectEqual(3, scrollToCursor(&lines, 0, 5, 3));
}

test "scrollToCursor scrolls up to reveal a cursor above the viewport" {
    // Scrolled to line 4 (showing 4..6); cursor on line 1 is above ⇒ top = 1.
    var lines = unitLines(6);
    try expectEqual(1, scrollToCursor(&lines, 4, 1, 3));
}

test "scrollToCursor leaves the offset alone when the cursor is already visible" {
    // Showing lines 2..4; cursor on line 3 is within ⇒ unchanged.
    var lines = unitLines(6);
    try expectEqual(2, scrollToCursor(&lines, 2, 3, 3));
}

test "scrollToCursor accounts for variable line heights when scrolling down" {
    // Lines are 2px tall except a 4px line 3. A 6px viewport at offset 0 shows
    // lines 0..2 (2+2+2=6); cursor on line 3 pushes the top down. From line 3
    // (4px) only line 2 (2px) also fits within 6px ⇒ top = 2.
    var lines = unitLines(5);
    for (&lines) |*line| line.h = 2;
    lines[3].h = 4;
    try expectEqual(2, scrollToCursor(&lines, 0, 3, 6));
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

    const contents = "abcdef";
    try feed(&state, .{ .text = contents }); // cursor at end (offset 6)

    // "abcdef" laid out as two soft-wrapped visual lines (no '\n' between them).
    // Hand-built, so this navigation is exercised with zero font dependency — only
    // `start`/`text.len` matter to the up/down logic.
    const lines = [_]Line{
        .{ .start = 0, .text = "abc" },
        .{ .start = 3, .text = "def" },
    };
    try handleInput(
        testing_allocator,
        .{ .ups = 1 },
        &state,
        &lines,
        &.{plainTokenize(contents)},
        testMeasurer(1_000_000),
    );

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
