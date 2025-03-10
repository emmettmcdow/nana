const expect = std.testing.expect;
const expectEqlStrings = std.testing.expectEqualStrings;
const testing_allocator = std.testing.allocator;
const std = @import("std");
const sqlite = @import("sqlite");

// pub const RuntimeGetError = error{NotFound};
const DB_LOCATION = "./db.db";

const GET_NOTE = "SELECT id,created,modified,path FROM notes WHERE id = ?;";

const INSERT_NOTE =
    \\INSERT INTO notes(id, created, modified, path ) VALUES(?, ?, ?, ?) ;
;
const NOTE_SCHEMA =
    \\CREATE TABLE IF NOT EXISTS notes (
    \\    id INTEGER PRIMARY KEY,
    \\    created INTEGER,
    \\    modified INTEGER,
    \\    path TEXT UNIQUE
    \\);
;
const UPDATE_NOTE =
    \\UPDATE notes SET modified = ? WHERE id = ?;
;
const GET_COLS = "PRAGMA table_info(notes);";

const NoteID = u64;
const Note = struct {
    id: NoteID,
    created: i64,
    modified: i64,
    path: []const u8,
};
const SchemaRow = struct {
    id: u8 = 0,
    name: []const u8,
    type: []const u8,
    unk1: u8 = 0,
    unk2: []const u8 = "",
    unk3: u8 = 0,
};

const Runtime = struct {
    basedir: std.fs.Dir,
    db: sqlite.Db,
    _next_id: NoteID = 1,

    pub fn create(self: *Runtime) !NoteID {
        const created = std.time.microTimestamp();
        const modified = created;

        var buf: [64]u8 = undefined;
        const path = try std.fmt.bufPrint(&buf, "{d}", .{self._next_id});

        const file = try self.basedir.createFile(path, .{});
        file.close();

        var diags = sqlite.Diagnostics{};
        var stmt = self.db.prepareWithDiags(INSERT_NOTE, .{ .diags = &diags }) catch |err| {
            std.log.info("unable to prepare statement, got error {}. diagnostics: {s}", .{ err, diags });
            try self.basedir.deleteFile(path);
            return err;
        };
        defer stmt.deinit();
        stmt.exec(.{}, .{
            .id = self._next_id,
            .created = created,
            .modified = modified,
            .path = path,
        }) catch |err| {
            try self.basedir.deleteFile(path);
            return err;
        };

        const id = self._next_id;
        self._next_id += 1;

        return id;
    }

    pub fn get(self: *Runtime, id: NoteID, alloc: std.mem.Allocator) !Note {
        var diags = sqlite.Diagnostics{};
        var stmt = self.db.prepareWithDiags(GET_NOTE, .{ .diags = &diags }) catch |err| {
            std.log.err("unable to prepare statement, got error {}. diagnostics: {s}", .{ err, diags });
            return err;
        };

        defer stmt.deinit();

        const row = try stmt.oneAlloc(Note, alloc, .{}, .{
            .id = id,
        });

        if (row) |r| {
            return Note{ .id = r.id, .created = r.created, .modified = r.modified, .path = r.path };
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
        .{ .name = "path", .type = "TEXT" },
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

test "r/w DB" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var rt = try init(tmpD.dir, true);
    defer rt.deinit();
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();

    const fakeID = 420;
    const badNote = rt.get(fakeID, arena.allocator());
    try expect(badNote == sqlite.Error.SQLiteNotFound);

    const now = std.time.microTimestamp();
    const noteID = try rt.create();
    const note1 = try rt.get(noteID, arena.allocator());

    try expect(note1.id == 0);
    try expectEqlStrings("0", note1.path);
    try expect(note1.created - now < 1_000); // Happened in the last millisecond(?)
    try expect(note1.modified - now < 1_000);
    try rt.basedir.access(note1.path, .{ .mode = .read_write });

    const now2 = std.time.microTimestamp();
    const noteID2 = try rt.create();
    const note2 = try rt.get(noteID2, arena.allocator());

    try expect(note2.id == 1);
    try expectEqlStrings("1", note2.path);
    try expect(note2.created - now2 < 1_000);
    try expect(note2.modified - now2 < 1_000);
    try rt.basedir.access(note2.path, .{ .mode = .read_write });
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
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();

    const then = std.time.microTimestamp();
    const noteID = try rt.create();
    var resNote = try rt.get(noteID, arena.allocator());
    try expect(resNote.id == 0);
    try expectEqlStrings("0", resNote.path);
    try expect(resNote.created - then < 1_000); // Happened in the last millisecond(?)
    try expect(resNote.modified - then < 1_000);
    try rt.basedir.access(resNote.path, .{ .mode = .read_write });

    resNote.path = "newPath";
    const now = std.time.microTimestamp();
    try rt.update(resNote);
    resNote = try rt.get(resNote.id, arena.allocator());
    try expect(resNote.id == 0);
    // Path should be same, shouldn't be able to update
    try expectEqlStrings("0", resNote.path);
    try expect(resNote.created - then < 1_000);
    try expect(resNote.modified - now < 1_000);
    try expect(resNote.created < resNote.modified);
    // Path should be same, shouldn't be able to update
    // try rt.basedir.access(resNote.path, .{ .mode = .read_write });
}
