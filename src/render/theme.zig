//! The colors and type size everything is drawn with.
//!
//! Every color is derived from just two — a background and a text color — rather than picked
//! independently. Markdown styling reads as weight and emphasis against the body text, so a
//! code span or a quote rule is the body color at a different opacity. Retheming is then a
//! matter of supplying a new pair, and no derived color can drift out of step with the rest.

pub const Theme = struct {
    background: Color,
    text: Color,
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

    /// Build a full theme from a background/text pair.
    pub fn derive(background: Color, text: Color, font_size: f64) Theme {
        return .{
            .background = background,
            .text = text,
            .highlight = text.withAlpha(0.25),
            .code = text.withAlpha(0.85),
            .code_bg = text.withAlpha(0.12),
            .quote = text.withAlpha(0.70),
            .quote_rule = text.withAlpha(0.35),
            .link = text,
            .caret = text,
            .font_size = font_size,
        };
    }
};

pub const DEFAULT_FONT_SIZE: f64 = 20;
pub const MIN_FONT_SIZE: f64 = 8;
pub const MAX_FONT_SIZE: f64 = 64;

const ink = Color.rgb(47.0 / 255.0, 47.0 / 255.0, 47.0 / 255.0);
const paper = Color.rgb(228.0 / 255.0, 228.0 / 255.0, 228.0 / 255.0);

pub fn light(font_size: f64) Theme {
    return Theme.derive(paper, ink, font_size);
}

pub fn dark(font_size: f64) Theme {
    return Theme.derive(ink, paper, font_size);
}

pub fn forAppearance(is_dark: bool, font_size: f64) Theme {
    return if (is_dark) dark(font_size) else light(font_size);
}

/// The theme in force. A global because every draw call wants it and threading it through the
/// whole render tree would be noise; the host sets it, `app.zig` only reads it.
pub var active: Theme = Theme.derive(ink, paper, DEFAULT_FONT_SIZE);

/// Shorthand for `active`. Draw code reads the theme on nearly every line, and the render
/// modules each alias this as `th` so those lines stay about what is being drawn.
pub fn th() Theme {
    return active;
}

const geom = @import("geom.zig");
const Color = geom.Color;

const std = @import("std");
const expect = std.testing.expect;

test "derived colors track the text color" {
    const t = dark(20);
    try expect(t.highlight.r == t.text.r and t.highlight.a == 0.25);
    try expect(t.code_bg.r == t.text.r and t.code_bg.a == 0.12);
    try expect(t.caret.r == t.text.r and t.caret.a == 1.0);
}

test "light and dark are inverses of one another" {
    const l = light(20);
    const d = dark(20);
    try expect(l.background.r == d.text.r);
    try expect(l.text.r == d.background.r);
}
