const std = @import("std");
const sqlite = @import("sqlite");

const types = @import("types.zig");
const VectorID = types.VectorID;

const DB_LOCATION = "./db.db";

const GET_LAST_ID = "SELECT id FROM notes ORDER BY id DESC LIMIT 1;";

const GET_NOTE = "SELECT id,created,modified FROM notes WHERE id = ?;";

const INSERT_NOTE =
    \\INSERT INTO notes(id, created, modified ) VALUES(?, ?, ?) ;
;

const DB_SETTINGS =
    \\PRAGMA foreign_keys = 1;
;

const NOTE_SCHEMA =
    \\CREATE TABLE IF NOT EXISTS notes (
    \\    id INTEGER PRIMARY KEY,
    \\    created INTEGER,
    \\    modified INTEGER
    \\);
;

const VECTOR_SCHEMA =
    \\CREATE TABLE IF NOT EXISTS vectors (
    \\    note_id INTEGER,
    \\    vector_id INTEGER,
    \\    next_vec_id INTEGER,
    \\    last_vec_id INTEGER,
    \\    FOREIGN KEY(note_id) REFERENCES notes(id)
    \\    FOREIGN KEY(next_vec_id) REFERENCES vectors(rowid),
    \\    FOREIGN KEY(last_vec_id) REFERENCES vectors(rowid)
    \\);
;

const UPDATE_NOTE =
    \\UPDATE notes SET modified = ? WHERE id = ?;
;

const GET_COLS_VECTOR = "PRAGMA table_info(vectors);";
const GET_COLS = "PRAGMA table_info(notes);";

const DELETE_NOTE = "DELETE FROM notes WHERE id = ?;";

const EMPTY_NOTE = "SELECT id FROM notes WHERE created = modified LIMIT 1;";

const SEARCH_NO_QUERY = "SELECT id FROM notes WHERE created != modified ORDER BY modified DESC LIMIT ?;";

pub const Error = error{ NotFound, BufferTooSmall, NotInitialized };

pub const NoteID = u64;
pub const Note = struct {
    id: NoteID,
    created: i64,
    modified: i64,

    pub fn path(self: Note, buf: []u8) []const u8 {
        const out = std.fmt.bufPrint(buf, "{d}", .{self.id}) catch |err| {
            std.log.err("Failed to write path of note {d}: {}\n", .{ self.id, err });
            @panic("Failed to write the path of a note!");
        };

        return out;
    }
};

pub const DBOpts = struct {
    basedir: std.fs.Dir,
    mem: bool = false,
};

pub const DB = struct {
    db: sqlite.Db,
    basedir: std.fs.Dir,
    next_id: NoteID,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, opts: DBOpts) !Self {
        var db: sqlite.Db = try sqlite.Db.init(.{
            .mode = if (opts.mem) sqlite.Db.Mode.Memory else sqlite.Db.Mode{ .File = DB_LOCATION },
            .open_flags = .{
                .write = true,
                .create = true,
            },
            .threading_mode = .MultiThread,
        });
        var stmt = try db.prepare(DB_SETTINGS);
        defer stmt.deinit();
        try stmt.exec(.{}, .{});

        var stmt1 = try db.prepare(NOTE_SCHEMA);
        defer stmt1.deinit();
        try stmt1.exec(.{}, .{});

        var stmt2 = try db.prepare(VECTOR_SCHEMA);
        defer stmt2.deinit();
        try stmt2.exec(.{}, .{});

        var next_id: usize = 1;
        const row = try db.one(NoteID, GET_LAST_ID, .{}, .{});
        if (row) |id| {
            next_id = id + 1;
        }
        return .{
            .allocator = allocator,
            .basedir = opts.basedir,
            .next_id = next_id,
            .db = db,
        };
    }
    pub fn deinit(self: *Self) void {
        self.db.deinit();
    }
    pub fn create(self: *Self) !NoteID {
        // Recycle empty notes
        const row = try self.db.one(NoteID, EMPTY_NOTE, .{}, .{});
        if (row) |id| {
            const note = try self.get(id);
            try self.update(note);
            return id;
        }

        const created = std.time.microTimestamp();
        const note = Note{ .id = self.next_id, .created = created, .modified = created };

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

        self.next_id += 1;

        return note.id;
    }
    pub fn get(self: *Self, id: NoteID) !Note {
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
        }
        return Error.NotFound;
    }

    pub fn update(self: *Self, note: Note) !void {
        var diags = sqlite.Diagnostics{};
        var stmt = self.db.prepareWithDiags(UPDATE_NOTE, .{ .diags = &diags }) catch |err| {
            std.log.err("unable to prepare statement, got error {}. diagnostics: {s}", .{ err, diags });
            return err;
        };
        defer stmt.deinit();

        const modified = std.time.microTimestamp();
        return stmt.exec(.{}, .{
            .modified = modified,
            .id = note.id,
        });
    }
    pub fn delete(self: *Self, note: Note) !void {
        var diags = sqlite.Diagnostics{};
        var stmt = self.db.prepareWithDiags(DELETE_NOTE, .{ .diags = &diags }) catch |err| {
            std.log.err("unable to prepare statement, got error {}. diagnostics: {s}", .{ err, diags });
            return err;
        };
        defer stmt.deinit();

        return stmt.exec(.{}, .{
            .id = note.id,
        });
    }

    pub fn searchNoQuery(self: *Self, buf: []c_int, ignore: ?NoteID) !usize {
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

    pub fn appendVector(self: *Self, nodeID: NoteID, vectorID: VectorID) !void {
        _ = self;
        _ = nodeID;
        _ = vectorID;
    }

    pub fn vecToNote(self: *Self, vectorID: VectorID) !?NoteID {
        _ = self;
        _ = vectorID;

        return null;
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

const expect = std.testing.expect;
const expectError = std.testing.expectError;
const testing_allocator = std.testing.allocator;
const expectEqlStrings = std.testing.expectEqualStrings;

test "init DB - notes" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();

    var db = try DB.init(testing_allocator, .{ .mem = true, .basedir = tmpD.dir });
    defer db.deinit();
    // Check if initialized
    var stmt = try db.db.prepare(GET_COLS);
    defer stmt.deinit();

    const expectedSchema = [_]SchemaRow{
        .{ .name = "id", .type = "INTEGER" },
        .{ .name = "created", .type = "INTEGER" },
        .{ .name = "modified", .type = "INTEGER" },
    };

    var buffer: [1000]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    const allocator = fba.allocator();

    var i: usize = 0;
    var iter = try stmt.iterator(SchemaRow, .{});
    while (try iter.nextAlloc(allocator, .{})) |row| {
        try expectEqlStrings(expectedSchema[i].name, row.name);
        try expectEqlStrings(expectedSchema[i].type, row.type);
        i += 1;
    }
    try expect(i == expectedSchema.len);
}

test "init DB - vector" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var db = try DB.init(testing_allocator, .{ .mem = true, .basedir = tmpD.dir });
    defer db.deinit();

    // Check if initialized
    var stmt = try db.db.prepare(GET_COLS_VECTOR);
    defer stmt.deinit();

    var iter = try stmt.iterator(SchemaRow, .{});

    const expectedSchema = [_]SchemaRow{
        .{ .name = "note_id", .type = "INTEGER" },
        .{ .name = "vector_id", .type = "INTEGER" },
        .{ .name = "next_vec_id", .type = "INTEGER" },
        .{ .name = "last_vec_id", .type = "INTEGER" },
    };

    var buffer: [1000]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    const allocator = fba.allocator();

    var i: usize = 0;
    while (true) {
        const row = (try iter.nextAlloc(allocator, .{})) orelse break;
        try expectEqlStrings(expectedSchema[i].name, row.name);
        try expectEqlStrings(expectedSchema[i].type, row.type);
        i += 1;
    }
    try expect(i == expectedSchema.len);
}

test "re-init DB" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var arena1 = std.heap.ArenaAllocator.init(testing_allocator);

    const cwd = std.fs.cwd();
    // TODO: fix this - sqlite library can't curently use tmpD... ugh
    _ = cwd.deleteFile("db.db") catch void; // Start fresh!
    defer _ = cwd.deleteFile("db.db") catch void; // Leave no trace!

    var db = try DB.init(arena1.allocator(), .{ .basedir = tmpD.parent_dir });

    const id1 = try db.create();
    const note1 = try db.get(id1);
    try db.update(note1);

    db.deinit();
    db = try DB.init(arena1.allocator(), .{ .basedir = tmpD.parent_dir });
    arena1.deinit();

    const id2 = try db.create();
    try expect(id2 == id1 + 1);
}

test "id not found" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var db = try DB.init(testing_allocator, .{ .mem = true, .basedir = tmpD.dir });
    defer db.deinit();

    const fakeID = 420;
    try expectError(Error.NotFound, db.get(fakeID));
}

test "recycle empty note" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var db = try DB.init(testing_allocator, .{ .mem = true, .basedir = tmpD.dir });
    defer db.deinit();

    const noteID1 = try db.create();
    const note1 = try db.get(noteID1);
    const noteID2 = try db.create();
    const note2 = try db.get(noteID2);

    try expect(noteID1 == noteID2);
    try expect(note1.modified != note2.modified);
}

test "update modified timestamp" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var db = try DB.init(testing_allocator, .{ .mem = true, .basedir = tmpD.dir });
    defer db.deinit();

    // Get time of creation of first note
    const then = std.time.microTimestamp();

    const noteID = try db.create();
    var resNote = try db.get(noteID);
    try expect(resNote.id == 1);
    try expect(resNote.created - then < 1_000); // Happened in the last millisecond(?)
    try expect(resNote.modified - then < 1_000);

    const now = std.time.microTimestamp();
    try db.update(resNote);
    resNote = try db.get(resNote.id);
    try expect(resNote.id == 1);
    try expect(resNote.created - then < 1_000);
    try expect(resNote.modified - now < 1_000);
    try expect(resNote.created < resNote.modified);
}
