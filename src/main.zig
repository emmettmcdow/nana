const expect = std.testing.expect;
const expectEqlStrings = std.testing.expectEqualStrings;
const testing_allocator = std.testing.allocator;
const std = @import("std");
const sqlite = @import("sqlite");

// pub const RuntimeGetError = error{NotFound};

const GET_NOTE =
    \\SELECT id,created,modified,path,content FROM notes WHERE id = ?;
;

const INSERT_NOTE =
    \\INSERT INTO notes(id, created, modified, path, content) VALUES(?, ?, ?, ?, ?) ;
;
const Runtime = struct {
    basedir: std.fs.Dir,
    db: sqlite.Db,
    arena: std.heap.ArenaAllocator,
    _next_id: NoteID = 0,

    pub fn create(self: *Runtime) !NoteID {
        const created = std.time.timestamp();
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
            .content = "",
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
            return Note{ .id = r.id, .created = r.created, .modified = r.modified, .path = r.path, .content = r.content };
        } else {
            return sqlite.Error.SQLiteNotFound;
        }
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

const DB_LOCATION = "./db.db";
const NOTE_SCHEMA =
    \\CREATE TABLE IF NOT EXISTS notes (
    \\    id INTEGER PRIMARY KEY,
    \\    created INTEGER,
    \\    modified INTEGER,
    \\    path TEXT UNIQUE,
    \\    content TEXT
    \\);
;
const GET_COLS = "PRAGMA table_info(notes);";

const NoteID = u64;
const Note = struct {
    id: NoteID,
    created: u32,
    modified: u32,
    path: []const u8,
    content: []const u8,
};

const SchemaRow = struct {
    id: u8 = 0,
    name: []const u8,
    type: []const u8,
    unk1: u8 = 0,
    unk2: []const u8 = "",
    unk3: u8 = 0,
};

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
        .{ .name = "content", .type = "TEXT" },
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

    const now = std.time.timestamp();
    const noteID = try rt.create();
    const note2 = try rt.get(noteID);
    if (note2) |note3| {
        try expect(note3.id == 0);
        expectEqlStrings("0", note3.path) catch |err| {
            std.debug.print("Path: wanted {s}, got {s}\n", .{ "0", note3.path });
            return err;
        };
        try expect(note3.created - now < 10);
        try expect(note3.modified - now < 10);
    } else {
        try expect(false);
    }
}
