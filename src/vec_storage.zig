pub const Error = error{ MultipleRemove, OverlappingVectors };

const LATEST_META_FORMAT_VERSION = 2;

const DEFAULT_DB_IDX_TYPE = BinaryTypeRepresentation.to_binary(u8);

const NULL_VEC_ID: VectorID = std.math.maxInt(VectorID);

pub const IndexEntry = packed struct {
    occupied: bool = false,
    dirty: bool = false,
    _padding: u6 = 0,

    pub fn toByte(self: IndexEntry) u8 {
        return @bitCast(self);
    }

    pub fn fromByte(byte: u8) IndexEntry {
        return @bitCast(byte);
    }
};

// **************************************************************************************** Helpers
// Endianness doesn't matter since we only check whether the value is 0 or not... for now
pub inline fn writeSlice(
    w: *FileWriter,
    slice: []u8,
) !void {
    const zone = tracy.beginZone(@src(), .{ .name = "vec_storage.zig:writeSlice" });
    defer zone.end();
    return w.writeAll(slice);
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

pub inline fn readVec(N: usize, T: type, v: *@Vector(N, T), r: *FileReader, endian: std.builtin.Endian) !void {
    for (0..N) |j| {
        const elem = r.readInt(BinaryTypeRepresentation.to_binary(T).stored_as(), endian) catch |err| {
            std.log.err("Error: {}\n", .{err});
            return err;
        };
        const converted = @as(T, @bitCast(elem));
        v[j] = converted;
    }
}

pub inline fn writeVec(N: usize, T: type, w: *FileWriter, v: @Vector(N, T), endian: std.builtin.Endian) !void {
    const zone = tracy.beginZone(@src(), .{ .name = "vec_storage.zig:writeVec" });
    defer zone.end();

    const native_endian = @import("builtin").cpu.arch.endian();
    var buf: [N]u32 = undefined;
    for (0..N) |i| {
        const as_int: u32 = @bitCast(v[i]);
        buf[i] = if (endian != native_endian)
            @byteSwap(as_int)
        else
            as_int;
    }

    return w.writeAll(std.mem.asBytes(&buf));
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

//  Data-oriented layout (Structure of Arrays):
//  ___Index____ ___Vecs____ ___NoteIDs___ ___StartIs___ ___EndIs___
// |___________||__________||____________||____________||___________|
// |1  |0  |1  ||v1 | X |v2 ||n1 | X |n2  ||s1 | X |s2  ||e1 | X |e2|
// |___|___|___||___|___|___||___|___|____||___|___|____||___|___|__|

pub fn Storage(vec_sz: usize, vec_type: type) type {
    const Vector = @Vector(vec_sz, vec_type);

    return struct {
        pub const VectorRow = struct {
            note_id: NoteID,
            start_i: usize,
            end_i: usize,
            vec: Vector,
        };

        pub const SearchEntry = struct {
            row: VectorRow,
            similarity: f32,
        };

        meta: StorageMetadata = .{
            .fmt_v = LATEST_META_FORMAT_VERSION,
            .vec_sz = vec_sz,
            .vec_type = BinaryTypeRepresentation.to_binary(vec_type),
            .idx_type = BinaryTypeRepresentation.to_binary(u8),
            .vec_n = 0,
        },
        index: []IndexEntry,
        vectors: []Vector,
        note_ids: []NoteID,
        start_is: []usize,
        end_is: []usize,
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
            const idx = try allocator.alloc(IndexEntry, opts.sz);
            @memset(idx, .{});
            const note_ids = try allocator.alloc(NoteID, opts.sz);
            @memset(note_ids, 0);
            const start_is = try allocator.alloc(usize, opts.sz);
            @memset(start_is, 0);
            const end_is = try allocator.alloc(usize, opts.sz);
            @memset(end_is, 0);
            return Self{
                .vectors = vecs,
                .index = idx,
                .note_ids = note_ids,
                .start_is = start_is,
                .end_is = end_is,
                .capacity = opts.sz,
                .allocator = allocator,
                .dir = dir,
            };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.vectors);
            self.allocator.free(self.index);
            self.allocator.free(self.note_ids);
            self.allocator.free(self.start_is);
            self.allocator.free(self.end_is);
        }

        pub fn get(self: Self, id: VectorID) VectorRow {
            assert(id != self.nullVec());
            return .{
                .note_id = self.note_ids[id],
                .start_i = self.start_is[id],
                .end_i = self.end_is[id],
                .vec = self.vectors[id],
            };
        }

        pub fn put(self: *Self, row: VectorRow) !VectorID {
            const new_id = self.nextIndex();
            assert(!self.isOccupied(new_id));
            self.meta.vec_n += 1;

            try self.grow();

            self.putAt(row, new_id);
            return new_id;
        }

        fn putAt(self: *Self, row: VectorRow, id: usize) void {
            assert(id != self.nullVec());
            self.vectors[id] = row.vec;
            self.note_ids[id] = row.note_id;
            self.start_is[id] = row.start_i;
            self.end_is[id] = row.end_i;
            self.setOccupied(id, true);
            self.setDirty(id, true);
        }

        pub fn rm(self: *Self, id: VectorID) Error!void {
            if (id == self.nullVec()) return;
            if (!self.isOccupied(id)) return Error.MultipleRemove;
            assert(self.meta.vec_n > 0);
            self.setOccupied(id, false);
            self.setDirty(id, false);
            self.meta.vec_n -= 1;
        }

        pub fn search(self: Self, query: Vector, buf: []SearchEntry, threshold: f32) !usize {
            const zone = tracy.beginZone(@src(), .{ .name = "vec_storage.zig:search" });
            defer zone.end();

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

            for (self.index, 0..) |idx_entry, id| {
                if (!idx_entry.occupied) continue;
                const similar = cosine_similarity(vec_sz, vec_type, self.vectors[id], query);
                debugSearchSimilar(id, similar);
                if (similar > threshold) {
                    try pq.add(.{ .id = id, .sim = similar });
                }
            }

            var i: usize = 0;
            while (pq.removeOrNull()) |pair| : (i += 1) {
                if (i >= buf.len) break;
                buf[i] = .{ .row = self.get(pair.id), .similarity = pair.sim };
            }

            return i;
        }

        fn debugSearchSimilar(vecID: VectorID, similar: vec_type) void {
            if (!config.debug) return;
            std.debug.print("    ID({d}) similarity: {d}\n", .{ vecID, similar });
        }

        pub fn save(self: *Self, path: []const u8) !void {
            const zone = tracy.beginZone(@src(), .{ .name = "vec_storage.zig:save" });
            defer zone.end();

            var f = self.dir.openFile(path, .{ .mode = .write_only }) catch |err| switch (err) {
                std.fs.File.OpenError.FileNotFound => try self.dir.createFile(path, .{}),
                else => return err,
            };
            defer f.close();

            var writer = f.writer();
            const endian = self.meta.endianness();
            try writer.writeStructEndian(self.meta, endian);

            var index_copy = try self.allocator.alloc(u8, self.index.len);
            defer self.allocator.free(index_copy);
            for (self.index, 0..) |idx_entry, i| {
                var clean_entry = idx_entry;
                clean_entry.dirty = false;
                index_copy[i] = clean_entry.toByte();
            }
            try writeSlice(&writer, index_copy);

            const len = end_i(index_copy);
            const vec_width: i64 = @intCast(vec_sz * @sizeOf(vec_type));

            for (0..len) |i| {
                if (self.isDirty(i)) {
                    try writeVec(vec_sz, vec_type, &writer, self.vectors[i], endian);
                } else {
                    try f.seekBy(vec_width);
                }
            }

            try writer.writeAll(std.mem.sliceAsBytes(self.note_ids[0..len]));
            try writer.writeAll(std.mem.sliceAsBytes(self.start_is[0..len]));
            try writer.writeAll(std.mem.sliceAsBytes(self.end_is[0..len]));

            for (0..len) |i| {
                self.setDirty(i, false);
            }

            return;
        }

        pub fn load(self: *Self, path: []const u8) !void {
            var f = self.dir.openFile(path, .{ .mode = .read_only }) catch |err| switch (err) {
                std.fs.File.OpenError.FileNotFound => return,
                else => return err,
            };
            defer f.close();
            var reader = f.reader();

            const endian = self.meta.endianness();
            self.meta = try reader.readStructEndian(StorageMetadata, endian);
            assert(self.meta.fmt_v == LATEST_META_FORMAT_VERSION);
            assert(self.meta.vec_sz == vec_sz);
            assert(self.meta.vec_type == BinaryTypeRepresentation.to_binary(vec_type));
            assert(self.meta.idx_type == DEFAULT_DB_IDX_TYPE);

            try self.grow();
            const index_bytes = try self.allocator.alloc(u8, self.index.len);
            defer self.allocator.free(index_bytes);
            try readSlice(&reader, index_bytes);
            for (index_bytes, 0..) |byte, i| {
                self.index[i] = IndexEntry.fromByte(byte);
            }

            const len = end_i(index_bytes);

            for (0..len) |i| {
                if (self.isOccupied(i)) {
                    try readVec(vec_sz, vec_type, &self.vectors[i], &reader, endian);
                } else {
                    try f.seekBy(@intCast(vec_sz * @sizeOf(vec_type)));
                }
            }

            const bytes_read = try reader.readAll(std.mem.sliceAsBytes(self.note_ids[0..len]));
            assert(bytes_read == len * @sizeOf(NoteID));
            const bytes_read2 = try reader.readAll(std.mem.sliceAsBytes(self.start_is[0..len]));
            assert(bytes_read2 == len * @sizeOf(usize));
            const bytes_read3 = try reader.readAll(std.mem.sliceAsBytes(self.end_is[0..len]));
            assert(bytes_read3 == len * @sizeOf(usize));
        }

        /// Generates a new ID for an existing VectorRow
        pub fn copy(self: *Self, id: VectorID) !VectorID {
            if (id == self.nullVec()) return self.nullVec();
            const new_id = self.nextIndex();
            assert(!self.isOccupied(new_id));
            self.meta.vec_n += 1;

            try self.grow();

            const row = self.get(id);
            self.putAt(row, new_id);
            return new_id;
        }

        pub fn nullVec(_: Self) VectorID {
            return NULL_VEC_ID;
        }

        /// Locates the next empty index for a vector. Prioritizes filling holes in the arrays.
        fn nextIndex(self: *Self) usize {
            for (0..self.index.len) |i| {
                if (!self.isOccupied(i)) {
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
            @memset(self.index[self.capacity..], .{});
            self.vectors = try self.allocator.realloc(self.vectors, sz);
            @memset(self.vectors[self.capacity..], std.mem.zeroes(Vector));
            self.note_ids = try self.allocator.realloc(self.note_ids, sz);
            @memset(self.note_ids[self.capacity..], 0);
            self.start_is = try self.allocator.realloc(self.start_is, sz);
            @memset(self.start_is[self.capacity..], 0);
            self.end_is = try self.allocator.realloc(self.end_is, sz);
            @memset(self.end_is[self.capacity..], 0);
            self.capacity = sz;
        }

        pub fn isDirty(self: Self, i: usize) bool {
            return self.index[i].dirty;
        }
        pub fn setDirty(self: *Self, i: usize, set: bool) void {
            self.index[i].dirty = set;
        }

        pub fn isOccupied(self: Self, i: usize) bool {
            return self.index[i].occupied;
        }
        pub fn setOccupied(self: *Self, i: usize, set: bool) void {
            self.index[i].occupied = set;
        }

        pub const VecForNoteEntry = struct {
            id: VectorID,
            row: VectorRow,
        };

        /// Returns all vectors for a given note_id, sorted by start_i
        pub fn vecsForNote(self: Self, allocator: std.mem.Allocator, note_id: NoteID) ![]VecForNoteEntry {
            var results = std.ArrayList(VecForNoteEntry).init(allocator);
            errdefer results.deinit();

            for (self.index, 0..) |idx_entry, i| {
                if (!idx_entry.occupied) continue;
                if (self.note_ids[i] == note_id) {
                    try results.append(.{
                        .id = i,
                        .row = self.get(i),
                    });
                }
            }

            const items = try results.toOwnedSlice();
            std.sort.insertion(VecForNoteEntry, items, {}, struct {
                fn lessThan(_: void, a: VecForNoteEntry, b: VecForNoteEntry) bool {
                    return a.row.start_i < b.row.start_i;
                }
            }.lessThan);

            return items;
        }

        /// Removes all vectors for a given note_id
        pub fn rmByNoteId(self: *Self, note_id: NoteID) void {
            for (self.index, 0..) |idx_entry, i| {
                if (!idx_entry.occupied) continue;
                if (self.note_ids[i] == note_id) {
                    self.rm(i) catch |err| {
                        std.log.err("rmByNoteId: failed to remove vector at index {d} for note {d}: {}", .{ i, note_id, err });
                        @panic("rmByNoteId: unexpected error during removal");
                    };
                }
            }
        }

        /// Validates that per note, there are no overlapping indices in the vectors.
        pub fn validate(self: *Self) !void {
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();

            var note_ids_seen = std.AutoHashMap(NoteID, void).init(arena.allocator());
            for (self.index, 0..) |idx_entry, i| {
                if (!idx_entry.occupied) continue;
                try note_ids_seen.put(self.note_ids[i], {});
            }

            var it = note_ids_seen.keyIterator();
            while (it.next()) |note_id_ptr| {
                const entries = try self.vecsForNote(arena.allocator(), note_id_ptr.*);
                for (0..entries.len) |i| {
                    for (i + 1..entries.len) |j| {
                        const a = entries[i].row;
                        const b = entries[j].row;
                        if (a.start_i < b.end_i and b.start_i < a.end_i) {
                            return Error.OverlappingVectors;
                        }
                    }
                }
            }
        }
    };
}



const TestT = f32;
const TestN = 3;
const TestVecType = @Vector(TestN, TestT);
const TestStorage = Storage(TestN, TestT);
const TestVectorRow = TestStorage.VectorRow;

fn makeTestRow(vec: TestVecType, note_id: NoteID, start_i: usize, end_i_val: usize) TestVectorRow {
    return .{
        .note_id = note_id,
        .start_i = start_i,
        .end_i = end_i_val,
        .vec = vec,
    };
}

test "test put / get" {
    var tmpD = tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();
    var inst = try TestStorage.init(arena.allocator(), tmpD.dir, .{});
    defer inst.deinit();

    try expect(inst.meta.vec_n == 0);
    const row1 = makeTestRow(.{ 1, 1, 1 }, 42, 0, 10);
    const id = try inst.put(row1);
    try expect(inst.meta.vec_n == 1);
    const row2 = inst.get(id);

    try expect(@reduce(.And, row1.vec == row2.vec));
    try expect(row2.note_id == 42);
    try expect(row2.start_i == 0);
    try expect(row2.end_i == 10);
}

test "re Storage" {
    var tmpD = tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();
    var inst = try TestStorage.init(arena.allocator(), tmpD.dir, .{});
    defer inst.deinit();

    try expect(inst.meta.vec_n == 0);
    const row1 = makeTestRow(.{ 1, 1, 1 }, 100, 5, 15);
    const id = try inst.put(row1);
    try expect(inst.meta.vec_n == 1);
    try inst.save("temp.db");
    inst.deinit();

    var inst2 = try TestStorage.init(arena.allocator(), tmpD.dir, .{});
    defer inst2.deinit();
    try inst2.load("temp.db");
    try expect(inst2.meta.vec_n == 1);
    const row2 = inst2.get(id);
    try expect(@reduce(.And, row1.vec == row2.vec));
    try expect(row2.note_id == 100);
    try expect(row2.start_i == 5);
    try expect(row2.end_i == 15);
}

test "re Storage multiple" {
    var tmpD = tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();

    const rows: [4]TestVectorRow = .{
        makeTestRow(.{ 1, 1, 1 }, 1, 0, 10),
        makeTestRow(.{ 1, 2, 3 }, 2, 10, 20),
        makeTestRow(.{ 0.5, 0.5, 0.5 }, 3, 20, 30),
        makeTestRow(.{ -0.5, -0.5, -0.5 }, 4, 30, 40),
    };

    var inst = try TestStorage.init(arena.allocator(), tmpD.dir, .{});
    try expect(inst.meta.vec_n == 0);
    for (rows) |row| {
        _ = try inst.put(row);
    }
    try expect(inst.meta.vec_n == rows.len);
    try inst.save("temp.db");
    inst.deinit();

    var inst2 = try TestStorage.init(arena.allocator(), tmpD.dir, .{});
    defer inst2.deinit();
    try inst2.load("temp.db");
    try expect(inst2.meta.vec_n == rows.len);
    for (rows, 0..) |row, i| {
        const loaded = inst2.get(i);
        try expect(@reduce(.And, row.vec == loaded.vec));
        try expect(row.note_id == loaded.note_id);
        try expect(row.start_i == loaded.start_i);
        try expect(row.end_i == loaded.end_i);
    }
}

test "re Storage index" {
    var tmpD = tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();

    const rows: [4]TestVectorRow = .{
        makeTestRow(.{ 1, 1, 1 }, 1, 0, 10),
        makeTestRow(.{ 1, 2, 3 }, 2, 10, 20),
        makeTestRow(.{ 0.5, 0.5, 0.5 }, 3, 20, 30),
        makeTestRow(.{ -0.5, -0.5, -0.5 }, 4, 30, 40),
    };
    var ids: [4]VectorID = undefined;

    var inst = try TestStorage.init(arena.allocator(), tmpD.dir, .{});
    try expect(inst.meta.vec_n == 0);
    for (rows, 0..) |row, i| {
        ids[i] = try inst.put(row);
    }
    for (0..4) |i| {
        try expect(inst.isOccupied(i));
    }
    try inst.rm(ids[0]);
    try inst.rm(ids[2]);

    try expect(!inst.isOccupied(0));
    try expect(inst.isOccupied(1));
    try expect(!inst.isOccupied(2));
    try expect(inst.isOccupied(3));
    try expect(inst.meta.vec_n == rows.len - 2);
    try inst.save("temp.db");
    inst.deinit();

    var inst2 = try TestStorage.init(arena.allocator(), tmpD.dir, .{});
    defer inst2.deinit();
    try inst2.load("temp.db");
    try expect(inst2.meta.vec_n == rows.len - 2);
    try expect(!inst2.isOccupied(0));
    try expect(inst2.isOccupied(1));
    try expect(!inst2.isOccupied(2));
    try expect(inst2.isOccupied(3));
}

test "test put resize" {
    var tmpD = tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();

    var inst = try TestStorage.init(arena.allocator(), tmpD.dir, .{});
    defer inst.deinit();
    try expect(inst.meta.vec_n == 0);
    try expect(inst.capacity == 32);

    const row1 = makeTestRow(.{ 1, 1, 1 }, 1, 0, 10);
    for (0..31) |_| {
        _ = try inst.put(row1);
    }
    try expect(inst.meta.vec_n == 31);
    try expect(inst.capacity == 32);
    _ = try inst.put(row1);
    try expect(inst.meta.vec_n == 32);
    try expect(inst.capacity == 64);
}

test "no failure on loading non-existent db" {
    var tmpD = tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();

    var inst = try TestStorage.init(arena.allocator(), tmpD.dir, .{});
    defer inst.deinit();
    try inst.load("vecs.db");
}

test "grow" {
    var tmpD = tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();

    var inst = try TestStorage.init(arena.allocator(), tmpD.dir, .{ .sz = 1 });
    defer inst.deinit();
    try inst.grow();
    try expect(inst.capacity == 1);
    try expect(inst.vectors.len == 1);
    try expect(inst.index.len == 1);
    try expect(inst.note_ids.len == 1);
    try expect(inst.start_is.len == 1);
    try expect(inst.end_is.len == 1);

    _ = try inst.put(makeTestRow(std.mem.zeroes(TestVecType), 1, 0, 0));
    try expect(inst.capacity == 2);
    try expect(inst.vectors.len == 2);
    try expect(inst.index.len == 2);

    _ = try inst.put(makeTestRow(std.mem.zeroes(TestVecType), 2, 0, 0));
    try expect(inst.capacity == 4);
    try expect(inst.vectors.len == 4);
    try expect(inst.index.len == 4);

    _ = try inst.put(makeTestRow(std.mem.zeroes(TestVecType), 3, 0, 0));
    try expect(inst.capacity == 4);
    try expect(inst.vectors.len == 4);
    try expect(inst.index.len == 4);
    try expect(inst.isOccupied(0));
    try expect(inst.isOccupied(1));
    try expect(inst.isOccupied(2));
    try expect(!inst.isOccupied(3));
}

test "copy" {
    var tmpD = tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();
    var inst = try TestStorage.init(arena.allocator(), tmpD.dir, .{ .sz = 2 });

    const row1 = makeTestRow(.{ 1, 1, 1 }, 42, 5, 15);
    const old_id = try inst.put(row1);
    const new_id = try inst.copy(old_id);
    try expect(old_id != new_id);
    const row2 = inst.get(new_id);
    try expect(@reduce(.And, row1.vec == row2.vec));
    try expect(row1.note_id == row2.note_id);
    try expect(row1.start_i == row2.start_i);
    try expect(row1.end_i == row2.end_i);
}

test "dirty and occupied" {
    var tmpD = tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();

    var inst = try TestStorage.init(arena.allocator(), tmpD.dir, .{});
    defer inst.deinit();

    const row1 = makeTestRow(.{ 1, 1, 1 }, 1, 0, 10);
    const id1 = try inst.put(row1);
    try expect(inst.isOccupied(id1));
    try expect(inst.isDirty(id1));
    try inst.save("temp.db");
    try expect(!inst.isDirty(id1));
    try expect(inst.isOccupied(id1));

    const row2 = makeTestRow(.{ 2, 2, 2 }, 2, 10, 20);
    const id2 = try inst.put(row2);
    try expect(inst.isOccupied(id2));
    try expect(inst.isDirty(id2));
    try inst.rm(id2);
    try expect(!inst.isDirty(id2));
    try expect(!inst.isOccupied(id2));
    try inst.save("temp.db");
    try expect(!inst.isDirty(id2));
    try expect(!inst.isOccupied(id2));
}

test "no write dirty" {
    var tmpD = tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();

    var inst = try TestStorage.init(arena.allocator(), tmpD.dir, .{});
    defer inst.deinit();
    const row1_a = makeTestRow(.{ 1, 1, 1 }, 100, 0, 10);
    const id = try inst.put(row1_a);
    try inst.save("temp.db");

    var inst2 = try TestStorage.init(arena.allocator(), tmpD.dir, .{});
    defer inst2.deinit();
    try inst2.load("temp.db");

    const row2 = makeTestRow(.{ 2, 2, 2 }, 200, 10, 20);
    inst2.putAt(row2, id);
    inst2.setDirty(id, false);
    try inst2.save("temp.db");

    var inst3 = try TestStorage.init(arena.allocator(), tmpD.dir, .{});
    defer inst3.deinit();
    try inst3.load("temp.db");
    const row1_b = inst3.get(id);
    // Vector data respects dirty flag (uses seek-based writes)
    try expect(@reduce(.And, row1_a.vec == row1_b.vec));
    // Scalar fields are batch-written, so they get overwritten regardless of dirty flag
    try expect(row2.note_id == row1_b.note_id);
}

test "loaded not dirty" {
    var tmpD = tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();

    var inst = try TestStorage.init(arena.allocator(), tmpD.dir, .{});
    defer inst.deinit();
    var ids: [10]VectorID = undefined;
    for (0..10) |i| {
        ids[i] = try inst.put(makeTestRow(.{ 1, 1, 1 }, @intCast(i), 0, 10));
        try expect(inst.isDirty(ids[i]));
    }
    try inst.save("temp.db");

    var inst2 = try TestStorage.init(arena.allocator(), tmpD.dir, .{});
    defer inst2.deinit();
    try inst2.load("temp.db");
    for (ids) |id| {
        try expect(!inst2.isDirty(id));
    }
}

test "search returns VectorRow" {
    var tmpD = tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();

    var inst = try TestStorage.init(arena.allocator(), tmpD.dir, .{});
    defer inst.deinit();

    _ = try inst.put(makeTestRow(.{ 1, 0, 0 }, 10, 0, 5));
    _ = try inst.put(makeTestRow(.{ 0.9, 0.1, 0 }, 20, 5, 10));
    _ = try inst.put(makeTestRow(.{ 0, 1, 0 }, 30, 10, 15));

    var results: [10]TestStorage.SearchEntry = undefined;
    const count = try inst.search(.{ 1, 0, 0 }, &results, 0.5);

    try expect(count == 2);
    try expect(results[0].row.note_id == 10);
    try expect(results[1].row.note_id == 20);
    try expect(results[0].similarity > results[1].similarity);
}

// **************************************************************************************** Vectors
pub fn dot(comptime N: u32, comptime T: type, a: @Vector(N, T), b: @Vector(N, T)) T {
    return @reduce(.Add, a * b);
}

pub fn magnitude(comptime N: u32, comptime T: type, a: @Vector(N, T)) T {
    return @sqrt(@reduce(.Add, a * a));
}

fn is_zero(comptime N: u32, comptime T: type, a: @Vector(N, T)) bool {
    const zero_vec: @Vector(N, T) = @splat(0);
    return @reduce(.And, a == zero_vec);
}

pub fn cosine_similarity(comptime N: u32, comptime T: type, a: @Vector(N, T), b: @Vector(N, T)) T {
    if (is_zero(N, T, a) or is_zero(N, T, b)) return 0;
    return dot(N, T, a, b) / (magnitude(N, T, a) * magnitude(N, T, b));
}

test "cosine orthogonal" {
    const a = TestVecType{ 1, 0, 0 };
    const b = TestVecType{ 0, 1, 0 };
    const c = TestVecType{ 0, 0, 1 };

    try expect(cosine_similarity(TestN, TestT, a, b) == 0);
    try expect(cosine_similarity(TestN, TestT, a, c) == 0);
    try expect(cosine_similarity(TestN, TestT, b, c) == 0);
}

test "cosine equal" {
    const a = TestVecType{ 1, 0, 0 };

    try expect(cosine_similarity(TestN, TestT, a, a) == 1);
}

test "cosine reverse" {
    const a = TestVecType{ 1, 0, 0 };
    const b = TestVecType{ -1, 0, 0 };

    try expect(cosine_similarity(TestN, TestT, a, b) == -1);
}

test "cosine 45-degree" {
    const a = TestVecType{ 1, 0, 0 };
    const b = TestVecType{ 1, 1, 0 };

    const output = cosine_similarity(TestN, TestT, a, b);
    try expect(output == 0.70710677);
}

test "cosine similar" {
    const a = TestVecType{ 1, 2, 3 };
    const b = TestVecType{ 1, 1, 1 };

    const output = cosine_similarity(TestN, TestT, a, b);
    try expect(output == 0.9258201);
}

test "cosine zero-vec" {
    const a = TestVecType{ 0, 0, 0 };
    const b = TestVecType{ 1, 0, 0 };

    const output = cosine_similarity(TestN, TestT, a, b);
    try expect(output == 0);
}

test "rmByNoteId" {
    var tmpD = tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();

    var s = try TestStorage.init(testing_allocator, tmpD.dir, .{});
    defer s.deinit();

    const note1: NoteID = 1;
    const note2: NoteID = 2;

    _ = try s.put(makeTestRow(.{ 1, 0, 0 }, note1, 0, 5));
    _ = try s.put(makeTestRow(.{ 0, 1, 0 }, note1, 5, 10));
    _ = try s.put(makeTestRow(.{ 0, 0, 1 }, note2, 0, 5));

    try std.testing.expectEqual(@as(usize, 3), s.meta.vec_n);

    s.rmByNoteId(note1);

    try std.testing.expectEqual(@as(usize, 1), s.meta.vec_n);

    const entries = try s.vecsForNote(testing_allocator, note2);
    defer testing_allocator.free(entries);
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqual(note2, entries[0].row.note_id);
}



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
const VectorID = types.VectorID;
pub const NoteID = u64;
