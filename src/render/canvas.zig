//! Canvas: the raylib-level drawing surface.
//!
//! Wraps a Core Graphics context handed in from the Swift/AppKit shell and offers a
//! handful of primitives (clear / fillRect / drawText / measureText) implemented with
//! Core Text + Core Graphics. These are plain C APIs — no Objective-C runtime, no
//! `objc_msgSend`. This is the ONE module that touches Apple frameworks; everything
//! above it stays platform-independent.
//!
//! Coordinate system: top-left origin, y grows downward (the host NSView is `isFlipped`).
//! `drawText` flips the text matrix so glyphs render upright in that space and treats the
//! given (x, y) as the top-left of the text box.

const std = @import("std");
const geom = @import("geom.zig");

// ── Opaque handle types ───────────────────────────────────────────────────────
pub const CGContextRef = ?*anyopaque;
const CFStringRef = ?*anyopaque;
const CFAttributedStringRef = ?*anyopaque;
const CFDictionaryRef = ?*anyopaque;
const CTFontRef = ?*anyopaque;
const CTLineRef = ?*anyopaque;
const CGColorRef = ?*anyopaque;

const CFDictionaryKeyCallBacks = opaque {};
const CFDictionaryValueCallBacks = opaque {};

// ── C structs (must match the Apple ABI) ──────────────────────────────────────
const CGPoint = extern struct { x: f64, y: f64 };
const CGSize = extern struct { width: f64, height: f64 };
const CGRect = extern struct { origin: CGPoint, size: CGSize };
const CGAffineTransform = extern struct { a: f64, b: f64, c: f64, d: f64, tx: f64, ty: f64 };

const kCFStringEncodingUTF8: u32 = 0x0800_0100;

// ── External symbols (CoreFoundation / CoreGraphics / CoreText) ────────────────
extern const kCTFontAttributeName: CFStringRef;
extern const kCTForegroundColorAttributeName: CFStringRef;
extern const kCFTypeDictionaryKeyCallBacks: CFDictionaryKeyCallBacks;
extern const kCFTypeDictionaryValueCallBacks: CFDictionaryValueCallBacks;

extern fn CFRelease(cf: ?*anyopaque) void;
extern fn CFStringCreateWithBytes(
    alloc: ?*anyopaque,
    bytes: [*]const u8,
    num_bytes: isize,
    encoding: u32,
    is_external_representation: u8,
) CFStringRef;
extern fn CFDictionaryCreate(
    alloc: ?*anyopaque,
    keys: [*]const ?*const anyopaque,
    values: [*]const ?*const anyopaque,
    num_values: isize,
    key_callbacks: ?*const CFDictionaryKeyCallBacks,
    value_callbacks: ?*const CFDictionaryValueCallBacks,
) CFDictionaryRef;
extern fn CFAttributedStringCreate(
    alloc: ?*anyopaque,
    str: CFStringRef,
    attributes: CFDictionaryRef,
) CFAttributedStringRef;

extern fn CTFontCreateWithName(name: CFStringRef, size: f64, matrix: ?*const CGAffineTransform) CTFontRef;
extern fn CTLineCreateWithAttributedString(string: CFAttributedStringRef) CTLineRef;
extern fn CTLineDraw(line: CTLineRef, context: CGContextRef) void;
extern fn CTLineGetTypographicBounds(line: CTLineRef, ascent: ?*f64, descent: ?*f64, leading: ?*f64) f64;

extern fn CGColorCreateGenericRGB(red: f64, green: f64, blue: f64, alpha: f64) CGColorRef;
extern fn CGContextSetRGBFillColor(c: CGContextRef, red: f64, green: f64, blue: f64, alpha: f64) void;
extern fn CGContextFillRect(c: CGContextRef, rect: CGRect) void;
extern fn CGContextSetTextPosition(c: CGContextRef, x: f64, y: f64) void;
extern fn CGContextSetTextMatrix(c: CGContextRef, t: CGAffineTransform) void;

/// Default font family. Menlo is a good monospace default for a text editor;
/// swap freely while iterating in app.zig.
const default_font: []const u8 = "Menlo";

pub const Canvas = struct {
    ctx: CGContextRef,
    size: geom.Size,

    /// Fill the whole canvas with a solid color.
    pub fn clear(self: *Canvas, color: geom.Color) void {
        self.fillRect(.{ .x = 0, .y = 0, .w = self.size.w, .h = self.size.h }, color);
    }

    /// Fill a rectangle (top-left origin) with a solid color.
    pub fn fillRect(self: *Canvas, rect: geom.Rect, color: geom.Color) void {
        CGContextSetRGBFillColor(self.ctx, color.r, color.g, color.b, color.a);
        CGContextFillRect(self.ctx, .{
            .origin = .{ .x = rect.x, .y = rect.y },
            .size = .{ .width = rect.w, .height = rect.h },
        });
    }

    /// Draw a single line of UTF-8 text. (x, y) is the top-left of the text box.
    /// Returns the typographic size of the drawn text.
    pub fn drawText(self: *Canvas, utf8: []const u8, x: f64, y: f64, font_size: f64, color: geom.Color) geom.Size {
        if (utf8.len == 0) return geom.Size.zero;
        const line = makeLine(utf8, font_size, color) orelse return geom.Size.zero;
        defer CFRelease(line);

        var ascent: f64 = 0;
        var descent: f64 = 0;
        var leading: f64 = 0;
        const width = CTLineGetTypographicBounds(line, &ascent, &descent, &leading);

        // Flip the text matrix so glyphs are upright in our y-down context, and place
        // the baseline `ascent` below the requested top-left y.
        CGContextSetTextMatrix(self.ctx, .{ .a = 1, .b = 0, .c = 0, .d = -1, .tx = 0, .ty = 0 });
        CGContextSetTextPosition(self.ctx, x, y + ascent);
        CTLineDraw(line, self.ctx);

        return .{ .w = width, .h = ascent + descent + leading };
    }

    /// Measure a line of UTF-8 text without drawing it.
    pub fn measureText(self: *Canvas, utf8: []const u8, font_size: f64) geom.Size {
        _ = self;
        if (utf8.len == 0) return geom.Size.zero;
        const line = makeLine(utf8, font_size, geom.Color.white) orelse return geom.Size.zero;
        defer CFRelease(line);
        var ascent: f64 = 0;
        var descent: f64 = 0;
        var leading: f64 = 0;
        const width = CTLineGetTypographicBounds(line, &ascent, &descent, &leading);
        return .{ .w = width, .h = ascent + descent + leading };
    }
};

/// Build a CTLine for one run of UTF-8 text. Caller owns the returned line (CFRelease).
/// All intermediate CF objects are released here.
fn makeLine(utf8: []const u8, font_size: f64, color: geom.Color) ?CTLineRef {
    const cfstr = CFStringCreateWithBytes(null, utf8.ptr, @intCast(utf8.len), kCFStringEncodingUTF8, 0);
    if (cfstr == null) return null;
    defer CFRelease(cfstr);

    const name = CFStringCreateWithBytes(null, default_font.ptr, @intCast(default_font.len), kCFStringEncodingUTF8, 0);
    defer if (name != null) CFRelease(name);

    const font = CTFontCreateWithName(name, font_size, null);
    defer if (font != null) CFRelease(font);

    const cgcolor = CGColorCreateGenericRGB(color.r, color.g, color.b, color.a);
    defer if (cgcolor != null) CFRelease(cgcolor);

    const keys = [_]?*const anyopaque{ kCTFontAttributeName, kCTForegroundColorAttributeName };
    const values = [_]?*const anyopaque{ font, cgcolor };
    const dict = CFDictionaryCreate(
        null,
        &keys,
        &values,
        keys.len,
        &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks,
    );
    if (dict == null) return null;
    defer CFRelease(dict);

    const attr = CFAttributedStringCreate(null, cfstr, dict);
    if (attr == null) return null;
    defer CFRelease(attr);

    return CTLineCreateWithAttributedString(attr);
}
