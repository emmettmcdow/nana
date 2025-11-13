pub const Error = error{MultipleRemove};

const latest_format_version = 1;
const v1_meta: StorageMetadata = .{
    .fmt_v = latest_format_version,
    .vec_sz = vec_sz,
    .vec_type = BinaryTypeRepresentation.to_binary(vec_type),
    .idx_type = BinaryTypeRepresentation.to_binary(u8),
    .vec_n = 0,
};

const NULL_VEC_ID: VectorID = std.math.maxInt(VectorID);

// **************************************************************************************** Helpers
// Endianness doesn't matter since we only check whether the value is 0 or not... for now
pub inline fn writeSlice(
    w: *FileWriter,
    slice: []u8,
) !void {
    for (slice) |byte| {
        try w.writeByte(byte);
    }
}

pub inline fn readSlice(
    r: *FileReader,
    buf: []u8,
) !void {
    for (0..buf.len) |i| {
        buf[i] = try r.readByte();
    }
}

pub inline fn end_i(s: []u8) usize {
    for (1..s.len + 1) |rev_i| {
        const i = s.len - rev_i;
        if (s[i] != 0) return i + 1;
    }
    return 0;
}

pub inline fn readVec(v: *Vector, r: *FileReader, endian: std.builtin.Endian) !void {
    for (0..v1_meta.vec_sz) |j| {
        const elem = r.readInt(v1_meta.vec_type.stored_as(), endian) catch |err| {
            std.log.err("Error: {}\n", .{err});
            return err;
        };
        const converted = @as(v1_meta.vec_type.to_type(), @bitCast(elem));
        v[j] = converted;
    }
}

pub inline fn writeVec(v: Vector, w: *FileWriter, endian: std.builtin.Endian) !void {
    const array: [vec_sz]vec_type = v;
    for (array) |elem| {
        try w.writeInt(
            v1_meta.vec_type.stored_as(),
            @bitCast(elem),
            endian,
        );
    }
}

// **************************************************************************************** Storage
pub const BinaryTypeRepresentation = enum(u8) {
    float32,
    uint8,

    pub inline fn to_type(self: BinaryTypeRepresentation) type {
        switch (self) {
            .float32 => return f32,
            .uint8 => return u8,
        }
    }

    pub inline fn to_binary(T: type) BinaryTypeRepresentation {
        switch (T) {
            f32 => return .float32,
            u8 => return .uint8,
            else => undefined,
        }
    }

    pub inline fn stored_as(self: BinaryTypeRepresentation) type {
        switch (self) {
            .float32 => return u32,
            .uint8 => return u8,
        }
    }
};

/// This is the metadata we need to determine what the binary format of the rest of the file looks
/// like. Nothing dynamic should be in here. Only fixed-size data.
pub const StorageMetadata = packed struct {
    /// Big if true
    endian: bool = true,
    /// This defines what version of the storage metadata to use
    fmt_v: u8,
    /// Dimensionality
    vec_sz: usize,
    /// Type of the elements in the vectors. Binary representation of a Zig type
    vec_type: BinaryTypeRepresentation,
    /// Type of the elements in the index. Binary representation of a Zig type
    idx_type: BinaryTypeRepresentation,
    /// Number of vectors
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
//  ___Index____ ___Vecs____
// |___________||__________|
// |1  |0  |1  |v1 |nil|v2 |
// |___|___|___|___|___|___|
//
//  Each index corresponds to a single index within the vector array.
//  The integer will be non-zero if that vector index is occupied, zero otherwise.
pub const Storage = struct {
    meta: StorageMetadata = v1_meta,
    index: []u8,
    vectors: []Vector,
    capacity: usize,
    allocator: std.mem.Allocator,
    dir: std.fs.Dir,

    const Opts = struct {
        sz: usize = 32,
    };

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, dir: std.fs.Dir, opts: Opts) !Self {
        const vecs = try allocator.alloc(Vector, opts.sz);
        @memset(vecs, std.mem.zeroes(Vector));
        const idx = try allocator.alloc(u8, opts.sz);
        @memset(idx, 0);
        return Storage{
            .vectors = vecs,
            .index = idx,
            .capacity = opts.sz,
            .allocator = allocator,
            .dir = dir,
        };
    }
    pub fn deinit(self: *Self) void {
        self.allocator.free(self.vectors);
        self.allocator.free(self.index);
    }

    pub fn get(self: Self, id: VectorID) Vector {
        assert(id != self.nullVec());
        return self.vectors[id];
    }

    pub fn put(self: *Self, v: Vector) !VectorID {
        const new_id = self.nextIndex();
        assert(self.index[new_id] == 0);
        self.meta.vec_n += 1;

        try self.grow();

        self.putAt(v, new_id);
        return new_id;
    }

    fn putAt(self: *Self, v: Vector, id: usize) void {
        assert(id != self.nullVec());
        self.vectors[id] = v;
        self.index[id] = 1;
    }

    pub fn rm(self: *Self, id: VectorID) !void {
        if (self.index[id] == 0) return Error.MultipleRemove;
        assert(id != self.nullVec());
        assert(self.meta.vec_n > 0);
        self.index[id] = 0;
        self.meta.vec_n -= 1;
    }

    pub fn search(self: Self, query: Vector, buf: []VectorID) !usize {
        const zone = tracy.beginZone(@src(), .{ .name = "vec_storage.zig:search" });
        defer zone.end();
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

        for (self.index, 0..) |valid, id| {
            if (valid == 0) continue;
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
        try writeSlice(&writer, self.index);
        for (0..end_i(self.index)) |i| {
            try writeVec(self.vectors[i], &writer, self.meta.endianness());
        }

        return;
    }

    pub fn load(self: *Self, path: []const u8) !void {
        // We take the naiive approach to reading for now. We only have one version of the file,
        // but we have future proofed ourselves to be able to use multiple. We don't yet need
        // multiple so we can just read the file in a "dumb" way.
        //
        // Dumb = not reading metadata before reading the whole file.
        var f = self.dir.openFile(path, .{ .mode = .read_only }) catch |err| switch (err) {
            // Don't do anything if there is no file to load: file is created on save
            std.fs.File.OpenError.FileNotFound => return,
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
        assert(self.meta.idx_type == v1_meta.idx_type);

        try self.grow();
        try readSlice(&reader, self.index);

        for (0..end_i(self.index)) |i| {
            var v: Vector = undefined;
            if (self.index[i] == 0) continue;
            try readVec(&v, &reader, endian);
            self.putAt(v, i);
        }
    }

    /// Generates a new ID for an existing Vector
    pub fn copy(self: *Self, id: VectorID) !VectorID {
        const new_id = self.nextIndex();
        assert(self.index[new_id] == 0);
        self.meta.vec_n += 1;

        try self.grow();

        self.putAt(self.get(id), new_id);
        return new_id;
    }

    pub fn nullVec(_: Self) VectorID {
        return NULL_VEC_ID;
    }

    /// Locates the next empty index for a vector. Prioritizes filling holes in the arrays.
    fn nextIndex(self: *Self) usize {
        for (self.index, 0..) |v, i| {
            if (v == 0) {
                assert(self.nullVec() != i);
                return i;
            }
        }
        unreachable;
    }

    /// Grows the backing data structure to fit the `self.meta.vec_n`.
    fn grow(self: *Self) !void {
        var sz = self.capacity;
        while (self.meta.vec_n >= sz) {
            sz *= 2;
        }
        if (sz == self.capacity) return;

        self.index = try self.allocator.realloc(self.index, sz);
        @memset(self.index[self.capacity..], 0);
        self.vectors = try self.allocator.realloc(self.vectors, sz);
        @memset(self.vectors[self.capacity..], std.mem.zeroes(Vector));
        self.capacity = sz;
    }
};

test "test put / get" {
    var tmpD = tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();
    var inst = try Storage.init(arena.allocator(), tmpD.dir, .{});
    defer inst.deinit();

    try expect(inst.meta.vec_n == 0);
    const vec1 = Vector{ 1, 1, 1 };
    const id = try inst.put(vec1);
    try expect(inst.meta.vec_n == 1);
    const vec2 = inst.get(id);

    try expect(@reduce(.And, vec1 == vec2));
}

test "re Storage" {
    var tmpD = tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();
    var inst = try Storage.init(arena.allocator(), tmpD.dir, .{});
    defer inst.deinit();

    try expect(inst.meta.vec_n == 0);
    const vec1 = Vector{ 1, 1, 1 };
    const id = try inst.put(vec1);
    try expect(inst.meta.vec_n == 1);
    try inst.save("temp.db");
    inst.deinit();

    var inst2 = try Storage.init(arena.allocator(), tmpD.dir, .{});
    defer inst2.deinit();
    try inst2.load("temp.db");
    try expect(inst2.meta.vec_n == 1);
    const vec2 = inst2.get(id);
    try expect(@reduce(.And, vec1 == vec2));
}

test "re Storage multiple" {
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

    var inst = try Storage.init(arena.allocator(), tmpD.dir, .{});
    try expect(inst.meta.vec_n == 0);
    for (vecs) |vec| {
        _ = try inst.put(vec);
    }
    try expect(inst.meta.vec_n == vecs.len);
    try inst.save("temp.db");
    inst.deinit();

    var inst2 = try Storage.init(arena.allocator(), tmpD.dir, .{});
    defer inst2.deinit();
    try inst2.load("temp.db");
    try expect(inst2.meta.vec_n == vecs.len);
    for (0..vecs.len - 1) |i| {
        try expect(@reduce(.And, vecs[i] == inst2.get(i)));
    }
}

test "re Storage index" {
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
    var ids: [4]VectorID = undefined;

    var inst = try Storage.init(arena.allocator(), tmpD.dir, .{});
    try expect(inst.meta.vec_n == 0);
    for (vecs, 0..) |vec, i| {
        ids[i] = try inst.put(vec);
    }
    for (inst.index[0..4]) |val| {
        try expect(val != 0);
    }
    try inst.rm(ids[0]);
    try inst.rm(ids[2]);

    try expect(inst.index[0] == 0);
    try expect(inst.index[1] == 1);
    try expect(inst.index[2] == 0);
    try expect(inst.index[3] == 1);
    try expect(inst.meta.vec_n == vecs.len - 2);
    try inst.save("temp.db");
    inst.deinit();

    var inst2 = try Storage.init(arena.allocator(), tmpD.dir, .{});
    defer inst2.deinit();
    try inst2.load("temp.db");
    try expect(inst2.meta.vec_n == vecs.len - 2);
    try expect(inst2.index[0] == 0);
    try expect(inst2.index[1] == 1);
    try expect(inst2.index[2] == 0);
    try expect(inst2.index[3] == 1);
}

test "test put resize" {
    var tmpD = tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();

    var inst = try Storage.init(arena.allocator(), tmpD.dir, .{});
    defer inst.deinit();
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

    var inst = try Storage.init(arena.allocator(), tmpD.dir, .{});
    defer inst.deinit();
    try inst.load("vecs.db");
}

test "grow" {
    var tmpD = tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();

    var inst = try Storage.init(arena.allocator(), tmpD.dir, .{ .sz = 1 });
    defer inst.deinit();
    try inst.grow();
    try expect(inst.capacity == 1);
    try expect(inst.vectors.len == 1);
    try expect(inst.index.len == 1);
    _ = try inst.put(std.mem.zeroes(Vector));
    try expect(inst.capacity == 2);
    try expect(inst.vectors.len == 2);
    try expect(inst.index.len == 2);
    _ = try inst.put(std.mem.zeroes(Vector));
    try expect(inst.capacity == 4);
    try expect(inst.vectors.len == 4);
    try expect(inst.index.len == 4);
    _ = try inst.put(std.mem.zeroes(Vector));
    try expect(inst.capacity == 4);
    try expect(inst.vectors.len == 4);
    try expect(inst.index.len == 4);
    try expect(inst.index[0] == 1);
    try expect(inst.index[1] == 1);
    try expect(inst.index[2] == 1);
    try expect(inst.index[3] == 0);
}

test "copy" {
    var tmpD = tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();
    var inst = try Storage.init(arena.allocator(), tmpD.dir, .{ .sz = 2 });

    const vec1 = Vector{ 1, 1, 1 };
    const old_id = try inst.put(vec1);
    const new_id = try inst.copy(old_id);
    try expect(old_id != new_id);
    const vec2 = inst.get(new_id);
    try expect(@reduce(.And, vec1 == vec2));
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

const native_endian = std.builtin.cpu.arch.endian();

const std = @import("std");
const assert = std.debug.assert;
const FileWriter = std.fs.File.Writer;
const FileReader = std.fs.File.Reader;
const tmpDir = std.testing.tmpDir;
const testing_allocator = std.testing.allocator;
const expect = std.testing.expect;

const config = @import("config");
const tracy = @import("tracy");

const types = @import("types.zig");
const Vector = types.Vector;
const VectorID = types.VectorID;
const vec_sz = types.vec_sz;
const vec_type = types.vec_type;
