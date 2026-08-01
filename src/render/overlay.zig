//! overlay — the chrome layered over the editor.
//!
//! The two corner buttons, the note list they open, and the search field at the top of it.
//! Nothing here touches the document; it reads the parts of `AppState` that describe the
//! panel and records what the user asked for in a `FrameActions` for the host to carry out.
//!
//! Drawn after `ted.frame`, so it sits on top. While the panel is up, `app.zig` withholds the
//! keyboard from the editor and routes it here instead — see `editQuery`.

const std = @import("std");

const app = @import("app.zig");
const AppState = app.AppState;
const NoteEntry = app.NoteEntry;
const FrameActions = app.FrameActions;

const geom = @import("geom.zig");
const Rect = geom.Rect;

const theme = @import("theme.zig");
const th = theme.th;

const ui = @import("ui.zig");
const Canvas = @import("canvas.zig").Canvas;
const input = @import("input.zig");
const Input = input.Input;

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
const testing_allocator = std.testing.allocator;

// ******************************************************************************* Global Constants
/// A search query is not prose, so it gets a fixed buffer in `AppState` rather than a growing
/// one; typing past the end simply stops. `app.zig` sizes the field from this.
pub const QUERY_MAX: usize = 256;

const BTN_SIZE: f64 = 44;
const BTN_GAP: f64 = 12;
const BTN_MARGIN: f64 = 20;
const LIST_MAX_W: f64 = 400;

// ****************************************************************************************** Types
/// Where this frame's chrome sits. Computed once at the top of `frame` so every widget call
/// below works from the same geometry.
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

// ********************************************************************************* Top Level Fns.
/// Draw the buttons and the note list, returning whatever the user asked for.
pub fn frame(
    canvas: *Canvas,
    in: Input,
    state: *AppState,
    notes: []const NoteEntry,
    actions: *FrameActions,
) void {
    const layout = layoutUi(canvas.size, state.list_visible, th().font_size);
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

// **************************************************************************************** Helpers

/// Apply this frame's typing to the query. Returns whether the text changed — the caret moving
/// on its own doesn't warrant redoing the search.
///
/// Called by `app.zig` rather than by `frame`: the same branch that decides the query gets the
/// keyboard is the one that decides the editor doesn't, so the two live together up there.
pub fn editQuery(state: *AppState, in: Input) bool {
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

// **************************************************************************************** Tests
test "typing edits the query and reports that it changed" {
    var buf: [16]u8 = undefined;
    var state = AppState.init(&buf);
    defer app.deinitHistory(&state, testing_allocator);

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
    defer app.deinitHistory(&state, testing_allocator);

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
    defer app.deinitHistory(&state, testing_allocator);

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
    defer app.deinitHistory(&state, testing_allocator);

    var long: [QUERY_MAX + 50]u8 = undefined;
    @memset(&long, 'z');
    _ = editQuery(&state, .{ .text = &long });
    try expectEqual(QUERY_MAX, state.query_len);
    try expectEqual(QUERY_MAX, state.query_cursor);
}

test "backspace at the start of the query does nothing" {
    var buf: [16]u8 = undefined;
    var state = AppState.init(&buf);
    defer app.deinitHistory(&state, testing_allocator);

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
