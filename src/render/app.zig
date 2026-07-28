//! This is your playground — the immediate-mode frame callback.
//!
//! `frame` is called once per display refresh with a `Canvas` to draw into and an
//! `Input` snapshot for this frame. Redraw the whole scene every call. Everything
//! you see on screen happens here; edit freely and rebuild the framework to iterate.
//!
//! Primitives available on `canvas`:
//!   canvas.clear(Color)
//!   canvas.fillRect(Rect, Color)
//!   canvas.drawText(utf8, x, y, Font, Color) -> Size
//!   canvas.measureText(utf8, Font) -> Size

const geom = @import("geom.zig");
const Canvas = @import("canvas.zig").Canvas;
const input = @import("input.zig");
const std = @import("std");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
const testing_allocator = std.testing.allocator;
const assert = std.debug.assert;
const markdown = @import("markdown.zig");
const Token = markdown.FlatToken;
const mod_shift = input.mod_shift;

const Color = geom.Color;
const Font = geom.Font;
const Input = input.Input;

/// Cursor/index math casts buffer offsets through signed types (see
/// `handleInput`'s left/right movement), so the buffer length must always be
/// indexable by a u32. Every growth is asserted against this bound.
const MAX_BUF_LEN: usize = std.math.maxInt(u32);

const BASE_SCRATCH_SIZE = 1024 * 1024; // 1MB
var scratch: ?[]u8 = null;

const BASE_LINE_SCRATCH_SIZE = 1024; // max rendered lines before regrow
var line_scratch: ?[]Line = null;

const BASE_FRAG_SCRATCH_SIZE = 1024; // max rendered fragments before regrow
var frag_scratch: ?[]Fragment = null;

// Visible-line placements for the current render pass; bounded by line count (≤ text_len).
var placement_scratch: ?[]Placement = null;

// Persisted across frames so the parse arena keeps its capacity. Each `tokenize`
// resets it (freeing the previous frame's tree) before parsing again.
var md_arena: ?std.heap.ArenaAllocator = null;

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
const HIGHLIGHT_COLOR: Color = TEXT_COLOR.withAlpha(0.25);

/// Code is set apart by ink weight, not by a new hue: slightly dimmed body text sitting on a
/// faint panel of that same body color. Both are translucent, which also keeps the selection
/// highlight (painted before the text) visible through a selected code span.
const CODE_COLOR: Color = TEXT_COLOR.withAlpha(0.85);
const CODE_BG_COLOR: Color = TEXT_COLOR.withAlpha(0.12);

/// Quoted text is dimmed and pushed right, with a rule per nesting level standing in the
/// gutter it was pushed out of.
const QUOTE_COLOR: Color = TEXT_COLOR.withAlpha(0.70);
const QUOTE_RULE_COLOR: Color = TEXT_COLOR.withAlpha(0.35);
const QUOTE_INDENT_PX: f64 = 24;
const QUOTE_RULE_W: f64 = 3;

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
    /// End-exclusive range into the fragment buffer: styled runs constitute this line.
    frag_start: usize = 0,
    frag_end: usize = 0,
    /// How far this row is pushed right of the content margin. Set by the owning block (a
    /// quote indents by its nesting depth), and it narrows the row's wrap budget by the same
    /// amount. Everything that maps between x and a text offset — caret, selection, mouse
    /// hit-testing — has to add it, so it lives on the line rather than being recomputed.
    indent: f64 = 0,
};

/// A token's slice of one visual row, the render loop quanta. Frags don't cross line bounds.
const Fragment = struct {
    /// Index into Token buffer specifying the styling.
    tok: usize,
    // Index into the full text buffers.
    start: usize,
    end: usize,
};

pub fn frame(allocator: std.mem.Allocator, canvas: *Canvas, in: Input, state: *AppState) !void {
    // debug: fps calculation
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
            .{ .size = font_size },
            TEXT_COLOR,
        );
    }

    { // scratch setup / init
        if (scratch == null) {
            scratch = try allocator.alloc(u8, BASE_SCRATCH_SIZE);
        }
        if (line_scratch == null) {
            line_scratch = try allocator.alloc(Line, BASE_LINE_SCRATCH_SIZE);
        }
        if (frag_scratch == null) {
            frag_scratch = try allocator.alloc(Fragment, BASE_FRAG_SCRATCH_SIZE);
        }
        if (placement_scratch == null) {
            placement_scratch = try allocator.alloc(Placement, BASE_LINE_SCRATCH_SIZE);
        }
        while (scratch.?.len <= state.text_len) {
            scratch = try allocator.realloc(scratch.?, scratch.?.len << 1);
        }
        while (line_scratch.?.len <= state.text_len) {
            line_scratch = try allocator.realloc(line_scratch.?, line_scratch.?.len << 1);
        }
        // Fragment count is bounded by row/token intersections, itself ≤ text_len.
        while (frag_scratch.?.len <= state.text_len) {
            frag_scratch = try allocator.realloc(frag_scratch.?, frag_scratch.?.len << 1);
        }
        // Placements are bounded by line count, itself ≤ text_len.
        while (placement_scratch.?.len <= state.text_len) {
            placement_scratch = try allocator.realloc(placement_scratch.?, placement_scratch.?.len << 1);
        }
        if (md_arena == null) {
            md_arena = std.heap.ArenaAllocator.init(allocator);
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
        const lines = splitLines(full_text, tokens, line_scratch.?, frag_scratch.?, measurer);
        try handleInput(allocator, in, state, lines, tokens, measurer);
    }

    { // Render pass
        const full_text = condenseGapBuf(scratch.?, state.*);
        const tokens = try tokenize(full_text);
        const lines = splitLines(full_text, tokens, line_scratch.?, frag_scratch.?, measurer);
        const text_x: f64 = MARGIN_PX;
        const viewport_h = canvas.size.h - (MARGIN_PX * 2);
        state.window_offset = scrollToCursor(lines, state.window_offset, cursorLine(lines, state.cursor_i), viewport_h);
        const top = @min(state.window_offset, lines.len);
        const placements = visiblePlacements(lines, top, viewport_h, placement_scratch.?);
        var caret_drawn = false;

        for (placements) |placement| {
            const line = lines[placement.line];
            const line_h = line.h;
            const text_y = MARGIN_PX + placement.y;
            // Where this row's text actually starts. Everything that converts between an x
            // and a text offset below works from this, not from `text_x` — an indented row
            // would otherwise draw its caret and selection a full indent to the left of its
            // glyphs. `text_x` still marks the gutter, which is what the quote rules want.
            const line_x = text_x + line.indent;
            // The row's usable width, which the indent eats into — the same budget splitLines
            // wrapped this row against, so a full-width panel ends where the text would have.
            const row_w = measurer.content_w - line.indent;
            { // Quote rules: one bar per nesting level, standing in the gutter the text
              // vacated. Drawn first so everything else layers over them.
                const owner = tokenAt(tokens, line.start);
                if (owner.tType == .QUOTE) {
                    for (0..owner.degree) |level| {
                        const bar_x = text_x + (@as(f64, @floatFromInt(level)) * QUOTE_INDENT_PX);
                        fillPanel(canvas, .{ .x = bar_x, .y = text_y, .w = QUOTE_RULE_W, .h = line_h }, QUOTE_RULE_COLOR);
                    }
                }
            }
            { // selection rendering
                const cursor_in_line = state.cursor_i >= line.start and state.cursor_i <= line.start + line.text.len;
                const anchor_in_line = state.selection_anchor != null and state.selection_anchor.? >= line.start and state.selection_anchor.? <= line.start + line.text.len;
                if (cursor_in_line and !caret_drawn) {
                    // At a soft-wrap boundary the cursor offset matches both the end
                    // of one line and the start of the next; prefer the earlier line.
                    const caret_offset = state.cursor_i - line.start;
                    const caret_x = line_x + measurer.width(line.text[0..caret_offset], tokens, line.start, line.start + caret_offset);
                    canvas.fillRect(.{ .x = caret_x, .y = text_y, .w = 2, .h = line_h }, Color.white);
                    caret_drawn = true;
                }
                if (cursor_in_line and anchor_in_line) {
                    if (state.selection_anchor) |anchor| {
                        const anchor_offset: usize = anchor - line.start;
                        const caret_offset = state.cursor_i - line.start;
                        const caret_x = line_x + measurer.width(line.text[0..caret_offset], tokens, line.start, line.start + caret_offset);
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
                        canvas.fillRect(.{ .x = line_x, .y = text_y, .w = selection_w, .h = line_h }, HIGHLIGHT_COLOR);
                    } else {
                        const caret_offset = state.cursor_i - line.start;
                        const selection_w: f64 = measurer.width(line.text[caret_offset..line.text.len], tokens, line.start + caret_offset, line.start + line.text.len);
                        const caret_x = line_x + measurer.width(line.text[0..caret_offset], tokens, line.start, line.start + caret_offset);
                        canvas.fillRect(.{ .x = caret_x, .y = text_y, .w = selection_w, .h = line_h }, HIGHLIGHT_COLOR);
                    }
                } else if (anchor_in_line) {
                    // Cursor is on another line
                    if (state.selection_anchor.? < state.cursor_i) {
                        const anchor_offset = state.selection_anchor.? - line.start;
                        const selection_w: f64 = measurer.width(line.text[anchor_offset..line.text.len], tokens, line.start + anchor_offset, line.start + line.text.len);
                        const anchor_x = line_x + measurer.width(line.text[0..anchor_offset], tokens, line.start, line.start + anchor_offset);
                        canvas.fillRect(.{ .x = anchor_x, .y = text_y, .w = selection_w, .h = line_h }, HIGHLIGHT_COLOR);
                    } else {
                        const anchor_offset = state.selection_anchor.? - line.start;
                        const selection_w: f64 = measurer.width(line.text[0..anchor_offset], tokens, line.start, line.start + anchor_offset);
                        canvas.fillRect(.{ .x = line_x, .y = text_y, .w = selection_w, .h = line_h }, HIGHLIGHT_COLOR);
                    }
                } else if (state.selection_anchor != null and
                    line.start > @min(state.selection_anchor.?, state.cursor_i) and
                    (line.start + line.text.len) < @max(state.selection_anchor.?, state.cursor_i))
                {
                    // Line is between the anchor and cursor.
                    const selection_w: f64 = if (line.text.len == 0)
                        measurer.width(" ", tokens, line.start, line.start + 1) // still render empty lines aas selected.
                    else
                        measurer.width(line.text[0..line.text.len], tokens, line.start, line.start + line.text.len);
                    canvas.fillRect(.{ .x = line_x, .y = text_y, .w = selection_w, .h = line_h }, HIGHLIGHT_COLOR);
                }
            }
            { // Draw Text
                const frags = frag_scratch.?[line.frag_start..line.frag_end];
                if (frags.len == 0) {
                    // A blank row carries no fragments, but it still belongs to whatever block
                    // owns it — a blank line inside a fence, say. Paint that block's panel so
                    // the slab has no holes where the source had empty lines. Only a `.full`
                    // panel applies; a `.run` panel over an empty row has nothing to hug.
                    const style = styleForToken(tokenAt(tokens, line.start));
                    if (style.background) |bg| {
                        if (style.panel == .full) {
                            fillPanel(canvas, .{ .x = line_x, .y = text_y, .w = row_w, .h = line_h }, bg);
                        }
                    }
                }
                var frag_x = line_x;
                for (frags) |frag| {
                    const shown = full_text[frag.start..frag.end];
                    const style = styleForToken(tokens[frag.tok]);
                    if (style.background) |bg| {
                        // The panel has to be down before the glyphs, so its width can't come
                        // from drawText's return — measure the run up front.
                        const w = switch (style.panel) {
                            .run => measurer.width(shown, tokens, frag.start, frag.end),
                            .full => row_w - (frag_x - line_x),
                        };
                        fillPanel(canvas, .{ .x = frag_x, .y = text_y, .w = w, .h = line_h }, bg);
                    }
                    frag_x += canvas.drawText(shown, frag_x, text_y, style.font, style.color).w;
                }
            }
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

fn fontForToken(token: Token) Font {
    return switch (token.tType) {
        .HEADER => .{ .size = FONT_SIZE * headerScale(token.degree) },
        .BOLD => .{ .size = FONT_SIZE, .bold = true },
        .ITALIC => .{ .size = FONT_SIZE, .italic = true },
        .EMPHASIS => .{ .size = FONT_SIZE, .bold = true, .italic = true },
        else => .{ .size = FONT_SIZE },
    };
}

/// How a token is painted. Measurement only ever needs `.font`, so `fontForToken` stays a
/// separate entry point and the `Measurer` signature is unaffected by anything here.
const Style = struct {
    font: Font,
    color: Color = TEXT_COLOR,
    /// Filled behind the run before the text is drawn. `null` means "leave the page showing".
    background: ?Color = null,
    panel: Panel = .run,
};

/// How wide a token's background panel is drawn.
const Panel = enum {
    /// Hugs the run's measured width — for spans sitting inside a line of prose.
    run,
    /// Spans the rest of the content column — for blocks that own whole lines, so consecutive
    /// rows tile into one slab with a straight right edge instead of a ragged one.
    full,
};

fn styleForToken(token: Token) Style {
    var style = Style{ .font = fontForToken(token) };
    switch (token.tType) {
        .CODE => {
            style.color = CODE_COLOR;
            style.background = CODE_BG_COLOR;
        },
        .BLOCK_CODE => {
            style.color = CODE_COLOR;
            style.background = CODE_BG_COLOR;
            style.panel = .full;
        },
        .QUOTE => style.color = QUOTE_COLOR,
        else => {},
    }
    return style;
}

/// How far right of the content margin a token's rows sit. Blocks that indent do so by their
/// nesting depth; everything inline sits flush, since an indent applies to a whole row and an
/// inline span only covers part of one.
fn indentForToken(token: Token) f64 {
    return switch (token.tType) {
        .QUOTE => QUOTE_INDENT_PX * @as(f64, @floatFromInt(token.degree)),
        else => 0,
    };
}

/// Headers shrink toward body size as the degree grows; degree 6 is body-sized, distinguished
/// only by the `######` still being visible.
fn headerScale(degree: u8) f64 {
    return switch (degree) {
        1 => 2.0,
        2 => 1.75,
        3 => 1.5,
        4 => 1.25,
        5 => 1.1,
        else => 1.0,
    };
}

/// The token covering source offset `i`, falling back to the last token when `i` is past the
/// end of the document (an offset one past the final character is a legal cursor position).
// FOLLOW-UP (unicode): `i` here is a byte offset (line.start / cursor offsets), but token
// startI/endI come out of parseFlat as codepoint offsets. These coincide only for ASCII;
// with multi-byte characters this matches the wrong token. splitLines has the same
// byte-vs-codepoint mismatch. Dormant today (sample docs are ASCII); fix separately by
// giving the renderer byte offsets while the frontend keeps codepoints.
fn tokenAt(tokens: []const Token, i: usize) Token {
    for (tokens) |t| {
        if (i >= t.startI and i < t.endI) return t;
    }
    return tokens[tokens.len - 1];
}

/// The font for whichever token covers source offset `i`.
fn fontAt(tokens: []const Token, i: usize) Font {
    return fontForToken(tokenAt(tokens, i));
}

fn widthWithCanvas(ctx: *anyopaque, text: []const u8, tokens: []const Token, start_i: usize, end_i: usize) f64 {
    _ = end_i;
    const canvas: *Canvas = @ptrCast(@alignCast(ctx));
    return canvas.measureText(text, fontAt(tokens, start_i)).w;
}

fn heightWithCanvas(ctx: *anyopaque, text: []const u8, tokens: []const Token, start_i: usize, end_i: usize) f64 {
    _ = end_i;
    const canvas: *Canvas = @ptrCast(@alignCast(ctx));
    // An empty line (e.g. a blank line after a trailing '\n') still occupies vertical space.
    const measured = if (text.len == 0) " " else text;
    return canvas.measureText(measured, fontAt(tokens, start_i)).h;
}

/// Fill one row's background panel. The vertical extent is snapped to whole points so panels
/// on consecutive rows share an exact edge. Line heights are fractional, so without this the
/// shared boundary lands mid-pixel, Core Graphics antialiases both sides of it, and the two
/// partial coverages composite to less than the full color — drawing a seam across every row
/// boundary of a multi-line block.
fn fillPanel(canvas: *Canvas, rect: geom.Rect, color: Color) void {
    const top = @floor(rect.y);
    const bottom = @floor(rect.y + rect.h);
    canvas.fillRect(.{ .x = rect.x, .y = top, .w = rect.w, .h = bottom - top }, color);
}

fn pushFragment(frags: []Fragment, count: *usize, tok: usize, from: usize, to: usize) void {
    if (to <= from) return;
    frags[count.*] = .{ .tok = tok, .start = from, .end = to };
    count.* += 1;
}

/// Open a row at `start`, inheriting the indent of the block that owns that offset. Looking the
/// owner up by offset gets both cases right without tracking state: a hard newline hands off to
/// the next token (a quote's '\n' is its last character, so the row after it is no longer
/// quoted), while a soft wrap stays inside the current token and keeps the indent.
fn beginRow(out: []Line, lineno: usize, start: usize, tokens: []const Token) void {
    out[lineno].start = start;
    out[lineno].indent = indentForToken(tokenAt(tokens, start));
}

/// Split `full_text` into renderable fragments bounded by lines.
fn splitLines(full_text: []const u8, tokens: []const Token, out: []Line, frags: []Fragment, m: Measurer) []Line {
    var lineno: usize = 0;
    beginRow(out, lineno, 0, tokens);

    var frag_count: usize = 0;
    var line_frag_start: usize = 0; // first fragment index of the current row
    var frag_from: usize = 0; // start offset of the run being accumulated
    var frag_tok: usize = 0; // token index of that run

    var last_token = tokens[0];
    for (tokens, 0..) |token, ti| {
        last_token = token;
        // Token boundary: close the previous token's run on this row (contiguous
        // tokens mean it ends exactly where this one starts), then open this token's.
        pushFragment(frags, &frag_count, frag_tok, frag_from, token.startI);
        frag_tok = ti;
        frag_from = token.startI;

        for (token.contents, 0..) |c, token_off| {
            const off = token.startI + token_off;
            if (c == '\n') {
                out[lineno].text = full_text[out[lineno].start..off];
                pushFragment(frags, &frag_count, frag_tok, frag_from, off);
                out[lineno].frag_start = line_frag_start;
                out[lineno].frag_end = frag_count;
                lineno += 1;
                beginRow(out, lineno, off + 1, tokens);
                out[lineno].text = "";
                line_frag_start = frag_count;
                frag_from = off + 1; // same token, resumes past the newline
                continue;
            }
            const text_including_new_char = full_text[out[lineno].start .. off + 1];
            // An indented row has correspondingly less room before it has to wrap.
            if (m.width(text_including_new_char, tokens, out[lineno].start, off) >= m.content_w - out[lineno].indent) {
                out[lineno].text = full_text[out[lineno].start..off];
                pushFragment(frags, &frag_count, frag_tok, frag_from, off);
                out[lineno].frag_start = line_frag_start;
                out[lineno].frag_end = frag_count;
                lineno += 1;
                beginRow(out, lineno, off, tokens);
                out[lineno].text = full_text[off .. off + 1];
                line_frag_start = frag_count;
                frag_from = off; // same token, the wrapped char begins the next row
                continue;
            }
        }
    }
    const doc_end = last_token.startI + last_token.contents.len;
    out[lineno].text = full_text[out[lineno].start..doc_end];
    pushFragment(frags, &frag_count, frag_tok, frag_from, doc_end);
    out[lineno].frag_start = line_frag_start;
    out[lineno].frag_end = frag_count;
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

/// A visible line and where to draw it: `y` is relative to the top of the content area
/// (add `MARGIN_PX` for an absolute canvas y).
const Placement = struct {
    line: usize,
    y: f64,
};

/// The lines from `top` onward that fit within a `viewport_h`-tall content area, each paired
/// with its content-relative y. Lines stack by height (the same rule `scrollToCursor` uses to
/// decide what "fits"); iteration stops at the first line that would overflow. The line at
/// `top` is always emitted even if it alone is taller than the viewport, so an oversized line
/// (e.g. a big header) is never silently dropped.
fn visiblePlacements(lines: []const Line, top: usize, viewport_h: f64, out: []Placement) []Placement {
    var count: usize = 0;
    var y: f64 = 0;
    var i = top;
    while (i < lines.len) : (i += 1) {
        const h = lines[i].h;
        if (count > 0 and y + h > viewport_h) break;
        out[count] = .{ .line = i, .y = y };
        count += 1;
        y += h;
    }
    return out[0..count];
}

/// Scroll enough to put `cursor_line` inside a `screen_h`px window, starting from `window_offset`.
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
            // Start where the row's glyphs start, not at the margin: on an indented row the
            // two differ, and walking from the margin would map every click an indent's worth
            // of characters to the right.
            var curr_x: f64 = MARGIN_PX + lines[lineno].indent;
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
        // A click leaves an empty selection; collapse it so only a real drag keeps the anchor.
        if (state.selection_anchor == state.cursor_i) state.selection_anchor = null;
    } else if (in.backspaces != 0) {
        if (state.selection_anchor) |anchor| {
            if (state.cursor_i > anchor) {
                // Sel. is in the pre-cursor area; drop it by moving the cursor back to the anchor.
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
                // Sel. is in the pre-cursor region; drop it by moving the cursor to the anchor.
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

/// Parse `full_text` into flat markdown tokens, falling back to a single plain token for an empty
/// document (which the parser returns none for). Tokens live in the parse arena and are valid only
/// until the next `tokenize` call, which resets it.
fn tokenize(full_text: []const u8) ![]const Token {
    _ = md_arena.?.reset(.retain_capacity);
    const parsed = try markdown.parseFlat(md_arena.?.allocator(), full_text);
    return if (parsed.len == 0) EMPTY_DOC_TOKENS else parsed;
}

/// Drive `handleInput` the way `frame` does, but with the fake measurer
fn feed(state: *AppState, in: Input) !void {
    var doc_buf: [1024]u8 = undefined;
    var line_buf: [256]Line = undefined;
    var frag_buf: [256]Fragment = undefined;
    const measurer = testMeasurer(1_000_000);
    const doc = condenseGapBuf(&doc_buf, state.*);
    const tokens = &.{plainTokenize(doc)};
    const lines = splitLines(doc, tokens, &line_buf, &frag_buf, measurer);
    try handleInput(testing_allocator, in, state, lines, tokens, measurer);
}

/// Build a Line with just the fields the vertical-layout functions read (start/text/height).
fn testLine(start: usize, text: []const u8, h: f64) Line {
    return .{ .start = start, .text = text, .h = h };
}

test "visiblePlacements stacks lines that fit and stops before overflow" {
    var out: [16]Placement = undefined;
    const lines = [_]Line{
        testLine(0, "a", 30),
        testLine(1, "b", 30),
        testLine(2, "c", 30),
        testLine(3, "d", 30),
    };
    // 100px viewport: 30+30+30 = 90 fits; a fourth (→120) would overflow.
    const vis = visiblePlacements(&lines, 0, 100, &out);
    try expectEqual(@as(usize, 3), vis.len);
    try expectEqual(@as(usize, 0), vis[0].line);
    try expectEqual(@as(f64, 0), vis[0].y);
    try expectEqual(@as(f64, 30), vis[1].y);
    try expectEqual(@as(f64, 60), vis[2].y);
}

test "visiblePlacements starts at `top` with y measured from the content top" {
    var out: [16]Placement = undefined;
    const lines = [_]Line{
        testLine(0, "a", 30),
        testLine(1, "b", 30),
        testLine(2, "c", 30),
        testLine(3, "d", 30),
    };
    const vis = visiblePlacements(&lines, 2, 100, &out);
    try expectEqual(@as(usize, 2), vis.len);
    try expectEqual(@as(usize, 2), vis[0].line);
    try expectEqual(@as(f64, 0), vis[0].y); // first visible line sits at the content top
    try expectEqual(@as(usize, 3), vis[1].line);
    try expectEqual(@as(f64, 30), vis[1].y);
}

test "visiblePlacements: a tall line leaves room for fewer lines" {
    var out: [16]Placement = undefined;
    const lines = [_]Line{
        testLine(0, "big", 60), // e.g. an H1
        testLine(1, "a", 30),
        testLine(2, "b", 30),
    };
    // 100px viewport: 60+30 = 90 fits; +30 → 120 overflows.
    const vis = visiblePlacements(&lines, 0, 100, &out);
    try expectEqual(@as(usize, 2), vis.len);
    try expectEqual(@as(f64, 0), vis[0].y);
    try expectEqual(@as(f64, 60), vis[1].y);
}

test "visiblePlacements always shows the top line even if it overflows" {
    var out: [16]Placement = undefined;
    const lines = [_]Line{
        testLine(0, "huge", 150), // taller than the whole viewport
        testLine(1, "a", 30),
    };
    const vis = visiblePlacements(&lines, 0, 100, &out);
    try expectEqual(@as(usize, 1), vis.len);
    try expectEqual(@as(usize, 0), vis[0].line);
    try expectEqual(@as(f64, 0), vis[0].y);
}

test "visiblePlacements fills the viewport to its bottom edge" {
    var out: [16]Placement = undefined;
    const lines = [_]Line{
        testLine(0, "a", 50),
        testLine(1, "b", 50), // 50+50 == 100, exactly fills the viewport
        testLine(2, "c", 50),
    };
    // Regression for the clipping bug: a line reaching exactly the bottom edge is still shown.
    const vis = visiblePlacements(&lines, 0, 100, &out);
    try expectEqual(@as(usize, 2), vis.len);
    try expectEqual(@as(f64, 50), vis[1].y);
}

test "scrollToCursor and visiblePlacements agree on what fits" {
    // The invariant the clipping bug broke: scrolling and the render clip must share one
    // definition of "fits," so a line scrollToCursor reveals is actually placed for drawing.
    const lines = [_]Line{
        testLine(0, "a", 30), testLine(1, "b", 30), testLine(2, "c", 30),
        testLine(3, "d", 30), testLine(4, "e", 30),
    };
    const viewport_h: f64 = 100;
    const top = scrollToCursor(&lines, 0, 4, viewport_h); // cursor below the viewport
    var out: [16]Placement = undefined;
    const vis = visiblePlacements(&lines, top, viewport_h, &out);
    try expectEqual(@as(usize, 4), vis[vis.len - 1].line); // cursor line is within the placed window
}

test "cursorLine resolves a soft-wrap boundary to the later line" {
    // One logical line "abc" wrapped into two rows: "ab" | "c".
    const lines = [_]Line{ testLine(0, "ab", 30), testLine(2, "c", 30) };
    try expectEqual(@as(usize, 1), cursorLine(&lines, 2)); // boundary offset → later row
    try expectEqual(@as(usize, 0), cursorLine(&lines, 0));
    try expectEqual(@as(usize, 1), cursorLine(&lines, 3));
}

test "splitLines breaks on newlines" {
    var out: [8]Line = undefined;
    var frags: [16]Fragment = undefined;
    const text = "ab\ncd";
    const lines = splitLines(text, &.{plainTokenize(text)}, &out, &frags, testMeasurer(1_000_000));

    try expectEqual(2, lines.len);
    try expectEqual(0, lines[0].start);
    try expectEqualStrings("ab", lines[0].text);
    try expectEqual(3, lines[1].start);
    try expectEqualStrings("cd", lines[1].text);
}

test "splitLines deal with trailing newline" {
    var out: [8]Line = undefined;
    var frags: [16]Fragment = undefined;
    const text = "ab\n";
    const lines = splitLines(text, &.{plainTokenize(text)}, &out, &frags, testMeasurer(1_000_000));
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
    var frags: [16]Fragment = undefined;
    const lines = splitLines(text, &.{plainTokenize(text)}, &out, &frags, testMeasurer(4));

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
    var frags: [16]Fragment = undefined;
    const lines = splitLines(text, &.{plainTokenize(text)}, &out, &frags, testMeasurer(4));

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
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();

    const contents: []const u8 = "foo**bar**baz";
    const tokens = try markdown.parseFlat(arena.allocator(), contents);
    var frags: [16]Fragment = undefined;
    const lines = splitLines(contents, tokens, &out, &frags, testMeasurer(1_000_000));

    try expectEqual(1, lines.len);
    const line = lines[0];
    try expectEqualStrings(contents, line.text);

    // One row, three tokens ⇒ three fragments that tile the row's text.
    try expectEqual(3, line.frag_end - line.frag_start);
    try expectEqualStrings("foo", contents[frags[0].start..frags[0].end]);
    try expectEqualStrings("**bar**", contents[frags[1].start..frags[1].end]);
    try expectEqualStrings("baz", contents[frags[2].start..frags[2].end]);
    try expectEqual(0, frags[0].tok);
    try expectEqual(1, frags[1].tok);
    try expectEqual(2, frags[2].tok);
}

test "splitLines output dimensions" {
    var out: [8]Line = undefined;
    const text = "1\n12\n123";
    var frags: [16]Fragment = undefined;
    const lines = splitLines(text, &.{plainTokenize(text)}, &out, &frags, testMeasurer(4));

    try expectEqual(3, lines.len);
    try expectEqual(1, lines[0].h);
    try expectEqual(1, lines[0].w);
    try expectEqual(1, lines[1].h);
    try expectEqual(2, lines[1].w);
    try expectEqual(1, lines[2].h);
    try expectEqual(3, lines[2].w);
}

test "splitLines fragments tile each line's text" {
    var out: [8]Line = undefined;
    var frags: [16]Fragment = undefined;
    const text = "ab\ncd";
    const lines = splitLines(text, &.{plainTokenize(text)}, &out, &frags, testMeasurer(1_000_000));

    for (lines) |line| {
        // Concatenating a row's fragment slices reconstructs the row's text, in order.
        var rebuilt_len: usize = 0;
        var expect_off: usize = line.start;
        for (frags[line.frag_start..line.frag_end]) |frag| {
            try expectEqual(expect_off, frag.start); // contiguous, no gaps/overlaps
            try expectEqualStrings(
                text[frag.start..frag.end],
                line.text[rebuilt_len .. rebuilt_len + (frag.end - frag.start)],
            );
            rebuilt_len += frag.end - frag.start;
            expect_off = frag.end;
        }
        try expectEqual(line.text.len, rebuilt_len);
    }
}

test "splitLines soft-wrap splits one token into a fragment per row" {
    var out: [8]Line = undefined;
    var frags: [16]Fragment = undefined;
    // Single plain token "abcdef" wraps into "abc" / "def" at content_w 4.
    const text = "abcdef";
    const lines = splitLines(text, &.{plainTokenize(text)}, &out, &frags, testMeasurer(4));

    try expectEqual(2, lines.len);
    try expectEqual(1, lines[0].frag_end - lines[0].frag_start);
    try expectEqual(1, lines[1].frag_end - lines[1].frag_start);
    // Both rows reference the same (only) token.
    try expectEqual(0, frags[lines[0].frag_start].tok);
    try expectEqual(0, frags[lines[1].frag_start].tok);
    try expectEqualStrings("abc", text[frags[lines[0].frag_start].start..frags[lines[0].frag_start].end]);
    try expectEqualStrings("def", text[frags[lines[1].frag_start].start..frags[lines[1].frag_start].end]);
}

test "a blank row inside a fence has no fragments but still belongs to the block" {
    var out: [8]Line = undefined;
    var frags: [16]Fragment = undefined;
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();

    // The blank line between "a" and "b" is inside the fence.
    const text = "```\na\n\nb\n```";
    const tokens = try markdown.parseFlat(arena.allocator(), text);
    const lines = splitLines(text, tokens, &out, &frags, testMeasurer(1_000_000));

    try expectEqual(5, lines.len);
    try expectEqualStrings("", lines[2].text);
    // Nothing to draw on that row, so the render loop can't reach the block's style through a
    // fragment — it has to look the owning token up by offset instead (see the frags.len == 0
    // branch in `frame`), or the code panel would have a hole in it.
    try expectEqual(0, lines[2].frag_end - lines[2].frag_start);
    try expectEqual(markdown.TokenType.BLOCK_CODE, tokenAt(tokens, lines[2].start).tType);

    // Every other row of the block does reach it through a fragment.
    for ([_]usize{ 0, 1, 3, 4 }) |i| {
        try expectEqual(markdown.TokenType.BLOCK_CODE, tokens[frags[lines[i].frag_start].tok].tType);
    }
}

test "quote rows carry an indent scaled by nesting depth" {
    var out: [8]Line = undefined;
    var frags: [32]Fragment = undefined;
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();

    const text = "plain\n> one\n>> two\nplain again";
    const tokens = try markdown.parseFlat(arena.allocator(), text);
    const lines = splitLines(text, tokens, &out, &frags, testMeasurer(1_000_000));

    try expectEqual(4, lines.len);
    try expectEqual(@as(f64, 0), lines[0].indent);
    try expectEqual(QUOTE_INDENT_PX * 1, lines[1].indent);
    try expectEqual(QUOTE_INDENT_PX * 2, lines[2].indent);
    // The row after a quote is not itself quoted. A quote token owns its trailing '\n', so
    // this only comes out right because beginRow resolves the owner at `off + 1`.
    try expectEqual(@as(f64, 0), lines[3].indent);
}

test "a soft-wrapped quote keeps its indent on continuation rows" {
    var out: [8]Line = undefined;
    var frags: [32]Fragment = undefined;
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();

    // fakeWidth is 1/byte and content_w is 10, so the quote wraps well before its text ends.
    const text = "> aaaaaaaaaaaaaaaaaa";
    const tokens = try markdown.parseFlat(arena.allocator(), text);
    const lines = splitLines(text, tokens, &out, &frags, testMeasurer(10 + QUOTE_INDENT_PX));

    try expect(lines.len > 1); // it did wrap
    for (lines) |line| {
        try expectEqual(QUOTE_INDENT_PX, line.indent);
    }
    // Wrapping happened against the *narrowed* budget, not the full content width. The row
    // breaks when it would reach the budget, so it holds budget - 1 == 9 bytes; against the
    // un-narrowed width it would have held 33.
    for (lines[0 .. lines.len - 1]) |line| {
        try expectEqual(@as(usize, 9), line.text.len);
    }
}

test "splitLines empty row has no fragments" {
    var out: [8]Line = undefined;
    var frags: [16]Fragment = undefined;
    // Trailing newline yields an empty second row.
    const text = "ab\n";
    const lines = splitLines(text, &.{plainTokenize(text)}, &out, &frags, testMeasurer(1_000_000));

    try expectEqual(2, lines.len);
    try expectEqual(1, lines[0].frag_end - lines[0].frag_start); // "ab"
    try expectEqual(0, lines[1].frag_end - lines[1].frag_start); // empty row draws nothing
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
