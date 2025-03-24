const expect = std.testing.expect;
const expectEqlStrings = std.testing.expectEqualStrings;
const testing_allocator = std.testing.allocator;
const std = @import("std");
const sqlite = @import("sqlite");

pub const Error = error{ NotFound, BufferTooSmall };
const DB_LOCATION = "./db.db";

const GET_LAST_ID = "SELECT id FROM notes ORDER BY id DESC LIMIT 1;";

const GET_NOTE = "SELECT id,created,modified FROM notes WHERE id = ?;";

const INSERT_NOTE =
    \\INSERT INTO notes(id, created, modified ) VALUES(?, ?, ?) ;
;
const NOTE_SCHEMA =
    \\CREATE TABLE IF NOT EXISTS notes (
    \\    id INTEGER PRIMARY KEY,
    \\    created INTEGER,
    \\    modified INTEGER
    \\);
;
const UPDATE_NOTE =
    \\UPDATE notes SET modified = ? WHERE id = ?;
;
const GET_COLS = "PRAGMA table_info(notes);";

const DELETE_NOTE = "DELETE FROM notes WHERE id = ?;";

const EMPTY_NOTE = "SELECT id FROM notes WHERE created = modified LIMIT 1;";

const SEARCH_NO_QUERY = "SELECT id FROM notes WHERE created != modified ORDER BY modified DESC LIMIT ?;";

const NoteID = u64;
const Note = struct {
    id: NoteID,
    created: i64,
    modified: i64,

    fn path(self: Note, buf: []u8) []const u8 {
        const out = std.fmt.bufPrint(buf, "{d}", .{self.id}) catch |err| {
            std.log.err("Failed to write path of note {d}: {}\n", .{ self.id, err });
            @panic("Failed to write the path of a note!");
        };

        return out;
    }
};
const SchemaRow = struct {
    id: u8 = 0,
    name: []const u8,
    type: []const u8,
    unk1: u8 = 0,
    unk2: []const u8 = "",
    unk3: u8 = 0,
};

pub const Runtime = struct {
    basedir: std.fs.Dir,
    db: sqlite.Db,
    _next_id: NoteID = 1,

    // FS lazy write - only create file on write
    pub fn create(self: *Runtime) !NoteID {

        // Recycle empty notes
        const row = try self.db.one(NoteID, EMPTY_NOTE, .{}, .{});
        if (row) |id| {
            const note = try self.get(id);
            try self.update(note);
            return id;
        }

        const created = std.time.microTimestamp();
        const note = Note{ .id = self._next_id, .created = created, .modified = created };

        var diags = sqlite.Diagnostics{};
        var stmt = self.db.prepareWithDiags(INSERT_NOTE, .{ .diags = &diags }) catch |err| {
            std.log.info("unable to prepare statement, got error {}. diagnostics: {s}", .{ err, diags });
            return err;
        };
        defer stmt.deinit();
        try stmt.exec(.{}, .{
            .id = note.id,
            .created = note.created,
            .modified = note.modified,
        });

        self._next_id += 1;

        return note.id;
    }

    pub fn get(self: *Runtime, id: NoteID) !Note {
        var diags = sqlite.Diagnostics{};
        var stmt = self.db.prepareWithDiags(GET_NOTE, .{ .diags = &diags }) catch |err| {
            std.log.err("unable to prepare statement, got error {}. diagnostics: {s}", .{ err, diags });
            return err;
        };

        defer stmt.deinit();

        const row = try stmt.one(Note, .{}, .{
            .id = id,
        });

        if (row) |r| {
            return Note{ .id = r.id, .created = r.created, .modified = r.modified };
        } else {
            return sqlite.Error.SQLiteNotFound;
        }
    }

    pub fn update(self: *Runtime, note: Note) !void {
        var diags = sqlite.Diagnostics{};
        var stmt = self.db.prepareWithDiags(UPDATE_NOTE, .{ .diags = &diags }) catch |err| {
            std.log.err("unable to prepare statement, got error {}. diagnostics: {s}", .{ err, diags });
            return err;
        };
        defer stmt.deinit();

        const modified = std.time.microTimestamp();
        try stmt.exec(.{}, .{
            .modified = modified,
            .id = note.id,
        });
    }

    pub fn delete(self: *Runtime, id: NoteID) !void {
        const note = try self.get(id);

        var buf: [64]u8 = undefined;
        try self.basedir.deleteFile(note.path(&buf));

        var diags = sqlite.Diagnostics{};
        var stmt = self.db.prepareWithDiags(DELETE_NOTE, .{ .diags = &diags }) catch |err| {
            std.log.err("unable to prepare statement, got error {}. diagnostics: {s}", .{ err, diags });
            return err;
        };
        defer stmt.deinit();

        try stmt.exec(.{}, .{
            .id = note.id,
        });
    }

    pub fn writeAll(self: *Runtime, id: NoteID, content: []const u8) !void {
        // std.debug.print("Writeall called on {d} with '{s}' (len: {d})\n", .{ id, content, content.len });
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
        if (query.len != 0) {
            unreachable;
        }

        var diags = sqlite.Diagnostics{};
        var stmt = self.db.prepareWithDiags(SEARCH_NO_QUERY, .{ .diags = &diags }) catch |err| {
            std.log.err("unable to prepare statement, got error {}. diagnostics: {s}", .{ err, diags });
            return err;
        };

        defer stmt.deinit();

        var iter = try stmt.iterator(NoteID, .{
            .limit = buf.len,
        });

        var written: usize = 0;
        while (try iter.next(.{})) |id| {
            if (written >= buf.len) {
                // TOO MANY ITEMS
                unreachable;
            }
            if (ignore) |toIgnore| {
                if (id == toIgnore) {
                    continue;
                }
            }
            buf[written] = @intCast(id);
            written += 1;
        }

        return written;
    }

    pub fn deinit(self: *Runtime) void {
        self.db.deinit();
    }
};

pub fn init(b: std.fs.Dir, mem: bool) !Runtime {
    var db = try sqlite.Db.init(.{
        .mode = if (mem) sqlite.Db.Mode.Memory else sqlite.Db.Mode{ .File = DB_LOCATION },
        .open_flags = .{
            .write = true,
            .create = true,
        },
        .threading_mode = .MultiThread,
    });
    var stmt = try db.prepare(NOTE_SCHEMA);
    defer stmt.deinit();
    try stmt.exec(.{}, .{});

    const row = try db.one(NoteID, GET_LAST_ID, .{}, .{});
    if (row) |id| {
        // std.log.err("Row: {d}\n", id);
        return Runtime{ .basedir = b, .db = db, ._next_id = id + 1 };
    }
    return Runtime{ .basedir = b, .db = db };
}

test "init DB" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();

    var rt = try init(tmpD.dir, true);
    defer rt.deinit();
    // Check if initialized
    var stmt = try rt.db.prepare(GET_COLS);
    defer stmt.deinit();

    var iter = try stmt.iterator(SchemaRow, .{});

    const expectedSchema = [_]SchemaRow{
        .{ .name = "id", .type = "INTEGER" },
        .{ .name = "created", .type = "INTEGER" },
        .{ .name = "modified", .type = "INTEGER" },
    };

    var i: usize = 0;
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();
    while (true) {
        const row = (try iter.nextAlloc(arena.allocator(), .{})) orelse break;
        try expectEqlStrings(expectedSchema[i].name, row.name);
        try expectEqlStrings(expectedSchema[i].type, row.type);
        i += 1;
    }
}

test "re-init DB" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();

    const cwd = std.fs.cwd();
    // TODO: fix this - sqlite library can't curently use tmpD... ugh
    _ = cwd.deleteFile("db.db") catch void; // Start fresh!
    defer _ = cwd.deleteFile("db.db") catch void; // Leave no trace!

    var rt = try init(tmpD.parent_dir, false);

    const id1 = try rt.create();
    _ = try rt.writeAll(id1, "norecycle");

    rt.deinit();
    rt = try init(tmpD.parent_dir, false);

    const id2 = try rt.create();
    try expect(id2 == id1 + 1);
}

test "no create on read" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var rt = try init(tmpD.dir, true);
    defer rt.deinit();

    const nid1 = try rt.create();
    const n1 = try rt.get(nid1);
    var buf: [64]u8 = undefined;
    const path = n1.path(&buf);
    try std.testing.expectError(error.FileNotFound, rt.basedir.access(path, .{ .mode = .read_write }));

    const sz = try rt.readAll(nid1, &buf);
    try expect(sz == 0);
    try std.testing.expectError(error.FileNotFound, rt.basedir.access(path, .{ .mode = .read_write }));
}

test "r/w DB" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var rt = try init(tmpD.dir, true);
    defer rt.deinit();

    const fakeID = 420;
    const badNote = rt.get(fakeID);
    try expect(badNote == sqlite.Error.SQLiteNotFound);

    const now = std.time.microTimestamp();
    const noteID = try rt.create();
    const note1 = try rt.get(noteID);

    try expect(note1.id == 1);
    var buf: [64]u8 = undefined;
    const note1Path = note1.path(&buf);

    try expectEqlStrings("1", note1Path);
    try expect(note1.created - now < 1_000); // Happened in the last millisecond(?)
    try expect(note1.modified - now < 1_000);
    _ = try rt.writeAll(noteID, "norecycle");
    try rt.basedir.access(note1Path, .{ .mode = .read_write });

    const now2 = std.time.microTimestamp();
    const noteID2 = try rt.create();
    _ = try rt.writeAll(noteID2, "norecycle");
    const note2 = try rt.get(noteID2);

    try expect(note2.id == 2);
    const note2Path = note2.path(&buf);
    try expectEqlStrings("2", note2Path);
    try expect(note2.created - now2 < 1_000);
    try expect(note2.modified - now2 < 1_000);
    try rt.basedir.access(note2Path, .{ .mode = .read_write });
}

test "recycle empty note" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var rt = try init(tmpD.dir, true);
    defer rt.deinit();

    const noteID1 = try rt.create();
    const note1 = try rt.get(noteID1);
    const noteID2 = try rt.create();
    const note2 = try rt.get(noteID2);

    try expect(noteID1 == noteID2);
    try expect(note1.modified != note2.modified);
}

const TestError = error{ DirectoryShouldBeEmpty, ExpectedError };
test "cleanup FS on DB failure create" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var rt = try init(tmpD.dir, true);
    rt.deinit();

    // Should throw an error - we de-init the db
    _ = rt.create() catch |err| {
        try expect(err == sqlite.Error.SQLiteMisuse);
        var dirIterator = rt.basedir.iterate();
        while (try dirIterator.next()) |_| {
            // Directory should be empty
            return TestError.DirectoryShouldBeEmpty;
        }
        return;
    };
    return TestError.ExpectedError;
}

test "update DB" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var rt = try init(tmpD.dir, true);
    defer rt.deinit();

    const then = std.time.microTimestamp();
    const noteID = try rt.create();
    var resNote = try rt.get(noteID);
    try expect(resNote.id == 1);
    var buf: [64]u8 = undefined;
    const resPath = resNote.path(&buf);

    try expectEqlStrings("1", resPath);
    try expect(resNote.created - then < 1_000); // Happened in the last millisecond(?)
    try expect(resNote.modified - then < 1_000);

    const now = std.time.microTimestamp();
    try rt.update(resNote);
    resNote = try rt.get(resNote.id);
    try expect(resNote.id == 1);
    try expect(resNote.created - then < 1_000);
    try expect(resNote.modified - now < 1_000);
    try expect(resNote.created < resNote.modified);
}

test "r/w-all note" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var rt = try init(tmpD.dir, true);
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
    var rt = try init(tmpD.dir, true);
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
    var rt = try init(tmpD.dir, true);
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

test "delete empty note on writeAll" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var rt = try init(tmpD.dir, true);
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
    try std.testing.expectError(sqlite.Error.SQLiteNotFound, out);

    var pathbuf: [64]u8 = undefined;
    const path = note.path(&pathbuf);
    const f = tmpD.dir.openFile(path, .{});
    try std.testing.expectError(error.FileNotFound, f);
}

test "search no query" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var rt = try init(tmpD.dir, true);
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

test "search no query orderby modified" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var rt = try init(tmpD.dir, true);
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
    var rt = try init(tmpD.dir, true);
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
    var rt = try init(tmpD.dir, true);
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
    var rt = try init(tmpD.dir, true);
    defer rt.deinit();

    const noteID1 = try rt.create();
    _ = try rt.writeAll(noteID1, "norecycle");
    _ = try rt.create();

    var buffer: [10]c_int = undefined;
    const written = try rt.search("", &buffer, null);
    try expect(written == 1);
    try expect(buffer[0] == @as(c_int, @intCast(noteID1)));
}
