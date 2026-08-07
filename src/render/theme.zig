//! The colors and type size everything is drawn with.
//!
//! Every color is derived from three — a background, a text color, and a tertiary accent —
//! rather than picked independently. Markdown styling reads as weight and emphasis against the
//! body text, so a code span or a quote rule is one of those colors at a different opacity.
//! Retheming is then a matter of supplying a new triple, and no derived color can drift out of
//! step with the rest.
//!
//! Alongside the colors sits `Metrics`: the handful of lengths the layout is built from. They
//! live here rather than as constants in `ted.zig` for the same reason the colors do — the user's
//! style file sets them, and the render tree reads them off the one global.

/// The three colors a theme is built from. One per appearance — the style file has a `[light]`
/// and a `[dark]` — and everything else is derived.
pub const Palette = struct {
    background: Color,
    foreground: Color,
    /// The accent. Defaults to the foreground, which is what the editor looked like before there
    /// was a third color to set.
    tertiary: Color,
};

pub const Theme = struct {
    background: Color,
    text: Color,
    /// The accent. Links, quotes and the selection wash come off this rather than off `text`, so
    /// a theme can give the marked-up parts of a document a color of their own.
    tertiary: Color,
    /// Selection wash. Translucent so it composites over whatever it covers.
    highlight: Color,
    code: Color,
    /// Panel behind code. Also translucent, so a selection under it still reads.
    code_bg: Color,
    quote: Color,
    quote_rule: Color,
    link: Color,
    /// Caret. Follows the text color rather than being fixed — a white caret is invisible on
    /// a light background.
    caret: Color,
    font_size: f64,
    metrics: Metrics = .{},

    /// Build a full theme from a palette.
    pub fn derive(p: Palette, font_size: f64, opacity: Opacity, metrics: Metrics) Theme {
        return .{
            .background = p.background,
            .text = p.foreground,
            .tertiary = p.tertiary,
            .highlight = p.tertiary.withAlpha(opacity.highlight),
            .code = p.foreground.withAlpha(opacity.code),
            .code_bg = p.foreground.withAlpha(opacity.code_bg),
            .quote = p.tertiary.withAlpha(opacity.quote),
            .quote_rule = p.tertiary.withAlpha(opacity.quote_rule),
            .link = p.tertiary,
            .caret = p.foreground,
            .font_size = font_size,
            .metrics = metrics,
        };
    }
};

/// How translucent each derived color is against the one it comes from. Split out from `Metrics`
/// because these are ratios, not lengths, and the style file groups them the same way.
pub const Opacity = struct {
    highlight: f32 = 0.25,
    code: f32 = 0.85,
    code_bg: f32 = 0.12,
    quote: f32 = 0.70,
    quote_rule: f32 = 0.35,
};

/// The lengths the layout is built from, in points.
pub const Metrics = struct {
    /// Space between the window's edge and the content column, on all four sides.
    padding: f64 = 100,
    /// Space above and below a run of headings, fenced code, or quoted text. Applied to the
    /// first and last row of the block only, so the rows inside one stay tight against
    /// each other. Adjacent blocks do not collapse their margins — two of them meeting leaves
    /// the sum of the two, which is what tuning them independently wants.
    heading_margin_y: f64 = 0,
    code_margin_y: f64 = 0,
    quote_margin_y: f64 = 0,
    /// How far one level of quote nesting pushes its text right, and how wide the rule standing
    /// in the gutter it vacated is drawn.
    quote_indent: f64 = 24,
    quote_rule_w: f64 = 3,
    /// Heading type size as a multiple of the body size: an h1 is `heading_scale`, and each
    /// further level steps down by `heading_step`. Never below 1x, so a deep heading cannot end
    /// up smaller than the text under it.
    heading_scale: f64 = 2.0,
    heading_step: f64 = 0.2,

    /// The type-size multiple for a heading of `degree` (1 for `#`, 2 for `##`, …).
    pub fn headingScale(self: Metrics, degree: usize) f64 {
        const steps = @as(f64, @floatFromInt(degree -| 1));
        return @max(1.0, self.heading_scale - (steps * self.heading_step));
    }
};

pub const DEFAULT_FONT_SIZE: f64 = 20;
pub const MIN_FONT_SIZE: f64 = 8;
pub const MAX_FONT_SIZE: f64 = 64;

pub const ink = Color.rgb(47.0 / 255.0, 47.0 / 255.0, 47.0 / 255.0);
pub const paper = Color.rgb(228.0 / 255.0, 228.0 / 255.0, 228.0 / 255.0);

pub const light_palette = Palette{ .background = paper, .foreground = ink, .tertiary = ink };
pub const dark_palette = Palette{ .background = ink, .foreground = paper, .tertiary = paper };

pub fn light(font_size: f64) Theme {
    return Theme.derive(light_palette, font_size, .{}, .{});
}

pub fn dark(font_size: f64) Theme {
    return Theme.derive(dark_palette, font_size, .{}, .{});
}

/// The theme in force. A global because every draw call wants it and threading it through the
/// whole render tree would be noise; the host sets it, `app.zig` only reads it.
pub var active: Theme = dark(DEFAULT_FONT_SIZE);

/// Shorthand for `active`. Draw code reads the theme on nearly every line, and the render
/// modules each alias this as `th` so those lines stay about what is being drawn.
pub fn th() Theme {
    return active;
}

const geom = @import("geom.zig");
const Color = geom.Color;

const std = @import("std");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

test "derived colors track the colors they come from" {
    const t = dark(20);
    try expect(t.highlight.r == t.tertiary.r and t.highlight.a == 0.25);
    try expect(t.code_bg.r == t.text.r and t.code_bg.a == 0.12);
    try expect(t.caret.r == t.text.r and t.caret.a == 1.0);
}

test "light and dark are inverses of one another" {
    const l = light(20);
    const d = dark(20);
    try expect(l.background.r == d.text.r);
    try expect(l.text.r == d.background.r);
}

test "a tertiary color separates the marked-up roles from the body text" {
    const accent = Color.rgb(0, 0.5, 1);
    const t = Theme.derive(.{ .background = ink, .foreground = paper, .tertiary = accent }, 20, .{}, .{});
    try expect(t.link.b == accent.b);
    try expect(t.quote.b == accent.b);
    try expect(t.quote_rule.b == accent.b);
    // Body text and code stay off the text color; the accent is not a wholesale recolor.
    try expect(t.text.b == paper.b and t.code.b == paper.b);
}

test "heading sizes step down and bottom out at body size" {
    const m = Metrics{};
    try expectEqual(@as(f64, 2.0), m.headingScale(1));
    try expectEqual(@as(f64, 1.8), m.headingScale(2));
    try expectEqual(@as(f64, 1.0), m.headingScale(6));
    // A degree past the last step, or a nonsensical one, still yields body size.
    try expectEqual(@as(f64, 1.0), m.headingScale(20));
    try expectEqual(@as(f64, 2.0), m.headingScale(0));
}
