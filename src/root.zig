pub const Error = error{ NotFound, BufferTooSmall, MalformedPath, NotNote };

// TODO: this is a hack...
const VECTOR_DB_PATH = "vecs.db";
pub const RuntimeOpts = struct {
    basedir: std.fs.Dir,
    mem: bool = false,
    skipEmbed: bool = false,
};

pub const Runtime = struct {
    basedir: std.fs.Dir,
    db: model.DB,
    vectors: vector.DB,
    embedder: embed.Embedder,
    allocator: std.mem.Allocator,
    skipEmbed: bool = false,

    pub fn init(allocator: std.mem.Allocator, opts: RuntimeOpts) !Runtime {
        const database = try model.DB.init(allocator, .{
            .basedir = opts.basedir,
            .mem = opts.mem,
        });

        const embedder = try embed.Embedder.init(allocator);
        var vectors = try vector.DB.init(allocator, opts.basedir, .{});

        return Runtime{
            .basedir = opts.basedir,
            .db = database,
            .vectors = try vectors.load(VECTOR_DB_PATH),
            .embedder = embedder,
            .allocator = allocator,
            .skipEmbed = opts.skipEmbed,
        };
    }

    pub fn deinit(self: *Runtime) void {
        self.db.deinit();
        self.vectors.deinit();
        self.embedder.deinit();
    }

    pub fn create(self: *Runtime) !NoteID {
        const zone = tracy.beginZone(@src(), .{ .name = "root.zig:create" });
        defer zone.end();

        return self.db.create();
    }

    const ImportOpts = struct {
        copy: bool = false,
    };

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
            try self.embedText(id, buf[0..sz]);
            break;
        }

        return id;
    }

    pub fn get(self: *Runtime, id: NoteID, allocator: std.mem.Allocator) !Note {
        const zone = tracy.beginZone(@src(), .{ .name = "root.zig:get" });
        defer zone.end();

        return self.db.get(id, allocator);
    }

    pub fn update(self: *Runtime, noteID: NoteID) !void {
        const zone = tracy.beginZone(@src(), .{ .name = "root.zig:update" });
        defer zone.end();

        return self.db.update(noteID);
    }

    pub fn delete(self: *Runtime, id: NoteID) !void {
        const zone = tracy.beginZone(@src(), .{ .name = "root.zig:delete" });
        defer zone.end();

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();

        const note = try self.get(id, arena.allocator());

        self.basedir.access(note.path, .{}) catch {
            return self.db.delete(note);
        };
        try self.basedir.deleteFile(note.path);
        return self.db.delete(note);
    }

    pub fn writeAll(self: *Runtime, id: NoteID, content: []const u8) !void {
        const zone = tracy.beginZone(@src(), .{ .name = "root.zig:writeAll" });
        defer zone.end();

        if (content.len == 0) {
            return self.delete(id);
        }

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();

        const note = try self.get(id, arena.allocator());

        const f = try self.basedir.createFile(note.path, .{ .read = true, .truncate = false });
        defer f.close();

        if (try isUnchanged(f, content)) return;

        try f.seekTo(0);
        try f.setEndPos(0);
        try f.writeAll(content);

        // can we flag this to be removed in prod?
        if (self.skipEmbed) {
            try self.update(id);
            return;
        }

        try self.embedText(id, content);
        try self.update(id);

        return;
    }

    fn embedText(self: *Runtime, id: NoteID, content: []const u8) !void {
        const zone = tracy.beginZone(@src(), .{ .name = "root.zig:embedText" });
        defer zone.end();

        var vecs = try self.db.vecsForNote(id);
        defer vecs.deinit();
        while (try vecs.next()) |v| {
            try self.db.deleteVec(v.vector_id);
            try self.vectors.rm(v.vector_id);
        }

        var it = std.mem.splitAny(u8, content, ".!?");
        while (it.next()) |sentence| {
            if (sentence.len < 2) continue;
            const vec = try self.embedder.embed(sentence) orelse continue;
            try self.db.appendVector(id, try self.vectors.put(vec));
            self.db.debugShowTable(.Vectors);
        }

        // be more efficient - don't save all of the vectors on every write
        try self.vectors.save(VECTOR_DB_PATH);
    }

    pub fn readAll(self: *Runtime, id: NoteID, buf: []u8) !usize {
        const zone = tracy.beginZone(@src(), .{ .name = "root.zig:readAll" });
        defer zone.end();

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const note = try self.get(id, arena.allocator());

        const f = self.basedir.openFile(note.path, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                return 0; // Lazy creation
            },
            else => {
                return err;
            },
        };
        defer f.close();

        const n = try f.readAll(buf);

        // Save space for the null-terminator
        if (n >= buf.len - 1) {
            return Error.BufferTooSmall;
        }
        buf[n] = 0;

        return n;
    }

    // Search should query the database and return N written
    // Parameter buf is really an array of NoteIDs. Need to use c_int though
    pub fn search(self: *Runtime, query: []const u8, buf: []c_int, ignore: ?NoteID) !usize {
        const zone = tracy.beginZone(@src(), .{ .name = "root.zig:search" });
        defer zone.end();

        if (query.len == 0) {
            return self.db.searchNoQuery(buf, ignore);
        }

        const query_vec = (try self.embedder.embed(query)) orelse return 0;

        var vec_ids: [1000]VectorID = undefined;

        debugSearchHeader(query);
        const found_n = try self.vectors.search(query_vec, &vec_ids);
        self.debugSearchRankedResults(vec_ids[0..found_n]);

        var unique_found_n: usize = 0;
        outer: for (0..@min(found_n, buf.len)) |i| {
            // TODO: create scoring system for multiple results in one note
            const noteID = @as(c_int, @intCast(try self.db.vecToNote(vec_ids[i])));
            for (0..unique_found_n) |j| {
                if (buf[j] == noteID) continue :outer;
            }
            buf[unique_found_n] = noteID;
            unique_found_n += 1;
        }
        return unique_found_n;
    }

    fn debugSearchHeader(query: []const u8) void {
        if (!config.debug) return;
        std.debug.print("Checking similarity against '{s}':\n", .{query});
    }
    fn debugSearchRankedResults(self: *Runtime, ids: []VectorID) void {
        if (!config.debug) return;
        const bufsz = 50;
        for (ids, 1..) |id, i| {
            var buf: [bufsz]u8 = undefined;
            const noteID = self.db.vecToNote(id) catch unreachable;
            const sz = self.readAll(
                noteID,
                &buf,
            ) catch unreachable;
            if (sz < 0) continue;
            std.debug.print("    {d}. ID({d})'{s}' \n", .{
                i,
                noteID,
                buf[0..@min(sz, bufsz)],
            });
        }
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

const expectError = std.testing.expectError;
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

// TODO: is this unnecessary automatic behavior?
test "delete empty note on empty writeAll" {
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
    var expected = "Some content!";
    try rt.writeAll(noteID, expected[0..]);

    // Should not fail
    const note = try rt.get(noteID, arena.allocator());
    var buffer: [20]u8 = undefined;
    const n = try rt.readAll(noteID, &buffer);
    try std.testing.expectEqualStrings(expected, buffer[0..n]);

    // Now lets clear it out
    const nothing = "";
    try rt.writeAll(noteID, nothing);

    const out = rt.get(noteID, arena.allocator());

    try std.testing.expectError(model.Error.NotFound, out);

    const f = tmpD.dir.openFile(note.path, .{});
    try std.testing.expectError(error.FileNotFound, f);
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

// TODO: do we want to move no-query searching testing to the model file? It's really just a DB op.
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

test "search remove duplicates" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();
    var rt = try Runtime.init(arena.allocator(), .{
        .mem = true,
        .basedir = tmpD.dir,
    });
    defer rt.deinit();

    const noteID1 = try rt.create();
    _ = try rt.writeAll(noteID1, "pizza. pizza. pizza.");

    var buffer: [10]c_int = undefined;
    const n = try rt.search("pizza", &buffer, null);
    try expect(n == 1);
    try expect(buffer[0] == @as(c_int, @intCast(noteID1)));
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

test "embedText hello" {
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

    const text = "hello";
    try rt.embedText(id, text);

    var buf: [1]c_int = undefined;
    const results = try rt.search(text, &buf, null);

    try expect(results == 1);
    try expect(buf[0] == id);
}

test "embedText skip empties" {
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

    const text = "/hello/";
    try rt.embedText(id, text);
}

test "embedText clear previous" {
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

    try rt.embedText(id, "hello");

    var buf: [1]c_int = undefined;
    try expect(try rt.search("hello", &buf, null) == 1);

    try rt.embedText(id, "flatiron");
    try expect(try rt.search("hello", &buf, null) == 0);
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

const std = @import("std");
const OutOfMemory = std.mem.Allocator.Error.OutOfMemory;
const expect = std.testing.expect;
const expectEqlStrings = std.testing.expectEqualStrings;
const assert = std.debug.assert;
const testing_allocator = std.testing.allocator;
const File = std.fs.File;

const tracy = @import("tracy");

const embed = @import("embed.zig");
const model = @import("model.zig");
const vector = @import("vector.zig");
const config = @import("config");
const types = @import("types.zig");
const vec_sz = types.vec_sz;
const vec_type = types.vec_type;
const Vector = types.Vector;
const VectorID = types.VectorID;
const NoteID = model.NoteID;
const Note = model.Note;
