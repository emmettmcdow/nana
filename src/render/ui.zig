//! A small immediate-mode widget layer.
//!
//! Widgets are drawn and hit-tested in the same call, so there is no view tree to keep in sync
//! with the document — the frame loop already redraws everything anyway. What must persist
//! between frames is only which widget the pointer is over and which one it pressed, so that
//! lives in `State` and everything else is recomputed.
//!
//! Widgets are identified by a caller-supplied id. Ids only need to be distinct among widgets
//! alive in the same frame.

pub const Id = u32;

/// The part of the UI that has to outlive a frame.
pub const State = struct {
    /// The widget under the pointer.
    hot: ?Id = null,
    /// The widget the pointer went down on. A click counts only if the pointer is still over
    /// the same widget when it comes back up, so dragging off cancels — as it should.
    active: ?Id = null,
    /// Button state as of the end of the previous frame, which is what press and release edges
    /// are derived from.
    ///
    /// Owned here rather than read off the editor's `mouse_was_down`: that field is rewritten
    /// to the *current* state partway through the frame, and it is skipped entirely whenever
    /// the UI holds the pointer — so from a widget's point of view a press would look like it
    /// never ended, leaving the widget stuck down and its click never firing.
    was_down: bool = false,
};

/// Per-frame input, plus a flag recording whether the UI took the pointer. The editor consults
/// that flag so a click on a button doesn't also move the caret underneath it.
pub const Ctx = struct {
    state: *State,
    mouse: Point,
    mouse_down: bool,
    /// True only on the frame the button went down.
    pressed: bool,
    /// True only on the frame it came back up.
    released: bool,
    /// Set once any widget claims the pointer this frame.
    captured: bool = false,

    pub fn init(state: *State, mouse: Point, mouse_down: bool) Ctx {
        return .{
            .state = state,
            .mouse = mouse,
            .mouse_down = mouse_down,
            .pressed = mouse_down and !state.was_down,
            .released = !mouse_down and state.was_down,
        };
    }

    /// Close the frame, carrying the button state forward. Must be called once per frame after
    /// the last widget, or every frame looks like a fresh press.
    pub fn end(self: *Ctx) void {
        self.state.was_down = self.mouse_down;
    }
};

/// How a widget is currently being interacted with. Returned so callers can style accordingly
/// without re-deriving it from the context.
pub const Interaction = struct {
    hovered: bool = false,
    held: bool = false,
    /// The click completed on this widget this frame.
    clicked: bool = false,
};

/// Hit-test `rect` for widget `id` and update hot/active. The shared core of every widget —
/// buttons and list rows differ only in how they draw.
pub fn interact(ctx: *Ctx, id: Id, rect: Rect) Interaction {
    const inside = rect.contains(ctx.mouse);
    if (inside) {
        ctx.state.hot = id;
        ctx.captured = true;
    } else if (ctx.state.hot == id) {
        ctx.state.hot = null;
    }

    var result = Interaction{ .hovered = inside };

    if (inside and ctx.pressed) {
        ctx.state.active = id;
    }
    if (ctx.state.active == id) {
        result.held = true;
        ctx.captured = true; // keep the pointer even if it strays off the widget mid-drag
        if (ctx.released) {
            // Releasing away from where the press started cancels, matching every other
            // button on the platform.
            result.clicked = inside;
            ctx.state.active = null;
        }
    }
    return result;
}

/// Background tint for a widget in a given interaction state, over the page.
fn surface(t: Theme, in: Interaction) Color {
    if (in.held) return t.text.withAlpha(0.24);
    if (in.hovered) return t.text.withAlpha(0.14);
    return t.text.withAlpha(0.08);
}

/// A rounded-ish rectangular button with a centred label. Returns true on the frame it is
/// clicked.
pub fn button(ctx: *Ctx, canvas: *Canvas, t: Theme, id: Id, rect: Rect, label: []const u8) bool {
    const it = interact(ctx, id, rect);
    canvas.fillRect(rect, surface(t, it));

    const font = Font{ .size = t.font_size };
    const size = canvas.measureText(label, font);
    _ = canvas.drawText(
        label,
        rect.x + (rect.w - size.w) / 2,
        rect.y + (rect.h - size.h) / 2,
        font,
        t.text,
    );
    return it.clicked;
}

/// One row of a list: a left-aligned label filling the row's width. Returns true when clicked.
pub fn listRow(
    ctx: *Ctx,
    canvas: *Canvas,
    t: Theme,
    id: Id,
    rect: Rect,
    label: []const u8,
    selected: bool,
) bool {
    const it = interact(ctx, id, rect);
    if (it.hovered or it.held or selected) {
        canvas.fillRect(rect, surface(t, it));
    }

    const font = Font{ .size = t.font_size };
    const size = canvas.measureText(label, font);
    const pad: f64 = 12;
    _ = canvas.drawText(
        label,
        rect.x + pad,
        rect.y + (rect.h - size.h) / 2,
        font,
        t.text,
    );
    return it.clicked;
}

/// A panel: an opaque surface that also swallows pointer input, so clicks that miss its
/// contents don't fall through to the editor behind it.
pub fn panel(ctx: *Ctx, canvas: *Canvas, t: Theme, rect: Rect) void {
    if (rect.contains(ctx.mouse)) ctx.captured = true;
    // Opaque first, so document text can't show through. Then a faint lift, because the panel
    // and the page share a background color — without it an open panel over empty space is
    // indistinguishable from no panel at all.
    canvas.fillRect(rect, t.background);
    canvas.fillRect(rect, t.text.withAlpha(0.06));

    // Outline every edge: which one faces the content depends on where the panel is anchored,
    // so a single hairline would be on the wrong side half the time.
    const line = t.text.withAlpha(0.20);
    canvas.fillRect(.{ .x = rect.x, .y = rect.y, .w = rect.w, .h = 1 }, line);
    canvas.fillRect(.{ .x = rect.x, .y = rect.y + rect.h - 1, .w = rect.w, .h = 1 }, line);
    canvas.fillRect(.{ .x = rect.x, .y = rect.y, .w = 1, .h = rect.h }, line);
    canvas.fillRect(.{ .x = rect.x + rect.w - 1, .y = rect.y, .w = 1, .h = rect.h }, line);
}

/// A single-line text field.
///
/// The caller owns the buffer and does the editing — this only draws. Widgets here hold no
/// document state of their own, so what a field contains stays somewhere the rest of the app
/// can reach without asking the UI for it.
pub fn textField(
    ctx: *Ctx,
    canvas: *Canvas,
    t: Theme,
    id: Id,
    rect: Rect,
    text: []const u8,
    cursor: usize,
    placeholder: []const u8,
) bool {
    const it = interact(ctx, id, rect);
    canvas.fillRect(rect, t.text.withAlpha(0.10));

    const font = Font{ .size = t.font_size };
    const pad: f64 = 10;
    const text_x = rect.x + pad;
    const size = canvas.measureText(if (text.len > 0) text else placeholder, font);
    const text_y = rect.y + (rect.h - size.h) / 2;

    if (text.len == 0) {
        _ = canvas.drawText(placeholder, text_x, text_y, font, t.text.withAlpha(0.40));
    } else {
        _ = canvas.drawText(text, text_x, text_y, font, t.text);
    }

    // The field always holds the keyboard while it is on screen, so the caret is always drawn.
    const before = canvas.measureText(text[0..@min(cursor, text.len)], font);
    canvas.fillRect(
        .{ .x = text_x + before.w, .y = rect.y + 6, .w = 2, .h = rect.h - 12 },
        t.caret,
    );
    return it.clicked;
}

/// Centred message for an otherwise empty panel, so a blank rectangle isn't left unexplained.
pub fn emptyLabel(canvas: *Canvas, t: Theme, rect: Rect, text: []const u8) void {
    const font = Font{ .size = t.font_size };
    const size = canvas.measureText(text, font);
    _ = canvas.drawText(
        text,
        rect.x + (rect.w - size.w) / 2,
        rect.y + (rect.h - size.h) / 2,
        font,
        t.text.withAlpha(0.55),
    );
}

const geom = @import("geom.zig");
const Canvas = @import("canvas.zig").Canvas;
const Theme = @import("theme.zig").Theme;
const Color = geom.Color;
const Font = geom.Font;
const Point = geom.Point;
const Rect = geom.Rect;

const std = @import("std");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

const test_rect = Rect{ .x = 10, .y = 10, .w = 100, .h = 30 };
const over = Point{ .x = 50, .y = 20 };
const away = Point{ .x = 500, .y = 500 };

test "a press and release inside the widget is a click" {
    var s = State{};
    var down = Ctx.init(&s, over, true);
    try expect(!interact(&down, 1, test_rect).clicked); // press alone isn't a click
    try expectEqual(@as(?Id, 1), s.active);

    s.was_down = true;
    var up = Ctx.init(&s, over, false);
    try expect(interact(&up, 1, test_rect).clicked);
    try expectEqual(@as(?Id, null), s.active);
}

test "releasing away from the press cancels the click" {
    var s = State{};
    var down = Ctx.init(&s, over, true);
    _ = interact(&down, 1, test_rect);

    // Pointer dragged off before release — the widget stays active but the click is dropped.
    s.was_down = true;
    var up = Ctx.init(&s, away, false);
    const it = interact(&up, 1, test_rect);
    try expect(!it.clicked);
    try expect(!it.hovered);
    try expectEqual(@as(?Id, null), s.active);
}

test "a widget being dragged keeps the pointer even when it strays off" {
    var s = State{};
    var down = Ctx.init(&s, over, true);
    _ = interact(&down, 1, test_rect);

    s.was_down = true;
    var drag = Ctx.init(&s, away, true);
    _ = interact(&drag, 1, test_rect);
    try expect(drag.captured); // still ours, so the editor doesn't see this drag
}

test "hovering captures the pointer so the editor doesn't also get the click" {
    var s = State{};
    var ctx = Ctx.init(&s, over, false);
    _ = interact(&ctx, 1, test_rect);
    try expect(ctx.captured);
    try expectEqual(@as(?Id, 1), s.hot);
}

test "a pointer elsewhere leaves the UI alone" {
    var s = State{};
    var ctx = Ctx.init(&s, away, false);
    const it = interact(&ctx, 1, test_rect);
    try expect(!it.hovered and !it.clicked);
    try expect(!ctx.captured);
    try expectEqual(@as(?Id, null), s.hot);
}

test "a click completes across real frames, and the widget doesn't stick down" {
    // Regression: edges were derived from the editor's mouse tracking, which the UI suppresses
    // whenever it holds the pointer. `pressed` was then true on every held frame and `released`
    // never true at all, so the widget latched down and its click never fired.
    var s = State{};
    var clicks: usize = 0;

    // Frame 1: press.
    {
        var ctx = Ctx.init(&s, over, true);
        if (interact(&ctx, 1, test_rect).clicked) clicks += 1;
        ctx.end();
    }
    try expectEqual(@as(usize, 0), clicks);
    try expectEqual(@as(?Id, 1), s.active);

    // Frame 2: still held. Not a fresh press, and still not a click.
    {
        var ctx = Ctx.init(&s, over, true);
        try expect(!ctx.pressed);
        if (interact(&ctx, 1, test_rect).clicked) clicks += 1;
        ctx.end();
    }
    try expectEqual(@as(usize, 0), clicks);

    // Frame 3: release — the click lands and the widget lets go.
    {
        var ctx = Ctx.init(&s, over, false);
        if (interact(&ctx, 1, test_rect).clicked) clicks += 1;
        ctx.end();
    }
    try expectEqual(@as(usize, 1), clicks);
    try expectEqual(@as(?Id, null), s.active);

    // Frame 4: idle. The click must not repeat.
    {
        var ctx = Ctx.init(&s, over, false);
        if (interact(&ctx, 1, test_rect).clicked) clicks += 1;
        ctx.end();
    }
    try expectEqual(@as(usize, 1), clicks);
}

test "holding a widget for many frames yields exactly one click" {
    var s = State{};
    var clicks: usize = 0;
    for (0..30) |_| {
        var ctx = Ctx.init(&s, over, true);
        if (interact(&ctx, 1, test_rect).clicked) clicks += 1;
        ctx.end();
    }
    try expectEqual(@as(usize, 0), clicks);
    var up = Ctx.init(&s, over, false);
    if (interact(&up, 1, test_rect).clicked) clicks += 1;
    up.end();
    try expectEqual(@as(usize, 1), clicks);
}

test "hot clears when the pointer leaves the widget it was over" {
    var s = State{ .hot = 1 };
    var ctx = Ctx.init(&s, away, false);
    _ = interact(&ctx, 1, test_rect);
    try expectEqual(@as(?Id, null), s.hot);
}
