pub const Error = error{ NotFound, BufferTooSmall, MalformedPath, NotNote, IncoherentDB };

pub const Runtime = struct {
    basedir: std.fs.Dir,
    db: *model.DB,
    vectors: vector.DB,
    markdown: markdown.Markdown,
    allocator: std.mem.Allocator,
    skipEmbed: bool = false,
    lastParsedMD: ?std.ArrayList(u8) = null,

    /// Optional arguments for initializing the libnana runtime.
    pub const Opts = struct {
        /// Storage directory for dbs and notes.
        basedir: std.fs.Dir,
        /// Testing only. Use memory instead of the file-system.
        mem: bool = false,
        /// Testing only. Don't bother embedding when writing.
        skipEmbed: bool = false,
    };

    /// Intializes the libnana runtime.
    pub fn init(allocator: std.mem.Allocator, opts: Runtime.Opts) !Runtime {
        const markdown_parser = markdown.Markdown.init(allocator);

        const db = try allocator.create(model.DB);
        errdefer allocator.destroy(db);
        db.* = try model.DB.init(allocator, .{ .basedir = opts.basedir, .mem = opts.mem });
        var self = Runtime{
            .basedir = opts.basedir,
            .db = db,
            .vectors = try vector.DB.init(allocator, opts.basedir, db),
            .markdown = markdown_parser,
            .allocator = allocator,
            .skipEmbed = opts.skipEmbed,
        };

        try self.migrate();

        var notes = try self.db.notes();
        defer notes.deinit();

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        while (try notes.next(arena.allocator())) |n| {
            const f = self.basedir.openFile(n.path, .{}) catch |e| switch (e) {
                error.FileNotFound => {
                    try self.delete(n.id);
                    continue;
                },
                else => return e,
            };
            defer f.close();
            const stat = try f.stat();
            if (stat.size == 0) try self.delete(n.id);
        }

        return self;
    }

    /// De-initializes the libnana runtime.
    pub fn deinit(self: *Runtime) void {
        self.vectors.deinit();
        self.db.deinit();
        self.allocator.destroy(self.db);
    }

    /// Create a new note.
    /// Does not create a new file. That is done lazily in `write*`. Returns the new note id.
    pub fn create(self: *Runtime) !NoteID {
        const zone = tracy.beginZone(@src(), .{ .name = "root.zig:create" });
        defer zone.end();

        return self.db.create();
    }

    const ImportOpts = struct {
        /// Whether to `copy` the file to the `basedir` or just use the original absolute path
        copy: bool = false,
    };

    /// Create a new note, but use the contents of another file specified by `path`.
    pub fn import(self: *Runtime, path: []const u8, opts: ImportOpts) !NoteID {
        const zone = tracy.beginZone(@src(), .{ .name = "root.zig:import" });
        defer zone.end();

        var f: std.fs.File = undefined;
        if (!opts.copy) {
            f = try self.basedir.openFile(path, .{});
        } else {
            f = try std.fs.openFileAbsolute(path, .{});
        }
        defer f.close();

        var notNote = true;
        for ([_][]const u8{ "md", "txt" }) |ext| {
            if (std.mem.eql(u8, path[path.len - ext.len ..], ext)) {
                notNote = false;
                break;
            }
        }

        const created: i64 = @intCast(@divTrunc((try f.metadata()).created().?, 1000));
        const modified: i64 = @intCast(@divTrunc((try f.metadata()).modified(), 1000));
        if (!opts.copy) {
            if (notNote) return Error.NotNote;
            return self.db.import(created, modified, .{ .path = path });
        }

        const sourceDirPath = std.fs.path.dirname(path) orelse return Error.MalformedPath;
        const sourceName = std.fs.path.basename(path);
        var sourceDir = try std.fs.openDirAbsolute(sourceDirPath, .{});
        defer sourceDir.close();
        try sourceDir.copyFile(sourceName, self.basedir, sourceName, .{});

        if (notNote) return Error.NotNote;
        const id = try self.db.import(created, modified, .{ .path = sourceName });
        if (self.skipEmbed) return id;

        var bufsz: usize = 64;
        var buf = try self.allocator.alloc(u8, bufsz);
        defer self.allocator.free(buf);
        while (true) {
            const sz = self.readAll(id, buf[0..bufsz]) catch |e| switch (e) {
                Error.BufferTooSmall => {
                    bufsz = try std.math.mul(usize, bufsz, 2);
                    if (!self.allocator.resize(buf, bufsz)) return OutOfMemory;
                    continue;
                },
                else => |leftover_err| return leftover_err,
            };
            try self.vectors.embedText(id, "", buf[0..sz]);
            break;
        }

        return id;
    }

    /// Gets metadata about the note specified by `id`.
    pub fn get(self: *Runtime, id: NoteID, allocator: std.mem.Allocator) !Note {
        const zone = tracy.beginZone(@src(), .{ .name = "root.zig:get" });
        defer zone.end();

        return self.db.get(id, allocator);
    }

    /// Touches a note. Updates the `modified` field of a `Note`.
    pub fn update(self: *Runtime, noteID: NoteID) !void {
        const zone = tracy.beginZone(@src(), .{ .name = "root.zig:update" });
        defer zone.end();

        return self.db.update(noteID);
    }

    /// Deletes a note in the db, the vector db, and the filesystem.
    pub fn delete(self: *Runtime, id: NoteID) !void {
        const zone = tracy.beginZone(@src(), .{ .name = "root.zig:delete" });
        defer zone.end();

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();

        const note = try self.get(id, arena.allocator());

        self.basedir.access(note.path, .{}) catch |e| switch (e) {
            error.FileNotFound => return self.db.delete(note),
            else => return e,
        };
        try self.basedir.deleteFile(note.path);
        return self.db.delete(note);
    }

    /// Writes the contents of `content` to the note and updates the embeddings.
    pub fn writeAll(self: *Runtime, id: NoteID, content: []const u8) !void {
        const zone = tracy.beginZone(@src(), .{ .name = "root.zig:writeAll" });
        defer zone.end();

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();

        const note = try self.get(id, arena.allocator());

        const f = try self.basedir.createFile(note.path, .{ .read = true, .truncate = false });
        defer f.close();

        if (try isUnchanged(f, content)) return;

        // Read old contents before truncating
        const stat = try f.stat();
        var old_contents: []u8 = undefined;
        const needs_free = stat.size > 0;
        if (needs_free) {
            old_contents = try self.allocator.alloc(u8, stat.size);
            try f.seekTo(0);
            _ = try f.readAll(old_contents);
        } else {
            old_contents = "";
        }
        defer if (needs_free) self.allocator.free(old_contents);

        try f.seekTo(0);
        try f.setEndPos(0);
        try f.writeAll(content);

        // can we flag this to be removed in prod?
        if (self.skipEmbed) {
            try self.update(id);
            return;
        }

        try self.vectors.embedText(id, old_contents, content);
        try self.update(id);

        return;
    }

    /// Reads all of the contents of the note.
    pub fn readAll(self: *Runtime, id: NoteID, buf: []u8) !usize {
        const zone = tracy.beginZone(@src(), .{ .name = "root.zig:readAll" });
        defer zone.end();
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const note = try self.get(id, arena.allocator());

        return util.readAllZ(self.basedir, note.path, buf);
    }

    /// Search does an embedding vector distance comparison to find the most semantically similar
    /// notes. Takes a `query`, writes to `buf`, and returns the number of results found.
    /// Optionally it can ignore a single `NoteID`. This is so that the current note does not show
    /// up in the search results.
    pub fn search(self: *Runtime, query: []const u8, buf: []c_int, ignore: ?NoteID) !usize {
        const zone = tracy.beginZone(@src(), .{ .name = "root.zig:search" });
        defer zone.end();

        if (query.len == 0) {
            std.log.info("Searching with no query\n", .{});
            return self.db.searchNoQuery(buf, ignore);
        }

        return self.vectors.search(query, buf);
    }

    /// Takes the contents of a note and returns a JSON spec of how it should be formatted.
    pub fn parseMarkdown(self: *Runtime, content: []const u8) ![]const u8 {
        const zone = tracy.beginZone(@src(), .{ .name = "root.zig:parseMarkdown" });
        defer zone.end();

        if (self.lastParsedMD) |ref| ref.deinit();
        self.lastParsedMD = std.ArrayList(u8).init(self.allocator);
        try json.stringify(self.markdown.parse(content), .{}, self.lastParsedMD.?.writer());
        try self.lastParsedMD.?.writer().writeByte(0);
        return self.lastParsedMD.?.items;
    }

    fn migrate(self: *Runtime) !void {
        const from = try self.db.version();
        const to = model.LATEST_V;

        if (from == to) return;
        try self.db.backup();

        try self.db.startTX();
        errdefer self.db.dropTX();

        for (from..to) |v| {
            switch (v) {
                0 => try self.db.upgrade_zero(),
                1 => try self.db.upgrade_one(),
                2 => try self.db.upgrade_two(),
                else => unreachable,
            }
        }

        if (!self.db.integrityCheck()) {
            std.log.err("Relational DB failed integrity check, exiting.", .{});
            return Error.IncoherentDB;
        }

        self.db.commitTX();
        return;
    }
};

fn isUnchanged(f: File, new_content: []const u8) !bool {
    defer f.seekTo(0) catch unreachable;

    const stat = try f.stat();
    if (stat.size != new_content.len) return false;

    var reader = f.reader();

    var i: usize = 0;
    while (true) : (i += 1) {
        const c = reader.readByte() catch |err| switch (err) {
            error.EndOfStream => return true,
            else => return err,
        };
        if (new_content[i] != c) return false;
    }

    return true;
}

test "no create on read" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();
    var rt = try Runtime.init(arena.allocator(), .{
        .mem = true,
        .basedir = tmpD.dir,
        .skipEmbed = true,
    });
    defer rt.deinit();

    const nid1 = try rt.create();
    const n1 = try rt.get(nid1, arena.allocator());
    try expectError(error.FileNotFound, rt.basedir.access(n1.path, .{ .mode = .read_write }));

    var buf: [1000]u8 = undefined;
    const sz = try rt.readAll(nid1, &buf);
    try expect(sz == 0);
    try expectError(error.FileNotFound, rt.basedir.access(n1.path, .{ .mode = .read_write }));
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
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();
    var rt = try Runtime.init(arena.allocator(), .{
        .mem = true,
        .basedir = tmpD.dir,
        .skipEmbed = true,
    });
    defer rt.deinit();

    const noteID = try rt.create();
    try expect(try _test_empty_dir_exclude_db(rt.basedir));

    _ = try rt.writeAll(noteID, "norecycle");
    try expect(!try _test_empty_dir_exclude_db(rt.basedir));
}

test "modify on write" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();
    var rt = try Runtime.init(arena.allocator(), .{
        .mem = true,
        .basedir = tmpD.dir,
        .skipEmbed = true,
    });
    defer rt.deinit();

    const noteID = try rt.create();
    const n1 = try rt.get(noteID, arena.allocator());
    try expect(n1.created == n1.modified);

    var expected = "Contents of a note!";
    try rt.writeAll(noteID, expected[0..]);
    const n2 = try rt.get(noteID, arena.allocator());
    try expect(n2.created != n2.modified);
}

test "readAll null-term" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();
    var rt = try Runtime.init(arena.allocator(), .{
        .mem = true,
        .basedir = tmpD.dir,
        .skipEmbed = true,
    });
    defer rt.deinit();

    const noteID = try rt.create();
    try rt.writeAll(noteID, "1234");

    var buf: [20]u8 = [_]u8{'1'} ** 20;
    _ = try rt.readAll(noteID, &buf);
    assert(buf[3] == '4');
    assert(buf[4] == 0);
}

test "no modify on read" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();
    var rt = try Runtime.init(arena.allocator(), .{
        .mem = true,
        .basedir = tmpD.dir,
        .skipEmbed = true,
    });
    defer rt.deinit();

    const noteID = try rt.create();
    const n1 = try rt.get(noteID, arena.allocator());
    try expect(n1.created == n1.modified);

    var buf: [20]u8 = undefined;
    _ = try rt.readAll(noteID, &buf);
    const n2 = try rt.get(noteID, arena.allocator());
    try expect(n2.created == n2.modified);
}

test "no modify on search" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();
    var rt = try Runtime.init(arena.allocator(), .{
        .mem = true,
        .basedir = tmpD.dir,
        .skipEmbed = true,
    });
    defer rt.deinit();

    const noteID = try rt.create();
    const n1 = try rt.get(noteID, arena.allocator());
    try expect(n1.created == n1.modified);

    var buf2: [20]c_int = undefined;
    _ = try rt.search("", &buf2, 420);
    const n2 = try rt.get(noteID, arena.allocator());
    try expect(n2.created == n2.modified);
}

test "r/w-all note" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();
    var rt = try Runtime.init(arena.allocator(), .{
        .mem = true,
        .basedir = tmpD.dir,
        .skipEmbed = true,
    });
    defer rt.deinit();

    const noteID = try rt.create();

    var expected = "Contents of a note!";
    try rt.writeAll(noteID, expected[0..]);

    var buffer: [21]u8 = undefined;
    const n = try rt.readAll(noteID, &buffer);

    try std.testing.expectEqualStrings(expected, buffer[0..n]);
}

test "r/w-all updated time" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();
    var rt = try Runtime.init(arena.allocator(), .{
        .mem = true,
        .basedir = tmpD.dir,
        .skipEmbed = true,
    });
    defer rt.deinit();

    const noteID = try rt.create();
    const oldNote = try rt.get(noteID, arena.allocator());

    var expected = "Contents of a note!";
    try rt.writeAll(noteID, expected[0..]);

    const newNote = try rt.get(noteID, arena.allocator());

    try expect(newNote.modified > oldNote.modified);
}

test "r/w-all too smol output buffer" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();
    var rt = try Runtime.init(arena.allocator(), .{
        .mem = true,
        .basedir = tmpD.dir,
        .skipEmbed = true,
    });
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

test "delete only if exists" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();
    var rt = try Runtime.init(arena.allocator(), .{
        .mem = true,
        .basedir = tmpD.dir,
        .skipEmbed = true,
    });
    defer rt.deinit();

    const noteID = try rt.create();
    try rt.delete(noteID);
}

test "search no query" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();
    var rt = try Runtime.init(arena.allocator(), .{
        .mem = true,
        .basedir = tmpD.dir,
        .skipEmbed = true,
    });
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
        try expect(buffer[8 - i] == @as(c_int, @intCast(i + 1)));
    }
}

test "search no query orderby modified" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();
    var rt = try Runtime.init(arena.allocator(), .{
        .mem = true,
        .basedir = tmpD.dir,
        .skipEmbed = true,
    });
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

    try rt.update(noteID1);

    var buffer2: [10]c_int = undefined;
    const written2 = try rt.search("", &buffer2, null);
    try expect(written2 == 2);
    try expect(buffer2[0] == @as(c_int, @intCast(noteID1)));
    try expect(buffer2[1] == @as(c_int, @intCast(noteID2)));
}

test "exclude param 'empty search'" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();
    var rt = try Runtime.init(arena.allocator(), .{
        .mem = true,
        .basedir = tmpD.dir,
        .skipEmbed = true,
    });
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
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();
    var rt = try Runtime.init(arena.allocator(), .{
        .mem = true,
        .basedir = tmpD.dir,
        .skipEmbed = true,
    });
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
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();
    var rt = try Runtime.init(arena.allocator(), .{
        .mem = true,
        .basedir = tmpD.dir,
        .skipEmbed = true,
    });
    defer rt.deinit();

    const noteID1 = try rt.create();
    _ = try rt.writeAll(noteID1, "norecycle");
    _ = try rt.create();

    var buffer: [10]c_int = undefined;
    const written = try rt.search("", &buffer, null);
    try expect(written == 1);
    try expect(buffer[0] == @as(c_int, @intCast(noteID1)));
}

test "import" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();
    var rt = try Runtime.init(arena.allocator(), .{
        .mem = true,
        .basedir = tmpD.dir,
        .skipEmbed = true,
    });
    defer rt.deinit();

    const path = "somefile.txt";
    var f = try tmpD.dir.createFile(path, .{});
    f.close();

    var f2 = try tmpD.dir.openFile(path, .{ .mode = .write_only });
    try f2.writeAll("Something!");
    const created: i64 = @intCast(@divTrunc((try f2.metadata()).created().?, 1000));
    const modified: i64 = @intCast(@divTrunc((try f2.metadata()).modified(), 1000));
    f2.close();

    const id = try rt.import(path, .{});
    const note = try rt.get(id, arena.allocator());

    try expect(note.created == created);
    try expect(note.modified == modified);
    try expectEqlStrings(note.path, path);
}

test "import copy" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();
    var rt = try Runtime.init(arena.allocator(), .{
        .mem = true,
        .basedir = tmpD.dir,
        .skipEmbed = true,
    });
    defer rt.deinit();

    const path = "/tmp/something.txt";
    var f = try std.fs.createFileAbsolute(path, .{});
    f.close();

    var f2 = try std.fs.openFileAbsolute(path, .{ .mode = .write_only });
    try f2.writeAll("Something!");
    const created: i64 = @intCast(@divTrunc((try f2.metadata()).created().?, 1000));
    const modified: i64 = @intCast(@divTrunc((try f2.metadata()).modified(), 1000));
    f2.close();

    const id = try rt.import(path, .{ .copy = true });
    try std.fs.deleteFileAbsolute(path);
    const note = try rt.get(id, arena.allocator());

    try expect(note.created == created);
    try expect(note.modified == modified);
    try expectEqlStrings(note.path, std.fs.path.basename(path));
}

test "import run embedding" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();
    var rt = try Runtime.init(arena.allocator(), .{
        .mem = true,
        .basedir = tmpD.dir,
    });
    defer rt.deinit();

    const path = "/tmp/something.txt";
    var f = try std.fs.createFileAbsolute(path, .{});
    defer f.close();
    try f.writeAll("hello");

    const id = try rt.import(path, .{ .copy = true });

    var buf: [1]c_int = undefined;
    const results = try rt.search("hello", &buf, null);

    try expect(results == 1);
    try expect(buf[0] == id);
}

test "import skip unrecognized file extensions" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();
    var rt = try Runtime.init(arena.allocator(), .{
        .mem = true,
        .basedir = tmpD.dir,
        .skipEmbed = true,
    });
    defer rt.deinit();

    const png = "/tmp/something.png";
    var f = try std.fs.createFileAbsolute(png, .{});
    try f.writeAll("something");
    f.close();
    const tar = "/tmp/something.tar";
    f = try std.fs.createFileAbsolute(tar, .{});
    try f.writeAll("something");
    f.close();
    const pdf = "/tmp/something.pdf";
    f = try std.fs.createFileAbsolute(pdf, .{});
    try f.writeAll("something");
    f.close();

    const txt = "/tmp/something.txt";
    f = try std.fs.createFileAbsolute(txt, .{});
    try f.writeAll("something");
    f.close();
    const md = "/tmp/something.md";
    f = try std.fs.createFileAbsolute(md, .{});
    try f.writeAll("something");
    f.close();

    for ([2][]const u8{ txt, md }) |path| {
        _ = try rt.import(path, .{ .copy = true });
        f = try tmpD.dir.openFile(std.fs.path.basename(path), .{});
        f.close();
    }
    for ([3][]const u8{ png, tar, pdf }) |path| {
        try expectError(Error.NotNote, rt.import(path, .{ .copy = true }));
        f = try tmpD.dir.openFile(std.fs.path.basename(path), .{});
        f.close();
    }
}

test "writeAll unchanged" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();
    var rt = try Runtime.init(arena.allocator(), .{
        .mem = true,
        .basedir = tmpD.dir,
    });
    defer rt.deinit();

    const id = try rt.create();
    _ = try rt.writeAll(id, "hello");
    const note_before = try rt.get(id, arena.allocator());
    _ = try rt.writeAll(id, "hello");
    const note_after = try rt.get(id, arena.allocator());

    try expect(note_before.modified == note_after.modified);
}

test "clear empties upon init" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    var rt = try Runtime.init(arena.allocator(), .{
        .basedir = tmpD.dir,
    });

    _ = try rt.writeAll(try rt.create(), "present");
    const id = try rt.create();
    _ = try rt.writeAll(id, "hello");
    _ = try rt.writeAll(id, "");
    _ = try rt.writeAll(try rt.create(), "present");

    rt.deinit();
    arena.deinit();

    var arena2 = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena2.deinit();
    var rt2 = try Runtime.init(arena2.allocator(), .{
        .basedir = tmpD.dir,
    });
    defer rt2.deinit();

    try expect(rt2.writeAll(id, "this should fail") == model.Error.NotFound);
}

test "parse markdown" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();
    var rt = try Runtime.init(arena.allocator(), .{
        .basedir = tmpD.dir,
    });
    defer rt.deinit();

    try expectEqlStrings(
        "[{\"tType\":\"PLAIN\",\"startI\":0,\"endI\":3,\"contents\":\"foo\",\"degree\":1}]\x00",
        try rt.parseMarkdown("foo"),
    );
    try expectEqlStrings(
        "[{\"tType\":\"BOLD\",\"startI\":0,\"endI\":7,\"contents\":\"**foo**\",\"degree\":1}]\x00",
        try rt.parseMarkdown("**foo**"),
    );
    try expectEqlStrings(
        "[{\"tType\":\"PLAIN\",\"startI\":0,\"endI\":1,\"contents\":\"a\",\"degree\":1},{\"tType\":\"BOLD\",\"startI\":1,\"endI\":6,\"contents\":\"**b**\",\"degree\":1}]\x00",
        try rt.parseMarkdown("a**b**"),
    );
}

const std = @import("std");
const assert = std.debug.assert;
const expect = std.testing.expect;
const expectEqlStrings = std.testing.expectEqualStrings;
const File = std.fs.File;
const json = std.json;
const OutOfMemory = std.mem.Allocator.Error.OutOfMemory;
const testing_allocator = std.testing.allocator;
const expectError = std.testing.expectError;

const tracy = @import("tracy");

const markdown = @import("markdown.zig");
const model = @import("model.zig");
const Note = model.Note;
const NoteID = model.NoteID;
const types = @import("types.zig");
const vec_sz = types.vec_sz;
const vec_type = types.vec_type;
const Vector = types.Vector;
const VectorID = types.VectorID;
const util = @import("util.zig");
const vector = @import("vector.zig");
