const std = @import("std");
const expect = std.testing.expect;
const expectEqlStrings = std.testing.expectEqualStrings;
const assert = std.debug.assert;
const testing_allocator = std.testing.allocator;

const embed = @import("embed.zig");
const model = @import("model.zig");
const vector = @import("vector.zig");

const types = @import("types.zig");
const vec_sz = types.vec_sz;
const vec_type = types.vec_type;
const Vector = types.Vector;
const VectorID = types.VectorID;

const NoteID = model.NoteID;
const Note = model.Note;

pub const Error = error{ NotFound, BufferTooSmall };

// TODO: this is a hack...
const SMALL_TESTING_MODEL = "zig-out/share/mnist-12-int8.onnx";
pub const RuntimeOpts = struct {
    basedir: std.fs.Dir,
    mem: bool = false,
    model: [:0]const u8 = SMALL_TESTING_MODEL,
    skipEmbed: bool = false,
};

pub const Runtime = struct {
    basedir: std.fs.Dir,
    db: model.DB,
    vectors: vector.DB,
    embedder: embed.Embedder,
    tokenizer: embed.Tokenizer,
    arena: std.heap.ArenaAllocator,
    embed_model: [:0]const u8 = SMALL_TESTING_MODEL,
    skipEmbed: bool = false,

    pub fn init(allocator: std.mem.Allocator, opts: RuntimeOpts) !Runtime {
        var arena = std.heap.ArenaAllocator.init(allocator);

        const database = try model.DB.init(arena.allocator(), .{
            .basedir = opts.basedir,
            .mem = opts.mem,
        });

        const embedder = try embed.Embedder.init(arena.allocator(), opts.model);
        const tokenizer = try embed.Tokenizer.init(arena.allocator());
        const vectors = try vector.DB.init(allocator, opts.basedir);

        return Runtime{
            .basedir = opts.basedir,
            .db = database,
            .vectors = vectors,
            .embedder = embedder,
            .tokenizer = tokenizer,
            .arena = arena,
            .skipEmbed = opts.skipEmbed,
        };
    }

    pub fn deinit(self: *Runtime) void {
        self.db.deinit();
        self.vectors.deinit();
        self.embedder.deinit();
        self.arena.deinit();
    }
    // FS lazy write - only create file on write
    pub fn create(self: *Runtime) !NoteID {
        return self.db.create();
    }

    pub fn get(self: *Runtime, id: NoteID) !Note {
        return self.db.get(id);
    }

    pub fn update(self: *Runtime, note: Note) !void {
        return self.db.update(note);
    }

    pub fn delete(self: *Runtime, id: NoteID) !void {
        const note = try self.get(id);

        var buf: [64]u8 = undefined;
        try self.basedir.deleteFile(note.path(&buf));

        return self.db.delete(note);
    }

    pub fn writeAll(self: *Runtime, id: NoteID, content: []const u8) !void {
        if (content.len == 0) {
            return self.delete(id);
        }

        const note = try self.get(id);

        var buf: [64]u8 = undefined;
        const path = note.path(&buf);

        const f = try self.basedir.createFile(path, .{ .read = true, .truncate = true });
        defer f.close();
        try f.writeAll(content);

        // TODO: can we flag this to be removed in prod?
        if (self.skipEmbed) {
            try self.update(note);
            return;
        }

        var it = std.mem.splitAny(u8, content, ",.!?;-()/'\"");
        while (it.next()) |sentence| {
            const tokens = try self.tokenizer.tokenize(sentence);
            // Skip anything not tokenizable - <2 means there's only the start and end tokens.
            if (tokens.input_ids.len < 3) continue;
            const embeddings = try self.embedder.embed(tokens);
            // TODO: remove this copy - it's only necessary at the moment because I haven't made
            //       the embedder quite as strict as the vector DB. So the embedder outputs slices
            //       but we need fixed length arrays. Hence the copy.
            // std.debug.print("Embeddings: {d}, vec_sz: {d}\n", .{ embeddings.len, vec_sz });
            assert(embeddings.len == vec_sz);
            var tmp_embeddings: [vec_sz]vec_type = undefined;
            std.mem.copyForwards(vec_type, &tmp_embeddings, embeddings);
            const vec: Vector = tmp_embeddings;

            const vector_id = try self.vectors.put(vec);
            try self.db.appendVector(id, vector_id);
        }

        try self.update(note);
        return;
    }

    pub fn readAll(self: *Runtime, id: NoteID, buf: []u8) !usize {
        const note = try self.get(id);

        var pathbuf: [64]u8 = undefined;
        const path = note.path(&pathbuf);
        const f = self.basedir.openFile(path, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                return 0; // Lazy creation
            },
            else => {
                return err;
            },
        };
        defer f.close();

        const n = try f.readAll(buf);

        if (n == buf.len) {
            return Error.BufferTooSmall;
        }

        return n;
    }

    // Search should query the database and return N written
    // Parameter buf is really an array of NoteIDs. Need to use c_int though
    // TODO: make the ignore field more complex?
    pub fn search(self: *Runtime, query: []const u8, buf: []c_int, ignore: ?NoteID) !usize {
        if (query.len == 0) {
            return self.db.searchNoQuery(buf, ignore);
        }

        const tokens = try self.tokenizer.tokenize(query);
        // Skip anything not tokenizable - <2 means there's only the start and end tokens.
        if (tokens.input_ids.len < 3) return 0;
        const embeddings = try self.embedder.embed(tokens);
        // TODO: remove this copy - it's only necessary at the moment because I haven't made
        //       the embedder quite as strict as the vector DB. So the embedder outputs slices
        //       but we need fixed length arrays. Hence the copy.
        // std.debug.print("Embeddings: {d}, vec_sz: {d}\n", .{ embeddings.len, vec_sz });
        assert(embeddings.len == vec_sz);
        var tmp_embeddings: [vec_sz]vec_type = undefined;
        std.mem.copyForwards(vec_type, &tmp_embeddings, embeddings);
        const query_vec: Vector = tmp_embeddings;

        var vec_ids: [1000]VectorID = undefined;

        // std.debug.print("Searching for {s}\n", .{query});
        const found_n = try self.vectors.search(query_vec, &vec_ids);

        for (0..found_n) |i| {
            // TODO: CRITICAL unsafe af casting
            buf[i] = @as(c_int, @intCast(try self.db.vecToNote(vec_ids[i])));
        }
        return found_n;
    }
};

const expectError = std.testing.expectError;
test "no create on read" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var rt = try Runtime.init(testing_allocator, .{ .mem = true, .basedir = tmpD.dir, .skipEmbed = true });
    defer rt.deinit();

    const nid1 = try rt.create();
    const n1 = try rt.get(nid1);
    var buf: [64]u8 = undefined;
    const path = n1.path(&buf);
    try expectError(error.FileNotFound, rt.basedir.access(path, .{ .mode = .read_write }));

    const sz = try rt.readAll(nid1, &buf);
    try expect(sz == 0);
    try expectError(error.FileNotFound, rt.basedir.access(path, .{ .mode = .read_write }));
}

fn _test_empty_dir_exclude_db(dir: std.fs.Dir) !bool {
    var dirIterator = dir.iterate();
    const dbname = "db.db";
    while (try dirIterator.next()) |dirent| {
        for (dirent.name, 0..) |c, i| {
            if (c != dbname[i]) return false;
        }
    }
    return true;
}

test "lazily create files" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var rt = try Runtime.init(testing_allocator, .{ .mem = true, .basedir = tmpD.dir, .skipEmbed = true });
    defer rt.deinit();

    const noteID = try rt.create();
    try expect(try _test_empty_dir_exclude_db(rt.basedir));

    _ = try rt.writeAll(noteID, "norecycle");
    try expect(!try _test_empty_dir_exclude_db(rt.basedir));
}

test "modify on write" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var rt = try Runtime.init(testing_allocator, .{ .mem = true, .basedir = tmpD.dir, .skipEmbed = true });
    defer rt.deinit();

    const noteID = try rt.create();
    var note = try rt.get(noteID);
    try expect(note.created == note.modified);

    var expected = "Contents of a note!";
    try rt.writeAll(noteID, expected[0..]);
    note = try rt.get(noteID);
    try expect(note.created != note.modified);
}

test "no modify on read" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var rt = try Runtime.init(testing_allocator, .{ .mem = true, .basedir = tmpD.dir, .skipEmbed = true });
    defer rt.deinit();

    const noteID = try rt.create();
    var note = try rt.get(noteID);
    try expect(note.created == note.modified);

    var buf: [20]u8 = undefined;
    _ = try rt.readAll(noteID, &buf);
    note = try rt.get(noteID);
    try expect(note.created == note.modified);
}

test "no modify on search" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var rt = try Runtime.init(testing_allocator, .{ .mem = true, .basedir = tmpD.dir, .skipEmbed = true });
    defer rt.deinit();

    const noteID = try rt.create();
    var note = try rt.get(noteID);
    try expect(note.created == note.modified);

    var buf2: [20]c_int = undefined;
    _ = try rt.search("", &buf2, 420);
    note = try rt.get(noteID);
    try expect(note.created == note.modified);
}

test "r/w-all note" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var rt = try Runtime.init(testing_allocator, .{ .mem = true, .basedir = tmpD.dir, .skipEmbed = true });
    defer rt.deinit();

    const noteID = try rt.create();

    var expected = "Contents of a note!";
    try rt.writeAll(noteID, expected[0..]);

    var buffer: [20]u8 = undefined;
    const n = try rt.readAll(noteID, &buffer);

    try std.testing.expectEqualStrings(expected, buffer[0..n]);
}

test "r/w-all updated time" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var rt = try Runtime.init(testing_allocator, .{ .mem = true, .basedir = tmpD.dir, .skipEmbed = true });
    defer rt.deinit();

    const noteID = try rt.create();
    const oldNote = try rt.get(noteID);

    var expected = "Contents of a note!";
    try rt.writeAll(noteID, expected[0..]);

    const newNote = try rt.get(noteID);

    try expect(newNote.modified > oldNote.modified);
}

test "r/w-all too smol output buffer" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var rt = try Runtime.init(testing_allocator, .{ .mem = true, .basedir = tmpD.dir, .skipEmbed = true });
    defer rt.deinit();

    const noteID = try rt.create();

    var expected = "Should be way too big!!!";
    try rt.writeAll(noteID, expected[0..]);

    var buffer: [1]u8 = undefined;
    _ = rt.readAll(noteID, &buffer) catch |err| {
        try expect(err == Error.BufferTooSmall);
        return;
    };

    try expect(false);
}

// TODO: is this unnecessary automatic behavior?
test "delete empty note on empty writeAll" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var rt = try Runtime.init(testing_allocator, .{ .mem = true, .basedir = tmpD.dir, .skipEmbed = true });
    defer rt.deinit();

    const noteID = try rt.create();
    var expected = "Some content!";
    try rt.writeAll(noteID, expected[0..]);

    // Should not fail
    const note = try rt.get(noteID);
    var buffer: [20]u8 = undefined;
    const n = try rt.readAll(noteID, &buffer);
    try std.testing.expectEqualStrings(expected, buffer[0..n]);

    // Now lets clear it out
    const nothing = "";
    try rt.writeAll(noteID, nothing);

    const out = rt.get(noteID);
    try std.testing.expectError(model.Error.NotFound, out);

    var pathbuf: [64]u8 = undefined;
    const path = note.path(&pathbuf);
    const f = tmpD.dir.openFile(path, .{});
    try std.testing.expectError(error.FileNotFound, f);
}

test "search no query" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var rt = try Runtime.init(testing_allocator, .{ .mem = true, .basedir = tmpD.dir, .skipEmbed = true });
    defer rt.deinit();

    var i: usize = 0;
    var id: NoteID = undefined;
    while (i < 9) : (i += 1) {
        id = try rt.create();
        _ = try rt.writeAll(id, "norecycle");
    }

    var buffer: [10]c_int = undefined;
    const written = try rt.search("", &buffer, null);
    try expect(written == 9);

    i = 0;
    while (i < 9) : (i += 1) {
        // std.debug.print("Want: {d}, Got: {d}\n", .{ i + 1, output[i] });
        try expect(buffer[8 - i] == @as(c_int, @intCast(i + 1)));
    }
}

// TODO: do we want to move no-query searching testing to the model file? It's really just a DB op.
test "search no query orderby modified" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var rt = try Runtime.init(testing_allocator, .{ .mem = true, .basedir = tmpD.dir, .skipEmbed = true });
    defer rt.deinit();

    const noteID1 = try rt.create();
    _ = try rt.writeAll(noteID1, "norecycle");
    const noteID2 = try rt.create();
    _ = try rt.writeAll(noteID2, "norecycle");

    var buffer: [10]c_int = undefined;
    const written = try rt.search("", &buffer, null);
    try expect(written == 2);
    try expect(buffer[0] == @as(c_int, @intCast(noteID2)));
    try expect(buffer[1] == @as(c_int, @intCast(noteID1)));

    const note1 = try rt.get(noteID1);
    try rt.update(note1);

    var buffer2: [10]c_int = undefined;
    const written2 = try rt.search("", &buffer2, null);
    try expect(written2 == 2);
    try expect(buffer2[0] == @as(c_int, @intCast(noteID1)));
    try expect(buffer2[1] == @as(c_int, @intCast(noteID2)));
}

test "exclude param 'empty search'" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var rt = try Runtime.init(testing_allocator, .{ .mem = true, .basedir = tmpD.dir, .skipEmbed = true });
    defer rt.deinit();

    const noteID1 = try rt.create();
    _ = try rt.writeAll(noteID1, "norecycle");
    const noteID2 = try rt.create();
    _ = try rt.writeAll(noteID2, "norecycle");

    var buffer: [10]c_int = undefined;
    const written = try rt.search("", &buffer, noteID1);
    try expect(written == 1);
    try expect(buffer[0] == @as(c_int, @intCast(noteID2)));
}

test "exclude param 'empty search' - 2" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var rt = try Runtime.init(testing_allocator, .{ .mem = true, .basedir = tmpD.dir, .skipEmbed = true });
    defer rt.deinit();

    const noteID1 = try rt.create();
    _ = try rt.writeAll(noteID1, "norecycle");
    const noteID2 = try rt.create();
    _ = try rt.writeAll(noteID2, "norecycle");

    var buffer: [10]c_int = undefined;
    const written = try rt.search("", &buffer, noteID2);
    try expect(written == 1);
    try expect(buffer[0] == @as(c_int, @intCast(noteID1)));
}

test "exclude from 'empty search' unmodifieds" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var rt = try Runtime.init(testing_allocator, .{ .mem = true, .basedir = tmpD.dir, .skipEmbed = true });
    defer rt.deinit();

    const noteID1 = try rt.create();
    _ = try rt.writeAll(noteID1, "norecycle");
    _ = try rt.create();

    var buffer: [10]c_int = undefined;
    const written = try rt.search("", &buffer, null);
    try expect(written == 1);
    try expect(buffer[0] == @as(c_int, @intCast(noteID1)));
}
