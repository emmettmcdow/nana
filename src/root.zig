const std = @import("std");
const expect = std.testing.expect;
const expectEqlStrings = std.testing.expectEqualStrings;
const testing_allocator = std.testing.allocator;

const embed = @import("embed.zig");
const model = @import("model.zig");
const NoteID = model.NoteID;
const Note = model.Note;

pub const Error = error{ NotFound, BufferTooSmall };

// TODO: this is a hack...
const SMALL_TESTING_MODEL = "zig-out/share/mnist-12-int8.onnx";
pub const RuntimeOpts = struct {
    basedir: std.fs.Dir,
    mem: bool = false,
    model: [:0]const u8 = SMALL_TESTING_MODEL,
};

pub const Runtime = struct {
    basedir: std.fs.Dir,
    db: model.DB,
    embedder: embed.Embedder,
    tokenizer: embed.Tokenizer,
    arena: std.heap.ArenaAllocator,
    embed_model: [:0]const u8 = SMALL_TESTING_MODEL,

    pub fn init(allocator: std.mem.Allocator, opts: RuntimeOpts) !Runtime {
        var arena = std.heap.ArenaAllocator.init(allocator);

        const database = try model.DB.init(arena.allocator(), .{
            .basedir = opts.basedir,
            .mem = opts.mem,
        });
        // const one = std.time.microTimestamp();
        const embedder = try embed.Embedder.init(arena.allocator(), opts.model);
        // const two = std.time.microTimestamp();
        const tokenizer = try embed.Tokenizer.init(arena.allocator());
        // const three = std.time.microTimestamp();
        // std.debug.print("Embedder took {d} ms to init\n", .{two - one});
        // std.debug.print("Tokenizer took {d} ms to init\n", .{three - two});

        return Runtime{
            .basedir = opts.basedir,
            .db = database,
            .embedder = embedder,
            .tokenizer = tokenizer,
            .arena = arena,
        };
    }

    pub fn deinit(self: *Runtime) void {
        self.db.deinit();
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
    pub fn search(self: *Runtime, query: []const u8, buf: []c_int, ignore: ?NoteID) !usize {
        if (query.len == 0) {
            return self.db.search_no_query(buf, ignore);
        }
        unreachable;
    }
};

const expectError = std.testing.expectError;
test "no create on read" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var rt = try Runtime.init(testing_allocator, .{ .mem = true, .basedir = tmpD.dir });
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
    var rt = try Runtime.init(testing_allocator, .{ .mem = true, .basedir = tmpD.dir });
    defer rt.deinit();

    const noteID = try rt.create();
    try expect(try _test_empty_dir_exclude_db(rt.basedir));

    _ = try rt.writeAll(noteID, "norecycle");
    try expect(!try _test_empty_dir_exclude_db(rt.basedir));
}

test "modify on write" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var rt = try Runtime.init(testing_allocator, .{ .mem = true, .basedir = tmpD.dir });
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
    var rt = try Runtime.init(testing_allocator, .{ .mem = true, .basedir = tmpD.dir });
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
    var rt = try Runtime.init(testing_allocator, .{ .mem = true, .basedir = tmpD.dir });
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
    var rt = try Runtime.init(testing_allocator, .{ .mem = true, .basedir = tmpD.dir });
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
    var rt = try Runtime.init(testing_allocator, .{ .mem = true, .basedir = tmpD.dir });
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
    var rt = try Runtime.init(testing_allocator, .{ .mem = true, .basedir = tmpD.dir });
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
    var rt = try Runtime.init(testing_allocator, .{ .mem = true, .basedir = tmpD.dir });
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
    var rt = try Runtime.init(testing_allocator, .{ .mem = true, .basedir = tmpD.dir });
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
    var rt = try Runtime.init(testing_allocator, .{ .mem = true, .basedir = tmpD.dir });
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
    var rt = try Runtime.init(testing_allocator, .{ .mem = true, .basedir = tmpD.dir });
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
    var rt = try Runtime.init(testing_allocator, .{ .mem = true, .basedir = tmpD.dir });
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
    var rt = try Runtime.init(testing_allocator, .{ .mem = true, .basedir = tmpD.dir });
    defer rt.deinit();

    const noteID1 = try rt.create();
    _ = try rt.writeAll(noteID1, "norecycle");
    _ = try rt.create();

    var buffer: [10]c_int = undefined;
    const written = try rt.search("", &buffer, null);
    try expect(written == 1);
    try expect(buffer[0] == @as(c_int, @intCast(noteID1)));
}
