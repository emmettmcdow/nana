pub const Error = error{ NotFound, BufferTooSmall, MalformedPath, NotNote, IncoherentDB };

pub const TITLE_BUF_LEN = 64;
pub const ELLIPSIS_LEN = 3;
pub const TITLE_LEN = TITLE_BUF_LEN - ELLIPSIS_LEN;

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

    /// Create a new note, but use the contents of another file specified by `path`.
    /// Overall rules:
    ///    - If it has a note extension, import it as a note.
    ///    - If it does not have a note extension, do not add as a note. Just make sure it is in
    ///      the basedir, copy if necessary.
    ///    - Never accept .db extension, this is a critical failure.
    ///    - Modify the name if:
    ///      - It matches the auto-generated id names (e.g. 123.md)
    ///      - There is a collision
    ///    - Only embed if we import as a note. Otherwise skip embedding.
    ///    - If we see an absolute path, we copy in. If it is relative, assert it is present in the
    ///      basedir.
    ///    - Use transactions. If there is a failure to import, we want to clean up our work in
    ///      both the relational DB and the vector DB.
    ///    - TOD_O: we want to re-write notes which point to external assets(images, etc). Their
    ///      paths should be updated to point to their relative paths. Do not implement this yet.
    ///      This needs to be done carefully.
    ///
    pub fn import(self: *Runtime, path: []const u8, destPathBuf: ?[]u8) !?NoteID {
        const zone = tracy.beginZone(@src(), .{ .name = "root.zig:import" });
        defer zone.end();

        const sourceName = std.fs.path.basename(path);
        const isAbsolute = std.fs.path.isAbsolute(path);

        if (hasDbExtension(sourceName)) return Error.NotNote;
        if (shouldIgnoreFile(sourceName)) return Error.NotNote;

        const isNote = hasNoteExtension(sourceName);

        // 1. Open the source file
        var f: std.fs.File = undefined;
        if (isAbsolute) {
            f = try std.fs.openFileAbsolute(path, .{});
        } else {
            f = try self.basedir.openFile(path, .{});
        }
        defer f.close();

        // 2. Read the metadata
        const created: i64 = @intCast(@divTrunc((try f.metadata()).created().?, 1000));
        const modified: i64 = @intCast(@divTrunc((try f.metadata()).modified(), 1000));

        // 3. Compute destination name (rename if matches auto-generated id pattern or collision)
        var destBuf: [PATH_MAX]u8 = undefined;
        const needsUnderscore = allNums(sourceName);
        var destName = if (needsUnderscore) blk: {
            if (sourceName.len + 1 >= PATH_MAX) return Error.MalformedPath;
            break :blk try std.fmt.bufPrint(&destBuf, "_{s}", .{sourceName});
        } else sourceName;

        // Handle collision: if file already exists in basedir, prefix with underscore
        if (isAbsolute) {
            var collisionBuf: [PATH_MAX]u8 = undefined;
            while (self.basedir.access(destName, .{})) |_| {
                if (destName.len + 1 >= PATH_MAX) return Error.MalformedPath;
                destName = try std.fmt.bufPrint(&collisionBuf, "_{s}", .{destName});
            } else |e| switch (e) {
                error.FileNotFound => {},
                else => return e,
            }
        }

        // 4. Copy the file if absolute path
        if (isAbsolute) {
            const sourceDirPath = std.fs.path.dirname(path) orelse return Error.MalformedPath;
            var sourceDir = try std.fs.openDirAbsolute(sourceDirPath, .{});
            defer sourceDir.close();
            try sourceDir.copyFile(sourceName, self.basedir, destName, .{});
        } else if (!std.mem.eql(u8, sourceName, destName)) {
            try self.basedir.copyFile(sourceName, self.basedir, destName, .{});
            try self.basedir.deleteFile(sourceName);
        }

        // 5. Write the destination path to the output buffer if provided
        if (destPathBuf) |outBuf| {
            if (destName.len > outBuf.len) return Error.BufferTooSmall;
            @memcpy(outBuf[0..destName.len], destName);
            @memset(outBuf[destName.len..], 0);
        }

        // 6. If not a note, just return null (file is now in basedir but not tracked as a note)
        if (!isNote) return null;

        // 7. Import into the DB
        const id = try self.db.import(created, modified, .{ .path = destName });
        if (self.skipEmbed) return id;

        // 8. Embed the contents
        var bufsz: usize = 128;
        var buf = try self.allocator.alloc(u8, bufsz);
        defer self.allocator.free(buf);
        while (true) {
            const sz = self.readAll(id, buf[0..bufsz]) catch |e| switch (e) {
                Error.BufferTooSmall => {
                    bufsz = try std.math.mul(usize, bufsz, 2);
                    buf = self.allocator.realloc(buf, bufsz) catch |alloc_e| {
                        std.log.err("Failed to resize to {d}: {}\n", .{ bufsz, alloc_e });
                        return OutOfMemory;
                    };
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
    pub fn search(self: *Runtime, query: []const u8, buf: []SearchResult) !usize {
        const zone = tracy.beginZone(@src(), .{ .name = "root.zig:search" });
        defer zone.end();

        return self.vectors.search(query, buf);
    }

    /// Index lists notes in reverse chronological order by modify time. Can optionally ignore a
    /// single note. Writes to `buf` and returns the number of found results.
    pub fn index(self: *Runtime, buf: []c_int, ignore: ?NoteID) !usize {
        const zone = tracy.beginZone(@src(), .{ .name = "root.zig:search" });
        defer zone.end();
        return self.db.searchNoQuery(buf, ignore);
    }

    /// Takes the contents of a note and returns a JSON spec of how it should be formatted.
    pub fn parseMarkdown(self: *Runtime, content: []const u8) ![]const u8 {
        const zone = tracy.beginZone(@src(), .{ .name = "root.zig:parseMarkdown" });
        defer zone.end();

        if (self.lastParsedMD) |ref| ref.deinit();
        self.lastParsedMD = std.ArrayList(u8).init(self.allocator);
        try json.stringify(try self.markdown.parse(content), .{}, self.lastParsedMD.?.writer());
        try self.lastParsedMD.?.writer().writeByte(0);
        return self.lastParsedMD.?.items;
    }

    pub fn title(self: *Runtime, noteID: NoteID, buf: []u8) ![]const u8 {
        const zone = tracy.beginZone(@src(), .{ .name = "root.zig:title" });
        defer zone.end();

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const note = try self.get(noteID, arena.allocator());

        const f = try self.basedir.openFile(note.path, .{});
        defer f.close();

        assert(buf.len == TITLE_BUF_LEN);

        var reader = f.reader();

        var pos: usize = 0;
        var skipping = true;
        while (pos < TITLE_LEN) {
            const c = reader.readByte() catch |err| switch (err) {
                error.EndOfStream => break,
                else => return err,
            };

            switch (c) {
                '\n' => {
                    // Only get the first line
                    break;
                },
                '#', ' ' => {
                    // Skip leading # and spaces
                    if (skipping) continue;
                },
                else => {
                    skipping = false;
                },
            }

            buf[pos] = c;
            pos += 1;
        }
        if (pos == TITLE_LEN) {
            buf[TITLE_BUF_LEN - 3] = '.';
            buf[TITLE_BUF_LEN - 2] = '.';
            buf[TITLE_BUF_LEN - 1] = '.';
            return buf[0..TITLE_BUF_LEN];
        }

        return buf[0..pos];
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

/// Resets metadata to a functioning state, returns list of paths to be re-imported.
/// Returns a double-null-terminated string: "path1\0path2\0\0"
pub fn doctor(allocator: std.mem.Allocator, basedir: std.fs.Dir) ![:0]const u8 {
    try deleteAllMeta(basedir);
    var output = std.ArrayList(u8).init(allocator);
    errdefer output.deinit();

    var it = basedir.iterate();
    while (try it.next()) |f| {
        if (f.kind == .file and !shouldIgnoreFile(f.name)) {
            try output.appendSlice(f.name);
            try output.append(0);
        } else if (f.kind == .directory) {
            std.log.warn("Saw a directory: {s}\n", .{f.name});
        }
    }

    // Final null terminator to mark end of array
    try output.append(0);
    return output.toOwnedSliceSentinel(0);
}

fn deleteAllMeta(basedir: std.fs.Dir) !void {
    var it = basedir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".db")) {
            try basedir.deleteFile(entry.name);
        }
    }
}

const IGNORED_FILES = [_][]const u8{".DS_Store"};
fn shouldIgnoreFile(path: []const u8) bool {
    for (IGNORED_FILES) |ignored_filename| {
        if (endsWith(path, ignored_filename)) return true;
    }
    return false;
}

const NOTE_EXT = [_][]const u8{ ".md", ".txt" };
fn hasNoteExtension(path: []const u8) bool {
    for (NOTE_EXT) |ext| if (endsWith(path, ext)) return true;
    return false;
}

fn hasDbExtension(path: []const u8) bool {
    return endsWith(path, ".db");
}

fn endsWith(path: []const u8, ext: []const u8) bool {
    return path.len >= ext.len and std.mem.eql(u8, path[path.len - ext.len ..], ext);
}

fn allNums(path: []const u8) bool {
    for (path, 0..) |c, i| {
        if (c < '0' or c > '9') {
            if (std.mem.eql(u8, path[i..], ".md") or std.mem.eql(u8, path[i..], ".txt")) {
                return true;
            }
            return false;
        }
    }
    return true;
}

fn isUnchanged(f: File, new_content: []const u8) !bool {
    const stat = try f.stat();
    if (stat.size != new_content.len) return false;

    var reader = f.reader();

    var i: usize = 0;
    while (true) : (i += 1) {
        const c = reader.readByte() catch |err| switch (err) {
            error.EndOfStream => {
                try f.seekTo(0);
                return true;
            },
            else => {
                try f.seekTo(0);
                return err;
            },
        };
        if (new_content[i] != c) {
            try f.seekTo(0);
            return false;
        }
    }

    try f.seekTo(0);
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
    try expectEqual('4', buf[3]);
    try expectEqual(0, buf[4]);
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

test "no modify on index" {
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
    _ = try rt.index(&buf2, 420);
    const n2 = try rt.get(noteID, arena.allocator());
    try expectEqual(n2.created, n2.modified);
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

test "index no query" {
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
    try expectEqual(9, try rt.index(&buffer, null));

    i = 0;
    while (i < 9) : (i += 1) {
        try expectEqual(@as(c_int, @intCast(i + 1)), buffer[8 - i]);
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
    try expectEqual(2, try rt.index(&buffer, null));
    try expectEqual(@as(c_int, @intCast(noteID2)), buffer[0]);
    try expectEqual(@as(c_int, @intCast(noteID1)), buffer[1]);

    try rt.update(noteID1);

    var buffer2: [10]c_int = undefined;
    const written2 = try rt.index(&buffer2, null);
    try expectEqual(2, written2);
    try expectEqual(@as(c_int, @intCast(noteID1)), buffer2[0]);
    try expectEqual(@as(c_int, @intCast(noteID2)), buffer2[1]);
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
    const written = try rt.index(&buffer, noteID1);
    try expectEqual(1, written);
    try expectEqual(@as(c_int, @intCast(noteID2)), buffer[0]);
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
    const written = try rt.index(&buffer, noteID2);
    try expectEqual(1, written);
    try expectEqual(@as(c_int, @intCast(noteID1)), buffer[0]);
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
    const written = try rt.index(&buffer, null);
    try expectEqual(1, written);
    try expectEqual(@as(c_int, @intCast(noteID1)), buffer[0]);
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

    const id = (try rt.import(path, null)).?;
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

    const id = (try rt.import(path, null)).?;
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

    const id = (try rt.import(path, null)).?;

    var buf: [1]SearchResult = undefined;
    try expectEqual(1, try rt.search("hello", &buf));
    try expectEqualSlices(SearchResult, &[_]SearchResult{
        .{ .id = id, .start_i = 0, .end_i = 5 },
    }, buf[0..1]);
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

    const ds_store = "/tmp/.DS_Store";
    f = try std.fs.createFileAbsolute(ds_store, .{});
    try f.writeAll("something");
    f.close();

    for ([_][]const u8{ txt, md }) |path| {
        try expect((try rt.import(path, null)) != null);
        (try tmpD.dir.openFile(std.fs.path.basename(path), .{})).close();
    }
    for ([_][]const u8{ png, tar, pdf }) |path| {
        try expect((try rt.import(path, null)) == null);
        (try tmpD.dir.openFile(std.fs.path.basename(path), .{})).close();
    }
    for ([_][]const u8{ds_store}) |path| {
        try expectError(Error.NotNote, rt.import(path, null));
        try expectError(FileNotFound, tmpD.dir.openFile(std.fs.path.basename(path), .{}));
    }
}
test "import auto-rename numeric filenames" {
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

    const cases = [_]struct { src: []const u8, dest: []const u8, srcDeleted: bool }{
        .{ .src = "/tmp/123.md", .dest = "_123.md", .srcDeleted = false },
        .{ .src = "456.txt", .dest = "_456.txt", .srcDeleted = true },
        .{ .src = "normal.md", .dest = "normal.md", .srcDeleted = false },
    };

    for (cases) |case| {
        const src_is_absolute = case.src[0] == '/';

        if (src_is_absolute) {
            (try std.fs.createFileAbsolute(case.src, .{})).close();
        } else {
            (try rt.basedir.createFile(case.src, .{})).close();
        }

        try expect((try rt.import(case.src, null)) != null);

        (try rt.basedir.openFile(case.dest, .{})).close();

        const maybe_f = if (src_is_absolute)
            std.fs.openFileAbsolute(case.src, .{})
        else
            rt.basedir.openFile(case.src, .{});

        if (case.srcDeleted) {
            try expectError(FileNotFound, maybe_f);
        } else {
            (try maybe_f).close();
        }
    }
}

test "import collision handling" {
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

    (try rt.basedir.createFile("existing.md", .{})).close();

    const path = "/tmp/existing.md";
    (try std.fs.createFileAbsolute(path, .{})).close();

    const id = (try rt.import(path, null)).?;
    const note = try rt.get(id, arena.allocator());

    try expectEqlStrings("_existing.md", note.path);
    (try rt.basedir.openFile("existing.md", .{})).close();
    (try rt.basedir.openFile("_existing.md", .{})).close();
}

test "import reject db extension" {
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

    const path = "/tmp/something.db";
    (try std.fs.createFileAbsolute(path, .{})).close();
    defer std.fs.deleteFileAbsolute(path) catch {};

    try expectError(Error.NotNote, rt.import(path, null));
}

test "import returns dest path in buffer" {
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

    {
        const path = "/tmp/test_import_destbuf.md";
        (try std.fs.createFileAbsolute(path, .{})).close();
        defer std.fs.deleteFileAbsolute(path) catch {};

        var destBuf: [PATH_MAX]u8 = undefined;
        _ = try rt.import(path, &destBuf);
        try expectEqlStrings("test_import_destbuf.md", std.mem.sliceTo(&destBuf, 0));
    }

    {
        const path = "/tmp/123.md";
        (try std.fs.createFileAbsolute(path, .{})).close();
        defer std.fs.deleteFileAbsolute(path) catch {};

        var destBuf: [PATH_MAX]u8 = undefined;
        _ = try rt.import(path, &destBuf);
        try expectEqlStrings("_123.md", std.mem.sliceTo(&destBuf, 0));
    }

    {
        (try rt.basedir.createFile("collision.md", .{})).close();
        const path = "/tmp/collision.md";
        (try std.fs.createFileAbsolute(path, .{})).close();
        defer std.fs.deleteFileAbsolute(path) catch {};

        var destBuf: [PATH_MAX]u8 = undefined;
        _ = try rt.import(path, &destBuf);
        try expectEqlStrings("_collision.md", std.mem.sliceTo(&destBuf, 0));
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

test "doctor" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();

    (try tmpD.dir.createFile("metadata.db", .{})).close();
    (try tmpD.dir.createFile("vectors.db", .{})).close();
    (try tmpD.dir.createFile("note1.txt", .{})).close();
    (try tmpD.dir.createFile("note2.md", .{})).close();
    (try tmpD.dir.createFile("1234", .{})).close();
    (try tmpD.dir.createFile(".DS_Store", .{})).close();

    const result = try doctor(arena.allocator(), tmpD.dir);
    defer arena.allocator().free(result);

    try expectError(error.FileNotFound, tmpD.dir.access("metadata.db", .{}));
    try expectError(error.FileNotFound, tmpD.dir.access("vectors.db", .{}));

    // Parse the double-null-terminated string
    var names: [3][]const u8 = undefined;
    var count: usize = 0;
    var i: usize = 0;
    while (result[i] != 0) {
        const start = i;
        while (result[i] != 0) : (i += 1) {}
        names[count] = result[start..i];
        count += 1;
        i += 1; // skip the null terminator
    }

    try expectEqual(3, count);
    try expect(std.mem.eql(u8, names[0], "note1.txt"));
    try expect(std.mem.eql(u8, names[1], "note2.md"));
    try expect(std.mem.eql(u8, names[2], "1234"));
    try expect(!std.mem.eql(u8, names[0], names[1]));
}

test "title" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();
    var rt = try Runtime.init(arena.allocator(), .{
        .basedir = tmpD.dir,
    });
    defer rt.deinit();

    const id = try rt.create();
    {
        var buf: [TITLE_BUF_LEN]u8 = undefined;
        try rt.writeAll(id, "Hello world!");
        try expectEqlStrings("Hello world!", try rt.title(id, buf[0..TITLE_BUF_LEN]));
    }
    {
        // Only the first line
        var buf: [TITLE_BUF_LEN]u8 = undefined;
        try rt.writeAll(id, "Hello world!\n foo bar baz");
        try expectEqlStrings("Hello world!", try rt.title(id, buf[0..TITLE_BUF_LEN]));
    }
    {
        // Strip markdown headers
        var buf: [TITLE_BUF_LEN]u8 = undefined;
        try rt.writeAll(id, "# Hello world!");
        try expectEqlStrings("Hello world!", try rt.title(id, buf[0..TITLE_BUF_LEN]));
    }
    {
        var buf: [TITLE_BUF_LEN]u8 = undefined;
        try rt.writeAll(id, "####### Hello world!");
        try expectEqlStrings("Hello world!", try rt.title(id, buf[0..TITLE_BUF_LEN]));
    }
    {
        // Truncate past TITLE_BUF_LEN
        var buf: [TITLE_BUF_LEN]u8 = undefined;
        try rt.writeAll(id, "******************************************************************");
        try expectEqlStrings(
            "*************************************************************...",
            try rt.title(id, buf[0..TITLE_BUF_LEN]),
        );
    }
}

const std = @import("std");
const assert = std.debug.assert;
const expect = std.testing.expect;
const expectEqlStrings = std.testing.expectEqualStrings;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;
const File = std.fs.File;
const FileNotFound = std.fs.File.OpenError.FileNotFound;
const json = std.json;
const OutOfMemory = std.mem.Allocator.Error.OutOfMemory;
const PATH_MAX = std.posix.PATH_MAX;
const testing_allocator = std.testing.allocator;
const expectError = std.testing.expectError;

const tracy = @import("tracy");

pub const CSearchResult = vector.CSearchResult;
const markdown = @import("markdown.zig");
const model = @import("model.zig");
const Note = model.Note;
const NoteID = model.NoteID;
pub const SearchResult = vector.SearchResult;
const types = @import("types.zig");
const Vector = types.Vector;
const VectorID = types.VectorID;
const util = @import("util.zig");
const vector = @import("vector.zig");
