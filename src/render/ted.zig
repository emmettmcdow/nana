//! ted — the text editor.
//!
//! Everything from the gap buffer up to the glyphs: the document, its undo history, the
//! markdown-aware line layout, and the caret/selection drawing that goes with it. `frame`
//! redraws the whole document each call from the `AppState` it is handed.
//!
//! The chrome layered over the editor — buttons, the note list, the search field — is
//! `overlay.zig`'s. This module knows nothing about it, and receives an already-masked
//! `Input` when the overlay has taken the keyboard.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const assert = std.debug.assert;

const app = @import("app.zig");
const AppState = app.AppState;

const geom = @import("geom.zig");
const Color = geom.Color;
const Rect = geom.Rect;
const Font = geom.Font;
const AttributedText = geom.AttributedText;

const theme = @import("theme.zig");
const th = theme.th;

const Canvas = @import("canvas.zig").Canvas;

const input = @import("input.zig");
const Input = input.Input;
const mod_shift = input.mod_shift;

const markdown = @import("markdown.zig");
const Token = markdown.FlatToken;

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
const testing_allocator = std.testing.allocator;

// ******************************************************************************* Global Constants
/// Cursor/index math casts buffer offsets through signed types (see
/// `handleInput`'s left/right movement), so the buffer length must always be
/// indexable by a u32. Every growth is asserted against this bound.
const MAX_BUF_LEN: usize = std.math.maxInt(u32);

/// A half-open span of document offsets, `lo` up to but not including `hi`.
pub const Range = struct { lo: usize, hi: usize };

// The parser yields zero tokens for an empty document; the rest of the pipeline
// (splitLines, tokenAt) needs at least one, so fall back to this.
const EMPTY_DOC_TOKENS: []const Token = &.{.{ .tType = .PLAIN, .startI = 0, .endI = 0, .contents = "" }};

/// Space between the window's edge and the content column. Read off the theme rather than fixed
/// here, since the user's style file sets it.
///
/// Public because the test harness maps canvas coordinates back to character cells, and the
/// content origin is where that mapping starts.
pub fn padding() f64 {
    return th().metrics.padding;
}

/// How many edits are kept before the oldest is dropped.
const MAX_UNDO_DEPTH: usize = 256;

// ****************************************************************************************** Types
const Measurer = struct {
    content_w: f64,
    ctx: *anyopaque,
    widthFn: *const fn (ctx: *anyopaque, text: []const u8, tokens: []const Token, start_i: usize, end_i: usize) f64,
    heightFn: *const fn (ctx: *anyopaque, text: []const u8, tokens: []const Token, start_i: usize, end_i: usize) f64,
    attrHeightFn: *const fn (ctx: *anyopaque, text: AttributedText) f64,
    attrWidthFn: *const fn (ctx: *anyopaque, text: AttributedText) f64,
    run_buf: []AttributedText.Run,

    fn width(self: Measurer, text: []const u8, tokens: []const Token, start_i: usize, end_i: usize) f64 {
        return self.widthFn(self.ctx, text, tokens, start_i, end_i);
    }

    fn height(self: Measurer, text: []const u8, tokens: []const Token, start_i: usize, end_i: usize) f64 {
        return self.heightFn(self.ctx, text, tokens, start_i, end_i);
    }

    fn attributedW(self: Measurer, text: AttributedText) f64 {
        return self.attrWidthFn(self.ctx, text);
    }

    fn attributedH(self: Measurer, text: AttributedText) f64 {
        return self.attrHeightFn(self.ctx, text);
    }
};

/// How a token is painted.
const Style = struct {
    font: Font,
    color: Color,
    background: ?Color = null,
    panel: Panel = .run,
};

/// How wide a token's background panel is drawn.
const Panel = enum {
    /// Hugs the run's measured width
    run,
    /// Spans the rest of the content column
    full,
};

/// A visible line and where to draw it: `y` is relative to the top of the content area
/// (add the editor padding for an absolute canvas y).
const Placement = struct {
    line: usize,
    y: f64,
};

/// One reversible change: `removed` was at `at`, and `inserted` took its place. A pure insert
/// has an empty `removed`, a pure delete an empty `inserted`, and replacing a selection has
/// both — so one shape covers every edit the editor can make.
///
/// Records rather than document snapshots: a note is not big, but a snapshot per keystroke
/// still costs its full length each time, where a record costs only what actually changed.
const Edit = struct {
    at: usize,
    removed: []const u8,
    inserted: []const u8,
    /// Caret and selection as they stood before the edit, so undo puts the user back where
    /// they were rather than wherever the text happened to end.
    cursor_before: usize,
    anchor_before: ?usize,
};

/// Lives on `AppState`, which `app.zig` owns, so it has to be reachable from there.
pub const History = struct {
    undo_stack: ArrayList(Edit) = .{},
    redo_stack: ArrayList(Edit) = .{},
    /// Whether the next insert may merge into the top undo entry. Typing a run should undo as
    /// one unit, but only while it stays a run — anything else (moving the caret, deleting,
    /// undoing) ends it, so the merge can't reach across unrelated edits.
    coalesce: bool = false,
};

const Line = struct {
    /// byte offset relative to the start of the document
    start: usize,
    text: []const u8,
    /// The row's full vertical extent, block margins included. Everything that stacks rows —
    /// placement, scrolling, hit-testing — works in these, so a margin is space the document
    /// genuinely occupies rather than something the render pass adds on top.
    h: f64 = 0,
    w: f64 = 0,
    /// The margin above and below this row, part of `h`. Non-zero only on the first and last row
    /// of a block that asks for one; what gets *drawn* — glyphs, caret, selection, panels — sits
    /// in `h - lead - trail`, so the margin stays empty.
    lead: f64 = 0,
    trail: f64 = 0,
    /// End-exclusive range into the fragment buffer: styled runs constitute this line.
    frag_start: usize = 0,
    frag_end: usize = 0,
    /// How far this row is pushed right of the content margin. Set by the owning block (a
    /// quote indents by its nesting depth), and it narrows the row's wrap budget by the same
    /// amount. Everything that maps between x and a text offset — caret, selection, mouse
    /// hit-testing — has to add it, so it lives on the line rather than being recomputed.
    indent: f64 = 0,

    /// The height of what is actually drawn on this row, the margins excluded.
    fn contentH(self: Line) f64 {
        return self.h - self.lead - self.trail;
    }
};

/// A token's slice of one visual row, the render loop quanta. Frags don't cross line bounds.
const Fragment = struct {
    /// Index into Token buffer specifying the styling.
    tok: usize,
    // Index into the full text buffers.
    start: usize,
    end: usize,
    /// The drawn sub-range of `[start, end)`. Equal to the whole range on a revealed row; on a
    /// hidden one it is clipped to the token's visible middle, which is what conceals the
    /// delimiters. A token hides only a prefix and a suffix, so what survives is contiguous
    /// and one pair of bounds is enough.
    vis_start: usize = 0,
    vis_end: usize = 0,
};

/// The span of source whose markdown delimiters are shown, being the line the cursor sits on.
///
/// Reveal is decided per *source* line rather than per visual row, which is what keeps this
/// tractable: hiding changes how wide a row is, so it changes where rows wrap, so it changes
/// which row the cursor lands on. Resolving that against source lines instead — they are
/// delimited by newlines and knowable before any measuring happens — cuts the loop.
const Reveal = struct {
    start: usize,
    end: usize,

    fn covers(self: Reveal, i: usize) bool {
        return i >= self.start and i < self.end;
    }

    /// Nothing revealed. For passes that have no cursor to speak of.
    const none = Reveal{ .start = 0, .end = 0 };
};

/// A non-owning summary of the undo stack's top entry.
///
/// Keeping the `Edit` itself does not work: it carries `removed` and `inserted` as heap slices
/// the history owns, and the history frees them underneath a copy — coalescing a run of
/// keystrokes reallocates `inserted`, and passing `MAX_UNDO_DEPTH` frees the oldest entry
/// outright. Comparing against a stored `Edit` therefore reads freed memory. Lengths and depths
/// are enough to notice that *something* changed, and they own nothing.
const EditPrint = struct {
    at: usize = 0,
    removed_len: usize = 0,
    inserted_len: usize = 0,
    cursor_before: usize = 0,
    anchor_before: ?usize = null,
    /// Both depths, so an undo or redo registers even when it leaves a similar entry on top.
    undo_depth: usize = 0,
    redo_depth: usize = 0,

    fn of(state: *const AppState) EditPrint {
        var p = EditPrint{
            .undo_depth = state.history.undo_stack.items.len,
            .redo_depth = state.history.redo_stack.items.len,
        };
        if (state.history.undo_stack.getLastOrNull()) |e| {
            p.at = e.at;
            p.removed_len = e.removed.len;
            p.inserted_len = e.inserted.len;
            p.cursor_before = e.cursor_before;
            p.anchor_before = e.anchor_before;
        }
        return p;
    }
};

const View = struct {
    full_text: []u8,
    tokens: []const Token,
    reveal: Reveal,
    lines: []Line,
    /// What the layout was computed against, so staleness is detectable.
    last_seen: EditPrint = .{},
    content_w: f64 = 0,
    /// Every `styleForToken` font is derived from this, so Cmd +/- rewraps everything. It
    /// reaches the editor through the `theme.active` global rather than through `state`, so
    /// nothing else here would notice it moved.
    font_size: f64 = 0,

};

// ******************************************************************************* The Layout Cache
const BASE_SCRATCH_SIZE = 1024 * 1024; // 1MB
const BASE_LINE_SCRATCH_SIZE = 1024; // max rendered lines before regrow
const BASE_FRAG_SCRATCH_SIZE = 1024; // max rendered fragments before regrow

/// Everything the editor keeps between frames: the scratch buffers a document is laid out into,
/// the arena its markdown tree lives in, and the `View` that results.
///
/// Handed to `frame` rather than reached for. The app makes one at startup and keeps it for the
/// life of the process, which is right for something with a single document open; a test binary
/// runs dozens of documents and wants one per harness, so that a layout cannot carry one test's
/// text into the next and the testing allocator has an owner to hold responsible.
///
/// `view` aliases `text`, `lines` and `frags`, and its tokens belong to `arena` — so it is
/// dangling the instant any of them is freed or moved, and every path that does either has to
/// clear it. That is a real hazard, not a stylistic one, and it is the reason all of this is one
/// struct with one owner instead of six variables.
pub const Layout = struct {
    /// The document condensed out of the gap buffer, NUL-terminated.
    text: []u8,
    lines: []Line,
    frags: []Fragment,
    /// Runs staged for one attributed measurement. Bounded by the token count, itself ≤ text_len.
    runs: []AttributedText.Run,
    /// Visible-line placements for the current render pass; bounded by line count (≤ text_len).
    placements: []Placement,
    /// Holds the parsed markdown tree. Kept across frames so it keeps its capacity — each
    /// `tokenize` resets it, freeing the previous frame's tree, before parsing again.
    arena: std.heap.ArenaAllocator,
    /// The laid-out document, or null when there is nothing usable to draw from yet.
    view: ?View = null,

    pub fn init(alloc: Allocator) !Layout {
        const text = try alloc.alloc(u8, BASE_SCRATCH_SIZE);
        errdefer alloc.free(text);
        const lines = try alloc.alloc(Line, BASE_LINE_SCRATCH_SIZE);
        errdefer alloc.free(lines);
        const frags = try alloc.alloc(Fragment, BASE_FRAG_SCRATCH_SIZE);
        errdefer alloc.free(frags);
        const runs = try alloc.alloc(AttributedText.Run, BASE_FRAG_SCRATCH_SIZE);
        errdefer alloc.free(runs);
        const placements = try alloc.alloc(Placement, BASE_LINE_SCRATCH_SIZE);

        return .{
            .text = text,
            .lines = lines,
            .frags = frags,
            .runs = runs,
            .placements = placements,
            .arena = std.heap.ArenaAllocator.init(alloc),
        };
    }

    pub fn deinit(self: *Layout, alloc: Allocator) void {
        // Before the buffers it points into, so nothing outlives it as a dangling view.
        self.view = null;
        alloc.free(self.text);
        alloc.free(self.lines);
        alloc.free(self.frags);
        alloc.free(self.runs);
        alloc.free(self.placements);
        self.arena.deinit();
    }

    /// Throw away the laid-out document, so the next frame builds it afresh.
    pub fn invalidate(self: *Layout) void {
        self.view = null;
    }

    /// Grow every buffer to fit a document of `text_len` bytes.
    fn ensure(self: *Layout, alloc: Allocator, text_len: usize) !void {
        // `view` holds slices into the first three, so a realloc that relocates one leaves it
        // pointing at freed memory. The growth bound is `text_len` in *bytes*, so this trips on
        // any note past a kilobyte, not on some pathological document.
        //
        // HACK: the real fix is for the layout not to alias buffers it does not own.
        const text_was = self.text.ptr;
        const lines_was = self.lines.ptr;
        const frags_was = self.frags.ptr;

        while (self.text.len <= text_len) {
            self.text = try alloc.realloc(self.text, self.text.len << 1);
        }
        while (self.lines.len <= text_len) {
            self.lines = try alloc.realloc(self.lines, self.lines.len << 1);
        }
        // Fragment count is bounded by row/token intersections, itself ≤ text_len.
        while (self.frags.len <= text_len) {
            self.frags = try alloc.realloc(self.frags, self.frags.len << 1);
        }
        // One run per token at worst, and there is never more than one token per byte.
        while (self.runs.len <= text_len) {
            self.runs = try alloc.realloc(self.runs, self.runs.len << 1);
        }
        // Placements are bounded by line count, itself ≤ text_len.
        while (self.placements.len <= text_len) {
            self.placements = try alloc.realloc(self.placements, self.placements.len << 1);
        }

        if (self.text.ptr != text_was or self.lines.ptr != lines_was or self.frags.ptr != frags_was) {
            self.invalidate();
        }
    }

    fn fullRecalc(self: *Layout, measurer: Measurer, state: *AppState) !void {
        const full_text = condenseGapBuf(self.text, state.*);
        const tokens = try tokenize(&self.arena, full_text);
        const reveal = revealForCursor(full_text, state.cursor_i);
        self.view = .{
            .full_text = full_text,
            .tokens = tokens,
            .reveal = reveal,
            .lines = splitLines(full_text, tokens, self.lines, self.frags, measurer, reveal),
            .last_seen = EditPrint.of(state),
            .content_w = measurer.content_w,
            .font_size = th().font_size,
        };
    }

    /// Redo the layout if anything it depends on moved. Despite the name this is still
    /// all-or-nothing: a staleness check in front of `fullRecalc`, not an incremental layout.
    fn partialRecalc(self: *Layout, measurer: Measurer, state: *AppState) !void {
        const v = self.view orelse return self.fullRecalc(measurer, state);
        // The document changed.
        const now = EditPrint.of(state);
        // The caret moved to another source line, so a different line shows its markup. Safe to
        // compute against a possibly-stale `full_text`: if the text itself changed then `now`
        // already differs and this comparison never gets to decide anything.
        const reveal_now = revealForCursor(v.full_text, state.cursor_i);

        if (!std.meta.eql(v.last_seen, now) or
            !std.meta.eql(v.reveal, reveal_now) or
            v.content_w != measurer.content_w or // the window was resized; rows wrap elsewhere
            v.font_size != th().font_size)
        {
            try self.fullRecalc(measurer, state);
        }
    }
};

// ********************************************************************************** Top-Level Fns
pub fn frame(
    allocator: std.mem.Allocator,
    canvas: *Canvas,
    in: Input,
    state: *AppState,
    layout: *Layout,
) !void {
    try layout.ensure(allocator, state.text_len);

    const measurer = Measurer{
        .content_w = canvas.size.w - (padding() * 2),
        .ctx = canvas,
        .widthFn = widthWithCanvas,
        .heightFn = heightWithCanvas,
        .attrWidthFn = attrWidthWithCanvas,
        .attrHeightFn = attrHeightWithCanvas,
        .run_buf = layout.runs,
    };

    if (state.clear_view) {
        state.clear_view = false;
        layout.invalidate();
    }
    // `handleInput` reads the laid-out rows, so there has to be a layout before it runs.
    if (layout.view == null) try layout.fullRecalc(measurer, state);

    // TODO: this is iffy, is this necessary?
    // Whether the view should chase the caret this frame. Only true when the caret actually
    // went somewhere: otherwise a wheel scroll that pushes the caret off screen would be
    // yanked straight back by `scrollToCursor` on the very next frame.
    var follow_cursor = false;

    { // Calculate the displayed text and handle inputs
        // Last frame's layout, which is what the input is being interpreted against — a click
        // lands on the rows the user was actually looking at when they clicked.
        const prev = layout.view.?;
        const cursor_before = state.cursor_i;
        try handleInput(allocator, in, state, prev.lines, prev.tokens, layout.frags, prev.full_text, measurer);
        // `dirty` covers deleting a selection ahead of the caret, which changes the text
        // without moving it.
        follow_cursor = state.cursor_i != cursor_before or state.dirty;
    }
    { // Render pass
        try layout.partialRecalc(measurer, state);
        // Taken after the recalc, so it is this frame's layout rather than the one the input
        // above was resolved against. A copy, not a pointer: nothing below re-lays it out.
        const view = layout.view.?;
        const text_x: f64 = padding();
        const viewport_h = canvas.size.h - (padding() * 2);

        // Wheel first, then the caret, so typing always wins over where the wheel had left us.
        state.scroll_y -= in.scroll_dy;
        if (follow_cursor) {
            state.scroll_y = scrollToCursor(view.lines, state.scroll_y, cursorLine(view.lines, state.cursor_i), viewport_h);
        }
        state.scroll_y = v: {
            var h: f64 = 0;
            for (view.lines) |line| h += line.h;
            break :v std.math.clamp(state.scroll_y, 0, @max(0, h - viewport_h));
        };

        const placements = visiblePlacements(view.lines, state.scroll_y, viewport_h, layout.placements);
        var caret_drawn = false;

        // Rows at the edges are cut off mid-line; keep them inside the content area.
        canvas.pushClip(.{ .x = 0, .y = padding(), .w = canvas.size.w, .h = viewport_h });
        defer canvas.popClip();

        for (placements) |placement| {
            const line = view.lines[placement.line];
            // The row's drawable band, which is the row less whatever block margin it carries.
            // Everything below is drawn against these two, so a margin is space nothing paints
            // into — no panel spilling into it, no selection reaching across it.
            const line_h = line.contentH();
            const text_y = padding() + placement.y + line.lead;
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
                const owner = tokenAt(view.tokens, line.start);
                if (owner.tType == .QUOTE) {
                    for (0..owner.degree) |level| {
                        const bar_x = text_x + (@as(f64, @floatFromInt(level)) * th().metrics.quote_indent);
                        fillPanel(canvas, .{ .x = bar_x, .y = text_y, .w = th().metrics.quote_rule_w, .h = line_h }, th().quote_rule);
                    }
                }
            }
            { // caret and selection
                const line_end = line.start + line.text.len;
                const cursor_in_line = state.cursor_i >= line.start and state.cursor_i <= line_end;
                if (cursor_in_line and !caret_drawn) {
                    // At a soft-wrap boundary the cursor offset matches both the end
                    // of one line and the start of the next; prefer the earlier line.
                    const caret_x = line_x + xForOffset(line, layout.frags, view.full_text, view.tokens, state.cursor_i, measurer);
                    canvas.fillRect(.{ .x = caret_x, .y = text_y, .w = 2, .h = line_h }, th().caret);
                    caret_drawn = true;
                }
                // One rect per row: clip the document-wide selection span to this row and draw
                // what is left. The old form branched on where the anchor and cursor each fell
                // relative to the row; intersecting the two ranges says the same thing without
                // enumerating the cases.
                if (state.selection_anchor) |anchor| {
                    const sel_lo = @min(anchor, state.cursor_i);
                    const sel_hi = @max(anchor, state.cursor_i);
                    const lo = @max(sel_lo, line.start);
                    const hi = @min(sel_hi, line_end);
                    if (lo <= hi) {
                        const x0 = xForOffset(line, layout.frags, view.full_text, view.tokens, lo, measurer);
                        const x1 = xForOffset(line, layout.frags, view.full_text, view.tokens, hi, measurer);
                        // A row wholly inside the selection but with nothing drawn on it — a
                        // blank line, or one that is all concealed markup — still shows a stub,
                        // so a multi-line selection doesn't look like it skipped a row.
                        const selection_w = if (x1 > x0)
                            x1 - x0
                        else if (sel_lo < line.start and sel_hi > line_end)
                            measurer.width(" ", view.tokens, line.start, line.start + 1)
                        else
                            0;
                        if (selection_w > 0) {
                            canvas.fillRect(.{ .x = line_x + x0, .y = text_y, .w = selection_w, .h = line_h }, th().highlight);
                        }
                    }
                }
            }
            { // Draw Text
                const frags = layout.frags[line.frag_start..line.frag_end];
                if (frags.len == 0) {
                    // A blank row carries no fragments, but it still belongs to whatever block
                    // owns it — a blank line inside a fence, say. Paint that block's panel so
                    // the slab has no holes where the source had empty lines. Only a `.full`
                    // panel applies; a `.run` panel over an empty row has nothing to hug.
                    const style = styleForToken(tokenAt(view.tokens, line.start));
                    if (style.background) |bg| {
                        if (style.panel == .full) {
                            fillPanel(canvas, .{ .x = line_x, .y = text_y, .w = row_w, .h = line_h }, bg);
                        }
                    }
                }
                var frag_x = line_x;
                for (frags) |frag| {
                    // Only the visible middle is drawn; on a row whose line isn't revealed the
                    // delimiters were clipped off this range and so take up no space.
                    const shown = view.full_text[frag.vis_start..frag.vis_end];
                    if (shown.len == 0) continue;
                    const style = styleForToken(view.tokens[frag.tok]);
                    if (style.background) |bg| {
                        // The panel has to be down before the glyphs, so its width can't come
                        // from drawText's return — measure the run up front.
                        const w = switch (style.panel) {
                            .run => measurer.width(shown, view.tokens, frag.vis_start, frag.vis_end),
                            .full => row_w - (frag_x - line_x),
                        };
                        fillPanel(canvas, .{ .x = frag_x, .y = text_y, .w = w, .h = line_h }, bg);
                    }
                    frag_x += canvas.drawText(shown, frag_x, text_y, style.font, style.color).w;
                }
            }
        }

        // Scrolling to the caret has to actually put it on screen. `scrollToCursor` and
        // `visiblePlacements` reach that conclusion separately — one from cumulative line tops,
        // the other by walking the same heights again — and nothing reconciles them, so a
        // disagreement shows up as a caret that was scrolled "into view" and still not drawn.
        //
        // Only when the caret moved: a wheel scroll is free to leave it off screen, and should.
        if (follow_cursor) assert(caret_drawn);
    }
}

/// Write the selection into `out`, returning the byte count. Zero if there is no selection or
/// `out` is too small — check `selectionLen` first to size the buffer.
///
/// Safe to call from outside the frame, unlike everything under "Commands" below: it reads the
/// gap buffer and mutates nothing, so there is no layout for it to leave stale.
pub fn copySelection(state: AppState, out: []u8) usize {
    const sel = selectionRange(state) orelse return 0;
    if (out.len < sel.hi - sel.lo) return 0;
    return copyRange(state, sel.lo, sel.hi, out);
}

pub fn selectionLen(state: AppState) usize {
    const sel = selectionRange(state) orelse return 0;
    return sel.hi - sel.lo;
}

/// Release every journalled edit.
pub fn deinitHistory(state: *AppState, alloc: Allocator) void {
    for (state.history.undo_stack.items) |e| freeEdit(alloc, e);
    for (state.history.redo_stack.items) |e| freeEdit(alloc, e);
    state.history.undo_stack.deinit(alloc);
    state.history.redo_stack.deinit(alloc);
    state.history = .{};
}

// ******************************************************************************* Menu Commands
// Undo, redo, select-all and the removal half of a cut. Every one of them moves the document or
// the caret, so none may run outside the frame: the layout is cached across frames and holds
// slices into the previous pass's buffers, and an edit landing between two frames is an edit the
// cache has no way to hear about.
//
// They are therefore private, and reached only through `input.Commands` — the host records what
// the user asked for and `applyCommands` carries it out at a defined point in the frame, in the
// same place the keyboard is handled.

/// Drop the selected text, leaving the cursor where the selection started. Records nothing;
/// callers that need the removal to be undoable want `deleteSelectionJournalled`.
fn deleteSelection(state: *AppState) void {
    const anchor = state.selection_anchor orelse return;
    if (state.cursor_i > anchor) {
        // Selection is behind the cursor; drop it by walking the cursor back over it.
        state.text_len -= state.cursor_i - anchor;
        state.cursor_i = anchor;
    } else {
        // Selection is ahead of the cursor; drop it by advancing the gap end past it.
        const removed = anchor - state.cursor_i;
        state.gap_end += removed;
        state.text_len -= removed;
    }
    state.selection_anchor = null;
}

/// Drop the selected text and journal it as one edit, so it can be undone. Does nothing when
/// there is no selection.
///
/// Shared by backspace-over-a-selection and the removal half of a cut: the two differ only in
/// what prompted them, and both owe the history the same record.
fn deleteSelectionJournalled(state: *AppState, alloc: Allocator) !void {
    const sel = selectionRange(state.*) orelse return;
    const cursor_before = state.cursor_i;
    const anchor_before = state.selection_anchor;

    // Capture the text before dropping it — afterwards there is nothing left to read.
    const removed = try alloc.alloc(u8, sel.hi - sel.lo);
    defer alloc.free(removed);
    _ = copyRange(state.*, sel.lo, sel.hi, removed);

    deleteSelection(state);
    try recordEdit(state, alloc, sel.lo, removed, "", cursor_before, anchor_before);
    state.dirty = true;
}

/// Select the whole document, leaving the cursor at the end as macOS does.
fn selectAll(state: *AppState) void {
    if (state.text_len == 0) return;
    moveCursorTo(state, state.text_len);
    state.selection_anchor = 0;
    state.history.coalesce = false;
}

/// Reverse the most recent edit. Returns false when there is nothing left to undo.
fn undo(state: *AppState, alloc: Allocator) !bool {
    if (state.history.undo_stack.items.len == 0) return false;
    const e = state.history.undo_stack.pop().?;

    try applyReplace(state, alloc, e.at, e.at + e.inserted.len, e.removed);
    moveCursorTo(state, e.cursor_before);
    state.selection_anchor = e.anchor_before;

    try state.history.redo_stack.append(alloc, e);
    state.history.coalesce = false;
    state.dirty = true;
    return true;
}

/// Re-apply the most recently undone edit. Returns false when there is nothing to redo.
fn redo(state: *AppState, alloc: Allocator) !bool {
    if (state.history.redo_stack.items.len == 0) return false;
    const e = state.history.redo_stack.pop().?;

    try applyReplace(state, alloc, e.at, e.at + e.removed.len, e.inserted);

    try state.history.undo_stack.append(alloc, e);
    state.history.coalesce = false;
    state.dirty = true;
    return true;
}

/// Carry out the commands the host recorded since the last frame.
///
/// Applied before the keyboard and *outside* its `else if` ladder, rather than as another rung
/// of it. That ladder is exclusive because the rungs are categories of keypress and only one
/// category can have arrived in a given frame; a menu command is a different source entirely, so
/// making it compete with the keyboard would mean a Cmd+Z swallowing text typed in the same
/// 16ms — or the other way round.
fn applyCommands(allocator: Allocator, cmds: input.Commands, state: *AppState) !void {
    // A run of presses replays as a run of edits. Both stacks run dry silently: the host already
    // told the user by declining to beep, and there is nothing further to report from here.
    for (0..cmds.undos) |_| {
        if (!try undo(state, allocator)) break;
    }
    for (0..cmds.redos) |_| {
        if (!try redo(state, allocator)) break;
    }
    if (cmds.select_all) selectAll(state);
    // The copy half of the cut already happened host-side; this is the removal it still owes.
    if (cmds.delete_selection) try deleteSelectionJournalled(state, allocator);
}

// ***************************************************************************** Testable Interface
fn handleInput(
    allocator: std.mem.Allocator,
    in: Input,
    state: *AppState,
    lines: []const Line,
    tokens: []const Token,
    frags: []const Fragment,
    full_text: []const u8,
    measurer: Measurer,
) !void {
    state.assertInvariant();
    try applyCommands(allocator, in.cmds, state);

    var cursor_target: ?usize = null;
    // Anything that isn't typing ends the current run, so an undo can't reach back across a
    // click or an arrow key into text the user typed somewhere else entirely.
    if (in.mouse_down or (in.lefts | in.rights | in.ups | in.downs) != 0) state.history.coalesce = false;

    // A right-click. Handled ahead of the ladder below rather than as a rung of it: it arrives
    // from the host's menu machinery, not the keyboard, so the same reasoning as `applyCommands`
    // applies — and unlike the commands there, it needs this frame's layout to turn the point
    // into an offset.
    if (in.cmds.context_click) |point| {
        const at = offsetAtPoint(point, state.scroll_y, lines, tokens, frags, full_text, measurer);
        // Inclusive of both ends: an offset equal to `hi` is a click on the right half of the
        // last selected character, which is visibly on top of the highlight. Reading that as
        // "outside" would throw away a selection the user was pointing straight at.
        const inside = if (selectionRange(state.*)) |sel| at >= sel.lo and at <= sel.hi else false;
        if (!inside) {
            state.history.coalesce = false;
            if (wordAt(full_text, at)) |word| {
                state.selection_anchor = word.lo;
                cursor_target = word.hi;
            } else {
                state.selection_anchor = null;
                cursor_target = at;
            }
        }
    }

    if (in.mouse_down) {
        const mouse_offset = offsetAtPoint(in.mouse, state.scroll_y, lines, tokens, frags, full_text, measurer);
        if (state.mouse_was_down) { // Drag
            if (state.word_drag) |origin| {
                // Started from a double-click, so the selection grows a word at a time and never
                // shrinks below the one that began it. Which edge is the anchor flips depending
                // on which side of that word the pointer has reached.
                const word = wordAt(full_text, mouse_offset) orelse Range{ .lo = mouse_offset, .hi = mouse_offset };
                if (word.lo < origin.lo) {
                    state.selection_anchor = origin.hi;
                    cursor_target = word.lo;
                } else {
                    state.selection_anchor = origin.lo;
                    cursor_target = word.hi;
                }
            } else {
                cursor_target = mouse_offset;
            }
        } else { // Press
            state.mouse_was_down = true;
            // A double-click takes the whole word under the pointer. On anything that isn't a
            // word — whitespace, a line end — it falls back to placing the caret, which is what
            // a single click there would have done anyway.
            const word = if (in.clicks >= 2) wordAt(full_text, mouse_offset) else null;
            state.word_drag = word;
            state.selection_anchor = if (word) |w| w.lo else mouse_offset;
            cursor_target = if (word) |w| w.hi else mouse_offset;
        }
    } else if (!in.mouse_down and state.mouse_was_down) { // Click release
        state.mouse_was_down = false;
        state.word_drag = null;
        // A click leaves an empty selection; collapse it so only a real drag keeps the anchor.
        if (state.selection_anchor == state.cursor_i) state.selection_anchor = null;
    } else if (in.backspaces != 0) {
        if (selectionRange(state.*) != null) {
            try deleteSelectionJournalled(state, allocator);
        } else {
            const cursor_before = state.cursor_i;
            const anchor_before = state.selection_anchor;
            const backspaces = @min(state.cursor_i, in.backspaces);
            if (backspaces > 0) {
                state.dirty = true;
                const at = state.cursor_i - backspaces;
                // The deleted run sits just behind the cursor, so it is contiguous in the
                // buffer's head — no gap to straddle.
                const removed = try allocator.dupe(u8, state.gap_buf[at..state.cursor_i]);
                defer allocator.free(removed);
                state.cursor_i -= backspaces;
                state.text_len -= backspaces;
                try recordEdit(state, allocator, at, removed, "", cursor_before, anchor_before);
            }
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
        state.dirty = true;
        const cursor_before = state.cursor_i;
        const anchor_before = state.selection_anchor;

        // Typing over a selection replaces it, so that text is part of this one edit.
        var removed: []u8 = &.{};
        defer allocator.free(removed);
        if (selectionRange(state.*)) |sel| {
            removed = try allocator.alloc(u8, sel.hi - sel.lo);
            _ = copyRange(state.*, sel.lo, sel.hi, removed);
        }
        deleteSelection(state);

        const at = state.cursor_i;
        try ensureCapacity(state, allocator, in.text.len);
        // Insert only real document content; drop control/non-printable bytes
        for (in.text) |byte| {
            const is_control_byte = (byte < 0x20 and byte != '\n') or byte == 0x7f;
            if (is_control_byte) continue;
            state.gap_buf[state.cursor_i] = byte;
            state.cursor_i += 1;
            state.text_len += 1;
        }
        // Read what landed rather than what was offered: filtering means the two can differ,
        // and undo has to restore the document, not the keystrokes.
        const inserted = state.gap_buf[at..state.cursor_i];
        if (removed.len > 0 or inserted.len > 0) {
            try recordEdit(state, allocator, at, removed, inserted, cursor_before, anchor_before);
        }
    }
    if (cursor_target) |target| moveCursorTo(state, target);
}

/// Split `full_text` into renderable fragments bounded by lines.
fn splitLines(
    full_text: []const u8,
    tokens: []const Token,
    out: []Line,
    frags: []Fragment,
    m: Measurer,
    reveal: Reveal,
) []Line {
    const last_token = tokens[tokens.len - 1];
    const doc_end = last_token.startI + last_token.contents.len;

    var lineno: usize = 0;
    var frag_count: usize = 0;
    var row_start: usize = 0;

    while (true) {
        beginRow(out, lineno, row_start, tokens, m, reveal);

        const hard_end = std.mem.indexOfScalarPos(u8, full_text[0..doc_end], row_start, '\n') orelse doc_end;
        const soft_end = maxFitLineEnd(
            m,
            reveal,
            tokens,
            full_text,
            row_start,
            hard_end,
            m.content_w - out[lineno].indent, // an indented row has that much less to fill
        );

        out[lineno].text = full_text[row_start..soft_end];
        out[lineno].frag_start = frag_count;
        pushRowFragments(frags, &frag_count, tokens, row_start, soft_end, reveal);
        out[lineno].frag_end = frag_count;
        lineno += 1;

        if (soft_end < hard_end) {
            row_start = soft_end;
        } else {
            // The row reached the newline that ended it, or the end of the document.
            if (hard_end >= doc_end) break;
            row_start = hard_end + 1; // step over the '\n'; it is drawn by nothing
        }
        if (lineno == out.len) break; // out of rows: lay out what fits rather than overrun
    }

    for (out[0..lineno]) |*line| {
        const line_end = line.start + line.text.len;
        const attr = attributedRange(full_text, tokens, line.start, line_end, reveal, m.run_buf);
        line.h = if (attr.isEmpty())
            m.height(line.text, tokens, line.start, line_end)
        else
            m.attributedH(attr);
        line.w = xForOffset(line.*, frags, full_text, tokens, line_end, m);
    }
    applyBlockMargins(out[0..lineno], tokens);

    // Running out of either buffer means the layout stops partway on purpose, so the "nothing
    // was left over" halves of the check don't apply to it.
    const truncated = lineno == out.len or frag_count == frags.len;
    assertRowsTile(out[0..lineno], frags, full_text, doc_end, truncated);

    return out[0..lineno];
}

/// The structural contract of a laid-out row set: rows tile the source, and each row's
/// fragments tile the row.
///
/// Everything downstream reads these as given. `handleInput` maps a click to an offset by
/// walking rows and assuming the next one starts where the last ended; `xForOffset` walks a
/// row's fragments and assumes they are contiguous and in order. Neither re-derives it, so a
/// gap here surfaces far away as a caret in the wrong place rather than as a layout fault.
///
/// Checked here rather than in tests because it holds for *every* input `splitLines` is ever
/// given, which no set of hand-picked examples can cover.
///
/// Guarded as a whole rather than left to the individual `assert`s. Those compile to nothing on
/// their own, but the walk that feeds them does not, and this is O(rows + fragments) on top of a
/// layout that already ran. `runtime_safety` is comptime-known, so in a release build the early
/// return is the entire function and the call goes with it. Same shape as
/// `std.debug.assertReadable`, for the same reason.
fn assertRowsTile(
    lines: []const Line,
    frags: []const Fragment,
    full_text: []const u8,
    doc_end: usize,
    truncated: bool,
) void {
    if (!std.debug.runtime_safety) return;
    if (lines.len == 0) return;
    assert(lines[0].start == 0);

    for (lines, 0..) |line, i| {
        const line_end = line.start + line.text.len;
        assert(line_end <= doc_end);

        if (i + 1 < lines.len) {
            // A soft wrap continues at the offset the last row stopped at. A hard break steps
            // over the '\n' that ended it, which belongs to no row because nothing draws it.
            const next = lines[i + 1].start;
            assert(next == line_end or
                (next == line_end + 1 and line_end < full_text.len and full_text[line_end] == '\n'));
        } else if (!truncated) {
            assert(line_end == doc_end); // no tail of the document went unlaid
        }

        // A blank row carries no fragments. It still belongs to whatever block owns it — the
        // render pass looks that up by offset — but there is nothing on it to tile.
        if (line.frag_start == line.frag_end) continue;

        var off = line.start;
        for (frags[line.frag_start..line.frag_end]) |frag| {
            assert(frag.start == off); // contiguous: no gaps, no overlaps, in order
            assert(frag.end > frag.start); // an empty fragment is never pushed
            off = frag.end;
        }
        if (!truncated) assert(off == line_end);
    }
}

fn maxFitLineEnd(
    m: Measurer,
    reveal: Reveal,
    tokens: []const Token,
    full_text: []const u8,
    start_i: usize,
    end_i: usize,
    max_width: f64,
) usize {
    if (end_i <= start_i) return start_i;

    var best = start_i;
    var lo = start_i;
    var hi = end_i;

    while (lo < hi) {
        const mid = lo + ((hi - lo) + 1) / 2;
        var probe = mid;
        while (probe < end_i and (full_text[probe] & 0xC0) == 0x80) probe += 1;

        const attr = attributedRange(full_text, tokens, start_i, probe, reveal, m.run_buf);
        if (m.attributedW(attr) < max_width) {
            best = @max(best, probe);
            lo = mid;
        } else {
            hi = mid - 1;
        }
    }

    if (best == start_i) {
        // Not even one character fits. Emit it anyway: a row has to advance, or `splitLines`
        // never terminates. Nothing to retreat to either, so this returns straight out.
        const seq = std.unicode.utf8ByteSequenceLength(full_text[start_i]) catch 1;
        return @min(start_i + seq, end_i);
    }
    return wrapPoint(m, reveal, tokens, full_text, start_i, best, end_i, max_width);
}

/// Move a character-level wrap point back to where a word ends, so a row does not split a word
/// down the middle.
///
/// Returns `best` unchanged when the row is not wrapping at all — it reached a newline or the end
/// of the document — and when retreating would not help, for which see below.
///
/// A space is ASCII, so it can never be a UTF-8 continuation byte: every offset this returns is
/// already on a codepoint boundary, and the search needs no decoding of its own.
fn wrapPoint(
    m: Measurer,
    reveal: Reveal,
    tokens: []const Token,
    full_text: []const u8,
    start_i: usize,
    best: usize,
    end_i: usize,
    max_width: f64,
) usize {
    if (best >= end_i) return best;

    // The break already falls between words. Let the spaces ride along on the row they end rather
    // than pushing them onto the next one, where they would read as a stray indent. Overhanging
    // the column costs nothing: a space draws no glyph.
    if (full_text[best] == ' ') {
        var b = best;
        while (b < end_i and full_text[b] == ' ') b += 1;
        return b;
    }

    // Mid-word. The only retreat worth making is to the start of the word being split, so scan
    // back for the space that begins it — anything earlier would give up a word that fit.
    var b = best;
    while (b > start_i and full_text[b - 1] != ' ') b -= 1;
    if (b == start_i) return best; // the row is one unbroken word; it has to break somewhere

    // Retreat only if that word will actually fit on a row of its own. A word wider than the
    // column gets broken wherever it falls no matter what we do here, and retreating for it would
    // leave this row nearly empty and *still* break the word on the next one.
    var word_end = b;
    while (word_end < end_i and full_text[word_end] != ' ') word_end += 1;
    const attr = attributedRange(full_text, tokens, b, word_end, reveal, m.run_buf);
    return if (m.attributedW(attr) < max_width) b else best;
}

/// The source line containing `cursor_i`, excluding its trailing newline.
fn revealForCursor(text: []const u8, cursor_i: usize) Reveal {
    const cursor = @min(cursor_i, text.len);
    var start: usize = 0;
    for (text[0..cursor], 0..) |c, i| {
        if (c == '\n') start = i + 1;
    }
    var end = cursor;
    while (end < text.len and text[end] != '\n') : (end += 1) {}
    return .{ .start = start, .end = end };
}

// **************************************************************************************** Helpers
/// Map a canvas point to the document offset the caret would take there — the inverse of
/// `xForOffset`, and the one place a pointer position becomes a text position.
fn offsetAtPoint(
    point: geom.Point,
    scroll_y: f64,
    lines: []const Line,
    tokens: []const Token,
    frags: []const Fragment,
    full_text: []const u8,
    measurer: Measurer,
) usize {
    // Work in document space: drop the content margin, then add how far we are scrolled. Falling
    // off either end of the loop clamps to the first or last row, which is what a click above or
    // below the text should do.
    const doc_y = (point.y - padding()) + scroll_y;
    var lineno: usize = lines.len - 1;
    var y: f64 = 0;
    for (lines, 0..) |l, i| {
        // The row's own height, margins and all, rather than a fresh measurement of its text: the
        // rows were *placed* by these, so anything else drifts from where the user is actually
        // looking — by a whole block margin next to a heading, and by the difference between a
        // measured line and a shaped one everywhere else.
        if (doc_y < y + l.h) {
            lineno = i;
            break;
        }
        y += l.h;
    }
    const line = lines[lineno];
    var col: usize = line.text.len;
    // Start where the row's glyphs start, not at the margin: on an indented row the two differ,
    // and walking from the margin would map every click an indent's worth of characters to the
    // right.
    var curr_x: f64 = padding() + line.indent;
    // Walk the row's visible runs. Concealed delimiters measure zero, so a click never lands past
    // them by their source length — and landing *inside* one is harmless, since arriving there
    // reveals the line.
    walk: for (frags[line.frag_start..line.frag_end]) |frag| {
        var off = frag.start;
        while (off < frag.end) : (off += 1) {
            const w = if (off >= frag.vis_start and off < frag.vis_end)
                charWidth(full_text, tokens, off, measurer)
            else
                0;
            if (point.x < curr_x + (w / 2.0)) {
                col = off - line.start;
                break :walk;
            }
            curr_x += w;
        }
    }
    return line.start + col;
}

/// Move the cursor to document offset `target`, shifting the gap to match.
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

/// The selected span as doc offsets, or null when nothing selected. Single caret != selection.
fn selectionRange(state: AppState) ?Range {
    const anchor = state.selection_anchor orelse return null;
    const lo = @min(anchor, state.cursor_i);
    const hi = @max(anchor, state.cursor_i);
    return if (lo == hi) null else .{ .lo = lo, .hi = hi };
}

/// Whether `c` belongs to a word, for the purposes of double-click and right-click selection.
///
/// Every non-ASCII byte counts. They are the lead and continuation bytes of a multi-byte
/// codepoint, and treating them as separators would cut an accented word in half — worse, in the
/// middle of a codepoint, which is not a position the caret may take.
fn isWordByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c >= 0x80;
}

/// The word surrounding caret offset `at`, or null when there is no word there.
///
/// The offset just past a word's last byte counts as on it: that is where a click on the right
/// half of the final character lands, and answering "no word" for the trailing edge of every word
/// would make double-click miss about half the time.
fn wordAt(text: []const u8, at: usize) ?Range {
    const on_word = at < text.len and isWordByte(text[at]);
    const after_word = at > 0 and at <= text.len and isWordByte(text[at - 1]);
    if (!on_word and !after_word) return null;

    var lo = at;
    while (lo > 0 and isWordByte(text[lo - 1])) lo -= 1;
    var hi = at;
    while (hi < text.len and isWordByte(text[hi])) hi += 1;
    return .{ .lo = lo, .hi = hi };
}

fn styleForToken(token: Token) Style {
    return switch (token.tType) {
        .HEADER => .{
            .color = th().text,
            .font = .{ .size = th().font_size * th().metrics.headingScale(token.degree) },
        },
        .BOLD => .{
            .color = th().text,
            .font = .{ .size = th().font_size, .bold = true },
        },
        .ITALIC => .{
            .color = th().text,
            .font = .{ .size = th().font_size, .italic = true },
        },
        .EMPHASIS => .{
            .color = th().text,
            .font = .{ .size = th().font_size, .bold = true, .italic = true },
        },
        .CODE => .{
            .color = th().code,
            .background = th().code_bg,
            .font = .{ .size = th().font_size },
        },
        .BLOCK_CODE => .{
            .color = th().code,
            .background = th().code_bg,
            .panel = .full,
            .font = .{ .size = th().font_size },
        },
        .LINK => .{
            .color = th().link,
            .font = .{ .size = th().font_size, .underline = true },
        },
        .QUOTE => .{
            .color = th().quote,
            .font = .{ .size = th().font_size },
        },
        else => .{
            .color = th().text,
            .font = .{ .size = th().font_size },
        },
    };
}

/// The token covering source offset `i`, falling back to final token if `i` is past the end.
fn tokenAt(tokens: []const Token, i: usize) Token {
    return tokens[tokenIndexAt(tokens, i)];
}

/// Where that token sits in the list. Two rows belong to the same block when this is equal for
/// both, which is what tells a soft-wrapped continuation from the start of something new.
fn tokenIndexAt(tokens: []const Token, i: usize) usize {
    for (tokens, 0..) |t, ti| {
        if (i >= t.startI and i < t.endI) return ti;
    }
    return tokens.len - 1;
}

/// The vertical space a block-level element asks for above and below itself. Zero for anything
/// that isn't one — body text is spaced by its own line height.
fn blockMarginY(token: Token) f64 {
    const m = th().metrics;
    return switch (token.tType) {
        .HEADER => m.heading_margin_y,
        .BLOCK_CODE => m.code_margin_y,
        .QUOTE => m.quote_margin_y,
        else => 0,
    };
}

/// Whether two rows belong to the same block, and so should not have a margin between them.
fn sameBlock(tokens: []const Token, a_start: usize, b_start: usize) bool {
    const ai = tokenIndexAt(tokens, a_start);
    const bi = tokenIndexAt(tokens, b_start);
    if (ai == bi) return true; // one token soft-wrapped across rows, or a fence's inner lines
    // A quote tokenizes one token per source line, so a five-line quote is five tokens. Left at
    // token identity it would be five blocks, and the margin would land *between* its lines
    // rather than around the whole of it.
    return tokens[ai].tType == .QUOTE and tokens[bi].tType == .QUOTE;
}

/// Give each block's first and last row the margin it asks for.
///
/// Run over the finished rows rather than folded into the height loop above: whether a row ends a
/// block is only knowable once the row after it exists. Margins are added to `h`, so every
/// consumer of a row's height — placement, scrolling, hit-testing — accounts for them without
/// knowing they are there.
///
/// Both fields are written for every row, never left alone. `lines` is the layout's scratch,
/// reused by every recalc, so a row that carried a margin before the window was resized is still
/// holding it when a rewrap makes that slot an ordinary paragraph. Skipping the write would leave
/// the stale value to be drawn against a height that no longer includes it — the row's glyphs
/// pushed down into the row below.
fn applyBlockMargins(lines: []Line, tokens: []const Token) void {
    for (lines, 0..) |*line, i| {
        const margin = blockMarginY(tokenAt(tokens, line.start));
        const opens = i == 0 or !sameBlock(tokens, lines[i - 1].start, line.start);
        const closes = i + 1 == lines.len or !sameBlock(tokens, line.start, lines[i + 1].start);
        line.lead = if (opens) margin else 0;
        line.trail = if (closes) margin else 0;
        line.h += line.lead + line.trail;
    }
}

fn widthWithCanvas(ctx: *anyopaque, text: []const u8, tokens: []const Token, start_i: usize, end_i: usize) f64 {
    _ = end_i;
    const canvas: *Canvas = @ptrCast(@alignCast(ctx));
    return canvas.measureText(text, styleForToken(tokenAt(tokens, start_i)).font).w;
}

fn heightWithCanvas(ctx: *anyopaque, text: []const u8, tokens: []const Token, start_i: usize, end_i: usize) f64 {
    _ = end_i;
    const canvas: *Canvas = @ptrCast(@alignCast(ctx));
    // An empty line (e.g. a blank line after a trailing '\n') still occupies vertical space.
    const measured = if (text.len == 0) " " else text;
    return canvas.measureText(measured, styleForToken(tokenAt(tokens, start_i)).font).h;
}

fn attrWidthWithCanvas(ctx: *anyopaque, text: AttributedText) f64 {
    const canvas: *Canvas = @ptrCast(@alignCast(ctx));
    return canvas.measureTextAttributed(text).w;
}

fn attrHeightWithCanvas(ctx: *anyopaque, text: AttributedText) f64 {
    const canvas: *Canvas = @ptrCast(@alignCast(ctx));
    return canvas.measureTextAttributed(text).h;
}

/// Open a row at `start`, inheriting the indent of the block that owns that offset.
fn beginRow(out: []Line, lineno: usize, start: usize, tokens: []const Token, m: Measurer, reveal: Reveal) void {
    out[lineno].start = start;
    const token = tokenAt(tokens, start);
    out[lineno].indent = switch (token.tType) {
        .QUOTE => th().metrics.quote_indent * @as(f64, @floatFromInt(token.degree)),
        .UNORDERED_LIST => s: {
            if (reveal.covers(start) and start == token.startI) {
                break :s 0;
            } else {
                const marker_end = @min(token.renderStart, token.contents.len);
                const marker_width = m.width(token.contents[0..marker_end], tokens, token.startI, token.startI + marker_end);
                break :s marker_width;
            }
        },
        else => 0,
    };
}

/// Fill one row's background panel.
fn fillPanel(canvas: *Canvas, rect: geom.Rect, color: Color) void {
    const top = @floor(rect.y);
    const bottom = @floor(rect.y + rect.h);
    canvas.fillRect(.{ .x = rect.x, .y = top, .w = rect.w, .h = bottom - top }, color);
}

fn pushFragment(
    frags: []Fragment,
    count: *usize,
    tokens: []const Token,
    tok: usize,
    from: usize,
    to: usize,
    reveal: Reveal,
) void {
    if (to <= from) return;
    // A fragment never straddles a newline, so the whole of it shares one reveal state.
    var vis_start = from;
    var vis_end = to;
    if (!reveal.covers(from)) {
        const token = tokens[tok];
        vis_start = std.math.clamp(token.startI + token.renderStart, from, to);
        vis_end = std.math.clamp(token.startI + token.renderEnd, vis_start, to);
    }
    // The drawn sub-range never escapes the fragment. The render pass slices `full_text` with
    // these two directly, so an inverted or out-of-range pair is a bad slice rather than a
    // wrong-looking row.
    assert(from <= vis_start and vis_start <= vis_end and vis_end <= to);
    frags[count.*] = .{ .tok = tok, .start = from, .end = to, .vis_start = vis_start, .vis_end = vis_end };
    count.* += 1;
}

/// Tile the row `[from, to)` with one fragment per token it touches.
///
/// The old character loop accumulated these as it went, opening a run at every token boundary
/// and closing it at every wrap. Now that a row's extent is known before anything is emitted,
/// the row can simply be intersected with the token list — the same clipping `attributedRange`
/// does, so what gets drawn and what got measured are derived the same way.
fn pushRowFragments(
    frags: []Fragment,
    count: *usize,
    tokens: []const Token,
    from: usize,
    to: usize,
    reveal: Reveal,
) void {
    if (to <= from) return; // a blank row owns no fragments, only the block it sits in
    for (tokens, 0..) |token, ti| {
        const lo = @max(token.startI, from);
        const hi = @min(token.startI + token.contents.len, to);
        if (hi <= lo) continue;
        if (count.* == frags.len) return;
        pushFragment(frags, count, tokens, ti, lo, hi, reveal);
    }
}

/// Describe `full_text[start_i..end_i)` the way the tokens style it: one run per styled span,
/// ready to be measured or drawn as a single line. The runs are written into `out`, and the
/// returned value views the prefix of it that was used.
///
/// Concealed delimiters are dropped rather than carried along as empty runs. What this
/// describes is what actually gets drawn, and a hidden delimiter occupies no width — the same
/// rule `pushFragment` applies, which is what makes a width measured through here agree with
/// the row the render pass goes on to lay down.
///
/// Reveal is read once per token rather than per character, on `pushFragment`'s grounds: a row
/// never straddles a newline, so its reveal state is uniform. A caller handing over a range
/// that does span one is outside that assumption.
fn attributedRange(
    full_text: []const u8,
    tokens: []const Token,
    start_i: usize,
    end_i: usize,
    reveal: Reveal,
    out: []AttributedText.Run,
) AttributedText {
    var count: usize = 0;
    // Source bounds of the run sitting at `out[count - 1]`, so a span that continues it can be
    // folded in without re-deriving where it started.
    var run_start: usize = 0;
    var run_end: usize = 0;

    for (tokens) |token| {
        // Clip the token to the requested range; most of the document falls outside it.
        const from = @max(token.startI, start_i);
        const to = @min(token.startI + token.contents.len, end_i);
        if (to <= from) continue;

        // Off the cursor's line only the token's middle is drawn, the delimiters around it
        // being concealed. Same clamp as `pushFragment`, so the two agree on what is visible.
        var vis_start = from;
        var vis_end = to;
        if (!reveal.covers(from)) {
            vis_start = std.math.clamp(token.startI + token.renderStart, from, to);
            vis_end = std.math.clamp(token.startI + token.renderEnd, vis_start, to);
        }
        if (vis_end <= vis_start) continue; // wholly concealed: no glyphs to shape

        const style = styleForToken(token);
        // Fold into the previous run where the two abut and are styled alike. Two plain tokens
        // in a row are one run as far as the shaper is concerned, and keeping them one lets it
        // kern across a boundary that exists only in the parse.
        if (count > 0 and run_end == vis_start and
            std.meta.eql(out[count - 1].font, style.font) and
            std.meta.eql(out[count - 1].color, style.color))
        {
            run_end = vis_end;
            out[count - 1].text = full_text[run_start..run_end];
            continue;
        }

        if (count == out.len) break; // out of room: describe what fits rather than overrun
        out[count] = .{
            .text = full_text[vis_start..vis_end],
            .font = style.font,
            .color = style.color,
        };
        count += 1;
        run_start = vis_start;
        run_end = vis_end;
    }

    return .{ .runs = out[0..count] };
}

/// Width of the one UTF-8 character starting at `off`.
fn charWidth(full_text: []const u8, tokens: []const Token, off: usize, m: Measurer) f64 {
    const seq_len = std.unicode.utf8ByteSequenceLength(full_text[off]) catch return 0;
    const end = @min(off + seq_len, full_text.len);
    return m.width(full_text[off..end], tokens, off, end);
}

/// The x of source offset `off`, relative to the row's text origin.
fn xForOffset(
    line: Line,
    frags: []const Fragment,
    full_text: []const u8,
    tokens: []const Token,
    off: usize,
    m: Measurer,
) f64 {
    var x: f64 = 0;
    for (frags[line.frag_start..line.frag_end]) |frag| {
        if (off >= frag.end) {
            x += m.width(full_text[frag.vis_start..frag.vis_end], tokens, frag.vis_start, frag.vis_end);
            continue;
        }
        const stop = std.math.clamp(off, frag.vis_start, frag.vis_end);
        x += m.width(full_text[frag.vis_start..stop], tokens, frag.vis_start, stop);
        break;
    }
    return x;
}

/// Index of the rendered line containing `cursor_i`.
fn cursorLine(lines: []const Line, cursor_i: usize) usize {
    var result: usize = 0;
    for (lines, 0..) |line, i| {
        if (cursor_i >= line.start and cursor_i <= line.start + line.text.len) result = i;
    }
    return result;
}

/// The line and height of every line visible when scrolled to `scroll_y`.
fn visiblePlacements(lines: []const Line, scroll_y: f64, viewport_h: f64, out: []Placement) []Placement {
    var count: usize = 0;
    var doc_y: f64 = 0; // top of the current line, in document space
    for (lines, 0..) |line, i| {
        const top = doc_y - scroll_y;
        doc_y += line.h;
        if (doc_y - scroll_y <= 0) continue; // entirely above the viewport
        if (top >= viewport_h) break; // entirely below it, and so is everything after
        out[count] = .{ .line = i, .y = top };
        count += 1;
    }
    return out[0..count];
}

/// Document-space y of the top of `line_i`.
fn lineTop(lines: []const Line, line_i: usize) f64 {
    var y: f64 = 0;
    for (lines[0..line_i]) |line| y += line.h;
    return y;
}

/// The smallest adjustment to `scroll_y` that brings `cursor_line` fully into view.
fn scrollToCursor(lines: []const Line, scroll_y: f64, cursor_line: usize, viewport_h: f64) f64 {
    const top = lineTop(lines, cursor_line);
    const bottom = top + lines[cursor_line].h;

    var result = scroll_y;
    if (bottom > result + viewport_h) result = bottom - viewport_h; // below the viewport
    // Checked second on purpose: a line taller than the viewport satisfies both tests, and
    // pinning it to its top is the more useful of the two outcomes.
    if (top < result) result = top;
    return result;
}

fn freeEdit(alloc: Allocator, e: Edit) void {
    alloc.free(e.removed);
    alloc.free(e.inserted);
}

fn clearRedo(state: *AppState, alloc: Allocator) void {
    for (state.history.redo_stack.items) |e| freeEdit(alloc, e);
    state.history.redo_stack.clearRetainingCapacity();
}

/// Journal an edit. `removed` and `inserted` are borrowed; this copies what it keeps.
fn recordEdit(
    state: *AppState,
    alloc: Allocator,
    at: usize,
    removed: []const u8,
    inserted: []const u8,
    cursor_before: usize,
    anchor_before: ?usize,
) !void {
    // Editing after undoing abandons the redone-future; those entries can never be reached.
    clearRedo(state, alloc);

    const pure_insert = removed.len == 0 and inserted.len > 0;
    if (state.history.coalesce and pure_insert and state.history.undo_stack.items.len > 0) {
        const top = &state.history.undo_stack.items[state.history.undo_stack.items.len - 1];
        const contiguous = at == top.at + top.inserted.len;
        // A newline ends the run: undoing a paragraph one line at a time is more useful than
        // losing all of it at once.
        const spans_newline = std.mem.indexOfScalar(u8, inserted, '\n') != null or
            std.mem.indexOfScalar(u8, top.inserted, '\n') != null;
        if (top.removed.len == 0 and contiguous and !spans_newline) {
            const merged = try alloc.alloc(u8, top.inserted.len + inserted.len);
            @memcpy(merged[0..top.inserted.len], top.inserted);
            @memcpy(merged[top.inserted.len..], inserted);
            alloc.free(top.inserted);
            top.inserted = merged;
            return;
        }
    }

    const entry = Edit{
        .at = at,
        .removed = try alloc.dupe(u8, removed),
        .inserted = try alloc.dupe(u8, inserted),
        .cursor_before = cursor_before,
        .anchor_before = anchor_before,
    };
    errdefer freeEdit(alloc, entry);
    try state.history.undo_stack.append(alloc, entry);

    if (state.history.undo_stack.items.len > MAX_UNDO_DEPTH) {
        freeEdit(alloc, state.history.undo_stack.orderedRemove(0));
    }
    state.history.coalesce = pure_insert;
}

/// Grow the gap buffer so `extra` more bytes fit, preserving the gap's position.
fn ensureCapacity(state: *AppState, allocator: Allocator, extra: usize) !void {
    const needed = state.text_len + extra;
    if (needed < state.gap_buf.len) return;

    var new_buf_len: usize = state.gap_buf.len;
    while (new_buf_len <= needed) new_buf_len = new_buf_len << 1;
    assert(new_buf_len <= MAX_BUF_LEN);

    const new_buf = try allocator.alloc(u8, new_buf_len);
    if (state.cursor_i > 0) {
        @memcpy(new_buf[0..state.cursor_i], state.gap_buf[0..state.cursor_i]);
    }
    assert(state.gap_buf.len >= state.gap_end);
    const new_gap_end = new_buf_len - (state.gap_buf.len - state.gap_end);
    if (state.gap_end < state.gap_buf.len) {
        @memcpy(new_buf[new_gap_end..new_buf_len], state.gap_buf[state.gap_end..state.gap_buf.len]);
    }
    allocator.free(state.gap_buf);
    state.gap_buf = new_buf;
    state.gap_end = new_gap_end;
}

/// Replace document range `[from, to)` with `text`, leaving the caret after the new text.
/// Unlike the typing path this does no filtering — it replays text the editor already accepted.
fn applyReplace(state: *AppState, alloc: Allocator, from: usize, to: usize, text: []const u8) !void {
    moveCursorTo(state, from);
    const deleted = to - from;
    state.gap_end += deleted;
    state.text_len -= deleted;

    try ensureCapacity(state, alloc, text.len);
    for (text) |b| {
        state.gap_buf[state.cursor_i] = b;
        state.cursor_i += 1;
        state.text_len += 1;
    }
    state.selection_anchor = null;
}

/// Copy document bytes `[from, to)` into `out`, returning how many were written.
///
/// The gap sits at the cursor, so a range straddling it lives in two pieces of `gap_buf` that
/// aren't adjacent — hence two copies rather than one slice.
fn copyRange(state: AppState, from: usize, to: usize, out: []u8) usize {
    var n: usize = 0;
    const head_end = @min(to, state.cursor_i);
    if (from < head_end) {
        const len = head_end - from;
        @memcpy(out[n..][0..len], state.gap_buf[from..head_end]);
        n += len;
    }
    if (to > state.cursor_i) {
        const tail_from = @max(from, state.cursor_i);
        const len = to - tail_from;
        const src = state.gap_end + (tail_from - state.cursor_i);
        @memcpy(out[n..][0..len], state.gap_buf[src..][0..len]);
        n += len;
    }
    return n;
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

// ****************************************************************************************** Tests
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

/// One unit per byte, matching `fakeWidth`, so a test can state its content width in
/// characters. Summing the runs is the point: concealed text is not among them, so it costs
/// nothing here exactly as it costs nothing on screen.
fn fakeAttrWidth(_: *anyopaque, text: AttributedText) f64 {
    var sum: f64 = 0.0;
    for (text.runs) |run| sum += @floatFromInt(run.text.len);
    return sum;
}

fn fakeAttrHeight(_: *anyopaque, _: AttributedText) f64 {
    return 1;
}

/// Backs `Measurer.run_buf` for the tests. A document in a test is a few dozen bytes and one
/// run per token is the ceiling, so this cannot be reached.
var test_run_buf: [256]AttributedText.Run = undefined;

fn testMeasurer(content_w: f64) Measurer {
    return .{
        .content_w = content_w,
        .ctx = &fake_ctx,
        .widthFn = fakeWidth,
        .heightFn = fakeHeight,
        .attrWidthFn = fakeAttrWidth,
        .attrHeightFn = fakeAttrHeight,
        .run_buf = &test_run_buf,
    };
}

/// A whole document as one plain token. `renderEnd` must be set explicitly: it defaults to 0,
/// which would mean "nothing between the delimiters is visible" and conceal the entire text.
fn plainTokenize(full_text: []const u8) Token {
    return Token{
        .tType = .PLAIN,
        .startI = 0,
        .endI = full_text.len,
        .contents = full_text,
        .renderStart = 0,
        .renderEnd = full_text.len,
    };
}

/// Parse `full_text` into flat markdown tokens, falling back to a single plain token for an empty
/// document (which the parser returns none for). Tokens live in `arena` and are valid only until
/// the next `tokenize` call against it, which resets it.
fn tokenize(arena: *std.heap.ArenaAllocator, full_text: []const u8) ![]const Token {
    _ = arena.reset(.retain_capacity);
    const parsed = try markdown.parseFlat(arena.allocator(), full_text);
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
    const reveal = revealForCursor(doc, state.cursor_i);
    const lines = splitLines(doc, tokens, &line_buf, &frag_buf, measurer, reveal);
    try handleInput(testing_allocator, in, state, lines, tokens, &frag_buf, doc, measurer);
}

/// Every line revealed, for tests about layout rather than concealment.
fn revealAll(text: []const u8) Reveal {
    return .{ .start = 0, .end = text.len };
}

test "revealForCursor picks out the cursor's source line" {
    const text = "one\ntwo\nthree";
    try expectEqual(Reveal{ .start = 0, .end = 3 }, revealForCursor(text, 0));
    try expectEqual(Reveal{ .start = 0, .end = 3 }, revealForCursor(text, 3)); // end of line 1
    try expectEqual(Reveal{ .start = 4, .end = 7 }, revealForCursor(text, 4));
    try expectEqual(Reveal{ .start = 4, .end = 7 }, revealForCursor(text, 6));
    try expectEqual(Reveal{ .start = 8, .end = 13 }, revealForCursor(text, 13)); // end of doc
}

/// Everything an attributed range would actually shape, concatenated.
fn attributedText(buf: []u8, at: AttributedText) []const u8 {
    var n: usize = 0;
    for (at.runs) |run| {
        @memcpy(buf[n .. n + run.text.len], run.text);
        n += run.text.len;
    }
    return buf[0..n];
}

test "attributedRange styles a span and drops what is concealed" {
    var runs: [16]AttributedText.Run = undefined;
    var buf: [64]u8 = undefined;
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();

    const text = "a**b**c";
    const tokens = try markdown.parseFlat(arena.allocator(), text);

    // Off the cursor's line the asterisks go, exactly as the render pass drops them — so a
    // width measured from this is the width of what the user will see.
    const hidden = attributedRange(text, tokens, 0, text.len, Reveal.none, &runs);
    try expectEqualStrings("abc", attributedText(&buf, hidden));
    try expectEqual(@as(usize, 3), hidden.runs.len);
    // The styling survives the concealment: only the middle run is bold.
    try expect(!hidden.runs[0].font.bold);
    try expect(hidden.runs[1].font.bold);
    try expect(!hidden.runs[2].font.bold);

    // On the cursor's line the delimiters come back, and they are the bold token's own text,
    // so they are shaped bold too.
    const shown = attributedRange(text, tokens, 0, text.len, revealAll(text), &runs);
    try expectEqualStrings("a**b**c", attributedText(&buf, shown));
}

test "attributedRange joins abutting runs that share a style" {
    var runs: [8]AttributedText.Run = undefined;
    var buf: [32]u8 = undefined;
    const text = "abcd";

    // Two plain tokens tiling the text. The shaper must not be shown a boundary that exists
    // only in the parse: kerning does not cross a run, so splitting here would measure wider
    // than the same text drawn as one piece.
    const plain = [_]Token{
        .{ .tType = .PLAIN, .startI = 0, .endI = 2, .contents = "ab", .renderEnd = 2 },
        .{ .tType = .PLAIN, .startI = 2, .endI = 4, .contents = "cd", .renderEnd = 2 },
    };
    const joined = attributedRange(text, &plain, 0, text.len, Reveal.none, &runs);
    try expectEqual(@as(usize, 1), joined.runs.len);
    try expectEqualStrings("abcd", attributedText(&buf, joined));

    // A genuine style change is a genuine boundary, and stays one.
    const mixed = [_]Token{
        .{ .tType = .PLAIN, .startI = 0, .endI = 2, .contents = "ab", .renderEnd = 2 },
        .{ .tType = .BOLD, .startI = 2, .endI = 4, .contents = "cd", .renderEnd = 2 },
    };
    const split = attributedRange(text, &mixed, 0, text.len, Reveal.none, &runs);
    try expectEqual(@as(usize, 2), split.runs.len);
    try expect(!split.runs[0].font.bold);
    try expect(split.runs[1].font.bold);
    try expectEqualStrings("abcd", attributedText(&buf, split));
}

test "attributedRange clips to the requested span" {
    var runs: [8]AttributedText.Run = undefined;
    var buf: [32]u8 = undefined;
    const text = "hello world";
    const tokens = &.{plainTokenize(text)};

    // The point of the range: `maxFitLineEnd` asks about a prefix of a row, not the document.
    const middle = attributedRange(text, tokens, 2, 7, Reveal.none, &runs);
    try expectEqualStrings("llo w", attributedText(&buf, middle));

    // An empty or inverted range describes nothing rather than the whole document.
    try expect(attributedRange(text, tokens, 4, 4, Reveal.none, &runs).isEmpty());
    try expect(attributedRange(text, tokens, 7, 2, Reveal.none, &runs).isEmpty());
}

test "attributedRange stops at the end of the run buffer" {
    var runs: [1]AttributedText.Run = undefined;
    const text = "abcd";
    const tokens = [_]Token{
        .{ .tType = .PLAIN, .startI = 0, .endI = 2, .contents = "ab", .renderEnd = 2 },
        .{ .tType = .BOLD, .startI = 2, .endI = 4, .contents = "cd", .renderEnd = 2 },
    };
    // Describing a prefix is wrong, but it is bounded and it is not a buffer overrun.
    const at = attributedRange(text, &tokens, 0, text.len, Reveal.none, &runs);
    try expectEqual(@as(usize, 1), at.runs.len);
}

test "copySelection reads a range that straddles the gap" {
    var buf: [64]u8 = undefined;
    var state = AppState.init(&buf);
    defer deinitHistory(&state, testing_allocator);
    try feed(&state, .{ .text = "abcdef" });

    // Put the cursor in the middle so the gap splits the document: "abc" | gap | "def".
    try feed(&state, .{ .lefts = 3 });
    try expectEqual(3, state.cursor_i);

    // Select "bcde" — two characters either side of the gap, so this is the case a naive
    // single-slice read would get wrong.
    state.selection_anchor = 1;
    moveCursorTo(&state, 5);

    var out: [16]u8 = undefined;
    try expectEqual(4, selectionLen(state));
    const n = copySelection(state, &out);
    try expectEqualStrings("bcde", out[0..n]);
}

test "copySelection handles selections wholly on either side of the gap" {
    var buf: [64]u8 = undefined;
    var state = AppState.init(&buf);
    defer deinitHistory(&state, testing_allocator);
    try feed(&state, .{ .text = "abcdef" });
    try feed(&state, .{ .lefts = 3 }); // cursor at 3

    var out: [16]u8 = undefined;

    { // entirely before the gap
        state.selection_anchor = 0;
        moveCursorTo(&state, 2);
        const n = copySelection(state, &out);
        try expectEqualStrings("ab", out[0..n]);
    }
    { // entirely after it
        moveCursorTo(&state, 3);
        state.selection_anchor = 4;
        moveCursorTo(&state, 6);
        const n = copySelection(state, &out);
        try expectEqualStrings("ef", out[0..n]);
    }
}

test "no selection copies nothing" {
    var buf: [64]u8 = undefined;
    var state = AppState.init(&buf);
    defer deinitHistory(&state, testing_allocator);
    try feed(&state, .{ .text = "abc" });

    var out: [16]u8 = undefined;
    try expectEqual(0, selectionLen(state));
    try expectEqual(0, copySelection(state, &out));

    // An anchor sitting exactly on the cursor is an empty selection, not a selection of one.
    state.selection_anchor = state.cursor_i;
    try expectEqual(0, selectionLen(state));
    try expectEqual(0, copySelection(state, &out));
}

test "copySelection refuses a buffer that is too small rather than truncating" {
    var buf: [64]u8 = undefined;
    var state = AppState.init(&buf);
    defer deinitHistory(&state, testing_allocator);
    try feed(&state, .{ .text = "abcdef" });
    state.selection_anchor = 0; // whole document selected, cursor already at the end

    var small: [3]u8 = undefined;
    try expectEqual(6, selectionLen(state));
    try expectEqual(0, copySelection(state, &small));
}

test "selectAll spans the document and leaves the cursor at the end" {
    var buf: [64]u8 = undefined;
    var state = AppState.init(&buf);
    defer deinitHistory(&state, testing_allocator);
    try feed(&state, .{ .text = "ab\ncd" });
    try feed(&state, .{ .lefts = 3 }); // cursor into the middle first

    selectAll(&state);
    try expectEqual(@as(?usize, 0), state.selection_anchor);
    try expectEqual(5, state.cursor_i);

    var out: [16]u8 = undefined;
    const n = copySelection(state, &out);
    try expectEqualStrings("ab\ncd", out[0..n]);
}

test "selectAll on an empty document selects nothing" {
    var buf: [16]u8 = undefined;
    var state = AppState.init(&buf);
    defer deinitHistory(&state, testing_allocator);
    selectAll(&state);
    try expectEqual(@as(?usize, null), state.selection_anchor);
}

test "cut removes exactly what it copied" {
    var buf: [64]u8 = undefined;
    var state = AppState.init(&buf);
    defer deinitHistory(&state, testing_allocator);
    try feed(&state, .{ .text = "abcdef" });
    try feed(&state, .{ .lefts = 3 });

    state.selection_anchor = 1;
    moveCursorTo(&state, 5); // "bcde", straddling the gap

    var out: [16]u8 = undefined;
    const n = copySelection(state, &out);
    try expectEqualStrings("bcde", out[0..n]);

    deleteSelection(&state);
    try expectTextContentsEquals("af", state);
    try expectEqual(@as(?usize, null), state.selection_anchor);
    try expectEqual(1, state.cursor_i); // caret left where the selection started
}

test "paste-sized input replaces a selection" {
    // Heap-allocated: this insert outgrows the buffer, and the grow path frees the old one.
    var state = AppState.init(try testing_allocator.alloc(u8, 16));
    defer deinitHistory(&state, testing_allocator);
    defer testing_allocator.free(state.gap_buf);
    try feed(&state, .{ .text = "abcdef" });
    try feed(&state, .{ .lefts = 4 }); // cursor at 2
    try feed(&state, .{ .rights = 2, .modifiers = mod_shift }); // select "cd"

    // Longer than the remaining buffer, so this also covers the grow path on paste.
    try feed(&state, .{ .text = "XXXXXXXXXXXXXXXX" });
    try expectTextContentsEquals("abXXXXXXXXXXXXXXXXef", state);
    try expectEqual(@as(?usize, null), state.selection_anchor);
}

test "undo reverses a typed run as one unit" {
    var buf: [64]u8 = undefined;
    var state = AppState.init(&buf);
    defer deinitHistory(&state, testing_allocator);

    // Each feed is a separate frame, as if five keystrokes arrived one per frame.
    for ("hello") |c| try feed(&state, .{ .text = &[_]u8{c} });
    try expectTextContentsEquals("hello", state);
    try expectEqual(1, state.history.undo_stack.items.len); // coalesced into one entry

    try expect(try undo(&state, testing_allocator));
    try expectTextContentsEquals("", state);
    try expect(!try undo(&state, testing_allocator)); // nothing left
}

test "a caret move splits a typing run into separate undo steps" {
    var buf: [64]u8 = undefined;
    var state = AppState.init(&buf);
    defer deinitHistory(&state, testing_allocator);

    try feed(&state, .{ .text = "abc" });
    try feed(&state, .{ .lefts = 3 }); // caret elsewhere — the run ends here
    try feed(&state, .{ .text = "X" });
    try expectTextContentsEquals("Xabc", state);

    try expect(try undo(&state, testing_allocator));
    try expectTextContentsEquals("abc", state); // only the X went
    try expect(try undo(&state, testing_allocator));
    try expectTextContentsEquals("", state);
}

test "a newline ends a typing run" {
    var buf: [64]u8 = undefined;
    var state = AppState.init(&buf);
    defer deinitHistory(&state, testing_allocator);

    try feed(&state, .{ .text = "ab" });
    try feed(&state, .{ .text = "\n" });
    try feed(&state, .{ .text = "cd" });
    try expectTextContentsEquals("ab\ncd", state);

    // Undoing a paragraph a line at a time beats losing all of it at once.
    try expect(try undo(&state, testing_allocator));
    try expectTextContentsEquals("ab\n", state);
}

test "undo restores text deleted by backspace" {
    var buf: [64]u8 = undefined;
    var state = AppState.init(&buf);
    defer deinitHistory(&state, testing_allocator);

    try feed(&state, .{ .text = "abcdef" });
    try feed(&state, .{ .backspaces = 1 });
    try feed(&state, .{ .backspaces = 1 });
    try expectTextContentsEquals("abcd", state);

    try expect(try undo(&state, testing_allocator));
    try expectTextContentsEquals("abcde", state);
    try expect(try undo(&state, testing_allocator));
    try expectTextContentsEquals("abcdef", state);
}

test "undo of a selection replacement restores both the text and the selection" {
    var buf: [64]u8 = undefined;
    var state = AppState.init(&buf);
    defer deinitHistory(&state, testing_allocator);

    try feed(&state, .{ .text = "abcdef" });
    try feed(&state, .{ .lefts = 4 }); // caret at 2
    try feed(&state, .{ .rights = 2, .modifiers = mod_shift }); // select "cd"
    try feed(&state, .{ .text = "Z" });
    try expectTextContentsEquals("abZef", state);

    try expect(try undo(&state, testing_allocator));
    try expectTextContentsEquals("abcdef", state);
    // The selection comes back too, so a mistaken overtype leaves you where you were.
    try expectEqual(@as(?usize, 2), state.selection_anchor);
    try expectEqual(4, state.cursor_i);
}

test "cut copies immediately and removes on the next frame, undoably" {
    var buf: [64]u8 = undefined;
    var state = AppState.init(&buf);
    defer deinitHistory(&state, testing_allocator);

    try feed(&state, .{ .text = "abcdef" });
    try feed(&state, .{ .lefts = 3 }); // caret at 3, so the gap splits the document
    state.selection_anchor = 1;
    moveCursorTo(&state, 5); // "bcde", straddling the gap

    // The host's half: read the bytes out now, because it has a pasteboard to fill and cannot
    // be handed them a frame later. The document is untouched at this point.
    var out: [16]u8 = undefined;
    const n = copySelection(state, &out);
    try expectEqualStrings("bcde", out[0..n]);
    try expectTextContentsEquals("abcdef", state);

    // The editor's half, on the next frame.
    try feed(&state, .{ .cmds = .{ .delete_selection = true } });
    try expectTextContentsEquals("af", state);

    try expect(try undo(&state, testing_allocator));
    try expectTextContentsEquals("abcdef", state);
}

test "a command and a keystroke in the same frame both take effect" {
    // The keyboard's `else if` ladder is exclusive; commands must not join it. If they did, one
    // of these two would be silently dropped — and which one would depend on rung order.
    var buf: [64]u8 = undefined;
    var state = AppState.init(&buf);
    defer deinitHistory(&state, testing_allocator);

    try feed(&state, .{ .text = "abc" });
    try feed(&state, .{ .rights = 1 }); // ends the run, so "def" journals separately
    try feed(&state, .{ .text = "def" });

    try feed(&state, .{ .cmds = .{ .undos = 1 }, .text = "Z" });
    // The undo took "def" off, and the "Z" still landed.
    try expectTextContentsEquals("abcZ", state);
}

test "repeated undo commands in one frame replay as a run, and stop at the bottom" {
    var buf: [64]u8 = undefined;
    var state = AppState.init(&buf);
    defer deinitHistory(&state, testing_allocator);

    try feed(&state, .{ .text = "abc" });
    try feed(&state, .{ .lefts = 1 }); // ends the coalescing run
    try feed(&state, .{ .text = "X" });

    // More undos than there are edits: the surplus is dropped rather than underflowing.
    try feed(&state, .{ .cmds = .{ .undos = 5 } });
    try expectTextContentsEquals("", state);
    try expectEqual(@as(usize, 0), state.history.undo_stack.items.len);
}

test "redo replays an undone edit, and a new edit discards the redo stack" {
    var buf: [64]u8 = undefined;
    var state = AppState.init(&buf);
    defer deinitHistory(&state, testing_allocator);

    try feed(&state, .{ .text = "abc" });
    try expect(try undo(&state, testing_allocator));
    try expectTextContentsEquals("", state);

    try expect(try redo(&state, testing_allocator));
    try expectTextContentsEquals("abc", state);

    try expect(try undo(&state, testing_allocator));
    try feed(&state, .{ .text = "xyz" }); // diverges from the redone future
    try expectEqual(0, state.history.redo_stack.items.len);
    try expect(!try redo(&state, testing_allocator));
}

test "undo and redo survive a round trip through the middle of the document" {
    var buf: [64]u8 = undefined;
    var state = AppState.init(&buf);
    defer deinitHistory(&state, testing_allocator);

    try feed(&state, .{ .text = "hello world" });
    try feed(&state, .{ .lefts = 6 }); // caret at 5, gap mid-document
    try feed(&state, .{ .text = "!!" });
    try expectTextContentsEquals("hello!! world", state);

    try expect(try undo(&state, testing_allocator));
    try expectTextContentsEquals("hello world", state);
    try expectEqual(5, state.cursor_i); // back where the typing started

    try expect(try redo(&state, testing_allocator));
    try expectTextContentsEquals("hello!! world", state);
}

test "the undo stack is bounded" {
    var state = AppState.init(try testing_allocator.alloc(u8, 8));
    defer deinitHistory(&state, testing_allocator);
    defer testing_allocator.free(state.gap_buf);

    // Each pair is a separate entry: the caret move between them breaks coalescing.
    for (0..MAX_UNDO_DEPTH + 20) |_| {
        try feed(&state, .{ .text = "x" });
        try feed(&state, .{ .lefts = 1 });
    }
    try expectEqual(MAX_UNDO_DEPTH, state.history.undo_stack.items.len);
}

test "styling follows the active theme" {
    const saved = theme.active;
    defer theme.active = saved;

    const plain = Token{ .tType = .PLAIN, .startI = 0, .endI = 1, .contents = "x", .renderEnd = 1 };
    const code = Token{ .tType = .CODE, .startI = 0, .endI = 3, .contents = "`x`", .renderStart = 1, .renderEnd = 2 };

    theme.active = theme.dark(20);
    try expectEqual(theme.dark(20).text, styleForToken(plain).color);
    try expectEqual(theme.dark(20).code_bg, styleForToken(code).background.?);
    try expectEqual(@as(f64, 20), styleForToken(plain).font.size);

    // Swapping the theme changes what gets drawn, with no other state to invalidate.
    theme.active = theme.light(31);
    try expectEqual(theme.light(31).text, styleForToken(plain).color);
    try expectEqual(@as(f64, 31), styleForToken(plain).font.size);
    // Headers scale off the theme's size rather than a fixed constant.
    const h1 = Token{ .tType = .HEADER, .startI = 0, .endI = 3, .contents = "# x", .degree = 1, .renderStart = 2, .renderEnd = 3 };
    try expectEqual(@as(f64, 62), styleForToken(h1).font.size);

    // Light and dark must actually differ, or none of the above proves anything.
    try expect(theme.light(20).text.r != theme.dark(20).text.r);
}

test "handleInput hello" {
    var buf: [20]u8 = undefined;
    var state = AppState.init(&buf);
    defer deinitHistory(&state, testing_allocator);

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
    defer deinitHistory(&state, testing_allocator);

    try feed(&state, .{ .text = "abc\ndef\nghi" });
    try expectTextContentsEquals("abc\ndef\nghi", state);
    try feed(&state, .{ .ups = 1 });
    try feed(&state, .{ .text = "X" });
    try expectTextContentsEquals("abc\ndefX\nghi", state);
}

test "handleInput backspace deletes the char before the cursor" {
    var buf: [20]u8 = undefined;
    var state = AppState.init(&buf);
    defer deinitHistory(&state, testing_allocator);

    try feed(&state, .{ .text = "h" });
    try feed(&state, .{ .text = "i" });
    try feed(&state, .{ .backspaces = 1 });

    try expectTextContentsEquals("h", state);
}

test "handleInput backspace on empty buffer is a no-op" {
    var buf: [20]u8 = undefined;
    var state = AppState.init(&buf);
    defer deinitHistory(&state, testing_allocator);

    try feed(&state, .{ .backspaces = 3 });

    try expectEqual(0, state.text_len);
    try expectEqual(0, state.cursor_i);
}

test "handleInput move cursor left and right" {
    var buf: [20]u8 = undefined;
    var state = AppState.init(&buf);
    defer deinitHistory(&state, testing_allocator);

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
        defer deinitHistory(&state, testing_allocator);
        try feed(&state, .{ .text = "hello" });
        try expectTextContentsEquals("hello", state);
        testing_allocator.free(state.gap_buf);
    }
    { // Cursor at beginning
        var state = AppState.init(try testing_allocator.alloc(u8, 1));
        defer deinitHistory(&state, testing_allocator);
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
        defer deinitHistory(&state, testing_allocator);
        try feed(&state, .{ .text = "[]" }); // Size is now 4
        try feed(&state, .{ .lefts = 1 });
        try feed(&state, .{ .text = "123" }); // Size is now 8
        try expectTextContentsEquals("[123]", state);
        testing_allocator.free(state.gap_buf);
    }
}

test "selection: plain movement never creates a selection" {
    var buf: [20]u8 = undefined;
    var state = AppState.init(&buf);
    defer deinitHistory(&state, testing_allocator);
    try feed(&state, .{ .text = "abc" });

    try feed(&state, .{ .lefts = 1 });
    try expectEqual(@as(?usize, null), state.selection_anchor);
    try expectEqual(2, state.cursor_i);
}

test "selection: shift+right starts and extends a selection" {
    var buf: [20]u8 = undefined;
    var state = AppState.init(&buf);
    defer deinitHistory(&state, testing_allocator);
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
    defer deinitHistory(&state, testing_allocator);
    try feed(&state, .{ .text = "abc" }); // cursor at 3

    try feed(&state, .{ .lefts = 2, .modifiers = mod_shift });
    try expectEqual(@as(?usize, 3), state.selection_anchor);
    try expectEqual(1, state.cursor_i); // range [1,3] = "bc"
}

test "selection: typing replaces the selected range" {
    var buf: [20]u8 = undefined;
    var state = AppState.init(&buf);
    defer deinitHistory(&state, testing_allocator);
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
    defer deinitHistory(&state, testing_allocator);
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
    defer deinitHistory(&state, testing_allocator);
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
    defer deinitHistory(&state, testing_allocator);
    try feed(&state, .{ .text = "ab\ncd" }); // cursor at end (5)
    try feed(&state, .{ .lefts = 5 }); // cursor 0

    try feed(&state, .{ .downs = 1, .modifiers = mod_shift });
    try expectEqual(@as(?usize, 0), state.selection_anchor);
    try expectEqual(3, state.cursor_i); // down one line from col 0 ⇒ offset 3
}

test "selection: plain up/down resets the anchor" {
    var buf: [20]u8 = undefined;
    var state = AppState.init(&buf);
    defer deinitHistory(&state, testing_allocator);
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
    defer deinitHistory(&state, testing_allocator);
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
    defer deinitHistory(&state, testing_allocator);
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
    defer deinitHistory(&state, testing_allocator);
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
    defer deinitHistory(&state, testing_allocator);

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
// (padding(), padding()); `fakeWidth` is 1 unit per byte and `line_h` is 1, so for
// a click at (x, y):
//   column = clamp(x - padding(), 0, line.text.len)
//   line   = window_offset + (y - padding()) / line_h     (clamped to last line)
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

const X0 = (theme.Metrics{}).padding; // x of column 0
const Y0 = (theme.Metrics{}).padding; // y of the first visible line (line_h == 1 under testMeasurer)
