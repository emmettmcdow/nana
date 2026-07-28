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
};

/// A font request. The canvas resolves the trait flags to a concrete face; nothing above
/// canvas.zig needs to know what the family is called.
pub const Font = struct {
    size: f64,
    bold: bool = false,
    italic: bool = false,
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

test "Color.withAlpha keeps the hue and replaces opacity" {
    const base = Color.rgb(0.1, 0.2, 0.3);
    const faded = base.withAlpha(0.25);
    try expect(faded.r == base.r and faded.g == base.g and faded.b == base.b);
    try expect(faded.a == 0.25);
    try expect(base.a == 1.0); // non-mutating
}
