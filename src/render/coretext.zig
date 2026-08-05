//! The Core Graphics / Core Text backend for `Canvas`.
//!
//! Wraps a CGContext handed in from the Swift/AppKit shell and implements the `Canvas` vtable
//! against Core Text + Core Graphics. These are plain C APIs — no Objective-C runtime, no
//! `objc_msgSend`. This is the ONE module that touches Apple frameworks; everything above it,
//! `canvas.zig` included, stays platform-independent.
//!
//! Coordinate system: top-left origin, y grows downward (the host NSView is `isFlipped`).
//! `drawText` flips the text matrix so glyphs render upright in that space and treats the
//! given (x, y) as the top-left of the text box.

const std = @import("std");
const geom = @import("geom.zig");
const Canvas = @import("canvas.zig").Canvas;

// ── Opaque handle types ───────────────────────────────────────────────────────
pub const CGContextRef = ?*anyopaque;
const CFStringRef = ?*anyopaque;
const CFAttributedStringRef = ?*anyopaque;
const CFMutableAttributedStringRef = ?*anyopaque;
const CFDictionaryRef = ?*anyopaque;
const CTFontRef = ?*anyopaque;
const CTLineRef = ?*anyopaque;
const CGColorRef = ?*anyopaque;
const CFNumberRef = ?*anyopaque;

const CFDictionaryKeyCallBacks = opaque {};
const CFDictionaryValueCallBacks = opaque {};

// ── C structs (must match the Apple ABI) ──────────────────────────────────────
const CGPoint = extern struct { x: f64, y: f64 };
const CGSize = extern struct { width: f64, height: f64 };
const CGRect = extern struct { origin: CGPoint, size: CGSize };
const CGAffineTransform = extern struct { a: f64, b: f64, c: f64, d: f64, tx: f64, ty: f64 };
/// CFIndex is `long`, so `isize` here. Note that a CFRange over a string counts UTF-16 code
/// units, never bytes — see `makeAttributedLine`.
const CFRange = extern struct { location: isize, length: isize };

const kCFStringEncodingUTF8: u32 = 0x0800_0100;

// ── External symbols (CoreFoundation / CoreGraphics / CoreText) ────────────────
extern const kCTFontAttributeName: CFStringRef;
extern const kCTForegroundColorAttributeName: CFStringRef;
extern const kCTUnderlineStyleAttributeName: CFStringRef;
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
extern fn CFNumberCreate(alloc: ?*anyopaque, theType: c_long, valuePtr: *const anyopaque) CFNumberRef;
extern fn CFStringGetLength(theString: CFStringRef) isize;
/// `max_length` of 0 means unbounded.
extern fn CFAttributedStringCreateMutable(alloc: ?*anyopaque, max_length: isize) CFMutableAttributedStringRef;
extern fn CFAttributedStringReplaceString(
    a_str: CFMutableAttributedStringRef,
    range: CFRange,
    replacement: CFStringRef,
) void;
extern fn CFAttributedStringSetAttributes(
    a_str: CFMutableAttributedStringRef,
    range: CFRange,
    replacement: CFDictionaryRef,
    clear_other_attributes: u8,
) void;
extern fn CFAttributedStringBeginEditing(a_str: CFMutableAttributedStringRef) void;
extern fn CFAttributedStringEndEditing(a_str: CFMutableAttributedStringRef) void;

const kCFNumberSInt32Type: c_long = 3;
const kCTUnderlineStyleSingle: i32 = 1;

extern fn CTFontCreateWithName(name: CFStringRef, size: f64, matrix: ?*const CGAffineTransform) CTFontRef;
extern fn CTLineCreateWithAttributedString(string: CFAttributedStringRef) CTLineRef;
extern fn CTLineDraw(line: CTLineRef, context: CGContextRef) void;
extern fn CTLineGetTypographicBounds(line: CTLineRef, ascent: ?*f64, descent: ?*f64, leading: ?*f64) f64;

extern fn CGColorCreateGenericRGB(red: f64, green: f64, blue: f64, alpha: f64) CGColorRef;
extern fn CGContextSetRGBFillColor(c: CGContextRef, red: f64, green: f64, blue: f64, alpha: f64) void;
extern fn CGContextFillRect(c: CGContextRef, rect: CGRect) void;
extern fn CGContextSetTextPosition(c: CGContextRef, x: f64, y: f64) void;
extern fn CGContextSetTextMatrix(c: CGContextRef, t: CGAffineTransform) void;
extern fn CGContextSaveGState(c: CGContextRef) void;
extern fn CGContextRestoreGState(c: CGContextRef) void;
extern fn CGContextClipToRect(c: CGContextRef, rect: CGRect) void;

/// Font faces, by PostScript name. Menlo is a good monospace default for a text editor and
/// ships with all four styles; swap the family freely while iterating in app.zig.
const face_regular: []const u8 = "Menlo-Regular";
const face_bold: []const u8 = "Menlo-Bold";
const face_italic: []const u8 = "Menlo-Italic";
const face_bold_italic: []const u8 = "Menlo-BoldItalic";

/// The face satisfying a font request's trait flags.
fn faceName(font: geom.Font) []const u8 {
    if (font.bold and font.italic) return face_bold_italic;
    if (font.bold) return face_bold;
    if (font.italic) return face_italic;
    return face_regular;
}

/// A `Canvas` backed by a CGContext. Hand it the context the host gave you, then call
/// `canvas()` to get the interface the render tree draws through.
pub const CoreTextCanvas = struct {
    ctx: CGContextRef,

    /// The interface view of this backend. Borrows `self`, so the backend must outlive the
    /// returned `Canvas` — in practice both live on the stack of one `nana_render_frame` call.
    pub fn canvas(self: *CoreTextCanvas, size: geom.Size) Canvas {
        return .{ .size = size, .ctx = self, .vtable = &vtable };
    }
};

const vtable = Canvas.VTable{
    .fillRect = fillRect,
    .pushClip = pushClip,
    .popClip = popClip,
    .drawText = drawText,
    .measureText = measureText,
    .measureTextAttributed = measureTextAttributed,
};

fn backend(ctx: *anyopaque) *CoreTextCanvas {
    return @ptrCast(@alignCast(ctx));
}

/// Fill a rectangle (top-left origin) with a solid color.
fn fillRect(ctx: *anyopaque, rect: geom.Rect, color: geom.Color) void {
    CGContextSetRGBFillColor(backend(ctx).ctx, color.r, color.g, color.b, color.a);
    CGContextFillRect(backend(ctx).ctx, .{
        .origin = .{ .x = rect.x, .y = rect.y },
        .size = .{ .width = rect.w, .height = rect.h },
    });
}

/// Needed once the view scrolls by pixels rather than whole lines: the topmost visible row is
/// then usually cut off partway, and without a clip its upper half would be drawn into the
/// margin above the content area.
fn pushClip(ctx: *anyopaque, rect: geom.Rect) void {
    CGContextSaveGState(backend(ctx).ctx);
    CGContextClipToRect(backend(ctx).ctx, .{
        .origin = .{ .x = rect.x, .y = rect.y },
        .size = .{ .width = rect.w, .height = rect.h },
    });
}

fn popClip(ctx: *anyopaque) void {
    CGContextRestoreGState(backend(ctx).ctx);
}

fn drawText(ctx: *anyopaque, utf8: []const u8, x: f64, y: f64, font: geom.Font, color: geom.Color) geom.Size {
    if (utf8.len == 0) return geom.Size.zero;
    const line = makeLine(utf8, font, color) orelse return geom.Size.zero;
    defer CFRelease(line);

    var ascent: f64 = 0;
    var descent: f64 = 0;
    var leading: f64 = 0;
    const width = CTLineGetTypographicBounds(line, &ascent, &descent, &leading);

    // Flip the text matrix so glyphs are upright in our y-down context, and place
    // the baseline `ascent` below the requested top-left y.
    CGContextSetTextMatrix(backend(ctx).ctx, .{ .a = 1, .b = 0, .c = 0, .d = -1, .tx = 0, .ty = 0 });
    CGContextSetTextPosition(backend(ctx).ctx, x, y + ascent);
    CTLineDraw(line, backend(ctx).ctx);

    return .{ .w = width, .h = ascent + descent + leading };
}

fn measureText(_: *anyopaque, utf8: []const u8, font: geom.Font) geom.Size {
    if (utf8.len == 0) return geom.Size.zero;
    const line = makeLine(utf8, font, geom.Color.white) orelse return geom.Size.zero;
    defer CFRelease(line);
    var ascent: f64 = 0;
    var descent: f64 = 0;
    var leading: f64 = 0;
    const width = CTLineGetTypographicBounds(line, &ascent, &descent, &leading);
    return .{ .w = width, .h = ascent + descent + leading };
}

/// Returns `Size.zero` when there is no text. That includes a line whose runs are all empty,
/// which is not the same as a blank line wanting a blank line's height — a caller laying out
/// rows still has to supply that height itself.
fn measureTextAttributed(_: *anyopaque, text: geom.AttributedText) geom.Size {
    const line = makeAttributedLine(text) orelse return geom.Size.zero;
    defer CFRelease(line);

    var ascent: f64 = 0;
    var descent: f64 = 0;
    var leading: f64 = 0;
    const width = CTLineGetTypographicBounds(line, &ascent, &descent, &leading);
    return .{ .w = width, .h = ascent + descent + leading };
}

/// Build a CTLine for one run of UTF-8 text. Caller owns the returned line (CFRelease).
/// All intermediate CF objects are released here.
fn makeLine(utf8: []const u8, font_req: geom.Font, color: geom.Color) ?CTLineRef {
    const cfstr = CFStringCreateWithBytes(null, utf8.ptr, @intCast(utf8.len), kCFStringEncodingUTF8, 0);
    if (cfstr == null) return null;
    defer CFRelease(cfstr);

    const dict = makeAttrDict(font_req, color) orelse return null;
    defer CFRelease(dict);

    const attr = CFAttributedStringCreate(null, cfstr, dict);
    if (attr == null) return null;
    defer CFRelease(attr);

    return CTLineCreateWithAttributedString(attr);
}

/// Build a CTLine spanning several differently styled runs, so Core Text shapes and measures
/// them as one line. Caller owns the returned line (CFRelease).
///
/// Returns null for text with nothing in it, matching `makeLine` on an empty slice.
fn makeAttributedLine(text: geom.AttributedText) ?CTLineRef {
    if (text.isEmpty()) return null;

    const attr = CFAttributedStringCreateMutable(null, 0);
    if (attr == null) return null;
    defer CFRelease(attr);

    // The runs are appended one at a time and styled in place. Bracketing that in
    // Begin/EndEditing keeps Core Foundation from re-deriving the string's bookkeeping after
    // every single one.
    CFAttributedStringBeginEditing(attr);

    var pos: isize = 0;
    for (text.runs) |run| {
        if (run.text.len == 0) continue; // a concealed run: no glyphs, no range to style
        const cfstr = CFStringCreateWithBytes(null, run.text.ptr, @intCast(run.text.len), kCFStringEncodingUTF8, 0);
        if (cfstr == null) continue;
        defer CFRelease(cfstr);

        // Ranges into an attributed string are in UTF-16 code units, so the span to style has
        // to be the CFString's own length. `run.text.len` is bytes, and the two part company
        // for anything outside ASCII — using it would style the wrong span and, past the first
        // multi-byte character, silently walk off the end of the string.
        const len = CFStringGetLength(cfstr);
        CFAttributedStringReplaceString(attr, .{ .location = pos, .length = 0 }, cfstr);

        // A run that fails to produce a dictionary still occupies its range; leaving it
        // unstyled measures it in the system default font, which is wrong but bounded, and
        // keeps the offsets of every later run correct.
        if (makeAttrDict(run.font, run.color)) |dict| {
            defer CFRelease(dict);
            CFAttributedStringSetAttributes(attr, .{ .location = pos, .length = len }, dict, 1);
        }
        pos += len;
    }

    CFAttributedStringEndEditing(attr);
    if (pos == 0) return null; // every run was empty or could not be converted

    return CTLineCreateWithAttributedString(attr);
}

/// The Core Text attribute dictionary describing one styled run. Caller owns the result
/// (CFRelease); the font and color it holds are released here, the dictionary having retained
/// them.
fn makeAttrDict(font_req: geom.Font, color: geom.Color) ?CFDictionaryRef {
    const face = faceName(font_req);
    const name = CFStringCreateWithBytes(null, face.ptr, @intCast(face.len), kCFStringEncodingUTF8, 0);
    defer if (name != null) CFRelease(name);

    const font = CTFontCreateWithName(name, font_req.size, null);
    defer if (font != null) CFRelease(font);

    const cgcolor = CGColorCreateGenericRGB(color.r, color.g, color.b, color.a);
    defer if (cgcolor != null) CFRelease(cgcolor);

    // Underlining is left to Core Text rather than drawn as a rule of our own: it positions and
    // thickens the line from the font's own metrics, which we would otherwise have to plumb out
    // of here just to guess at.
    const underline_style: i32 = kCTUnderlineStyleSingle;
    const underline = if (font_req.underline)
        CFNumberCreate(null, kCFNumberSInt32Type, &underline_style)
    else
        null;
    defer if (underline != null) CFRelease(underline);

    var keys = [_]?*const anyopaque{ kCTFontAttributeName, kCTForegroundColorAttributeName, undefined };
    var values = [_]?*const anyopaque{ font, cgcolor, undefined };
    var attr_count: isize = 2;
    if (underline != null) {
        keys[2] = kCTUnderlineStyleAttributeName;
        values[2] = underline;
        attr_count = 3;
    }
    return CFDictionaryCreate(
        null,
        &keys,
        &values,
        attr_count,
        &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks,
    );
}
