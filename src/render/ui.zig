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
    /// The area widgets can currently be hit in, or null for the whole canvas. The hit-testing
    /// counterpart of `Canvas.pushClip` — see `pushClip` below.
    clip: ?Rect = null,

    pub fn init(state: *State, mouse: Point, mouse_down: bool) Ctx {
        return .{
            .state = state,
            .mouse = mouse,
            .mouse_down = mouse_down,
            .pressed = mouse_down and !state.was_down,
            .released = !mouse_down and state.was_down,
        };
    }

    /// Confine hit-testing to `rect`, and hand back the clip to restore afterwards:
    ///
    ///     const saved = ctx.pushClip(viewport);
    ///     defer ctx.popClip(saved);
    ///
    /// A widget scrolled halfway out of a viewport is drawn cut in half by `Canvas.pushClip`,
    /// but its rect is unchanged, so without the same clip here it stays hoverable and clickable
    /// over the half that was never painted — including well outside the panel containing it.
    /// Clips nest, each narrowing the last.
    pub fn pushClip(self: *Ctx, rect: Rect) ?Rect {
        const prev = self.clip;
        self.clip = if (prev) |c| c.intersect(rect) else rect;
        return prev;
    }

    pub fn popClip(self: *Ctx, prev: ?Rect) void {
        self.clip = prev;
    }

    /// Whether the pointer is somewhere widgets can be hit at all this frame.
    fn inClip(self: Ctx) bool {
        return if (self.clip) |c| c.contains(self.mouse) else true;
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
    const inside = rect.contains(ctx.mouse) and ctx.inClip();
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
    const pad: f64 = 12;
    const it = interact(ctx, id, rect);
    if (it.hovered or it.held or selected) {
        canvas.fillRect(rect, surface(t, it));
    }

    const font = Font{ .size = t.font_size };
    const line_end = @min(256, maxFitLineEnd(canvas, label, t, rect.w - 2 * pad));
    var label_buf: [256]u8 = undefined;
    const mod_label = if (line_end == label.len) label else b: {
        @memcpy(label_buf[0..line_end], label[0..line_end]);
        if (256 - line_end >= 3) {
            // 0xE2 0x80 0xA6 - Ellipsis Character in UTF-8
            label_buf[line_end] = 0xE2;
            label_buf[line_end + 1] = 0x80;
            label_buf[line_end + 2] = 0xA6;
            break :b label_buf[0 .. line_end + 3];
        } else {
            // Better to cut off a word than drop the ellipsis
            label_buf[line_end - 3] = 0xE2;
            label_buf[line_end - 2] = 0x80;
            label_buf[line_end - 1] = 0xA6;
            break :b label_buf[0..line_end];
        }
    };

    const size = canvas.measureText(mod_label, font);
    _ = canvas.drawText(
        mod_label,
        rect.x + pad,
        rect.y + (rect.h - size.h) / 2,
        font,
        t.text,
    );
    return it.clicked;
}

/// Similar to same function in ted.zig, but more suited to this particular use-case.
fn maxFitLineEnd(canvas: *Canvas, full_text: []const u8, t: Theme, max_width: f64) usize {
    var best: usize = 0;
    var lo: usize = 0;
    var hi: usize = full_text.len;

    const font = Font{ .size = t.font_size };
    while (lo < hi) {
        const mid = lo + ((hi - lo) + 1) / 2;
        var probe = mid;
        while (probe < full_text.len and (full_text[probe] & 0xC0) == 0x80) probe += 1;

        const w = canvas.measureText(full_text[0..probe], font).w;
        if (w < max_width) {
            best = @max(best, probe);
            lo = mid;
        } else {
            hi = mid - 1;
        }
    }

    if (best == 0) {
        // Not even one character fits. Emit it anyway: a row has to advance, or `splitLines`
        // never terminates. Nothing to retreat to either, so this returns straight out.
        const seq = std.unicode.utf8ByteSequenceLength(full_text[0]) catch 1;
        return @min(seq, full_text.len);
    }

    // From wrapPoint
    if (best >= full_text.len) return best;

    // Mid-word. The only retreat worth making is to the start of the word being split, so scan
    // back for the space that begins it — anything earlier would give up a word that fit.
    var b = best;
    while (b > 0 and full_text[b - 1] != ' ') b -= 1;
    while (b > 0 and full_text[b - 1] == ' ') b -= 1;
    if (b == 0) return best; // the row is one unbroken word; it has to break somewhere
    return b;
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

test "a clip keeps the hidden part of a widget from answering to the pointer" {
    // The half of a scrolled row that the canvas clip cut away is still inside the row's rect.
    // Without the same clip on the hit test it hovers and clicks like the part that was drawn.
    const clip = Rect{ .x = 0, .y = 20, .w = 200, .h = 100 }; // cuts test_rect's top half
    const hidden = Point{ .x = 50, .y = 15 };

    var s = State{};
    var ctx = Ctx.init(&s, hidden, true);
    const saved = ctx.pushClip(clip);
    const it = interact(&ctx, 1, test_rect);
    try expect(!it.hovered);
    try expect(!ctx.captured);
    try expectEqual(@as(?Id, null), s.active); // and no press to release into a click later

    // Past the clip, the visible half still behaves normally.
    ctx.popClip(saved);
    try expect(interact(&ctx, 1, test_rect).hovered);
}

test "clips nest, each narrowing the last" {
    var s = State{};
    var ctx = Ctx.init(&s, over, false);

    const outer = ctx.pushClip(.{ .x = 0, .y = 0, .w = 100, .h = 100 });
    try expect(interact(&ctx, 1, test_rect).hovered);

    // A wider inner clip must not widen the effective one back out.
    const inner = ctx.pushClip(.{ .x = 0, .y = 0, .w = 1000, .h = 15 });
    try expect(!interact(&ctx, 1, test_rect).hovered);

    ctx.popClip(inner);
    try expect(interact(&ctx, 1, test_rect).hovered);
    ctx.popClip(outer);
    try expectEqual(@as(?Rect, null), ctx.clip);
}

test "hot clears when the pointer leaves the widget it was over" {
    var s = State{ .hot = 1 };
    var ctx = Ctx.init(&s, away, false);
    _ = interact(&ctx, 1, test_rect);
    try expectEqual(@as(?Id, null), s.hot);
}
