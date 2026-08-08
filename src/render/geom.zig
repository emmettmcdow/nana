//! Pure geometry/color primitives shared across the render scaffold.
//! No platform dependencies — fully unit-testable headless.

pub const Point = struct {
    x: f64,
    y: f64,
};

pub const Size = struct {
    w: f64,
    h: f64,

    pub const zero = Size{ .w = 0, .h = 0 };
};

pub const Rect = struct {
    x: f64,
    y: f64,
    w: f64,
    h: f64,

    pub fn fromOriginSize(origin: Point, size: Size) Rect {
        return .{ .x = origin.x, .y = origin.y, .w = size.w, .h = size.h };
    }

    /// Top-left-origin containment (y grows downward). Right/bottom edges exclusive.
    pub fn contains(self: Rect, p: Point) bool {
        return p.x >= self.x and p.x < self.x + self.w and
            p.y >= self.y and p.y < self.y + self.h;
    }

    /// The area the two rects have in common. Disjoint rects give back a non-positive width or
    /// height rather than a null, which `contains` already reads as "nothing is inside" — so an
    /// empty intersection needs no special case at the call site.
    pub fn intersect(self: Rect, other: Rect) Rect {
        const x0 = @max(self.x, other.x);
        const y0 = @max(self.y, other.y);
        const x1 = @min(self.x + self.w, other.x + other.w);
        const y1 = @min(self.y + self.h, other.y + other.h);
        return .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
    }
};

/// A text-drawing request: the face to use, plus decorations that ride along with it. The
/// canvas resolves the trait flags to a concrete face; nothing above canvas.zig needs to know
/// what the family is called.
pub const Font = struct {
    size: f64,
    bold: bool = false,
    italic: bool = false,
    /// A decoration rather than a face trait, but it travels with the draw call and does not
    /// affect advance widths, so measuring with it set gives the same answer as without.
    underline: bool = false,
};

/// A single line of text whose styling changes partway along it: a sequence of runs that,
/// taken together, are shaped and measured as one line.
///
/// Describing a line this way rather than as a series of separate draw calls exists for one
/// reason: the shaper gets to see the whole line at once. Run widths do not simply add up —
/// the shaper kerns across a run boundary and rounds the line's advance once rather than once
/// per run — so measuring run by run and summing drifts from what actually gets drawn, and the
/// drift grows with the number of runs.
pub const AttributedText = struct {
    runs: []const Run,

    /// One stretch of uniformly styled text.
    pub const Run = struct {
        text: []const u8,
        font: Font,
        /// Carried so that one value can describe a draw as well as a measurement. It has no
        /// bearing on metrics.
        color: Color = Color.black,
    };

    /// Whether there is anything here to measure or draw. An empty run is not an error — a
    /// concealed delimiter leaves one behind — it simply contributes nothing.
    pub fn isEmpty(self: AttributedText) bool {
        for (self.runs) |run| {
            if (run.text.len > 0) return false;
        }
        return true;
    }
};

pub const Color = struct {
    r: f32,
    g: f32,
    b: f32,
    a: f32 = 1.0,

    pub fn rgb(r: f32, g: f32, b: f32) Color {
        return .{ .r = r, .g = g, .b = b, .a = 1.0 };
    }

    pub fn rgba(r: f32, g: f32, b: f32, a: f32) Color {
        return .{ .r = r, .g = g, .b = b, .a = a };
    }

    /// The same hue at a new opacity. Lets derived colors stay tied to a base color, so
    /// retheming means editing one constant.
    pub fn withAlpha(self: Color, a: f32) Color {
        return .{ .r = self.r, .g = self.g, .b = self.b, .a = a };
    }

    pub const black = Color{ .r = 0, .g = 0, .b = 0, .a = 1 };
    pub const white = Color{ .r = 1, .g = 1, .b = 1, .a = 1 };
};

const std = @import("std");
const expect = std.testing.expect;

test "Rect.contains top-left origin" {
    const r = Rect{ .x = 10, .y = 10, .w = 100, .h = 50 };
    try expect(r.contains(.{ .x = 10, .y = 10 })); // top-left inclusive
    try expect(r.contains(.{ .x = 59, .y = 59 }));
    try expect(!r.contains(.{ .x = 110, .y = 30 })); // right edge exclusive
    try expect(!r.contains(.{ .x = 50, .y = 60 })); // bottom edge exclusive
    try expect(!r.contains(.{ .x = 9, .y = 30 }));
}

test "Rect.intersect keeps the common area and empties when there is none" {
    const r = Rect{ .x = 10, .y = 10, .w = 100, .h = 50 };
    const overlapping = r.intersect(.{ .x = 60, .y = 0, .w = 100, .h = 100 });
    try expect(overlapping.x == 60 and overlapping.y == 10);
    try expect(overlapping.w == 50 and overlapping.h == 50);

    // Containment either way returns the smaller rect unchanged.
    const inner = Rect{ .x = 20, .y = 20, .w = 10, .h = 10 };
    try expect(std.meta.eql(r.intersect(inner), inner));
    try expect(std.meta.eql(inner.intersect(r), inner));

    // Disjoint: no point is inside the result, which is all callers ask of it.
    const apart = r.intersect(.{ .x = 500, .y = 500, .w = 10, .h = 10 });
    try expect(!apart.contains(.{ .x = 500, .y = 500 }));
    try expect(!apart.contains(.{ .x = 50, .y = 30 }));
}

test "Rect.fromOriginSize" {
    const r = Rect.fromOriginSize(.{ .x = 3, .y = 4 }, .{ .w = 5, .h = 6 });
    try expect(r.x == 3 and r.y == 4 and r.w == 5 and r.h == 6);
}

test "Color constructors" {
    const c = Color.rgb(0.1, 0.2, 0.3);
    try expect(c.a == 1.0);
    const t = Color.rgba(0.1, 0.2, 0.3, 0.5);
    try expect(t.a == 0.5);
}

test "AttributedText.isEmpty ignores runs that carry no text" {
    const f = Font{ .size = 12 };
    try expect((AttributedText{ .runs = &.{} }).isEmpty());
    // Every run concealed: there are runs, but nothing to draw.
    try expect((AttributedText{ .runs = &.{
        .{ .text = "", .font = f },
        .{ .text = "", .font = f },
    } }).isEmpty());
    // One run with text is enough, wherever it sits.
    try expect(!(AttributedText{ .runs = &.{
        .{ .text = "", .font = f },
        .{ .text = "x", .font = f },
    } }).isEmpty());
}

test "Color.withAlpha keeps the hue and replaces opacity" {
    const base = Color.rgb(0.1, 0.2, 0.3);
    const faded = base.withAlpha(0.25);
    try expect(faded.r == base.r and faded.g == base.g and faded.b == base.b);
    try expect(faded.a == 0.25);
    try expect(base.a == 1.0); // non-mutating
}
