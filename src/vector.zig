const std = @import("std");
const config = @import("config");

const vec_sz = config.vec_sz;
// const vec_type = config.vec_type;
const vec_type = f32;
const Vector = @Vector(vec_sz, vec_type);

pub const DB = struct {
    sz: usize,
    vectors: []std.meta.Vector,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) *Self {
        return &Self{ .sz = 0, .vectors = .{}, .allocator = allocator };
    }
    pub fn save(self: Self) void {
        _ = self;
        return;
    }
    pub fn load(self: Self) *Self {
        _ = self;
        return &Self{ .sz = 0, .vectors = .{} };
    }
};

pub fn dot(a: Vector, b: Vector) vec_type {
    return @reduce(.Add, a * b);
}

pub fn magnitude(a: Vector) vec_type {
    return @sqrt(@reduce(.Add, a * a));
}

const zero_vec: Vector = @splat(0);
fn is_zero(a: Vector) bool {
    return @reduce(.And, a == zero_vec);
}

pub fn cosine_similarity(a: Vector, b: Vector) vec_type {
    if (is_zero(a) or is_zero(b)) return 0;
    return dot(a, b) / (magnitude(a) * magnitude(b));
}

const expect = std.testing.expect;
test "cosine orthogonal" {
    try expect(vec_type == f32);
    try expect(vec_sz == 3);

    const a = Vector{ 1, 0, 0 };
    const b = Vector{ 0, 1, 0 };
    const c = Vector{ 0, 0, 1 };

    try expect(cosine_similarity(a, b) == 0);
    try expect(cosine_similarity(a, c) == 0);
    try expect(cosine_similarity(b, c) == 0);
}

test "cosine equal" {
    const a = Vector{ 1, 0, 0 };

    try expect(cosine_similarity(a, a) == 1);
}

test "cosine reverse" {
    const a = Vector{ 1, 0, 0 };
    const b = Vector{ -1, 0, 0 };

    try expect(cosine_similarity(a, b) == -1);
}

test "cosine 45-degree" {
    const a = Vector{ 1, 0, 0 };
    const b = Vector{ 1, 1, 0 };

    const output = cosine_similarity(a, b);
    try expect(output == 0.70710677);
}

test "cosine similar" {
    const a = Vector{ 1, 2, 3 };
    const b = Vector{ 1, 1, 1 };

    const output = cosine_similarity(a, b);
    try expect(output == 0.9258201);
}

test "cosine zero-vec" {
    const a = Vector{ 0, 0, 0 };
    const b = Vector{ 1, 0, 0 };

    const output = cosine_similarity(a, b);
    try expect(output == 0);
}
