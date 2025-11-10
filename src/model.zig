pub const LATEST_V = 2;
const PATH_MAX = 1000;
const DB_FILENAME = "db.db";
const DB_SETTINGS =
    \\PRAGMA foreign_keys = 1;
;

const NOTE_SCHEMA =
    \\CREATE TABLE IF NOT EXISTS notes (
    \\    id INTEGER PRIMARY KEY,
    \\    created INTEGER,
    \\    modified INTEGER,
    \\    path TEXT
    \\);
;
const GET_COLS = "PRAGMA table_info(notes);";
const SHOW_NOTES = "SELECT * from notes;";
const GET_LAST_ID = "SELECT id FROM notes ORDER BY id DESC LIMIT 1;";
const GET_NOTE = "SELECT id,created,modified,path FROM notes WHERE id = ?;";
const DELETE_NOTE = "DELETE FROM notes WHERE id = ?;";
const EMPTY_NOTE = "SELECT id FROM notes WHERE created = modified LIMIT 1;";
const SEARCH_NO_QUERY =
    \\SELECT id FROM notes WHERE created != modified ORDER BY modified DESC LIMIT ?;
;
const INSERT_NOTE =
    \\INSERT INTO notes(id, created, modified, path) VALUES(?, ?, ?, ?) ;
;
const UPDATE_NOTE =
    \\UPDATE notes SET modified = ? WHERE id = ?;
;

// Making (next|last)_vec_id not a fk because it makes the logic easier - sue me
const VECTOR_SCHEMA =
    \\CREATE TABLE IF NOT EXISTS vectors (
    \\    vector_id INTEGER PRIMARY KEY,
    \\    note_id INTEGER,
    \\    next_vec_id INTEGER,
    \\    last_vec_id INTEGER,
    \\    start_i INTEGER,
    \\    end_i INTEGER,
    \\    FOREIGN KEY(note_id) REFERENCES notes(id)
    \\);
;
const VECTOR_ADD_IDX =
    \\ALTER TABLE vectors ADD COLUMN start_i INTEGER DEFAULT 0;
    \\ALTER TABLE vectors ADD COLUMN end_i INTEGER DEFAULT 0;
;
const GET_COLS_VECTOR = "PRAGMA table_info(vectors);";
const SHOW_VECTOR = "SELECT * from vectors;";
const GET_NOTEID_FROM_VECID = "SELECT note_id FROM vectors WHERE vector_id = ?;";
const DELETE_VEC = "DELETE FROM vectors WHERE vector_id = ?;";
const GET_VECS_FROM_NOTEID =
    \\SELECT vector_id, note_id, next_vec_id, last_vec_id, start_i, end_i
    \\FROM vectors WHERE note_id = ?
    \\ORDER BY start_i;
;
pub const Error = error{ NotFound, BufferTooSmall, NotInitialized };

pub const NoteID = u64;

pub const Note = struct {
    id: NoteID,
    created: i64,
    modified: i64,
    path: []const u8,
};

pub fn genPath(noteID: NoteID, buf: []u8) []const u8 {
    const out = std.fmt.bufPrint(buf, "{d}", .{noteID}) catch |err| {
        std.log.err("Failed to write path of note {d}: {}\n", .{ noteID, err });
        @panic("Failed to write the path of a note!");
    };

    return out;
}

pub const VectorRow = struct {
    vector_id: VectorID,
    note_id: NoteID,
    next_vec_id: ?VectorID = null,
    last_vec_id: ?VectorID = null,
    start_i: usize,
    end_i: usize,

    fn equal(self: VectorRow, other: VectorRow) bool {
        return self.note_id == other.note_id and
            self.vector_id == other.vector_id and
            self.next_vec_id == other.next_vec_id and
            self.last_vec_id == self.last_vec_id and
            self.start_i == other.start_i and
            self.end_i == self.end_i;
    }
};

const VectorIterator = struct {
    stmt: sqlite.StatementType(.{}, GET_VECS_FROM_NOTEID),
    it: Iterator(VectorRow),

    const Self = @This();

    pub fn deinit(self: *Self) void {
        self.stmt.deinit();
    }

    pub fn next(self: *Self) !?VectorRow {
        return self.it.next(.{});
    }
};

const NoteIterator = struct {
    stmt: sqlite.StatementType(.{}, SHOW_NOTES),
    it: Iterator(Note),

    const Self = @This();

    pub fn deinit(self: *Self) void {
        self.stmt.deinit();
    }

    pub fn next(self: *Self, allocator: std.mem.Allocator) !?Note {
        return self.it.nextAlloc(allocator, .{});
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
    ready: bool,
    savepoint: ?sqlite.Savepoint = null,
    saved_next_id: ?NoteID = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, opts: DBOpts) !Self {
        const basedir_path = try opts.basedir.realpathAlloc(allocator, ".");
        defer allocator.free(basedir_path);
        const c_db_path = try std.fs.path.joinZ(allocator, &.{ basedir_path, DB_FILENAME });
        defer allocator.free(c_db_path);

        var we_created = opts.mem;
        if (!opts.mem) {
            _ = opts.basedir.access(DB_FILENAME, .{}) catch {
                we_created = true;
            };
        }

        var db: sqlite.Db = try sqlite.Db.init(.{
            .mode = if (opts.mem) sqlite.Db.Mode.Memory else sqlite.Db.Mode{ .File = c_db_path },
            .open_flags = .{
                .write = true,
                .create = true,
            },
            .threading_mode = .MultiThread,
        });
        if (!we_created) {
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
                .ready = false,
            };
        }

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

        var self: Self = .{
            .allocator = allocator,
            .basedir = opts.basedir,
            .next_id = next_id,
            .db = db,
            .ready = true,
        };
        try self.setVersion(std.fmt.comptimePrint("{d}", .{LATEST_V}));

        return self;
    }
    pub fn deinit(self: *Self) void {
        self.db.deinit();
    }

    pub fn is_ready(self: *Self) bool {
        if (self.ready) return true;
        const v = self.version() catch return false;
        if (v == LATEST_V) {
            self.ready = true;
        }
        return self.ready;
    }

    pub fn version(self: *Self) !u32 {
        if (try self.db.pragma(u32, .{}, "user_version", null)) |v| {
            return v;
        } else {
            std.debug.print("Could not get user version\n", .{});
        }
        unreachable;
    }

    pub fn setVersion(self: *Self, comptime vers: []const u8) !void {
        _ = try self.db.pragma(void, .{}, "user_version", vers);
        return;
    }

    const PathTypeTag = enum { path, id_based };
    const PathType = union(PathTypeTag) {
        /// Path is a string
        path: []const u8,
        /// Path is derived from the ID
        id_based: void,
    };

    pub fn create(self: *Self) !NoteID {
        assert(self.is_ready());
        // Recycle empty notes
        const row = try self.db.one(NoteID, EMPTY_NOTE, .{}, .{});
        if (row) |id| {
            return id;
        }
        const created = std.time.microTimestamp();
        const modified = created;
        return self.import(created, modified, .id_based);
    }

    pub fn import(self: *Self, created: i64, modified: i64, pathOpt: PathType) !NoteID {
        assert(self.is_ready());

        var diags = sqlite.Diagnostics{};
        var stmt = self.db.prepareWithDiags(INSERT_NOTE, .{ .diags = &diags }) catch |err| {
            std.debug.print("unable to prepare statement, got error {}. diagnostics: {s}", .{ err, diags });
            return err;
        };
        defer stmt.deinit();

        var buf: [PATH_MAX]u8 = undefined;
        const path: []const u8 = switch (pathOpt) {
            .path => pathOpt.path,
            .id_based => genPath(self.next_id, &buf),
        };

        const id = self.next_id;
        try stmt.exec(.{}, .{ .id = id, .created = created, .modified = modified, .path = path });

        self.next_id += 1;

        return id;
    }

    pub fn get(self: *Self, id: NoteID, allocator: std.mem.Allocator) !Note {
        assert(self.is_ready());

        var diags = sqlite.Diagnostics{};
        var stmt = self.db.prepareWithDiags(GET_NOTE, .{ .diags = &diags }) catch |err| {
            std.log.err(
                "unable to prepare statement, got error {}. diagnostics: {s}",
                .{ err, diags },
            );
            return err;
        };

        defer stmt.deinit();

        const row = try stmt.oneAlloc(Note, allocator, .{ .diags = &diags }, .{ .id = id });

        if (row) |r| {
            return .{
                .id = r.id,
                .created = r.created,
                .modified = r.modified,
                .path = r.path,
            };
        }
        return Error.NotFound;
    }

    pub fn notes(self: *Self) !NoteIterator {
        assert(self.is_ready());

        var diags = sqlite.Diagnostics{};
        var stmt = self.db.prepareWithDiags(SHOW_NOTES, .{ .diags = &diags }) catch |err| {
            std.log.err("unable to prepare statement, got error {}. diagnostics: {s}", .{ err, diags });
            return err;
        };
        return .{ .stmt = stmt, .it = try stmt.iterator(Note, .{}) };
    }

    pub fn update(self: *Self, noteID: NoteID) !void {
        assert(self.is_ready());

        var diags = sqlite.Diagnostics{};
        var stmt = self.db.prepareWithDiags(UPDATE_NOTE, .{ .diags = &diags }) catch |err| {
            std.log.err(
                "unable to prepare statement, got error {}. diagnostics: {s}",
                .{ err, diags },
            );
            return err;
        };
        defer stmt.deinit();

        const modified = std.time.microTimestamp();
        return stmt.exec(.{}, .{
            .modified = modified,
            .id = noteID,
        });
    }

    pub fn delete(self: *Self, note: Note) !void {
        assert(self.is_ready());

        var diags = sqlite.Diagnostics{};
        var stmt = self.db.prepareWithDiags(DELETE_NOTE, .{ .diags = &diags }) catch |err| {
            std.log.err(
                "unable to prepare statement, got error {}. diagnostics: {s}",
                .{ err, diags },
            );
            return err;
        };
        defer stmt.deinit();

        return stmt.exec(.{}, .{
            .id = note.id,
        });
    }

    pub fn searchNoQuery(self: *Self, buf: []c_int, ignore: ?NoteID) !usize {
        assert(self.is_ready());

        const zone = tracy.beginZone(@src(), .{ .name = "model.zig:searchNoQuery" });
        defer zone.end();

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

    const GET_LAST_VECTOR =
        \\SELECT vector_id, note_id, next_vec_id, last_vec_id, start_i, end_i
        \\FROM vectors WHERE next_vec_id IS NULL AND note_id = ?;
    ;
    const UPDATE_VECTOR = "UPDATE vectors SET next_vec_id = ? WHERE vector_id = ?;";
    const APPEND_VECTOR =
        \\INSERT INTO vectors(vector_id, note_id, next_vec_id, last_vec_id, start_i, end_i)
        \\VALUES(?, ?, ?, ?, ?, ?);
    ;
    pub fn appendVector(
        self: *Self,
        noteID: NoteID,
        vectorID: VectorID,
        start_i: usize,
        end_i: usize,
    ) !void {
        assert(self.is_ready());

        // Get head of list
        const row = try self.db.one(VectorRow, GET_LAST_VECTOR, .{}, .{ .note_id = noteID });
        var prev_head_id: ?VectorID = null;
        if (row) |prev_head| {
            prev_head_id = prev_head.vector_id;
            // Update head
            var diags = sqlite.Diagnostics{};
            var stmt = self.db.prepareWithDiags(UPDATE_VECTOR, .{ .diags = &diags }) catch |err| {
                std.log.err("unable to prepare statement, got error {}. diagnostics: {s}", .{ err, diags });
                return err;
            };
            defer stmt.deinit();
            try stmt.exec(.{}, .{
                .next_vec_id = vectorID,
                .vector_id = prev_head.vector_id,
            });
        }
        // Add new head
        var diags = sqlite.Diagnostics{};
        var stmt = self.db.prepareWithDiags(APPEND_VECTOR, .{ .diags = &diags }) catch |err| {
            std.log.err("unable to prepare statement, got error {}. diagnostics: {s}", .{ err, diags });
            return err;
        };
        defer stmt.deinit();
        try stmt.exec(.{}, .{
            .vector_id = vectorID,
            .note_id = noteID,
            .next_vec_id = null,
            .last_vec_id = prev_head_id,
            .start_i = start_i,
            .end_i = end_i,
        });
    }

    pub fn vecToNote(self: *Self, vectorID: VectorID) !NoteID {
        assert(self.is_ready());

        var diags = sqlite.Diagnostics{};
        const query = GET_NOTEID_FROM_VECID;
        var stmt = self.db.prepareWithDiags(query, .{ .diags = &diags }) catch |err| {
            std.log.err(
                "unable to prepare statement, got error {}. diagnostics: {s}",
                .{ err, diags },
            );
            return err;
        };

        defer stmt.deinit();

        const row = try stmt.one(NoteID, .{}, .{
            .id = vectorID,
        });

        if (row) |id| {
            return id;
        }
        return Error.NotFound;
    }

    pub fn vecsForNote(self: *Self, allocator: std.mem.Allocator, noteID: NoteID) ![]VectorRow {
        assert(self.is_ready());

        var diags = sqlite.Diagnostics{};
        var stmt = self.db.prepareWithDiags(GET_VECS_FROM_NOTEID, .{ .diags = &diags }) catch |err| {
            std.log.err("unable to prepare statement, got error {}. diagnostics: {s}", .{ err, diags });
            return err;
        };
        defer stmt.deinit();

        return try stmt.all(VectorRow, allocator, .{}, .{ .note_id = noteID });
    }

    pub fn deleteVec(self: *Self, vID: VectorID) !void {
        assert(self.is_ready());

        var diags = sqlite.Diagnostics{};
        var stmt = self.db.prepareWithDiags(DELETE_VEC, .{ .diags = &diags }) catch |err| {
            std.log.err("unable to prepare statement, got error {}. diagnostics: {s}", .{ err, diags });
            return err;
        };
        defer stmt.deinit();

        return stmt.exec(.{}, .{ .vector_id = vID });
    }

    pub fn startTX(self: *Self) !void {
        assert(self.savepoint == null);
        assert(self.saved_next_id == null);
        self.savepoint = try self.db.savepoint("TX");
        self.saved_next_id = self.next_id;
        return;
    }

    pub fn commitTX(self: *Self) void {
        assert(self.savepoint != null);
        assert(self.saved_next_id != null);
        self.savepoint.?.commit();
        self.saved_next_id = null;
        self.savepoint = null;
        return;
    }

    pub fn dropTX(self: *Self) void {
        assert(self.savepoint != null);
        assert(self.saved_next_id != null);
        self.savepoint.?.rollback();
        self.next_id = self.saved_next_id.?;
        self.saved_next_id = null;
        self.savepoint = null;
        return;
    }

    pub fn backup(self: *Self) !void {
        var buf: [PATH_MAX]u8 = undefined;
        const backup_name = try std.fmt.bufPrint(
            &buf,
            "{s}.bak.{d}",
            .{ DB_FILENAME, try self.version() },
        );

        var src_f = try self.basedir.openFile(DB_FILENAME, .{ .mode = .read_only });
        defer src_f.close();
        var src = src_f.reader();

        var dest_f = try self.basedir.createFile(backup_name, .{});
        defer dest_f.close();
        var dest = dest_f.writer();

        var buffer: [4096]u8 = undefined;
        while (true) {
            const bytes_read = try src.readAll(buffer[0..]);
            if (bytes_read == 0) break;
            try dest.writeAll(buffer[0..bytes_read]);
        }

        return;
    }

    const Table = enum { Notes, Vectors };

    pub fn debugShowTable(self: *Self, comptime table: Table) void {
        if (!config.debug) return;
        var diags = sqlite.Diagnostics{};
        var stmt = self.db.prepareWithDiags(switch (table) {
            .Notes => SHOW_NOTES,
            .Vectors => SHOW_VECTOR,
        }, .{ .diags = &diags }) catch |err| {
            std.log.err("unable to prepare statement, got error {}. diagnostics: {s}", .{ err, diags });
            return;
        };

        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        switch (table) {
            .Notes => {
                const rows = stmt.all(Note, arena.allocator(), .{}, .{}) catch undefined;
                for (rows) |note| {
                    std.debug.print("{d},{d},{d},{s}\n", note);
                }
            },
            .Vectors => {
                const rows = stmt.all(VectorRow, arena.allocator(), .{}, .{}) catch undefined;
                std.debug.print("{s}, {s}, {s}, {s}\n", .{
                    "vec. ID",
                    "note ID",
                    "next ID",
                    "last ID",
                });
                for (rows) |vector| {
                    std.debug.print("{d: ^7}| {d: ^7}| {d: ^7}| {d: ^7}\n", .{
                        vector.vector_id,
                        vector.note_id,
                        vector.next_vec_id orelse 420,
                        vector.last_vec_id orelse 420,
                    });
                }
            },
        }
    }

    pub fn upgrade_zero(self: *Self) !void {
        try self.setVersion("1");
        return;
    }

    pub fn upgrade_one(self: *Self) !void {
        var stmt = try self.db.prepare(VECTOR_ADD_IDX);
        defer stmt.deinit();
        try stmt.exec(.{}, .{});
        try self.setVersion("2");
        return;
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
        .{ .name = "path", .type = "TEXT" },
    };

    var buffer: [1000]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    const allocator = fba.allocator();

    var i: usize = 0;
    var iter = try stmt.iterator(SchemaRow, .{});
    while (try iter.nextAlloc(allocator, .{})) |row| {
        try expectEqualStrings(expectedSchema[i].name, row.name);
        try expectEqualStrings(expectedSchema[i].type, row.type);
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
        .{ .name = "vector_id", .type = "INTEGER" },
        .{ .name = "note_id", .type = "INTEGER" },
        .{ .name = "next_vec_id", .type = "INTEGER" },
        .{ .name = "last_vec_id", .type = "INTEGER" },
        .{ .name = "start_i", .type = "INTEGER" },
        .{ .name = "end_i", .type = "INTEGER" },
    };

    var buffer: [1000]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    const allocator = fba.allocator();

    var i: usize = 0;
    while (true) {
        const row = (try iter.nextAlloc(allocator, .{})) orelse break;
        try expectEqualStrings(expectedSchema[i].name, row.name);
        try expectEqualStrings(expectedSchema[i].type, row.type);
        i += 1;
    }
    try expect(i == expectedSchema.len);
}

test "re-init DB" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var arena1 = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena1.deinit();

    var db = try DB.init(arena1.allocator(), .{ .basedir = tmpD.dir });

    const id1 = try db.create();
    try db.update(id1);

    db.deinit();
    db = try DB.init(arena1.allocator(), .{ .basedir = tmpD.dir });

    const id2 = try db.create();
    try expect(id2 == id1 + 1);
}

test "id not found" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();
    var db = try DB.init(arena.allocator(), .{ .mem = true, .basedir = tmpD.dir });
    defer db.deinit();

    const fakeID = 420;
    try expectError(Error.NotFound, db.get(fakeID, arena.allocator()));
}

test "recycle empty note" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var db = try DB.init(testing_allocator, .{ .mem = true, .basedir = tmpD.dir });
    defer db.deinit();

    const noteID1 = try db.create();
    const noteID2 = try db.create();

    try expect(noteID1 == noteID2);
}

test "update modified timestamp" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();
    var db = try DB.init(arena.allocator(), .{ .mem = true, .basedir = tmpD.dir });
    defer db.deinit();

    // Get time of creation of first note
    const then = std.time.microTimestamp();

    const noteID = try db.create();
    const resNote = try db.get(noteID, arena.allocator());
    try expect(resNote.id == 1);
    try expect(resNote.created - then < 1_000); // Happened in the last millisecond(?)
    try expect(resNote.modified - then < 1_000);

    const now = std.time.microTimestamp();
    try db.update(noteID);
    const resNote2 = try db.get(resNote.id, arena.allocator());
    try expect(resNote2.id == 1);
    try expect(resNote2.created - then < 1_000);
    try expect(resNote2.modified - now < 1_000);
    try expect(resNote2.created < resNote2.modified);
}

test "appendVector + vec2note simple" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var db = try DB.init(testing_allocator, .{ .mem = true, .basedir = tmpD.dir });
    defer db.deinit();

    const noteID = try db.create();
    try db.appendVector(noteID, 420, 0, 0);
    try db.appendVector(noteID, 69, 0, 0);
    try db.appendVector(noteID, 42, 0, 0);

    try expect(noteID == try db.vecToNote(420));
    try expect(noteID == try db.vecToNote(69));
    try expect(noteID == try db.vecToNote(42));
    // not found case
    try expect(9000 == db.vecToNote(1234) catch 9000);
}

test "appending is consecutive" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var db = try DB.init(testing_allocator, .{ .mem = true, .basedir = tmpD.dir });
    defer db.deinit();

    const noteID = try db.create();
    try db.appendVector(noteID, 1, 0, 2);
    try db.appendVector(noteID, 2, 2, 4);
    try db.appendVector(noteID, 3, 4, 6);

    const want: [3]VectorRow = .{
        .{
            .note_id = noteID,
            .vector_id = 1,
            .next_vec_id = 2,
            .last_vec_id = null,
            .start_i = 0,
            .end_i = 2,
        },
        .{
            .note_id = noteID,
            .vector_id = 2,
            .next_vec_id = 3,
            .last_vec_id = 1,
            .start_i = 2,
            .end_i = 4,
        },
        .{
            .note_id = noteID,
            .vector_id = 3,
            .next_vec_id = null,
            .last_vec_id = 2,
            .start_i = 4,
            .end_i = 6,
        },
    };

    const got = try db.vecsForNote(testing_allocator, noteID);
    defer testing_allocator.free(got);
    try expectEqualSlices(VectorRow, &want, got);
}

test "import note" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();
    var db = try DB.init(arena.allocator(), .{ .mem = true, .basedir = tmpD.dir });
    defer db.deinit();

    const now = std.time.microTimestamp();
    const later = now + 100;
    const noteID = try db.import(now, later, .{ .path = "/foo/bar/path" });

    const note = try db.get(noteID, arena.allocator());
    try expect(note.created == now);
    try expect(note.modified == later);
    try expectEqualStrings(note.path, "/foo/bar/path");
}

test "deleteVec" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var db = try DB.init(testing_allocator, .{ .mem = true, .basedir = tmpD.dir });
    defer db.deinit();

    const noteID = try db.create();
    try db.appendVector(noteID, 1, 0, 0);
    try db.appendVector(noteID, 2, 0, 0);
    try db.appendVector(noteID, 3, 0, 0);

    const vecs = try db.vecsForNote(testing_allocator, noteID);
    defer testing_allocator.free(vecs);
    for (vecs) |row| {
        try db.deleteVec(row.vector_id);
    }

    const vecs_after = try db.vecsForNote(testing_allocator, noteID);
    defer testing_allocator.free(vecs_after);
    try expect(vecs_after.len == 0);
}

test "version" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var db = try DB.init(testing_allocator, .{ .mem = true, .basedir = tmpD.dir });
    defer db.deinit();

    try expectEqual(LATEST_V, db.version());
    try db.setVersion("69420");
    try expectEqual(69420, db.version());
}

test "ready" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var db = try DB.init(testing_allocator, .{ .basedir = tmpD.dir });
    db.deinit();
    db = try DB.init(testing_allocator, .{ .basedir = tmpD.dir });
    try db.setVersion("0");
    db.ready = false;

    try expect(!db.is_ready());
    try db.setVersion(std.fmt.comptimePrint("{d}", .{LATEST_V}));
    try expect(db.is_ready());
    try expect(db.ready);
}

test "transactions" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();
    var db = try DB.init(arena.allocator(), .{ .mem = true, .basedir = tmpD.dir });
    defer db.deinit();

    try db.startTX();
    const noteID = try db.create();
    try db.update(noteID);
    db.commitTX();
    _ = try db.get(noteID, arena.allocator());

    const old_next_id = db.next_id;
    try db.startTX();
    const noteID2 = try db.create();
    try db.update(noteID);
    db.dropTX();
    try expectError(Error.NotFound, db.get(noteID2, arena.allocator()));
    try expectEqual(old_next_id, db.next_id);
}

fn equalData(d: *std.fs.Dir, file_path_1: []const u8, file_path_2: []const u8) !bool {
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();

    const file1 = try d.openFile(file_path_1, .{ .mode = .read_only });
    defer file1.close();
    const file2 = try d.openFile(file_path_2, .{ .mode = .read_only });
    defer file2.close();

    const buffer_size = 4096;
    var buffer1 = try arena.allocator().alloc(u8, buffer_size);
    var buffer2 = try arena.allocator().alloc(u8, buffer_size);

    while (true) {
        const bytes_read1 = try file1.read(buffer1);
        const bytes_read2 = try file2.read(buffer2);

        if (bytes_read1 != bytes_read2) return false;
        if (bytes_read1 == 0) return true;

        if (!std.mem.eql(u8, buffer1[0..bytes_read1], buffer2[0..bytes_read2])) return false;
    }
}

test "backup" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();
    var db = try DB.init(arena.allocator(), .{ .basedir = tmpD.dir });
    defer db.deinit();

    try db.backup();
    var buf: [PATH_MAX]u8 = undefined;
    const backup_name = try std.fmt.bufPrint(
        &buf,
        "{s}.bak.{d}",
        .{ DB_FILENAME, try db.version() },
    );
    try tmpD.dir.access(backup_name, .{});
    try expect(try equalData(&tmpD.dir, DB_FILENAME, backup_name));
}

const std = @import("std");
const assert = std.debug.assert;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectError = std.testing.expectError;
const testing_allocator = std.testing.allocator;
const expectEqualStrings = std.testing.expectEqualStrings;
const expectEqualSlices = std.testing.expectEqualSlices;

const config = @import("config");
const sqlite = @import("sqlite");
const Iterator = sqlite.Iterator;
const tracy = @import("tracy");

const types = @import("types.zig");
const VectorID = types.VectorID;
