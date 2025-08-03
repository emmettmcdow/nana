// ********************************************************************************************* DB
pub const BinaryTypeRepresentation = enum(u8) {
    float32,

    pub inline fn to_type(self: BinaryTypeRepresentation) type {
        switch (self) {
            .float32 => return f32,
        }
    }

    pub inline fn to_binary(T: type) BinaryTypeRepresentation {
        switch (T) {
            f32 => return .float32,
            else => undefined,
        }
    }

    pub inline fn stored_as(self: BinaryTypeRepresentation) type {
        switch (self) {
            .float32 => return u32,
        }
    }
};

pub const StorageMetadata = packed struct {
    // Big if true
    endian: bool = true,
    // This defines what version of the storage metadata to use
    fmt_v: u8,
    // Dimensionality
    vec_sz: usize,
    // Binary representation of a Zig type
    vec_type: BinaryTypeRepresentation,
    // Number of vectors
    vec_n: usize,

    const Self = @This();

    pub fn endianness(self: Self) std.builtin.Endian {
        if (self.endian) {
            return .big;
        } else {
            return .little;
        }
    }
};

const assert = std.debug.assert;
pub const DB = struct {
    meta: StorageMetadata = v1_meta,
    vectors: []Vector,
    capacity: usize,
    allocator: std.mem.Allocator,
    dir: std.fs.Dir,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, dir: std.fs.Dir) !Self {
        return DB{
            .vectors = try allocator.alloc(Vector, 32),
            .capacity = 32,
            .allocator = allocator,
            .dir = dir,
        };
    }
    pub fn deinit(self: *Self) void {
        self.allocator.free(self.vectors);
    }

    pub fn get(self: Self, id: VectorID) Vector {
        return self.vectors[id - 1];
    }

    pub fn put(self: *Self, v: Vector) !VectorID {
        if (self.meta.vec_n + 1 == self.capacity) {
            self.vectors = try self.allocator.realloc(self.vectors, self.capacity * 2);
            self.capacity *= 2;
        }
        self.vectors[self.meta.vec_n] = v;
        self.meta.vec_n += 1;
        return self.meta.vec_n;
    }

    pub fn search(self: Self, query: Vector, buf: []VectorID) !usize {
        // This scores best on the benchmark but vibes-wise it's way off
        const THRESHOLD = 0.35;
        // const THRESHOLD = 0.7;

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();

        const entry = struct {
            id: VectorID,
            sim: vec_type,

            const InnerSelf = @This();

            pub fn order(_: void, a: InnerSelf, b: InnerSelf) std.math.Order {
                return std.math.order(b.sim, a.sim);
            }
        };

        var pq = std.PriorityQueue(entry, void, entry.order).init(arena.allocator(), undefined);

        for (1..self.meta.vec_n + 1) |id| {
            const similar = cosine_similarity(self.get(id), query);
            debugSearchSimilar(id, similar);
            if (similar > THRESHOLD) {
                try pq.add(.{ .id = id, .sim = similar });
            }
        }

        var i: usize = 0;
        while (pq.removeOrNull()) |pair| : (i += 1) {
            if (i >= buf.len) break;
            buf[i] = pair.id;
        }

        return i;
    }

    fn debugSearchSimilar(vecID: VectorID, similar: vec_type) void {
        if (!config.debug) return;
        std.debug.print("    ID({d}) similarity: {d}\n", .{ vecID, similar });
    }

    pub fn save(self: Self, path: []const u8) !void {
        var f = self.dir.openFile(path, .{ .mode = .write_only }) catch |err| switch (err) {
            std.fs.File.OpenError.FileNotFound => try self.dir.createFile(path, .{}),
            else => return err,
        };
        defer f.close();
        var writer = f.writer();
        try writer.writeStructEndian(self.meta, self.meta.endianness());
        for (self.vectors, 0..) |vec, i| {
            if (i >= self.meta.vec_n) break;
            const array: [vec_sz]vec_type = vec;
            for (array) |elem| {
                try writer.writeInt(
                    v1_meta.vec_type.stored_as(),
                    @bitCast(elem),
                    self.meta.endianness(),
                );
            }
        }

        return;
    }

    pub fn load(self: *Self, path: []const u8) !Self {
        // We take the naiive approach to reading for now. We only have one version of the file,
        // but we have future proofed ourselves to be able to use multiple. We don't yet need
        // multiple so we can just read the file in a "dumb" way.
        //
        // Dumb = not reading metadata before reading the whole file.
        var f = self.dir.openFile(path, .{ .mode = .read_only }) catch |err| switch (err) {
            // Don't do anything if there is no file to load: file is created on save
            std.fs.File.OpenError.FileNotFound => return self.*,
            else => return err,
        };
        defer f.close();
        var reader = f.reader();

        const endian = self.meta.endianness();
        self.meta = try reader.readStructEndian(StorageMetadata, endian);
        // This is a hack to deal with my poor grasp of comptime.
        // Maybe we can come in and create multiple load body functions. Firstly you check the
        // version, and then you call out to one of the many load functions. Where the meta is
        // comptime known.
        assert(self.meta.fmt_v == v1_meta.fmt_v);
        assert(self.meta.vec_sz == v1_meta.vec_sz);
        assert(self.meta.vec_type == v1_meta.vec_type);

        // Reset the number of vectors - put increments the size
        const vec_n = self.meta.vec_n;
        self.meta.vec_n = 0;
        for (0..vec_n) |_| {
            var v: Vector = undefined;
            for (0..v1_meta.vec_sz) |j| {
                const elem = try reader.readInt(v1_meta.vec_type.stored_as(), endian);
                const converted = @as(v1_meta.vec_type.to_type(), @bitCast(elem));
                v[j] = converted;
            }
            // Improvement: we know the sz of the vectors. Alloc once instead of realloc with put.
            _ = try self.put(v);
        }

        return self.*;
    }
};

const tmpDir = std.testing.tmpDir;
const testing_allocator = std.testing.allocator;
const expect = std.testing.expect;

test "test put / get" {
    var tmpD = tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();

    var inst = try DB.init(arena.allocator(), tmpD.dir);
    try expect(inst.meta.vec_n == 0);
    const vec1 = Vector{ 1, 1, 1 };
    const id = try inst.put(vec1);
    try expect(inst.meta.vec_n == 1);
    const vec2 = inst.get(id);

    try expect(@reduce(.And, vec1 == vec2));
}

test "re-init DB" {
    var tmpD = tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();

    var inst = try DB.init(arena.allocator(), tmpD.dir);
    try expect(inst.meta.vec_n == 0);
    const vec1 = Vector{ 1, 1, 1 };
    const id = try inst.put(vec1);
    try expect(inst.meta.vec_n == 1);
    try inst.save("temp.db");
    inst.deinit();

    var inst2 = try DB.init(arena.allocator(), tmpD.dir);
    inst2 = try inst2.load("temp.db");
    try expect(inst2.meta.vec_n == 1);
    const vec2 = inst2.get(id);
    try expect(@reduce(.And, vec1 == vec2));
    inst2.deinit();
}

test "re-init DB multiple" {
    var tmpD = tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();

    const vecs: [4]Vector = .{
        .{ 1, 1, 1 },
        .{ 1, 2, 3 },
        .{ 0.5, 0.5, 0.5 },
        .{ -0.5, -0.5, -0.5 },
    };

    var inst = try DB.init(arena.allocator(), tmpD.dir);
    try expect(inst.meta.vec_n == 0);
    for (vecs) |vec| {
        _ = try inst.put(vec);
    }
    try expect(inst.meta.vec_n == vecs.len);
    try inst.save("temp.db");
    inst.deinit();

    var inst2 = try DB.init(arena.allocator(), tmpD.dir);
    inst2 = try inst2.load("temp.db");
    try expect(inst2.meta.vec_n == vecs.len);
    for (1..vecs.len) |i| {
        const vec2 = inst2.get(i);
        try expect(@reduce(.And, vecs[i - 1] == vec2));
    }
    inst2.deinit();
}

test "test put resize" {
    var tmpD = tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();

    var inst = try DB.init(arena.allocator(), tmpD.dir);
    try expect(inst.meta.vec_n == 0);
    try expect(inst.capacity == 32);

    const vec1 = Vector{ 1, 1, 1 };
    for (0..31) |_| {
        _ = try inst.put(vec1);
    }
    try expect(inst.meta.vec_n == 31);
    try expect(inst.capacity == 32);
    _ = try inst.put(vec1);
    try expect(inst.meta.vec_n == 32);
    try expect(inst.capacity == 64);
}

test "no failure on loading non-existent db" {
    var tmpD = tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();

    var inst = try DB.init(arena.allocator(), tmpD.dir);
    _ = try inst.load("vecs.db");
    inst.deinit();
}

// **************************************************************************************** Vectors
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

fn cosine_similarity(a: Vector, b: Vector) vec_type {
    if (is_zero(a) or is_zero(b)) return 0;
    return dot(a, b) / (magnitude(a) * magnitude(b));
}

fn similarity(a: Vector, b: Vector) vec_type {
    return cosine_similarity(a, b);
}

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

const std = @import("std");

const config = @import("config");
const types = @import("types.zig");
const Vector = types.Vector;
const VectorID = types.VectorID;
const vec_sz = types.vec_sz;
const vec_type = types.vec_type;

const latest_format_version = 1;
const v1_meta: StorageMetadata = .{
    .fmt_v = latest_format_version,
    .vec_sz = vec_sz,
    .vec_type = BinaryTypeRepresentation.to_binary(vec_type),
    .vec_n = 0,
};
