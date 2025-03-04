const std = @import("std");

const expect = std.testing.expect;

const Runtime = struct {
    basedir: std.fs.Dir,
    db: std.fs.File,
};

const DB_LOCATION = "./db.db";

pub fn init(b: std.fs.Dir) !Runtime {
    const db = b.createFile(DB_LOCATION, .{ .read = true, .exclusive = true, .mode = 0o600, .truncate = false }) catch |err| switch (err) {
        std.fs.File.OpenError.PathAlreadyExists => try b.openFile(DB_LOCATION, std.fs.File.OpenFlags{ .mode = .read_write }),
        else => {
            return err;
        },
    };
    return Runtime{ .basedir = b, .db = db };
}

test "init DB" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();

    var rt = try init(tmpD.dir);
    try expect(tmpD.dir.fd == rt.basedir.fd);
    _ = try rt.db.stat();

    // Don't recreate db file if exists
    rt.db.close();
    rt = try init(tmpD.dir);
    _ = try rt.db.stat();
}
