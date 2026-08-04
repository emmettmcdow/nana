//! The immediate-mode frame callback, and the state the whole renderer shares.
//!
//! `frame` is called once per display refresh with a `Canvas` to draw into and an `Input`
//! snapshot for this frame. Redraw the whole scene every call.
//!
//! The drawing itself lives one level down, in two modules that don't know about each other:
//!
//!   * `ted.zig`    — the document: gap buffer, undo history, markdown layout, caret.
//!   * `overlay.zig` — the chrome on top: buttons, the note list, the search field.
//!
//! What this file keeps is what both of them need: `AppState`, the routing decision about who
//! gets the keyboard this frame, and the re-exports `intf.zig` calls across the C boundary.

const std = @import("std");
const assert = std.debug.assert;

const ted = @import("ted.zig");
const overlay = @import("overlay.zig");

const geom = @import("geom.zig");
const theme = @import("theme.zig");
const th = theme.th;
const ui = @import("ui.zig");
const Canvas = @import("canvas.zig").Canvas;
const input = @import("input.zig");
const Input = input.Input;

const QUERY_MAX = overlay.QUERY_MAX;

// ******************************************************************************* Global Constants
// Wall-clock duration of the previous `frame` call, used to report the FPS we
// would hit if Swift weren't capping us at 60. Displayed a frame late (the debug
// text is drawn before this frame's own time is known), which is fine at 60 Hz.
var last_frame_ns: u64 = 0;

// ****************************************************************************************** Types
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
    /// consumes it clears it; the render modules only ever set it.
    dirty: bool = false,
    history: ted.History = .{},
    ui: ui.State = .{},
    /// Whether the note list is showing.
    list_visible: bool = false,
    list_scroll: f64 = 0,
    /// The search query. A fixed buffer because a query is not prose; overflow just stops
    /// accepting characters rather than growing without bound.
    query_buf: [QUERY_MAX]u8 = undefined,
    query_len: usize = 0,
    query_cursor: usize = 0,

    clear_view: bool = true, // HACK: When this flag is set, globals are reset in the editor.

    /// Takes a pointer, not a value. `query_buf` is an array, so a by-value `self` would be a
    /// copy of it, and the returned slice would point into that copy — dead the moment the
    /// call returns.
    pub fn query(self: *const AppState) []const u8 {
        return self.query_buf[0..self.query_len];
    }

    pub fn init(gap_buf: []u8) AppState {
        return .{ .gap_buf = gap_buf, .gap_end = gap_buf.len };
    }

    /// Public because `ted.zig` does the buffer arithmetic that has to preserve this.
    pub fn assertInvariant(self: AppState) void {
        assert(self.text_len == self.cursor_i + (self.gap_buf.len - self.gap_end));
        // The gap sits between head and tail: document up to `cursor_i`, gap, then document
        // again from `gap_end`. Letting the two cross would make the "tail" read the head's
        // bytes back a second time, which every range read here would then silently duplicate.
        assert(self.cursor_i <= self.gap_end);
        assert(self.gap_end <= self.gap_buf.len);
        // An anchor past the end selects text that isn't there. Undo restores an anchor saved
        // before an edit, so this is the assertion that catches it being restored into a
        // document the edit made shorter.
        if (self.selection_anchor) |a| assert(a <= self.text_len);
    }
};

/// A note as the file list needs it. Borrowed from the host for the duration of the frame.
pub const NoteEntry = struct {
    path: []const u8,
    title: []const u8,
};

/// What this frame is asking the host to do.
///
/// The render modules cannot reach the note store — importing it would drag the vector DB and
/// the embedder into every render test — so widgets record an intent here and the host, which
/// has both, carries it out.
pub const FrameActions = struct {
    new_note: bool = false,
    /// Index into the `notes` slice handed to `frame`.
    open_note: ?usize = null,
    /// The query changed this frame, so the host should redo the lookup that feeds `notes`.
    query_changed: bool = false,
};

// ****************************************************************************** Editor Re-exports
// `intf.zig` reaches these across the C boundary. They are the editor's, but the host knows
// only this module, so they are surfaced here rather than making it import `ted.zig` too.
pub const deinitHistory = ted.deinitHistory;
pub const undo = ted.undo;
pub const redo = ted.redo;
pub const selectAll = ted.selectAll;
pub const selectionLen = ted.selectionLen;
pub const copySelection = ted.copySelection;
pub const cutSelection = ted.cutSelection;

// ********************************************************************************** Top-Level Fns
pub fn frame(
    allocator: std.mem.Allocator,
    canvas: *Canvas,
    in: Input,
    state: *AppState,
    notes: []const NoteEntry,
) !FrameActions {
    canvas.clear(th().background); // background

    // debug: fps calculation
    var frame_timer = std.time.Timer.start() catch null;
    defer if (frame_timer) |*t| {
        last_frame_ns = t.read();
    };

    { // display debug info
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

    var editor_in = in;
    var actions = FrameActions{};
    if (state.list_visible) {
        editor_in = Input{}; // The editor should receive no inputs while the list is active
        actions.query_changed = overlay.editQuery(state, in);
        if (std.mem.indexOfScalar(u8, in.text, '\n') != null) {
            // Enter accepts the top hit, the usual way out of a search field.
            if (notes.len > 0) actions.open_note = 0;
        }
        if (in.escapes > 0) state.list_visible = false;
    }

    // The editor draws first and the chrome over it. `overlay.frame` may add to `actions` —
    // a click on a row or a button — on top of whatever the query branch above recorded.
    try ted.frame(allocator, canvas, editor_in, state);
    overlay.frame(canvas, in, state, notes, &actions);
    return actions;
}
