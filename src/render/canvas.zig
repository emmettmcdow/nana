//! Canvas: the drawing surface the render tree draws into.
//!
//! An interface, not an implementation. `coretext.zig` backs it with Core Graphics for the real
//! window; `testing.zig` backs it with a recorder that keeps the calls instead of rasterising
//! them. Everything above this file is written against the methods here and cannot tell the two
//! apart, which is what lets the editor be driven headlessly by a test at full fidelity — the
//! same `ted.frame`, the same layout, only the pixels going somewhere else.
//!
//! Coordinate system: top-left origin, y grows downward. `drawText` treats (x, y) as the
//! top-left of the text box and returns the typographic size of what it drew.
//!
//! The indirection costs a call through a pointer per primitive, which is nothing next to what
//! the Core Text backend does inside each one. Measurement — the expensive half, and the half
//! on the layout's hot path — is cached by `ted.zig`'s `View` regardless of backend.

const geom = @import("geom.zig");

pub const Canvas = struct {
    /// The drawable area. Read directly by the render tree, which lays out against it.
    size: geom.Size,
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        fillRect: *const fn (ctx: *anyopaque, rect: geom.Rect, color: geom.Color) void,
        pushClip: *const fn (ctx: *anyopaque, rect: geom.Rect) void,
        popClip: *const fn (ctx: *anyopaque) void,
        drawText: *const fn (
            ctx: *anyopaque,
            utf8: []const u8,
            x: f64,
            y: f64,
            font: geom.Font,
            color: geom.Color,
        ) geom.Size,
        measureText: *const fn (ctx: *anyopaque, utf8: []const u8, font: geom.Font) geom.Size,
        measureTextAttributed: *const fn (ctx: *anyopaque, text: geom.AttributedText) geom.Size,
    };

    /// Fill a rectangle (top-left origin) with a solid color.
    pub fn fillRect(self: *Canvas, rect: geom.Rect, color: geom.Color) void {
        self.vtable.fillRect(self.ctx, rect, color);
    }

    /// Confine subsequent drawing to `rect` until the matching `popClip`. Calls must be
    /// balanced and may nest.
    pub fn pushClip(self: *Canvas, rect: geom.Rect) void {
        self.vtable.pushClip(self.ctx, rect);
    }

    pub fn popClip(self: *Canvas) void {
        self.vtable.popClip(self.ctx);
    }

    /// Draw a single line of UTF-8 text. (x, y) is the top-left of the text box.
    /// Returns the typographic size of the drawn text.
    pub fn drawText(
        self: *Canvas,
        utf8: []const u8,
        x: f64,
        y: f64,
        font: geom.Font,
        color: geom.Color,
    ) geom.Size {
        return self.vtable.drawText(self.ctx, utf8, x, y, font, color);
    }

    /// Measure a line of UTF-8 text without drawing it.
    pub fn measureText(self: *Canvas, utf8: []const u8, font: geom.Font) geom.Size {
        return self.vtable.measureText(self.ctx, utf8, font);
    }

    /// Measure a run-styled line without drawing it, shaping it as one line.
    ///
    /// This is the one thing `measureText` cannot be made to do by calling it repeatedly: the
    /// width of a mixed-style line is not the sum of its runs' widths, and its height is not
    /// obtainable at all from the parts, because ascent and descent are the maxima taken over
    /// every run rather than anything a single run knows.
    pub fn measureTextAttributed(self: *Canvas, text: geom.AttributedText) geom.Size {
        return self.vtable.measureTextAttributed(self.ctx, text);
    }

    /// Fill the whole canvas with a solid color. Derived rather than dispatched: every backend
    /// would write the same one-line body.
    pub fn clear(self: *Canvas, color: geom.Color) void {
        self.fillRect(.{ .x = 0, .y = 0, .w = self.size.w, .h = self.size.h }, color);
    }
};
