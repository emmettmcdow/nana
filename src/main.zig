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
    \\UPDATE notes SET modified = ?, path = ? WHERE id = ?;
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
    // TODO: get rid of this, not correct.
    arena: std.heap.ArenaAllocator,
    _next_id: NoteID = 0,

    pub fn create(self: *Runtime) !NoteID {
        const created = std.time.microTimestamp();
        const modified = created;

        var buf: [64]u8 = undefined;
        const path = try std.fmt.bufPrint(&buf, "{d}", .{self._next_id});

        var diags = sqlite.Diagnostics{};
        var stmt = self.db.prepareWithDiags(INSERT_NOTE, .{ .diags = &diags }) catch |err| {
            std.log.err("unable to prepare statement, got error {}. diagnostics: {s}", .{ err, diags });
            return err;
        };
        defer stmt.deinit();
        try stmt.exec(.{}, .{
            .id = self._next_id,
            .created = created,
            .modified = modified,
            .path = path,
        });

        const id = self._next_id;
        self._next_id += 1;

        return id;
    }

    pub fn get(self: *Runtime, id: NoteID) !?Note {
        var diags = sqlite.Diagnostics{};
        var stmt = self.db.prepareWithDiags(GET_NOTE, .{ .diags = &diags }) catch |err| {
            std.log.err("unable to prepare statement, got error {}. diagnostics: {s}", .{ err, diags });
            return err;
        };

        defer stmt.deinit();

        const row = try stmt.oneAlloc(Note, self.arena.allocator(), .{}, .{
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
            .path = note.path,
            .id = note.id,
        });
    }

    pub fn deinit(self: *Runtime) void {
        self.arena.deinit();
    }
};

pub fn init(b: std.fs.Dir, mem: bool, allocator: std.mem.Allocator) !Runtime {
    const arena = std.heap.ArenaAllocator.init(allocator);
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
    return Runtime{ .basedir = b, .db = db, .arena = arena };
}

test "init DB" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();

    var rt = try init(tmpD.dir, true, testing_allocator);
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
    while (true) {
        var arena = std.heap.ArenaAllocator.init(testing_allocator);
        defer arena.deinit();

        const row = (try iter.nextAlloc(arena.allocator(), .{})) orelse break;
        try expectEqlStrings(expectedSchema[i].name, row.name);
        try expectEqlStrings(expectedSchema[i].type, row.type);
        i += 1;
    }
}

test "r/w DB" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var rt = try init(tmpD.dir, true, testing_allocator);
    defer rt.deinit();

    const fakeID = 420;
    const note1 = rt.get(fakeID);
    try expect(note1 == sqlite.Error.SQLiteNotFound);

    const now = std.time.microTimestamp();
    const noteID = try rt.create();
    const note2 = try rt.get(noteID);
    if (note2) |resNote| {
        try expect(resNote.id == 0);
        try expectEqlStrings("0", resNote.path);
        try expect(resNote.created - now < 1_000); // Happened in the last 10s
        try expect(resNote.modified - now < 1_000);
    } else {
        try expect(false);
    }

    const now2 = std.time.microTimestamp();
    const noteID3 = try rt.create();
    const note3 = try rt.get(noteID3);
    if (note3) |resNote| {
        try expect(resNote.id == 1);
        try expectEqlStrings("1", resNote.path);
        try expect(resNote.created - now2 < 1_000);
        try expect(resNote.modified - now2 < 1_000);
    } else {
        try expect(false);
    }
}

test "update DB" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var rt = try init(tmpD.dir, true, testing_allocator);
    defer rt.deinit();

    const then = std.time.microTimestamp();
    const noteID = try rt.create();
    const note2 = try rt.get(noteID);
    var note: Note = undefined;
    if (note2) |resNote| {
        try expect(resNote.id == 0);
        try expectEqlStrings("0", resNote.path);
        try expect(resNote.created - then < 1_000); // Happened in the last 10s
        try expect(resNote.modified - then < 1_000);
        note = resNote;
    } else {
        try expect(false);
    }

    note.path = "newPath";
    const now = std.time.microTimestamp();
    try rt.update(note);
    const note3 = try rt.get(note.id);
    if (note3) |resNote| {
        try expect(resNote.id == 0);
        try expectEqlStrings("newPath", resNote.path);
        try expect(resNote.created - then < 1_000);
        try expect(resNote.modified - now < 1_000);
        std.debug.print("{d}, {d}\n", .{ resNote.created, resNote.modified });
        try expect(resNote.created < resNote.modified);
    } else {
        try expect(false);
    }
}
