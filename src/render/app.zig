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
const theme = @import("theme.zig");
const ui = @import("ui.zig");
const Canvas = @import("canvas.zig").Canvas;
const input = @import("input.zig");
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
const testing_allocator = std.testing.allocator;
const assert = std.debug.assert;
const markdown = @import("markdown.zig");
const Token = markdown.FlatToken;
const mod_shift = input.mod_shift;

const Color = geom.Color;
const Rect = geom.Rect;
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

const MARGIN_PX: f64 = 100;

/// Quoted text is pushed right, with a rule per nesting level standing in the gutter it was
/// pushed out of.
const QUOTE_INDENT_PX: f64 = 24;
const QUOTE_RULE_W: f64 = 3;

/// Colors and type size come from the active theme rather than constants here, so light and
/// dark are the same code path. `theme.active` is set by the host; this module only reads it.
///
/// Code is set apart by ink weight rather than a new hue — dimmed body text on a faint panel
/// of the same color — and a link by the rule under it. Both fall out of the theme's derived
/// colors; see theme.zig for how they relate.
fn th() theme.Theme {
    return theme.active;
}

pub const AppState = struct {
    gap_buf: []u8,
    text_len: usize = 0,
    cursor_i: usize = 0,
    gap_end: usize = 0,
    /// How far the view is scrolled from the top of the document, in points.
    ///
    /// Points rather than a line index: a trackpad delivers sub-line deltas, and quantising
    /// them to whole rows makes scrolling feel stepped. The cost is that the top and bottom
    /// visible rows are usually cut off partway, so the render pass has to clip.
    scroll_y: f64 = 0,
    selection_anchor: ?usize = null,
    mouse_was_down: bool = false,
    /// Set whenever this frame's input changed the document's *text*, so a layer above can
    /// persist it. Cursor and selection movement don't count — nothing to write. Whoever
    /// consumes it clears it; `app.zig` only ever sets it.
    dirty: bool = false,
    history: History = .{},
    ui: ui.State = .{},
    /// Whether the note list is showing.
    list_visible: bool = false,
    list_scroll: f64 = 0,
    /// The search query. A fixed buffer because a query is not prose; overflow just stops
    /// accepting characters rather than growing without bound.
    query_buf: [QUERY_MAX]u8 = undefined,
    query_len: usize = 0,
    query_cursor: usize = 0,

    /// Takes a pointer, not a value. `query_buf` is an array, so a by-value `self` would be a
    /// copy of it, and the returned slice would point into that copy — dead the moment the
    /// call returns.
    pub fn query(self: *const AppState) []const u8 {
        return self.query_buf[0..self.query_len];
    }

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

/// Whether source offset `off` is drawn: either its line is revealed, or it falls inside the
/// token's visible middle rather than in the delimiters the parser marked off.
fn isVisible(token: Token, off: usize, reveal: Reveal) bool {
    if (reveal.covers(off)) return true;
    return off >= token.startI + token.renderStart and off < token.startI + token.renderEnd;
}

/// A note as the file list needs it. Borrowed from the host for the duration of the frame.
pub const NoteEntry = struct {
    path: []const u8,
    title: []const u8,
};

/// What this frame is asking the host to do.
///
/// `app.zig` cannot reach the note store — importing it would drag the vector DB and the
/// embedder into every render test — so widgets record an intent here and the host, which has
/// both, carries it out.
pub const FrameActions = struct {
    new_note: bool = false,
    /// Index into the `notes` slice handed to `frame`.
    open_note: ?usize = null,
    /// The query changed this frame, so the host should redo the lookup that feeds `notes`.
    query_changed: bool = false,
};

const QUERY_MAX: usize = 256;

const BTN_SIZE: f64 = 44;
const BTN_GAP: f64 = 12;
const BTN_MARGIN: f64 = 20;
const LIST_MAX_W: f64 = 400;

/// Where this frame's chrome sits. Computed before anything is drawn so the editor can be told
/// to ignore a click that belongs to the UI, then reused by the widget pass itself.
const UiLayout = struct {
    new_note: Rect,
    toggle_list: Rect,
    /// Null when the list is hidden.
    panel: ?Rect,
    /// The query field, and the area below it the rows scroll in. Both null with the panel.
    query: ?Rect,
    rows: ?Rect,
    row_h: f64,
};

fn layoutUi(size: geom.Size, list_visible: bool, font_size: f64) UiLayout {
    const bx = size.w - BTN_MARGIN - BTN_SIZE;
    const by = size.h - BTN_MARGIN - BTN_SIZE;
    const panel: ?Rect = if (list_visible) .{
        .x = size.w - @min(LIST_MAX_W, size.w * 0.4),
        .y = 0,
        .w = @min(LIST_MAX_W, size.w * 0.4),
        .h = size.h,
    } else null;

    const field_h = font_size * 2.0;
    const pad: f64 = 10;
    return .{
        .new_note = .{ .x = bx, .y = by, .w = BTN_SIZE, .h = BTN_SIZE },
        .toggle_list = .{ .x = bx, .y = by - BTN_SIZE - BTN_GAP, .w = BTN_SIZE, .h = BTN_SIZE },
        .panel = panel,
        .query = if (panel) |p| .{
            .x = p.x + pad,
            .y = p.y + pad,
            .w = p.w - pad * 2,
            .h = field_h,
        } else null,
        .rows = if (panel) |p| .{
            .x = p.x,
            .y = p.y + field_h + pad * 2,
            .w = p.w,
            .h = p.h - (field_h + pad * 2),
        } else null,
        .row_h = font_size * 2.2,
    };
}

/// Apply this frame's typing to the query. Returns whether the text changed — the caret moving
/// on its own doesn't warrant redoing the search.
fn editQuery(state: *AppState, in: Input) bool {
    var changed = false;

    if (in.backspaces > 0 and state.query_cursor > 0) {
        const n = @min(state.query_cursor, in.backspaces);
        std.mem.copyForwards(
            u8,
            state.query_buf[state.query_cursor - n .. state.query_len - n],
            state.query_buf[state.query_cursor..state.query_len],
        );
        state.query_len -= n;
        state.query_cursor -= n;
        changed = true;
    }
    if (in.lefts > 0) state.query_cursor -= @min(state.query_cursor, in.lefts);
    if (in.rights > 0) state.query_cursor = @min(state.query_len, state.query_cursor + in.rights);

    for (in.text) |b| {
        // Single-line: a newline means "accept", handled by the caller, and control bytes are
        // not text.
        if (b < 0x20 or b == 0x7f) continue;
        if (state.query_len == state.query_buf.len) break;
        std.mem.copyBackwards(
            u8,
            state.query_buf[state.query_cursor + 1 .. state.query_len + 1],
            state.query_buf[state.query_cursor..state.query_len],
        );
        state.query_buf[state.query_cursor] = b;
        state.query_cursor += 1;
        state.query_len += 1;
        changed = true;
    }
    return changed;
}

fn clearQuery(state: *AppState) void {
    state.query_len = 0;
    state.query_cursor = 0;
}

/// Whether the chrome should take this frame's pointer input, leaving the editor to ignore it.
/// A widget already being dragged keeps the pointer wherever it has wandered to.
fn uiCapturesMouse(layout: UiLayout, mouse: geom.Point, ui_state: ui.State) bool {
    if (ui_state.active != null) return true;
    if (layout.new_note.contains(mouse)) return true;
    if (layout.toggle_list.contains(mouse)) return true;
    if (layout.panel) |p| {
        if (p.contains(mouse)) return true;
    }
    return false;
}

pub fn frame(
    allocator: std.mem.Allocator,
    canvas: *Canvas,
    in: Input,
    state: *AppState,
    notes: []const NoteEntry,
) !FrameActions {
    // debug: fps calculation
    var frame_timer = std.time.Timer.start() catch null;
    defer if (frame_timer) |*t| {
        last_frame_ns = t.read();
    };

    // Background.
    canvas.clear(th().background);

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
            th().text,
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

    // Whether the view should chase the caret this frame. Only true when the caret actually
    // went somewhere: otherwise a wheel scroll that pushes the caret off screen would be
    // yanked straight back by `scrollToCursor` on the very next frame.
    var follow_cursor = false;

    const layout = layoutUi(canvas.size, state.list_visible, th().font_size);
    // Decided before `handleInput` runs, and from the same rects the widget pass will use, so
    // a click on a button can't also move the caret in the text underneath it.
    const ui_has_mouse = uiCapturesMouse(layout, in.mouse, state.ui);
    var editor_in = in;
    if (ui_has_mouse) {
        editor_in.mouse_down = false;
        editor_in.scroll_dy = 0; // the list scrolls instead
    }

    var actions = FrameActions{};
    if (state.list_visible) {
        // An open list holds the keyboard: typing goes to the query, not the document behind
        // it. Withhold the keys from the editor rather than letting both act on them.
        actions.query_changed = editQuery(state, in);
        if (std.mem.indexOfScalar(u8, in.text, '\n') != null) {
            // Enter accepts the top hit, the usual way out of a search field.
            if (notes.len > 0) actions.open_note = 0;
        }
        if (in.escapes > 0) state.list_visible = false;

        editor_in.text = &.{};
        editor_in.backspaces = 0;
        editor_in.lefts = 0;
        editor_in.rights = 0;
        editor_in.ups = 0;
        editor_in.downs = 0;
    }

    { // Calculate the displayed text and handle inputs
        const full_text = condenseGapBuf(scratch.?, state.*);
        const tokens = try tokenize(full_text);
        // Laid out against the cursor as it stands *before* this frame's input, which is the
        // layout the user was looking at when they clicked or pressed a key.
        const reveal = revealForCursor(full_text, state.cursor_i);
        const lines = splitLines(full_text, tokens, line_scratch.?, frag_scratch.?, measurer, reveal);
        const cursor_before = state.cursor_i;
        try handleInput(allocator, editor_in, state, lines, tokens, frag_scratch.?, full_text, measurer);
        // `dirty` covers deleting a selection ahead of the caret, which changes the text
        // without moving it.
        follow_cursor = state.cursor_i != cursor_before or state.dirty;
    }

    { // Render pass
        const full_text = condenseGapBuf(scratch.?, state.*);
        const tokens = try tokenize(full_text);
        const reveal = revealForCursor(full_text, state.cursor_i);
        const lines = splitLines(full_text, tokens, line_scratch.?, frag_scratch.?, measurer, reveal);
        const text_x: f64 = MARGIN_PX;
        const viewport_h = canvas.size.h - (MARGIN_PX * 2);

        // Wheel first, then the caret, so typing always wins over where the wheel had left us.
        state.scroll_y -= editor_in.scroll_dy;
        if (follow_cursor) {
            state.scroll_y = scrollToCursor(lines, state.scroll_y, cursorLine(lines, state.cursor_i), viewport_h);
        }
        state.scroll_y = clampScroll(state.scroll_y, lines, viewport_h);

        const placements = visiblePlacements(lines, state.scroll_y, viewport_h, placement_scratch.?);
        var caret_drawn = false;

        // Rows at the edges are cut off mid-line; keep them inside the content area.
        canvas.pushClip(.{ .x = 0, .y = MARGIN_PX, .w = canvas.size.w, .h = viewport_h });
        defer canvas.popClip();

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
                        fillPanel(canvas, .{ .x = bar_x, .y = text_y, .w = QUOTE_RULE_W, .h = line_h }, th().quote_rule);
                    }
                }
            }
            { // caret and selection
                const line_end = line.start + line.text.len;
                const cursor_in_line = state.cursor_i >= line.start and state.cursor_i <= line_end;
                if (cursor_in_line and !caret_drawn) {
                    // At a soft-wrap boundary the cursor offset matches both the end
                    // of one line and the start of the next; prefer the earlier line.
                    const caret_x = line_x + xForOffset(line, frag_scratch.?, full_text, tokens, state.cursor_i, measurer);
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
                        const x0 = xForOffset(line, frag_scratch.?, full_text, tokens, lo, measurer);
                        const x1 = xForOffset(line, frag_scratch.?, full_text, tokens, hi, measurer);
                        // A row wholly inside the selection but with nothing drawn on it — a
                        // blank line, or one that is all concealed markup — still shows a stub,
                        // so a multi-line selection doesn't look like it skipped a row.
                        const selection_w = if (x1 > x0)
                            x1 - x0
                        else if (sel_lo < line.start and sel_hi > line_end)
                            measurer.width(" ", tokens, line.start, line.start + 1)
                        else
                            0;
                        if (selection_w > 0) {
                            canvas.fillRect(.{ .x = line_x + x0, .y = text_y, .w = selection_w, .h = line_h }, th().highlight);
                        }
                    }
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
                    // Only the visible middle is drawn; on a row whose line isn't revealed the
                    // delimiters were clipped off this range and so take up no space.
                    const shown = full_text[frag.vis_start..frag.vis_end];
                    if (shown.len == 0) continue;
                    const style = styleForToken(tokens[frag.tok]);
                    if (style.background) |bg| {
                        // The panel has to be down before the glyphs, so its width can't come
                        // from drawText's return — measure the run up front.
                        const w = switch (style.panel) {
                            .run => measurer.width(shown, tokens, frag.vis_start, frag.vis_end),
                            .full => row_w - (frag_x - line_x),
                        };
                        fillPanel(canvas, .{ .x = frag_x, .y = text_y, .w = w, .h = line_h }, bg);
                    }
                    frag_x += canvas.drawText(shown, frag_x, text_y, style.font, style.color).w;
                }
            }
        }
    }

    // Chrome last, so it sits over the text. Input for it was already accounted for above.
    drawChrome(canvas, in, state, layout, notes, &actions);
    return actions;
}

/// Draw the buttons and the note list, returning whatever the user asked for.
fn drawChrome(
    canvas: *Canvas,
    in: Input,
    state: *AppState,
    layout: UiLayout,
    notes: []const NoteEntry,
    actions: *FrameActions,
) void {
    const t = th();
    // Edges come from the UI's own record of the previous frame, not the editor's — see
    // `ui.State.was_down` for why the editor's is unusable here.
    var ctx = ui.Ctx.init(&state.ui, in.mouse, in.mouse_down);
    defer ctx.end();

    if (layout.panel) |p| {
        ui.panel(&ctx, canvas, t, p);
        _ = ui.textField(&ctx, canvas, t, 3, layout.query.?, state.query(), state.query_cursor, "Search notes");

        const rows = layout.rows.?;
        if (p.contains(in.mouse)) state.list_scroll -= in.scroll_dy;
        const content_h = @as(f64, @floatFromInt(notes.len)) * layout.row_h;
        state.list_scroll = std.math.clamp(state.list_scroll, 0, @max(0, content_h - rows.h));

        canvas.pushClip(rows);
        defer canvas.popClip();

        if (notes.len == 0) {
            // Distinguish "nothing matched" from "nothing saved" — an empty rectangle leaves
            // the user unsure which of the two they are looking at.
            const msg = if (state.query_len > 0) "No matches" else "No saved notes yet";
            ui.emptyLabel(canvas, t, rows, msg);
        }

        for (notes, 0..) |note, i| {
            const y = rows.y + (@as(f64, @floatFromInt(i)) * layout.row_h) - state.list_scroll;
            if (y + layout.row_h <= rows.y or y >= rows.y + rows.h) continue; // off-panel
            const row = Rect{ .x = rows.x, .y = y, .w = rows.w, .h = layout.row_h };
            // Falling back to the path keeps an untitled note selectable rather than invisible.
            const label = if (note.title.len > 0) note.title else note.path;
            if (ui.listRow(&ctx, canvas, t, @intCast(100 + i), row, label, false)) {
                actions.open_note = i;
                state.list_visible = false;
            }
        }
    }

    if (ui.button(&ctx, canvas, t, 1, layout.toggle_list, if (state.list_visible) "x" else "=")) {
        state.list_visible = !state.list_visible;
        state.list_scroll = 0;
        // Opening on a stale query would show yesterday's results against an empty-looking
        // field, so start clean either way.
        clearQuery(state);
        actions.query_changed = true;
    }
    if (ui.button(&ctx, canvas, t, 2, layout.new_note, "+")) {
        actions.new_note = true;
        state.list_visible = false;
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
        .HEADER => .{ .size = th().font_size * headerScale(token.degree) },
        .BOLD => .{ .size = th().font_size, .bold = true },
        .ITALIC => .{ .size = th().font_size, .italic = true },
        .EMPHASIS => .{ .size = th().font_size, .bold = true, .italic = true },
        .LINK => .{ .size = th().font_size, .underline = true },
        else => .{ .size = th().font_size },
    };
}

/// How a token is painted. Measurement only ever needs `.font`, so `fontForToken` stays a
/// separate entry point and the `Measurer` signature is unaffected by anything here.
const Style = struct {
    font: Font,
    /// No default: it comes from the active theme, which is not comptime-known.
    color: Color,
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
    var style = Style{ .font = fontForToken(token), .color = th().text };
    switch (token.tType) {
        .CODE => {
            style.color = th().code;
            style.background = th().code_bg;
        },
        .BLOCK_CODE => {
            style.color = th().code;
            style.background = th().code_bg;
            style.panel = .full;
        },
        .QUOTE => style.color = th().quote,
        .LINK => style.color = th().link,
        else => {},
    }
    return style;
}

/// How far right of the content margin the row starting at `start` sits.
///
/// Quotes indent every row by their nesting depth. Lists do the opposite: their first row sits
/// flush, because a list's structure is already in the source as literal text — the leading
/// tabs measure a real 28pt each in Menlo, and `- ` reads as the bullet — so indenting on top
/// of that would double it. What a list needs instead is a *hanging* indent, so a wrapped item's
/// continuation rows line up under the item's text rather than sliding back under its marker.
///
/// Everything inline sits flush: an indent applies to a whole row, and an inline span only
/// covers part of one.
///
/// A list's indent therefore depends on whether its marker is currently concealed. Revealed,
/// the marker is drawn and its own width does the indenting, so the first row sits flush.
/// Concealed, the marker is gone — including the tabs — and the indent has to be supplied here
/// or the nesting would collapse to the margin. Both cases put the item's *content* at the same
/// x, so text doesn't slide sideways as the cursor enters and leaves the line.
fn indentForRow(token: Token, start: usize, tokens: []const Token, m: Measurer, reveal: Reveal) f64 {
    return switch (token.tType) {
        .QUOTE => QUOTE_INDENT_PX * @as(f64, @floatFromInt(token.degree)),
        .UNORDERED_LIST => if (reveal.covers(start) and start == token.startI)
            0
        else
            markerWidth(token, tokens, m),
        else => 0,
    };
}

/// Width of a list item's leading marker (its tabs plus `- `), which the parser already
/// delimits with `renderStart`. This is the offset a continuation row hangs at.
fn markerWidth(token: Token, tokens: []const Token, m: Measurer) f64 {
    const marker_end = @min(token.renderStart, token.contents.len);
    return m.width(token.contents[0..marker_end], tokens, token.startI, token.startI + marker_end);
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
///
/// `i` is a byte offset, matching `parseFlat`. Both are bytes on purpose: the renderer slices
/// the source directly, so any other coordinate space would need converting on every lookup.
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
    frags[count.*] = .{ .tok = tok, .start = from, .end = to, .vis_start = vis_start, .vis_end = vis_end };
    count.* += 1;
}

/// Width of the one character starting at `off`. A UTF-8 continuation byte measures zero — its
/// lead byte already accounted for the whole codepoint — so summing this over a byte range
/// gives the range's width without ever handing a partial sequence to the text engine.
fn charWidth(full_text: []const u8, tokens: []const Token, off: usize, m: Measurer) f64 {
    const seq_len = std.unicode.utf8ByteSequenceLength(full_text[off]) catch return 0;
    const end = @min(off + seq_len, full_text.len);
    return m.width(full_text[off..end], tokens, off, end);
}

/// Open a row at `start`, inheriting the indent of the block that owns that offset. Looking the
/// owner up by offset gets both cases right without tracking state: a hard newline hands off to
/// the next token (a quote's '\n' is its last character, so the row after it is no longer
/// quoted), while a soft wrap stays inside the current token and keeps the indent.
fn beginRow(out: []Line, lineno: usize, start: usize, tokens: []const Token, m: Measurer, reveal: Reveal) void {
    out[lineno].start = start;
    out[lineno].indent = indentForRow(tokenAt(tokens, start), start, tokens, m, reveal);
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
    var lineno: usize = 0;
    beginRow(out, lineno, 0, tokens, m, reveal);

    var frag_count: usize = 0;
    var line_frag_start: usize = 0; // first fragment index of the current row
    var frag_from: usize = 0; // start offset of the run being accumulated
    var frag_tok: usize = 0; // token index of that run
    // Visible width laid down on the current row. Accumulated per character rather than
    // re-measuring the row's whole prefix each time, because hidden delimiters have to
    // contribute nothing and a contiguous source slice can't express "skip the middle".
    var row_w: f64 = 0;

    var last_token = tokens[0];
    for (tokens, 0..) |token, ti| {
        last_token = token;
        // Token boundary: close the previous token's run on this row (contiguous
        // tokens mean it ends exactly where this one starts), then open this token's.
        pushFragment(frags, &frag_count, tokens, frag_tok, frag_from, token.startI, reveal);
        frag_tok = ti;
        frag_from = token.startI;

        for (token.contents, 0..) |c, token_off| {
            const off = token.startI + token_off;
            if (c == '\n') {
                out[lineno].text = full_text[out[lineno].start..off];
                pushFragment(frags, &frag_count, tokens, frag_tok, frag_from, off, reveal);
                out[lineno].frag_start = line_frag_start;
                out[lineno].frag_end = frag_count;
                lineno += 1;
                beginRow(out, lineno, off + 1, tokens, m, reveal);
                out[lineno].text = "";
                line_frag_start = frag_count;
                frag_from = off + 1; // same token, resumes past the newline
                row_w = 0;
                continue;
            }
            // A concealed delimiter occupies no width, so it can never push a row over budget.
            const char_w = if (isVisible(token, off, reveal)) charWidth(full_text, tokens, off, m) else 0;
            // An indented row has correspondingly less room before it has to wrap.
            if (row_w + char_w >= m.content_w - out[lineno].indent) {
                out[lineno].text = full_text[out[lineno].start..off];
                pushFragment(frags, &frag_count, tokens, frag_tok, frag_from, off, reveal);
                out[lineno].frag_start = line_frag_start;
                out[lineno].frag_end = frag_count;
                lineno += 1;
                beginRow(out, lineno, off, tokens, m, reveal);
                out[lineno].text = full_text[off .. off + 1];
                line_frag_start = frag_count;
                frag_from = off; // same token, the wrapped char begins the next row
                row_w = char_w;
                continue;
            }
            row_w += char_w;
        }
    }
    const doc_end = last_token.startI + last_token.contents.len;
    out[lineno].text = full_text[out[lineno].start..doc_end];
    pushFragment(frags, &frag_count, tokens, frag_tok, frag_from, doc_end, reveal);
    out[lineno].frag_start = line_frag_start;
    out[lineno].frag_end = frag_count;
    lineno += 1;

    for (out[0..lineno]) |*line| {
        line.h = m.height(line.text, tokens, line.start, line.start + line.text.len);
        line.w = xForOffset(line.*, frags, full_text, tokens, line.start + line.text.len, m);
    }
    return out[0..lineno];
}

/// The x of source offset `off`, relative to the row's text origin.
///
/// This is the one place the offset-to-pixel mapping lives. It walks the row's fragments so
/// each run is measured in its own font — a row mixing a header, bold and plain text has no
/// single font to measure against — and so concealed delimiters contribute no width. An offset
/// inside a concealed run collapses onto the near edge of that run, which is the best answer
/// available: it isn't drawn anywhere.
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

/// Every line that intersects the viewport when scrolled to `scroll_y`, paired with its y
/// relative to the top of the content area. The first and last are typically cut off, so their
/// `y` may be negative or place their bottom past `viewport_h` — the render pass clips.
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

/// Total height of the laid-out document.
fn documentHeight(lines: []const Line) f64 {
    var h: f64 = 0;
    for (lines) |line| h += line.h;
    return h;
}

/// Hold `scroll_y` within the document. The lower bound wins when the document is shorter than
/// the viewport, which would otherwise give a negative maximum.
fn clampScroll(scroll_y: f64, lines: []const Line, viewport_h: f64) f64 {
    return std.math.clamp(scroll_y, 0, @max(0, documentHeight(lines) - viewport_h));
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
    return clampScroll(result, lines, viewport_h);
}

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
    var cursor_target: ?usize = null;
    // Anything that isn't typing ends the current run, so an undo can't reach back across a
    // click or an arrow key into text the user typed somewhere else entirely.
    if (in.mouse_down or (in.lefts | in.rights | in.ups | in.downs) != 0) breakCoalesce(state);
    if (in.mouse_down) {
        const mouse_offset: usize = cursor: { // point to offset
            // Work in document space: drop the content margin, then add how far we are
            // scrolled. Falling off either end of the loop clamps to the first or last row,
            // which is what a click above or below the text should do.
            const doc_y = (in.mouse.y - MARGIN_PX) + state.scroll_y;
            var lineno: usize = lines.len - 1;
            var y: f64 = 0;
            for (lines, 0..) |l, i| {
                const line_h = measurer.height(l.text, tokens, l.start, l.start + l.text.len);
                if (doc_y < y + line_h) {
                    lineno = i;
                    break;
                }
                y += line_h;
            }
            const line = lines[lineno];
            var col: usize = line.text.len;
            // Start where the row's glyphs start, not at the margin: on an indented row the
            // two differ, and walking from the margin would map every click an indent's worth
            // of characters to the right.
            var curr_x: f64 = MARGIN_PX + line.indent;
            // Walk the row's visible runs, the inverse of `xForOffset`. Concealed delimiters
            // measure zero, so a click never lands past them by their source length — and
            // landing *inside* one is harmless, since arriving there reveals the line.
            walk: for (frags[line.frag_start..line.frag_end]) |frag| {
                var off = frag.start;
                while (off < frag.end) : (off += 1) {
                    const w = if (off >= frag.vis_start and off < frag.vis_end)
                        charWidth(full_text, tokens, off, measurer)
                    else
                        0;
                    if (in.mouse.x < curr_x + (w / 2.0)) {
                        col = off - line.start;
                        break :walk;
                    }
                    curr_x += w;
                }
            }
            break :cursor line.start + col;
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
        const cursor_before = state.cursor_i;
        const anchor_before = state.selection_anchor;
        if (selectionRange(state.*)) |sel| {
            state.dirty = true;
            // Capture the text before dropping it — afterwards there is nothing left to read.
            const removed = try allocator.alloc(u8, sel.hi - sel.lo);
            defer allocator.free(removed);
            _ = copyRange(state.*, sel.lo, sel.hi, removed);
            deleteSelection(state);
            try recordEdit(state, allocator, sel.lo, removed, "", cursor_before, anchor_before);
        } else {
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

/// Move the cursor to document offset `target`, shifting the gap to match.
pub fn moveCursorTo(state: *AppState, target: usize) void {
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

/// How many edits are kept before the oldest is dropped.
const MAX_UNDO_DEPTH: usize = 256;

const History = struct {
    undo_stack: ArrayList(Edit) = .{},
    redo_stack: ArrayList(Edit) = .{},
    /// Whether the next insert may merge into the top undo entry. Typing a run should undo as
    /// one unit, but only while it stays a run — anything else (moving the caret, deleting,
    /// undoing) ends it, so the merge can't reach across unrelated edits.
    coalesce: bool = false,
};

/// End any in-progress typing run, so the next insert starts a fresh undo entry.
pub fn breakCoalesce(state: *AppState) void {
    state.history.coalesce = false;
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

/// Reverse the most recent edit. Returns false when there is nothing left to undo.
pub fn undo(state: *AppState, alloc: Allocator) !bool {
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
pub fn redo(state: *AppState, alloc: Allocator) !bool {
    if (state.history.redo_stack.items.len == 0) return false;
    const e = state.history.redo_stack.pop().?;

    try applyReplace(state, alloc, e.at, e.at + e.removed.len, e.inserted);

    try state.history.undo_stack.append(alloc, e);
    state.history.coalesce = false;
    state.dirty = true;
    return true;
}

/// Release every journalled edit.
pub fn deinitHistory(state: *AppState, alloc: Allocator) void {
    for (state.history.undo_stack.items) |e| freeEdit(alloc, e);
    for (state.history.redo_stack.items) |e| freeEdit(alloc, e);
    state.history.undo_stack.deinit(alloc);
    state.history.redo_stack.deinit(alloc);
    state.history = .{};
}

/// The selected span as document offsets, or null when nothing is selected. An anchor sitting
/// exactly on the cursor is an empty selection and counts as nothing.
pub fn selectionRange(state: AppState) ?struct { lo: usize, hi: usize } {
    const anchor = state.selection_anchor orelse return null;
    const lo = @min(anchor, state.cursor_i);
    const hi = @max(anchor, state.cursor_i);
    return if (lo == hi) null else .{ .lo = lo, .hi = hi };
}

pub fn selectionLen(state: AppState) usize {
    const sel = selectionRange(state) orelse return 0;
    return sel.hi - sel.lo;
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

/// Write the selection into `out`, returning the byte count. Zero if there is no selection or
/// `out` is too small — check `selectionLen` first to size the buffer.
pub fn copySelection(state: AppState, out: []u8) usize {
    const sel = selectionRange(state) orelse return 0;
    if (out.len < sel.hi - sel.lo) return 0;
    return copyRange(state, sel.lo, sel.hi, out);
}

/// Drop the selected text, leaving the cursor where the selection started.
pub fn deleteSelection(state: *AppState) void {
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

/// Select the whole document, leaving the cursor at the end as macOS does.
pub fn selectAll(state: *AppState) void {
    if (state.text_len == 0) return;
    moveCursorTo(state, state.text_len);
    state.selection_anchor = 0;
    breakCoalesce(state);
}

/// Copy the selection into `out` and remove it, as one journalled edit. Returns the byte count,
/// or 0 if there was no selection or `out` was too small — in which case nothing is removed.
pub fn cutSelection(state: *AppState, alloc: Allocator, out: []u8) !usize {
    const sel = selectionRange(state.*) orelse return 0;
    const n = copySelection(state.*, out);
    if (n == 0) return 0;

    const cursor_before = state.cursor_i;
    const anchor_before = state.selection_anchor;
    deleteSelection(state);
    try recordEdit(state, alloc, sel.lo, out[0..n], "", cursor_before, anchor_before);
    state.dirty = true;
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
    const reveal = revealForCursor(doc, state.cursor_i);
    const lines = splitLines(doc, tokens, &line_buf, &frag_buf, measurer, reveal);
    try handleInput(testing_allocator, in, state, lines, tokens, &frag_buf, doc, measurer);
}

/// Every line revealed, for tests about layout rather than concealment.
fn revealAll(text: []const u8) Reveal {
    return .{ .start = 0, .end = text.len };
}

/// Build a Line with just the fields the vertical-layout functions read (start/text/height).
fn testLine(start: usize, text: []const u8, h: f64) Line {
    return .{ .start = start, .text = text, .h = h };
}

test "visiblePlacements returns every line intersecting the viewport" {
    var out: [16]Placement = undefined;
    const lines = [_]Line{
        testLine(0, "a", 30),
        testLine(1, "b", 30),
        testLine(2, "c", 30),
        testLine(3, "d", 30),
    };
    // 100px viewport at the top: 30+30+30 = 90 fits, and the fourth line straddles the bottom
    // edge, so it is placed too — it is partly visible and the clip trims the rest.
    const vis = visiblePlacements(&lines, 0, 100, &out);
    try expectEqual(@as(usize, 4), vis.len);
    try expectEqual(@as(f64, 0), vis[0].y);
    try expectEqual(@as(f64, 30), vis[1].y);
    try expectEqual(@as(f64, 60), vis[2].y);
    try expectEqual(@as(f64, 90), vis[3].y);
}

test "visiblePlacements offsets rows by a fractional scroll" {
    var out: [16]Placement = undefined;
    const lines = [_]Line{
        testLine(0, "a", 30),
        testLine(1, "b", 30),
        testLine(2, "c", 30),
        testLine(3, "d", 30),
    };
    // Scrolled 45px: the first row is half gone, so the top visible row is line 1 sitting at
    // y = -15. A negative y is the point of scrolling by pixels rather than by whole lines.
    const vis = visiblePlacements(&lines, 45, 100, &out);
    try expectEqual(@as(usize, 1), vis[0].line);
    try expectEqual(@as(f64, -15), vis[0].y);
    try expectEqual(@as(usize, 2), vis[1].line);
    try expectEqual(@as(f64, 15), vis[1].y);
}

test "visiblePlacements drops rows entirely above or below the viewport" {
    var out: [16]Placement = undefined;
    const lines = [_]Line{
        testLine(0, "a", 30),
        testLine(1, "b", 30),
        testLine(2, "c", 30),
        testLine(3, "d", 30),
        testLine(4, "e", 30),
    };
    // Scrolled exactly past the first two rows, 50px viewport ⇒ rows 2 and 3 only.
    const vis = visiblePlacements(&lines, 60, 50, &out);
    try expectEqual(@as(usize, 2), vis.len);
    try expectEqual(@as(usize, 2), vis[0].line);
    try expectEqual(@as(f64, 0), vis[0].y);
    try expectEqual(@as(usize, 3), vis[1].line);
}

test "clampScroll keeps the view inside the document" {
    const lines = [_]Line{ testLine(0, "a", 30), testLine(1, "b", 30), testLine(2, "c", 30) };
    try expectEqual(@as(f64, 0), clampScroll(-40, &lines, 50)); // can't scroll above the start
    try expectEqual(@as(f64, 40), clampScroll(999, &lines, 50)); // 90 tall - 50 viewport
    try expectEqual(@as(f64, 20), clampScroll(20, &lines, 50)); // untouched in range
    // A document shorter than the viewport has nowhere to scroll to.
    try expectEqual(@as(f64, 0), clampScroll(30, &lines, 500));
}

test "scrollToCursor reveals a caret below the viewport, moving as little as possible" {
    const lines = [_]Line{
        testLine(0, "a", 30), testLine(1, "b", 30), testLine(2, "c", 30),
        testLine(3, "d", 30), testLine(4, "e", 30),
    };
    // Caret on line 4 spans 120..150; a 100px viewport at 0 must scroll to 50 to show it.
    try expectEqual(@as(f64, 50), scrollToCursor(&lines, 0, 4, 100));
}

test "scrollToCursor reveals a caret above the viewport" {
    const lines = [_]Line{
        testLine(0, "a", 30), testLine(1, "b", 30), testLine(2, "c", 30),
        testLine(3, "d", 30), testLine(4, "e", 30),
    };
    // Scrolled to 90 (showing from line 3); caret on line 1 sits at 30 ⇒ scroll up to 30.
    try expectEqual(@as(f64, 30), scrollToCursor(&lines, 90, 1, 100));
}

test "scrollToCursor leaves the view alone when the caret is already visible" {
    const lines = [_]Line{
        testLine(0, "a", 30), testLine(1, "b", 30), testLine(2, "c", 30),
        testLine(3, "d", 30), testLine(4, "e", 30),
    };
    // Showing 30..130; line 2 spans 60..90, comfortably inside.
    try expectEqual(@as(f64, 30), scrollToCursor(&lines, 30, 2, 100));
}

test "scrollToCursor pins a caret line taller than the viewport to its top" {
    // The line satisfies both "below the viewport" and "above the viewport" at once. Showing
    // its top is the useful answer — scrolling to its bottom would hide where the text starts.
    const lines = [_]Line{ testLine(0, "a", 30), testLine(1, "huge", 300), testLine(2, "c", 30) };
    try expectEqual(@as(f64, 30), scrollToCursor(&lines, 0, 1, 100));
}

test "scrollToCursor accounts for variable line heights" {
    var lines = unitLines(5);
    for (&lines) |*line| line.h = 2;
    lines[3].h = 4;
    // Line 3 spans 6..10; a 6px viewport must scroll to 4 to bring its bottom into view.
    try expectEqual(@as(f64, 4), scrollToCursor(&lines, 0, 3, 6));
}

test "a scrolled-to caret is actually placed for drawing" {
    // The invariant that matters: whatever scrollToCursor decides, visiblePlacements must
    // agree the caret's line is on screen. Otherwise the caret can be scrolled "into view"
    // and still not drawn.
    const lines = [_]Line{
        testLine(0, "a", 30), testLine(1, "b", 30), testLine(2, "c", 30),
        testLine(3, "d", 30), testLine(4, "e", 30),
    };
    const viewport_h: f64 = 100;
    for (0..lines.len) |cursor_line| {
        const scroll = scrollToCursor(&lines, 0, cursor_line, viewport_h);
        var out: [16]Placement = undefined;
        const vis = visiblePlacements(&lines, scroll, viewport_h, &out);
        var found = false;
        for (vis) |p| {
            if (p.line == cursor_line) found = true;
        }
        try expect(found);
    }
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
    const lines = splitLines(text, &.{plainTokenize(text)}, &out, &frags, testMeasurer(1_000_000), Reveal.none);

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
    const lines = splitLines(text, &.{plainTokenize(text)}, &out, &frags, testMeasurer(1_000_000), Reveal.none);
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
    const lines = splitLines(text, &.{plainTokenize(text)}, &out, &frags, testMeasurer(4), Reveal.none);

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
    const lines = splitLines(text, &.{plainTokenize(text)}, &out, &frags, testMeasurer(4), Reveal.none);

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
    const lines = splitLines(contents, tokens, &out, &frags, testMeasurer(1_000_000), Reveal.none);

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
    const lines = splitLines(text, &.{plainTokenize(text)}, &out, &frags, testMeasurer(4), Reveal.none);

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
    const lines = splitLines(text, &.{plainTokenize(text)}, &out, &frags, testMeasurer(1_000_000), Reveal.none);

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
    const lines = splitLines(text, &.{plainTokenize(text)}, &out, &frags, testMeasurer(4), Reveal.none);

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
    const lines = splitLines(text, tokens, &out, &frags, testMeasurer(1_000_000), revealAll(text));

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
    const lines = splitLines(text, tokens, &out, &frags, testMeasurer(1_000_000), revealAll(text));

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
    const lines = splitLines(text, tokens, &out, &frags, testMeasurer(10 + QUOTE_INDENT_PX), revealAll(text));

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

test "a list item's first row sits flush and its wrapped rows hang under the text" {
    var out: [8]Line = undefined;
    var frags: [32]Fragment = undefined;
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();

    // fakeWidth is 1/byte, so the marker "- " measures 2 and the item wraps at width 12.
    const text = "- aaaaaaaaaaaaaaaaaaaaaa";
    const tokens = try markdown.parseFlat(arena.allocator(), text);
    const lines = splitLines(text, tokens, &out, &frags, testMeasurer(12), revealAll(text));

    try expect(lines.len > 1); // it did wrap
    try expectEqual(@as(f64, 0), lines[0].indent); // the marker row is flush
    for (lines[1..]) |line| {
        try expectEqual(@as(f64, 2), line.indent); // continuations hang under "- "
    }
}

test "a nested list item is not indented on top of its literal tabs" {
    var out: [8]Line = undefined;
    var frags: [32]Fragment = undefined;
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();

    // Nesting is expressed by leading tabs, which are real drawn characters with a real
    // advance. Adding a computed indent as well would double every level.
    const text = "- one\n\t- two\n\t\t- three";
    const tokens = try markdown.parseFlat(arena.allocator(), text);
    const lines = splitLines(text, tokens, &out, &frags, testMeasurer(1_000_000), revealAll(text));

    try expectEqual(3, lines.len);
    for (lines) |line| {
        try expectEqual(@as(f64, 0), line.indent);
    }
    // The tabs are still present as text, which is what actually does the indenting.
    try expectEqualStrings("\t- two", lines[1].text);
    try expectEqualStrings("\t\t- three", lines[2].text);
}

test "the hanging indent scales with a nested item's marker" {
    var out: [8]Line = undefined;
    var frags: [32]Fragment = undefined;
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();

    // Degree 3: marker is "\t\t- ", four bytes wide under fakeWidth.
    const text = "\t\t- aaaaaaaaaaaaaaaaaaaa";
    const tokens = try markdown.parseFlat(arena.allocator(), text);
    const lines = splitLines(text, tokens, &out, &frags, testMeasurer(14), revealAll(text));

    try expect(lines.len > 1);
    try expectEqual(@as(f64, 0), lines[0].indent);
    for (lines[1..]) |line| {
        try expectEqual(@as(f64, 4), line.indent);
    }
}

/// The text a row would actually draw: its fragments' visible ranges, concatenated.
fn drawnText(buf: []u8, line: Line, frags: []const Fragment, full_text: []const u8) []const u8 {
    var n: usize = 0;
    for (frags[line.frag_start..line.frag_end]) |frag| {
        const shown = full_text[frag.vis_start..frag.vis_end];
        @memcpy(buf[n .. n + shown.len], shown);
        n += shown.len;
    }
    return buf[0..n];
}

test "revealForCursor picks out the cursor's source line" {
    const text = "one\ntwo\nthree";
    try expectEqual(Reveal{ .start = 0, .end = 3 }, revealForCursor(text, 0));
    try expectEqual(Reveal{ .start = 0, .end = 3 }, revealForCursor(text, 3)); // end of line 1
    try expectEqual(Reveal{ .start = 4, .end = 7 }, revealForCursor(text, 4));
    try expectEqual(Reveal{ .start = 4, .end = 7 }, revealForCursor(text, 6));
    try expectEqual(Reveal{ .start = 8, .end = 13 }, revealForCursor(text, 13)); // end of doc
}

test "delimiters are concealed off the cursor's line and shown on it" {
    var out: [8]Line = undefined;
    var frags: [32]Fragment = undefined;
    var buf: [64]u8 = undefined;
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();

    const text = "a**b**c\n# H\nx`y`z";
    const tokens = try markdown.parseFlat(arena.allocator(), text);

    { // Cursor on line 1: that line keeps its markup, the others lose theirs.
        const lines = splitLines(text, tokens, &out, &frags, testMeasurer(1_000_000), revealForCursor(text, 0));
        try expectEqualStrings("a**b**c", drawnText(&buf, lines[0], &frags, text));
        try expectEqualStrings("H", drawnText(&buf, lines[1], &frags, text));
        try expectEqualStrings("xyz", drawnText(&buf, lines[2], &frags, text));
    }
    { // Cursor on line 2 — the header — and the reveal moves with it.
        const lines = splitLines(text, tokens, &out, &frags, testMeasurer(1_000_000), revealForCursor(text, 9));
        try expectEqualStrings("abc", drawnText(&buf, lines[0], &frags, text));
        try expectEqualStrings("# H", drawnText(&buf, lines[1], &frags, text));
        try expectEqualStrings("xyz", drawnText(&buf, lines[2], &frags, text));
    }
    { // A link hides its target but keeps its label.
        const link = "see [label](https://example.com) here";
        const link_tokens = try markdown.parseFlat(arena.allocator(), link);
        const lines = splitLines(link, link_tokens, &out, &frags, testMeasurer(1_000_000), Reveal.none);
        try expectEqualStrings("see label here", drawnText(&buf, lines[0], &frags, link));
    }
}

test "concealed delimiters take up no width" {
    var out: [8]Line = undefined;
    var frags: [32]Fragment = undefined;
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();

    // fakeWidth is 1/byte. "a**b**c" is 7 bytes of source but only 3 drawn.
    const text = "a**b**c";
    const tokens = try markdown.parseFlat(arena.allocator(), text);

    const hidden = splitLines(text, tokens, &out, &frags, testMeasurer(1_000_000), Reveal.none);
    try expectEqual(@as(f64, 3), hidden[0].w);

    const shown = splitLines(text, tokens, &out, &frags, testMeasurer(1_000_000), revealAll(text));
    try expectEqual(@as(f64, 7), shown[0].w);
}

test "wrapping measures visible text, so concealing a line lets more fit on a row" {
    var out: [8]Line = undefined;
    var frags: [32]Fragment = undefined;
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();

    // Ten bold single letters: 10 drawn characters, 40 bytes of source.
    const text = "**a****b****c****d****e****f****g****h****i****j**";
    const tokens = try markdown.parseFlat(arena.allocator(), text);

    // Budget 8: concealed, 7 letters fit on the first row even though they span 35 bytes.
    const hidden = splitLines(text, tokens, &out, &frags, testMeasurer(8), Reveal.none);
    try expectEqual(@as(f64, 7), hidden[0].w);

    // Revealed, the same budget only holds 7 bytes of source — a single `**a**` and change.
    const shown = splitLines(text, tokens, &out, &frags, testMeasurer(8), revealAll(text));
    try expectEqual(@as(f64, 7), shown[0].w);
    try expect(shown.len > hidden.len); // markup shown ⇒ more rows
}

test "xForOffset skips concealed runs and measures each run in its own font" {
    var out: [8]Line = undefined;
    var frags: [32]Fragment = undefined;
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();

    const text = "a**b**c";
    const tokens = try markdown.parseFlat(arena.allocator(), text);
    const m = testMeasurer(1_000_000);
    const lines = splitLines(text, tokens, &out, &frags, m, Reveal.none);
    const line = lines[0];

    // Drawn as "abc": offset 0 -> x 0, and the whole row is 3 wide.
    try expectEqual(@as(f64, 0), xForOffset(line, &frags, text, tokens, 0, m));
    try expectEqual(@as(f64, 1), xForOffset(line, &frags, text, tokens, 1, m)); // before "**"
    // Offsets 1..3 are the opening "**" — concealed, so they all collapse to the same x as the
    // 'b' they precede rather than spreading across width the row never drew.
    try expectEqual(@as(f64, 1), xForOffset(line, &frags, text, tokens, 2, m));
    try expectEqual(@as(f64, 1), xForOffset(line, &frags, text, tokens, 3, m));
    try expectEqual(@as(f64, 2), xForOffset(line, &frags, text, tokens, 4, m)); // after 'b'
    try expectEqual(@as(f64, 3), xForOffset(line, &frags, text, tokens, 7, m)); // end of row
}

test "a list keeps its content in place whether or not its marker is shown" {
    var out: [8]Line = undefined;
    var frags: [32]Fragment = undefined;
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();

    // Concealing a list marker also conceals the tabs that were doing the indenting, so the
    // indent has to be supplied instead — landing the content at the same x either way.
    const text = "\t\t- three";
    const tokens = try markdown.parseFlat(arena.allocator(), text);
    const marker_w: f64 = 4; // "\t\t- " under fakeWidth

    // Both calls lay out into `out`, so the second overwrites the first's rows — read the
    // values across before comparing them.
    const hidden = splitLines(text, tokens, &out, &frags, testMeasurer(1_000_000), Reveal.none);
    const hidden_indent = hidden[0].indent;
    const hidden_w = hidden[0].w;
    try expectEqual(marker_w, hidden_indent); // indent replaces the vanished tabs
    try expectEqual(@as(f64, 5), hidden_w); // only "three" is drawn

    const shown = splitLines(text, tokens, &out, &frags, testMeasurer(1_000_000), revealAll(text));
    const shown_indent = shown[0].indent;
    try expectEqual(@as(f64, 0), shown_indent); // the marker itself does the indenting
    try expectEqual(@as(f64, 9), shown[0].w);

    // Content x == indent + width of whatever precedes it on the row: the marker when it is
    // drawn, nothing when it isn't. Identical either way, so the text never slides sideways.
    try expectEqual(marker_w, hidden_indent + 0);
    try expectEqual(marker_w, shown_indent + marker_w);
}

test "splitLines empty row has no fragments" {
    var out: [8]Line = undefined;
    var frags: [16]Fragment = undefined;
    // Trailing newline yields an empty second row.
    const text = "ab\n";
    const lines = splitLines(text, &.{plainTokenize(text)}, &out, &frags, testMeasurer(1_000_000), Reveal.none);

    try expectEqual(2, lines.len);
    try expectEqual(1, lines[0].frag_end - lines[0].frag_start); // "ab"
    try expectEqual(0, lines[1].frag_end - lines[1].frag_start); // empty row draws nothing
}

/// `n` unit-height lines, for exercising scroll logic independent of measured heights.
fn unitLines(comptime n: usize) [n]Line {
    var lines: [n]Line = undefined;
    for (&lines, 0..) |*line, i| line.* = .{ .start = i, .text = "", .h = 1, .w = 0 };
    return lines;
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

test "cut is undoable" {
    var buf: [64]u8 = undefined;
    var state = AppState.init(&buf);
    defer deinitHistory(&state, testing_allocator);

    try feed(&state, .{ .text = "abcdef" });
    try feed(&state, .{ .lefts = 3 }); // caret at 3, so the gap splits the document
    state.selection_anchor = 1;
    moveCursorTo(&state, 5); // "bcde", straddling the gap

    var out: [16]u8 = undefined;
    const n = try cutSelection(&state, testing_allocator, &out);
    try expectEqualStrings("bcde", out[0..n]);
    try expectTextContentsEquals("af", state);

    try expect(try undo(&state, testing_allocator));
    try expectTextContentsEquals("abcdef", state);
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

test "typing edits the query and reports that it changed" {
    var buf: [16]u8 = undefined;
    var state = AppState.init(&buf);
    defer deinitHistory(&state, testing_allocator);

    try expect(editQuery(&state, .{ .text = "abc" }));
    try expectEqualStrings("abc", state.query());
    try expectEqual(@as(usize, 3), state.query_cursor);

    // Moving the caret is not a content change: it must not trigger another search.
    try expect(!editQuery(&state, .{ .lefts = 1 }));
    try expectEqual(@as(usize, 2), state.query_cursor);

    // Insertion happens at the caret, not the end.
    try expect(editQuery(&state, .{ .text = "X" }));
    try expectEqualStrings("abXc", state.query());

    try expect(editQuery(&state, .{ .backspaces = 1 }));
    try expectEqualStrings("abc", state.query());
}

test "query() aliases the live buffer, not a copy of it" {
    // Regression: `query` used to take `self` by value. `query_buf` is an array, so the copy
    // brought the characters with it and the returned slice pointed into that copy — dead as
    // soon as the call returned. It read as the field clearing itself a frame after typing.
    var buf: [16]u8 = undefined;
    var state = AppState.init(&buf);
    defer deinitHistory(&state, testing_allocator);

    _ = editQuery(&state, .{ .text = "abc" });
    const q = state.query();
    try expect(@intFromPtr(q.ptr) == @intFromPtr(&state.query_buf));

    // And it tracks later edits, rather than being a snapshot.
    _ = editQuery(&state, .{ .text = "d" });
    try expectEqualStrings("abcd", state.query());
}

test "the query field rejects newlines and control bytes" {
    var buf: [16]u8 = undefined;
    var state = AppState.init(&buf);
    defer deinitHistory(&state, testing_allocator);

    // Enter means "accept" and is handled by the caller; it must never land in the text.
    try expect(!editQuery(&state, .{ .text = "\n" }));
    try expect(!editQuery(&state, .{ .text = "\x1b" }));
    try expectEqual(@as(usize, 0), state.query_len);

    _ = editQuery(&state, .{ .text = "a\nb" });
    try expectEqualStrings("ab", state.query());
}

test "the query stops accepting text at the buffer's end rather than overflowing" {
    var buf: [16]u8 = undefined;
    var state = AppState.init(&buf);
    defer deinitHistory(&state, testing_allocator);

    var long: [QUERY_MAX + 50]u8 = undefined;
    @memset(&long, 'z');
    _ = editQuery(&state, .{ .text = &long });
    try expectEqual(QUERY_MAX, state.query_len);
    try expectEqual(QUERY_MAX, state.query_cursor);
}

test "backspace at the start of the query does nothing" {
    var buf: [16]u8 = undefined;
    var state = AppState.init(&buf);
    defer deinitHistory(&state, testing_allocator);

    _ = editQuery(&state, .{ .text = "ab" });
    _ = editQuery(&state, .{ .lefts = 5 }); // clamps to 0
    try expectEqual(@as(usize, 0), state.query_cursor);
    try expect(!editQuery(&state, .{ .backspaces = 1 }));
    try expectEqualStrings("ab", state.query());
}

test "the query field and the row area divide the panel between them" {
    const layout = layoutUi(.{ .w = 1000, .h = 800 }, true, 20);
    const p = layout.panel.?;
    const q = layout.query.?;
    const rows = layout.rows.?;

    // The field sits inside the panel, and the rows start below it — they must not overlap, or
    // the top row would be drawn under the search box.
    try expect(q.y >= p.y);
    try expect(rows.y >= q.y + q.h);
    try expect(rows.y + rows.h <= p.y + p.h);
}

test "the chrome claims clicks that land on it" {
    const size = geom.Size{ .w = 1000, .h = 800 };
    const layout = layoutUi(size, false, 20);
    const idle = ui.State{};

    // A press on the buttons is the UI's, not the editor's — otherwise clicking "new note"
    // would also drop the caret into whatever text sits behind the button.
    try expect(uiCapturesMouse(layout, .{ .x = layout.new_note.x + 5, .y = layout.new_note.y + 5 }, idle));
    try expect(uiCapturesMouse(layout, .{ .x = layout.toggle_list.x + 5, .y = layout.toggle_list.y + 5 }, idle));
    // Anywhere else belongs to the editor.
    try expect(!uiCapturesMouse(layout, .{ .x = 200, .y = 200 }, idle));
}

test "an open list claims the whole panel, a closed one claims none of it" {
    const size = geom.Size{ .w = 1000, .h = 800 };
    const idle = ui.State{};

    const closed = layoutUi(size, false, 20);
    try expect(closed.panel == null);
    try expect(!uiCapturesMouse(closed, .{ .x = 900, .y = 300 }, idle));

    const open = layoutUi(size, true, 20);
    const p = open.panel.?;
    try expect(uiCapturesMouse(open, .{ .x = p.x + 5, .y = 300 }, idle));
    // The panel is anchored to the right edge and runs the full height.
    try expectEqual(size.w, p.x + p.w);
    try expectEqual(size.h, p.h);
    // ...and leaves the editor reachable to its left.
    try expect(!uiCapturesMouse(open, .{ .x = p.x - 5, .y = 300 }, idle));
}

test "a widget being dragged keeps the pointer wherever it wanders" {
    const layout = layoutUi(.{ .w = 1000, .h = 800 }, false, 20);
    // Press started on a button; the pointer has since moved over the text. The editor still
    // must not see it, or a drag off a button would start selecting text.
    const dragging = ui.State{ .active = 2 };
    try expect(uiCapturesMouse(layout, .{ .x = 200, .y = 200 }, dragging));
}

test "styling follows the active theme" {
    const saved = theme.active;
    defer theme.active = saved;

    const plain = Token{ .tType = .PLAIN, .startI = 0, .endI = 1, .contents = "x", .renderEnd = 1 };
    const code = Token{ .tType = .CODE, .startI = 0, .endI = 3, .contents = "`x`", .renderStart = 1, .renderEnd = 2 };

    theme.active = theme.dark(20);
    try expectEqual(theme.dark(20).text, styleForToken(plain).color);
    try expectEqual(theme.dark(20).code_bg, styleForToken(code).background.?);
    try expectEqual(@as(f64, 20), fontForToken(plain).size);

    // Swapping the theme changes what gets drawn, with no other state to invalidate.
    theme.active = theme.light(31);
    try expectEqual(theme.light(31).text, styleForToken(plain).color);
    try expectEqual(@as(f64, 31), fontForToken(plain).size);
    // Headers scale off the theme's size rather than a fixed constant.
    const h1 = Token{ .tType = .HEADER, .startI = 0, .endI = 3, .contents = "# x", .degree = 1, .renderStart = 2, .renderEnd = 3 };
    try expectEqual(@as(f64, 62), fontForToken(h1).size);

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

test "handleInput up-down cursor" {
    var buf: [20]u8 = undefined;
    var state = AppState.init(&buf);
    defer deinitHistory(&state, testing_allocator);

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
    defer deinitHistory(&state, testing_allocator);

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
    defer deinitHistory(&state, testing_allocator);

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
        &.{}, // no fragments: up/down navigation never consults them
        contents,
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

test "selection: a plain right collapses to the right edge" {
    var buf: [20]u8 = undefined;
    var state = AppState.init(&buf);
    defer deinitHistory(&state, testing_allocator);
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
    defer deinitHistory(&state, testing_allocator);
    try feed(&state, .{ .text = "abc" }); // cursor 3
    try feed(&state, .{ .lefts = 2, .modifiers = mod_shift }); // range [1,3], cursor 1

    try feed(&state, .{ .lefts = 1 }); // plain
    try expectEqual(@as(?usize, null), state.selection_anchor);
    try expectEqual(1, state.cursor_i); // left edge, no extra step
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
    defer deinitHistory(&state, testing_allocator);
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
    defer deinitHistory(&state, testing_allocator);
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
    defer deinitHistory(&state, testing_allocator);
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
    defer deinitHistory(&state, testing_allocator);
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
    defer deinitHistory(&state, testing_allocator);
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
    defer deinitHistory(&state, testing_allocator);
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
