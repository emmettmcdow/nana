const expect = std.testing.expect;
const testing_allocator = std.testing.allocator;
const std = @import("std");
const sqlite = @import("sqlite");

const Runtime = struct {
    basedir: std.fs.Dir,
    db: sqlite.Db,
};

const DB_LOCATION = "./db.db";
const SCHEMA =
    \\CREATE TABLE IF NOT EXISTS notes (
    \\    id INTEGER PRIMARY KEY,
    \\    created INTEGER,
    \\    modified INTEGER,
    \\    path TEXT UNIQUE,
    \\    content TEXT
    \\);
;

pub fn init(b: std.fs.Dir) !Runtime {
    var db = try sqlite.Db.init(.{
        .mode = sqlite.Db.Mode{ .File = DB_LOCATION },
        .open_flags = .{
            .write = true,
            .create = true,
        },
        .threading_mode = .MultiThread,
    });
    var stmt = try db.prepare(SCHEMA);
    defer stmt.deinit();
    try stmt.exec(.{}, .{});
    return Runtime{ .basedir = b, .db = db };
}

const GET_COLS = "PRAGMA table_info(notes);";
test "init DB" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();

    var rt = try init(tmpD.dir);
    // Check if initialized
    var stmt = try rt.db.prepare(GET_COLS);
    defer stmt.deinit();

    var iter = try stmt.iterator(struct {
        id: u8,
        name: []u8,
        type: []u8,
        unk1: u8,
        unk2: []u8,
        unk3: u8,
    }, .{});

    while (true) {
        var arena = std.heap.ArenaAllocator.init(testing_allocator);
        defer arena.deinit();

        const row = (try iter.nextAlloc(arena.allocator(), .{})) orelse break;
        std.debug.print("{s} {s}\n", .{ row.name, row.type });
    }

    // // Don't recreate db file if exists
    // rt.db.close();
    // rt = try init(tmpD.dir);
    // _ = try rt.db.stat();
}
