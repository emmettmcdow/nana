pub const Error = error{
    NotFound,
    BufferTooSmall,
    MalformedPath,
    NotNote,
    IncoherentDB,
    ExhaustedIDs,
};

pub const TITLE_BUF_LEN = 64;
pub const ELLIPSIS_LEN = 3;
pub const TITLE_LEN = TITLE_BUF_LEN - ELLIPSIS_LEN;

pub const Note = struct {
    path: []const u8,
    created: i64,
    modified: i64,
};

pub const Runtime = struct {
    basedir: std.fs.Dir,
    vectors: *VectorDB,
    markdown: markdown.Markdown,
    allocator: std.mem.Allocator,
    skipEmbed: bool = false,
    lastParsedMD: ?std.ArrayList(u8) = null,
    embedder: *Embedder,
    next_id: u64 = 1,

    const Embedder = if (embedding_model == .jina_embedding)
        embed.JinaEmbedder
    else
        embed.NLEmbedder;

    pub const Opts = struct {
        basedir: std.fs.Dir,
        skipEmbed: bool = false,
    };

    pub fn init(allocator: std.mem.Allocator, opts: Runtime.Opts) !Runtime {
        const markdown_parser = markdown.Markdown.init(allocator);

        const embedder_ptr = try allocator.create(Embedder);
        errdefer allocator.destroy(embedder_ptr);
        embedder_ptr.* = try Embedder.init();

        const vectors = try VectorDB.init(allocator, opts.basedir, embedder_ptr.embedder());
        try vectors.validate();

        var self = Runtime{
            .basedir = opts.basedir,
            .vectors = vectors,
            .markdown = markdown_parser,
            .allocator = allocator,
            .skipEmbed = opts.skipEmbed,
            .embedder = embedder_ptr,
        };

        try self.pruneOrphanedNotes();
        try self.cleanupEmptyFiles();

        return self;
    }

    pub fn deinit(self: *Runtime) void {
        self.vectors.deinit();
        self.allocator.destroy(self.embedder);
    }

    pub fn doctor(self: *Runtime) !void {
        // Deinitialize old vectordb (also deinits the embedder interface)
        self.vectors.deinit();
        self.allocator.destroy(self.embedder);

        // Call vector.doctor to delete db files and re-embed all notes
        try vector.doctor(self.allocator, self.basedir);

        // Create new embedder and vectordb
        const embedder_ptr = try self.allocator.create(Embedder);
        errdefer self.allocator.destroy(embedder_ptr);
        embedder_ptr.* = try Embedder.init();

        const vectors = try VectorDB.init(self.allocator, self.basedir, embedder_ptr.embedder());

        self.embedder = embedder_ptr;
        self.vectors = vectors;
    }

    fn pruneOrphanedNotes(self: *Runtime) !void {
        try self.vectors.pruneOrphanedPaths(self.basedir);
    }

    fn cleanupEmptyFiles(self: *Runtime) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();

        var to_delete = std.ArrayList([]const u8).init(arena.allocator());

        var it = self.basedir.iterate();
        while (try it.next()) |entry| {
            if (entry.kind != .file) continue;
            if (!hasNoteExtension(entry.name)) continue;
            if (shouldIgnoreFile(entry.name)) continue;

            const f = self.basedir.openFile(entry.name, .{}) catch continue;
            defer f.close();
            const stat = f.stat() catch continue;
            if (stat.size == 0) {
                try to_delete.append(try arena.allocator().dupe(u8, entry.name));
            }
        }

        for (to_delete.items) |path| {
            try self.basedir.deleteFile(path);
            try self.vectors.removePath(path);
        }
    }

    pub fn create(self: *Runtime, outBuf: []u8) ![]const u8 {
        const zone = tracy.beginZone(@src(), .{ .name = "root.zig:create" });
        defer zone.end();

        // Iterate until we find something to name the file.
        for (self.next_id..maxInt(u64)) |id| {
            self.next_id = id;
            const path = try std.fmt.bufPrint(outBuf, "{d}.md", .{self.next_id});

            self.basedir.access(path, .{}) catch |err| switch (err) {
                error.FileNotFound => {
                    return path;
                },
                else => return err,
            };
        }
        return Error.ExhaustedIDs;
    }

    pub fn import(self: *Runtime, path: []const u8, outBuf: []u8) !?[]const u8 {
        const zone = tracy.beginZone(@src(), .{ .name = "root.zig:import" });
        defer zone.end();

        const sourceName = std.fs.path.basename(path);
        const isAbsolute = std.fs.path.isAbsolute(path);

        if (hasDbExtension(sourceName)) return Error.NotNote;
        if (shouldIgnoreFile(sourceName)) return Error.NotNote;

        const isNote = hasNoteExtension(sourceName);

        var f: std.fs.File = undefined;
        if (isAbsolute) {
            f = try std.fs.openFileAbsolute(path, .{});
        } else {
            f = try self.basedir.openFile(path, .{});
        }
        defer f.close();

        var destBuf: [PATH_MAX]u8 = undefined;
        const needsUnderscore = allNums(sourceName);
        var destName = if (needsUnderscore) blk: {
            if (sourceName.len + 1 >= PATH_MAX) return Error.MalformedPath;
            break :blk try std.fmt.bufPrint(&destBuf, "_{s}", .{sourceName});
        } else sourceName;

        if (isAbsolute) {
            var collisionBufs: [2][PATH_MAX]u8 = undefined;
            var bufIdx: u1 = 0;
            while (self.basedir.access(destName, .{})) |_| {
                if (destName.len + 1 >= PATH_MAX) return Error.MalformedPath;
                destName = try std.fmt.bufPrint(&collisionBufs[bufIdx], "_{s}", .{destName});
                bufIdx +%= 1;
            } else |e| switch (e) {
                error.FileNotFound => {},
                else => return e,
            }
        }

        if (isAbsolute) {
            const sourceDirPath = std.fs.path.dirname(path) orelse return Error.MalformedPath;
            var sourceDir = try std.fs.openDirAbsolute(sourceDirPath, .{});
            defer sourceDir.close();
            try sourceDir.copyFile(sourceName, self.basedir, destName, .{});
        } else if (!std.mem.eql(u8, sourceName, destName)) {
            try self.basedir.copyFile(sourceName, self.basedir, destName, .{});
            try self.basedir.deleteFile(sourceName);
        }

        if (destName.len > outBuf.len) return Error.BufferTooSmall;
        @memcpy(outBuf[0..destName.len], destName);

        if (!isNote) return null;

        if (self.skipEmbed) {
            return outBuf[0..destName.len];
        }

        var bufsz: usize = 128;
        var buf = try self.allocator.alloc(u8, bufsz);
        defer self.allocator.free(buf);
        while (true) {
            const sz = self.readAllPath(destName, buf[0..bufsz]) catch |e| switch (e) {
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
            try self.vectors.embedTextAsync(destName, buf[0..sz]);
            break;
        }

        return outBuf[0..destName.len];
    }

    pub fn get(self: *Runtime, path: []const u8) !Note {
        const zone = tracy.beginZone(@src(), .{ .name = "root.zig:get" });
        defer zone.end();

        const f = self.basedir.openFile(path, .{}) catch |err| switch (err) {
            // File doesn't exist yet (lazy creation) - return zero timestamps
            error.FileNotFound => return Note{
                .path = path,
                .created = 0,
                .modified = 0,
            },
            else => return err,
        };
        defer f.close();

        const metadata = try f.metadata();
        const modified: i64 = @intCast(@divTrunc(metadata.modified(), 1000));
        const created: i64 = if (metadata.created()) |c|
            @intCast(@divTrunc(c, 1000))
        else
            modified;

        return Note{
            .path = path,
            .created = created,
            .modified = modified,
        };
    }

    pub fn writeAll(self: *Runtime, path: []const u8, content: []const u8) !void {
        const zone = tracy.beginZone(@src(), .{ .name = "root.zig:writeAll" });
        defer zone.end();

        const f = self.basedir.createFile(path, .{ .read = true, .truncate = false }) catch |err| switch (err) {
            error.FileNotFound => return Error.NotFound,
            else => return err,
        };
        defer f.close();

        if (try isUnchanged(f, content)) return;

        try f.seekTo(0);
        try f.setEndPos(0);
        try f.writeAll(content);

        if (self.skipEmbed) return;

        try self.vectors.embedTextAsync(path, content);
    }

    pub fn readAll(self: *Runtime, path: []const u8, buf: []u8) !usize {
        const zone = tracy.beginZone(@src(), .{ .name = "root.zig:readAll" });
        defer zone.end();

        return self.readAllPath(path, buf);
    }

    fn readAllPath(self: *Runtime, path: []const u8, buf: []u8) !usize {
        return util.readAllZ(self.basedir, path, buf);
    }

    pub fn readRange(self: *Runtime, path: []const u8, start_i: usize, end_i: usize, buf: []u8) !void {
        const zone = tracy.beginZone(@src(), .{ .name = "root.zig:readRange" });
        defer zone.end();

        const text_len = end_i - start_i;
        assert(buf.len == text_len + 1);

        const f = self.basedir.openFile(path, .{}) catch |err| switch (err) {
            error.FileNotFound => return Error.NotFound,
            else => return err,
        };
        defer f.close();
        try f.seekBy(@intCast(start_i));
        const n = try f.read(buf[0..text_len]);
        assert(n == text_len);
        buf[n] = 0;
    }

    pub fn delete(self: *Runtime, path: []const u8) !void {
        const zone = tracy.beginZone(@src(), .{ .name = "root.zig:delete" });
        defer zone.end();

        try self.vectors.removePath(path);

        self.basedir.access(path, .{}) catch |e| switch (e) {
            error.FileNotFound => return,
            else => return e,
        };
        try self.basedir.deleteFile(path);
    }

    pub const SearchDetailOpts = struct {
        skip_highlights: bool = false,
    };

    pub fn searchDetail(
        self: *Runtime,
        search_result: SearchResult,
        query: []const u8,
        output: *SearchDetail,
        opts: SearchDetailOpts,
    ) !void {
        const zone = tracy.beginZone(@src(), .{ .name = "root.zig:preview" });
        defer zone.end();

        const path = search_result.path;

        try self.readRange(
            path,
            search_result.start_i,
            search_result.end_i,
            output.content,
        );
        const text_len = search_result.end_i - search_result.start_i;
        if (!opts.skip_highlights) {
            try self.vectors.populateHighlights(
                query,
                output.content[0..text_len],
                &output.highlights,
            );
        }
    }

    pub fn search(self: *Runtime, query: []const u8, buf: []SearchResult) !usize {
        const zone = tracy.beginZone(@src(), .{ .name = "root.zig:search" });
        defer zone.end();

        return self.vectors.search(query, buf);
    }

    pub fn index(self: *Runtime, buf: [][]const u8, ignore: ?[]const u8) !usize {
        const zone = tracy.beginZone(@src(), .{ .name = "root.zig:index" });
        defer zone.end();

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();

        const Entry = struct {
            path: []const u8,
            modified: i64,
        };

        var entries = std.ArrayList(Entry).init(arena.allocator());

        var it = self.basedir.iterate();
        while (try it.next()) |entry| {
            if (entry.kind != .file) continue;
            if (!hasNoteExtension(entry.name)) continue;
            if (shouldIgnoreFile(entry.name)) continue;

            if (ignore) |ign| {
                if (std.mem.eql(u8, entry.name, ign)) continue;
            }

            const f = self.basedir.openFile(entry.name, .{}) catch continue;
            defer f.close();

            const stat = f.stat() catch continue;
            if (stat.size == 0) continue;

            const metadata = f.metadata() catch continue;
            const modified: i64 = @intCast(@divTrunc(metadata.modified(), 1000));

            try entries.append(.{
                .path = try arena.allocator().dupe(u8, entry.name),
                .modified = modified,
            });
        }

        std.sort.insertion(Entry, entries.items, {}, struct {
            fn lessThan(_: void, a: Entry, b: Entry) bool {
                return a.modified > b.modified;
            }
        }.lessThan);

        const count = @min(entries.items.len, buf.len);
        for (0..count) |i| {
            buf[i] = try self.allocator.dupe(u8, entries.items[i].path);
        }

        return count;
    }

    pub fn parseMarkdown(self: *Runtime, content: []const u8) ![]const u8 {
        const zone = tracy.beginZone(@src(), .{ .name = "root.zig:parseMarkdown" });
        defer zone.end();

        if (self.lastParsedMD) |ref| ref.deinit();
        self.lastParsedMD = std.ArrayList(u8).init(self.allocator);
        try json.stringify(try self.markdown.parse(content), .{}, self.lastParsedMD.?.writer());
        try self.lastParsedMD.?.writer().writeByte(0);
        return self.lastParsedMD.?.items;
    }

    pub fn title(self: *Runtime, path: []const u8, buf: []u8) ![]const u8 {
        const zone = tracy.beginZone(@src(), .{ .name = "root.zig:title" });
        defer zone.end();

        const f = self.basedir.openFile(path, .{}) catch |err| switch (err) {
            error.FileNotFound => return Error.NotFound,
            else => return err,
        };
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
                '\n' => break,
                '#', ' ' => {
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
};

pub const N_SEARCH_HIGHLIGHTS = 5;
pub const SearchDetail = struct {
    content: []u8,
    highlights: [N_SEARCH_HIGHLIGHTS * 2]usize = .{0} ** (N_SEARCH_HIGHLIGHTS * 2),
};

pub const CSearchDetail = extern struct {
    content: [*]u8,
    highlights: [N_SEARCH_HIGHLIGHTS * 2]c_uint,
};

pub fn doctor(allocator: std.mem.Allocator, basedir: std.fs.Dir) !void {
    return vector.doctor(allocator, basedir);
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
        .basedir = tmpD.dir,
        .skipEmbed = true,
    });
    defer rt.deinit();

    var path_buf: [PATH_MAX]u8 = undefined;
    const path = try rt.create(&path_buf);
    try expectError(error.FileNotFound, rt.basedir.access(path, .{ .mode = .read_write }));

    var buf: [1000]u8 = undefined;
    const sz = try rt.readAll(path, &buf);
    try expect(sz == 0);
    try expectError(error.FileNotFound, rt.basedir.access(path, .{ .mode = .read_write }));
}

fn _test_empty_dir_exclude_db(dir: std.fs.Dir) !bool {
    var dirIterator = dir.iterate();
    while (try dirIterator.next()) |dirent| {
        if (!std.mem.endsWith(u8, dirent.name, ".db") and
            !std.mem.eql(u8, dirent.name, ".nana_note_ids"))
        {
            return false;
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
        .basedir = tmpD.dir,
        .skipEmbed = true,
    });
    defer rt.deinit();

    var path_buf: [PATH_MAX]u8 = undefined;
    const path = try rt.create(&path_buf);
    try expect(try _test_empty_dir_exclude_db(rt.basedir));

    _ = try rt.writeAll(path, "norecycle");
    try expect(!try _test_empty_dir_exclude_db(rt.basedir));
}

test "modify on write" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();
    var rt = try Runtime.init(arena.allocator(), .{
        .basedir = tmpD.dir,
        .skipEmbed = true,
    });
    defer rt.deinit();

    var path_buf: [PATH_MAX]u8 = undefined;
    const path = try rt.create(&path_buf);

    try rt.writeAll(path, "first");
    const n1 = try rt.get(path);
    std.time.sleep(10 * std.time.ns_per_ms);

    try rt.writeAll(path, "second");
    const n2 = try rt.get(path);
    try expect(n2.modified >= n1.modified);
}

test "readAll null-term" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();
    var rt = try Runtime.init(arena.allocator(), .{
        .basedir = tmpD.dir,
        .skipEmbed = true,
    });
    defer rt.deinit();

    var path_buf: [PATH_MAX]u8 = undefined;
    const path = try rt.create(&path_buf);
    try rt.writeAll(path, "1234");

    var buf: [20]u8 = [_]u8{'1'} ** 20;
    _ = try rt.readAll(path, &buf);
    try expectEqual('4', buf[3]);
    try expectEqual(0, buf[4]);
}

test "readRange" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();
    var rt = try Runtime.init(arena.allocator(), .{
        .basedir = tmpD.dir,
        .skipEmbed = true,
    });
    defer rt.deinit();

    var path_buf: [PATH_MAX]u8 = undefined;
    const path = try rt.create(&path_buf);
    try rt.writeAll(path, "1/23/4");

    var buf: [3]u8 = [_]u8{'1'} ** 3;
    _ = try rt.readRange(path, 2, 4, &buf);
    try expectEqlStrings("23", buf[0..2]);
    try expectEqual(0, buf[2]);
}

test "no modify on read" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();
    var rt = try Runtime.init(arena.allocator(), .{
        .basedir = tmpD.dir,
        .skipEmbed = true,
    });
    defer rt.deinit();

    var path_buf: [PATH_MAX]u8 = undefined;
    const path = try rt.create(&path_buf);
    try rt.writeAll(path, "hello");
    const n1 = try rt.get(path);

    var buf: [20]u8 = undefined;
    _ = try rt.readAll(path, &buf);
    const n2 = try rt.get(path);
    try expectEqual(n1.modified, n2.modified);
}

test "r/w-all note" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();
    var rt = try Runtime.init(arena.allocator(), .{
        .basedir = tmpD.dir,
        .skipEmbed = true,
    });
    defer rt.deinit();

    var path_buf: [PATH_MAX]u8 = undefined;
    const path = try rt.create(&path_buf);

    const expected = "Contents of a note!";
    try rt.writeAll(path, expected);

    var buffer: [21]u8 = undefined;
    const n = try rt.readAll(path, &buffer);

    try std.testing.expectEqualStrings(expected, buffer[0..n]);
}

test "r/w-all too smol output buffer" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();
    var rt = try Runtime.init(arena.allocator(), .{
        .basedir = tmpD.dir,
        .skipEmbed = true,
    });
    defer rt.deinit();

    var path_buf: [PATH_MAX]u8 = undefined;
    const path = try rt.create(&path_buf);

    const expected = "Should be way too big!!!";
    try rt.writeAll(path, expected);

    var buffer: [1]u8 = undefined;
    _ = rt.readAll(path, &buffer) catch |err| {
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
        .basedir = tmpD.dir,
        .skipEmbed = true,
    });
    defer rt.deinit();

    var path_buf: [PATH_MAX]u8 = undefined;
    const path = try rt.create(&path_buf);
    try rt.delete(path);
}

test "index" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();
    var rt = try Runtime.init(arena.allocator(), .{
        .basedir = tmpD.dir,
        .skipEmbed = true,
    });
    defer rt.deinit();

    var path_bufs: [9][PATH_MAX]u8 = undefined;
    var paths: [9][]const u8 = undefined;
    for (0..9) |i| {
        paths[i] = try rt.create(&path_bufs[i]);
        try rt.writeAll(paths[i], "norecycle");
        std.time.sleep(10 * std.time.ns_per_ms);
    }

    var buffer: [10][]const u8 = undefined;
    try expectEqual(9, try rt.index(&buffer, null));
    defer for (buffer[0..9]) |p| rt.allocator.free(p);
}

test "index orderby modified" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();
    var rt = try Runtime.init(arena.allocator(), .{
        .basedir = tmpD.dir,
        .skipEmbed = true,
    });
    defer rt.deinit();

    var path1_buf: [PATH_MAX]u8 = undefined;
    const path1 = try rt.create(&path1_buf);
    try rt.writeAll(path1, "norecycle");
    std.time.sleep(50 * std.time.ns_per_ms);

    var path2_buf: [PATH_MAX]u8 = undefined;
    const path2 = try rt.create(&path2_buf);
    try rt.writeAll(path2, "norecycle");

    var buffer: [10][]const u8 = undefined;
    try expectEqual(2, try rt.index(&buffer, null));
    defer rt.allocator.free(buffer[0]);
    defer rt.allocator.free(buffer[1]);

    try expectEqlStrings(path2, buffer[0]);
    try expectEqlStrings(path1, buffer[1]);
}

test "index exclude param" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();
    var rt = try Runtime.init(arena.allocator(), .{
        .basedir = tmpD.dir,
        .skipEmbed = true,
    });
    defer rt.deinit();

    var path1_buf: [PATH_MAX]u8 = undefined;
    const path1 = try rt.create(&path1_buf);
    try rt.writeAll(path1, "norecycle");

    var path2_buf: [PATH_MAX]u8 = undefined;
    const path2 = try rt.create(&path2_buf);
    try rt.writeAll(path2, "norecycle");

    var buffer: [10][]const u8 = undefined;
    const written = try rt.index(&buffer, path1);
    defer for (buffer[0..written]) |p| rt.allocator.free(p);

    try expectEqual(1, written);
    try expectEqlStrings(path2, buffer[0]);
}

test "index exclude unmodifieds" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();
    var rt = try Runtime.init(arena.allocator(), .{
        .basedir = tmpD.dir,
        .skipEmbed = true,
    });
    defer rt.deinit();

    var path1_buf: [PATH_MAX]u8 = undefined;
    const path1 = try rt.create(&path1_buf);
    try rt.writeAll(path1, "norecycle");

    var path2_buf: [PATH_MAX]u8 = undefined;
    _ = try rt.create(&path2_buf);

    var buffer: [10][]const u8 = undefined;
    const written = try rt.index(&buffer, null);
    defer for (buffer[0..written]) |p| rt.allocator.free(p);

    try expectEqual(1, written);
    try expectEqlStrings(path1, buffer[0]);
}

test "import" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();
    var rt = try Runtime.init(arena.allocator(), .{
        .basedir = tmpD.dir,
        .skipEmbed = true,
    });
    defer rt.deinit();

    const sourcePath = "somefile.txt";
    {
        var f = try tmpD.dir.createFile(sourcePath, .{});
        defer f.close();
        try f.writeAll("Something!");
    }

    var destBuf: [PATH_MAX]u8 = undefined;
    const destPath = (try rt.import(sourcePath, &destBuf)).?;
    const note = try rt.get(destPath);

    try expectEqlStrings(note.path, sourcePath);
}

test "import copy" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();
    var rt = try Runtime.init(arena.allocator(), .{
        .basedir = tmpD.dir,
        .skipEmbed = true,
    });
    defer rt.deinit();

    const path = "/tmp/something_import_copy.txt";
    {
        var f = try std.fs.createFileAbsolute(path, .{});
        defer f.close();
        try f.writeAll("Something!");
    }
    defer std.fs.deleteFileAbsolute(path) catch {};

    var destBuf: [PATH_MAX]u8 = undefined;
    const destPath = (try rt.import(path, &destBuf)).?;
    const note = try rt.get(destPath);

    try expectEqlStrings(note.path, std.fs.path.basename(path));
}

test "import run embedding" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();
    var rt = try Runtime.init(arena.allocator(), .{
        .basedir = tmpD.dir,
    });
    defer rt.deinit();

    const path = "/tmp/something_embed.txt";
    {
        var f = try std.fs.createFileAbsolute(path, .{});
        defer f.close();
        try f.writeAll("hello");
    }

    var destBuf: [PATH_MAX]u8 = undefined;
    const destPath = (try rt.import(path, &destBuf)).?;

    std.time.sleep(2 * std.time.ns_per_s);

    var buf: [1]SearchResult = undefined;
    try expectEqual(1, try rt.search("hello", &buf));
    try expectEqlStrings(destPath, buf[0].path);
    try expectEqual(@as(usize, 0), buf[0].start_i);
    try expectEqual(@as(usize, 5), buf[0].end_i);
}

test "import skip unrecognized file extensions" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();
    var rt = try Runtime.init(arena.allocator(), .{
        .basedir = tmpD.dir,
        .skipEmbed = true,
    });
    defer rt.deinit();

    const png = "/tmp/something.png";
    var f = try std.fs.createFileAbsolute(png, .{});
    try f.writeAll("something");
    f.close();
    defer std.fs.deleteFileAbsolute(png) catch {};

    const tar = "/tmp/something.tar";
    f = try std.fs.createFileAbsolute(tar, .{});
    try f.writeAll("something");
    f.close();
    defer std.fs.deleteFileAbsolute(tar) catch {};

    const pdf = "/tmp/something.pdf";
    f = try std.fs.createFileAbsolute(pdf, .{});
    try f.writeAll("something");
    f.close();
    defer std.fs.deleteFileAbsolute(pdf) catch {};

    const txt = "/tmp/something_ext.txt";
    f = try std.fs.createFileAbsolute(txt, .{});
    try f.writeAll("something");
    f.close();
    defer std.fs.deleteFileAbsolute(txt) catch {};

    const md = "/tmp/something_ext.md";
    f = try std.fs.createFileAbsolute(md, .{});
    try f.writeAll("something");
    f.close();
    defer std.fs.deleteFileAbsolute(md) catch {};

    const ds_store = "/tmp/.DS_Store";
    f = try std.fs.createFileAbsolute(ds_store, .{});
    try f.writeAll("something");
    f.close();
    defer std.fs.deleteFileAbsolute(ds_store) catch {};

    var destBuf: [PATH_MAX]u8 = undefined;
    for ([_][]const u8{ txt, md }) |p| {
        const result = try rt.import(p, &destBuf);
        try expect(result != null);
        (try tmpD.dir.openFile(std.fs.path.basename(p), .{})).close();
    }
    for ([_][]const u8{ png, tar, pdf }) |p| {
        try expect((try rt.import(p, &destBuf)) == null);
        (try tmpD.dir.openFile(std.fs.path.basename(p), .{})).close();
    }
    for ([_][]const u8{ds_store}) |p| {
        try expectError(Error.NotNote, rt.import(p, &destBuf));
        try expectError(FileNotFound, tmpD.dir.openFile(std.fs.path.basename(p), .{}));
    }
}

test "import auto-rename numeric filenames" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();
    var rt = try Runtime.init(arena.allocator(), .{
        .basedir = tmpD.dir,
        .skipEmbed = true,
    });
    defer rt.deinit();

    // Only delete files which are within our storage
    const cases = [_]struct { src: []const u8, dest: []const u8, srcDeleted: bool }{
        .{ .src = "/tmp/777.md", .dest = "_777.md", .srcDeleted = false },
        .{ .src = "456.txt", .dest = "_456.txt", .srcDeleted = true },
        .{ .src = "normal.md", .dest = "normal.md", .srcDeleted = false },
    };

    var destBuf: [PATH_MAX]u8 = undefined;
    for (cases) |case| {
        const src_is_absolute = case.src[0] == '/';

        if (src_is_absolute) {
            (try std.fs.createFileAbsolute(case.src, .{})).close();
        } else {
            (try rt.basedir.createFile(case.src, .{})).close();
        }

        const result = try rt.import(case.src, &destBuf);
        try expect(result != null);

        (try rt.basedir.openFile(case.dest, .{})).close();

        const maybe_f = if (src_is_absolute)
            std.fs.openFileAbsolute(case.src, .{})
        else
            rt.basedir.openFile(case.src, .{});

        if (case.srcDeleted) {
            try expectError(FileNotFound, maybe_f);
        } else {
            (try maybe_f).close();
            if (src_is_absolute) {
                std.fs.deleteFileAbsolute(case.src) catch {};
            }
        }
    }
}

test "import collision handling" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();
    var rt = try Runtime.init(arena.allocator(), .{
        .basedir = tmpD.dir,
        .skipEmbed = true,
    });
    defer rt.deinit();

    (try rt.basedir.createFile("existing.md", .{})).close();

    const path = "/tmp/existing.md";
    (try std.fs.createFileAbsolute(path, .{})).close();
    defer std.fs.deleteFileAbsolute(path) catch {};

    var destBuf: [PATH_MAX]u8 = undefined;
    const destPath = (try rt.import(path, &destBuf)).?;
    const note = try rt.get(destPath);

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
        .basedir = tmpD.dir,
        .skipEmbed = true,
    });
    defer rt.deinit();

    const path = "/tmp/something.db";
    (try std.fs.createFileAbsolute(path, .{})).close();
    defer std.fs.deleteFileAbsolute(path) catch {};

    var destBuf: [PATH_MAX]u8 = undefined;
    try expectError(Error.NotNote, rt.import(path, &destBuf));
}

test "import returns dest path in buffer" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();
    var rt = try Runtime.init(arena.allocator(), .{
        .basedir = tmpD.dir,
        .skipEmbed = true,
    });
    defer rt.deinit();

    {
        const path = "/tmp/test_import_destbuf2.md";
        (try std.fs.createFileAbsolute(path, .{})).close();
        defer std.fs.deleteFileAbsolute(path) catch {};

        var destBuf: [PATH_MAX]u8 = undefined;
        const result = try rt.import(path, &destBuf);
        try expect(result != null);
        try expectEqlStrings("test_import_destbuf2.md", result.?);
    }

    {
        const path = "/tmp/999.md";
        (try std.fs.createFileAbsolute(path, .{})).close();
        defer std.fs.deleteFileAbsolute(path) catch {};

        var destBuf: [PATH_MAX]u8 = undefined;
        const result = try rt.import(path, &destBuf);
        try expect(result != null);
        try expectEqlStrings("_999.md", result.?);
    }

    {
        (try rt.basedir.createFile("collision2.md", .{})).close();
        const path = "/tmp/collision2.md";
        (try std.fs.createFileAbsolute(path, .{})).close();
        defer std.fs.deleteFileAbsolute(path) catch {};

        var destBuf: [PATH_MAX]u8 = undefined;
        const result = try rt.import(path, &destBuf);
        try expect(result != null);
        try expectEqlStrings("_collision2.md", result.?);
    }
}

test "writeAll unchanged" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();
    var rt = try Runtime.init(arena.allocator(), .{
        .basedir = tmpD.dir,
    });
    defer rt.deinit();

    var path_buf: [PATH_MAX]u8 = undefined;
    const path = try rt.create(&path_buf);
    try rt.writeAll(path, "hello");
    const note_before = try rt.get(path);
    try rt.writeAll(path, "hello");
    const note_after = try rt.get(path);

    try expect(note_before.modified == note_after.modified);
}

test "root: get returns zero timestamps for uncreated file" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();
    var rt = try Runtime.init(arena.allocator(), .{
        .basedir = tmpD.dir,
    });
    defer rt.deinit();

    var path_buf: [PATH_MAX]u8 = undefined;
    const path = try rt.create(&path_buf);

    // File doesn't exist yet (lazy creation), get should return zero timestamps
    const note = try rt.get(path);
    try expectEqual(0, note.created);
    try expectEqual(0, note.modified);
}

test "root: get returns real timestamps after file is written" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();
    var rt = try Runtime.init(arena.allocator(), .{
        .basedir = tmpD.dir,
    });
    defer rt.deinit();

    var path_buf: [PATH_MAX]u8 = undefined;
    const path = try rt.create(&path_buf);

    // Before writing, timestamps are zero
    const note_before = try rt.get(path);
    try expectEqual(0, note_before.created);
    try expectEqual(0, note_before.modified);

    // Write content to create the file
    try rt.writeAll(path, "hello world");

    // After writing, timestamps should be real (non-zero)
    const note_after = try rt.get(path);
    try expect(note_after.created > 0);
    try expect(note_after.modified > 0);
}

test "clear empties upon init" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();

    var path1_copy: [32]u8 = undefined;
    var path1_saved: []u8 = undefined;
    var path2_copy: [32]u8 = undefined;
    var path2_saved: []u8 = undefined;

    {
        var arena = std.heap.ArenaAllocator.init(testing_allocator);
        defer arena.deinit();

        var rt = try Runtime.init(arena.allocator(), .{
            .basedir = tmpD.dir,
            .skipEmbed = true,
        });
        defer rt.deinit();

        var path1_buf: [PATH_MAX]u8 = undefined;
        const path1 = try rt.create(&path1_buf);
        @memcpy(path1_copy[0..path1.len], path1);
        path1_saved = path1_copy[0..path1.len];
        try rt.writeAll(path1, "present");

        var path2_buf: [PATH_MAX]u8 = undefined;
        const path2 = try rt.create(&path2_buf);
        @memcpy(path2_copy[0..path2.len], path2);
        path2_saved = path2_copy[0..path2.len];
        try rt.writeAll(path2_saved, "hello");

        try rt.writeAll(path2_saved, "");

        var path3_buf: [PATH_MAX]u8 = undefined;
        const path3 = try rt.create(&path3_buf);
        try rt.writeAll(path3, "present");
    }

    var arena2 = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena2.deinit();
    var rt2 = try Runtime.init(arena2.allocator(), .{
        .basedir = tmpD.dir,
        .skipEmbed = true,
    });
    defer rt2.deinit();

    // Path1 should be present because it had content
    try rt2.basedir.access(path1_saved, .{});
    // Path2 should get deleted because it was empty
    try expectError(error.FileNotFound, rt2.basedir.access(path2_saved, .{}));
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

test "doctor reinitializes vectordb" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();

    // Create a note file
    {
        const f = try tmpD.dir.createFile("note1.md", .{});
        defer f.close();
        try f.writeAll("hello world");
    }

    var rt = try Runtime.init(arena.allocator(), .{
        .basedir = tmpD.dir,
    });
    defer rt.deinit();

    // Capture old vectordb pointer
    const old_vectors = rt.vectors;

    // Run doctor - should deinit old db, call vector.doctor, and create new instance
    try rt.doctor();

    // Verify vectordb instance was replaced
    try expect(rt.vectors != old_vectors);

    // Verify search still works after doctor
    var results: [10]SearchResult = undefined;
    const found = try rt.search("hello", &results);
    try expect(found >= 1);
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

    var buf: [TITLE_BUF_LEN]u8 = undefined;
    var path_buf: [PATH_MAX]u8 = undefined;
    const path = try rt.create(&path_buf);
    { // Single line
        try rt.writeAll(path, "Hello world!");
        try expectEqlStrings("Hello world!", try rt.title(path, buf[0..TITLE_BUF_LEN]));
    }
    { // Multiple lines
        try rt.writeAll(path, "Hello world!\n foo bar baz");
        try expectEqlStrings("Hello world!", try rt.title(path, buf[0..TITLE_BUF_LEN]));
    }
    { // Single line strip single header
        try rt.writeAll(path, "# Hello world!");
        try expectEqlStrings("Hello world!", try rt.title(path, buf[0..TITLE_BUF_LEN]));
    }
    { // Single line strip multiple headers
        try rt.writeAll(path, "####### Hello world!");
        try expectEqlStrings("Hello world!", try rt.title(path, buf[0..TITLE_BUF_LEN]));
    }
    { // Truncate long first line
        try rt.writeAll(
            path,
            "******************************************************************",
        );
        try expectEqlStrings(
            "*************************************************************...",
            try rt.title(path, buf[0..TITLE_BUF_LEN]),
        );
    }
}

test "search_detail" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();
    var rt = try Runtime.init(arena.allocator(), .{
        .basedir = tmpD.dir,
    });
    defer rt.deinit();

    var path_buf: [PATH_MAX]u8 = undefined;
    const path = try rt.create(&path_buf);
    const content = "Hello world!";
    const nullterm_content = content ++ "\x00";
    try rt.writeAll(path, content);

    { // Preview on the entire content
        var preview_buf: [content.len + 1]u8 = undefined;
        var preview = SearchDetail{ .content = &preview_buf };
        try rt.searchDetail(
            .{ .path = path, .start_i = 0, .end_i = content.len },
            "hello",
            &preview,
            .{},
        );
        try expectEqlStrings(nullterm_content, preview.content);
        try expectEqual(0, preview.highlights[0]);
        try expectEqual(5, preview.highlights[1]);
        try expectEqlStrings(
            "Hello",
            preview.content[preview.highlights[0]..preview.highlights[1]],
        );
    }
    { // Preview over a subset of the content
        const start_i = 0;
        const end_i = 5;
        const text_len = end_i - start_i;
        var preview_buf: [text_len + 1]u8 = undefined;
        var preview = SearchDetail{ .content = &preview_buf };
        try rt.searchDetail(
            .{ .path = path, .start_i = start_i, .end_i = end_i },
            "hello",
            &preview,
            .{},
        );
        try expectEqual(0, preview.highlights[0]);
        try expectEqual(5, preview.highlights[1]);
    }
    { // Skip highlighting
        const start_i = 0;
        const end_i = 5;
        const text_len = end_i - start_i;
        var preview_buf: [text_len + 1]u8 = undefined;
        var preview = SearchDetail{ .content = &preview_buf };
        try rt.searchDetail(
            .{ .path = path, .start_i = start_i, .end_i = end_i },
            "hello",
            &preview,
            .{ .skip_highlights = true },
        );
        for (preview.highlights) |hl| try expectEqual(0, hl);
    }
}

test "unicode endpoint checks" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();
    var rt = try Runtime.init(arena.allocator(), .{
        .basedir = tmpD.dir,
    });
    defer rt.deinit();

    var path_buf: [PATH_MAX]u8 = undefined;
    const path = try rt.create(&path_buf);
    const query = "heart";
    const note_content = "heart❤️";
    try rt.writeAll(path, note_content);

    std.time.sleep(2 * std.time.ns_per_s);

    var results: [1]SearchResult = undefined;
    const n_results = try rt.search(query, &results);
    try expectEqual(1, n_results);
    const result = results[0];
    try expectEqlStrings(note_content, note_content[result.start_i..result.end_i]);

    const content_buf = try arena.allocator().alloc(u8, (result.end_i - result.start_i) + 1);
    var detail: SearchDetail = .{
        .content = content_buf,
    };
    try rt.searchDetail(result, query, &detail, .{});
    try expectEqlStrings(
        note_content,
        note_content[detail.highlights[0]..detail.highlights[1]],
    );
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
const maxInt = std.math.maxInt;
const OutOfMemory = std.mem.Allocator.Error.OutOfMemory;
const PATH_MAX = std.posix.PATH_MAX;
const testing_allocator = std.testing.allocator;
const expectError = std.testing.expectError;

const tracy = @import("tracy");

pub const CSearchResult = vector.CSearchResult;
const embed = @import("embed.zig");
const markdown = @import("markdown.zig");
pub const SearchResult = vector.SearchResult;
const util = @import("util.zig");
const vector = @import("vector.zig");
const config = @import("config");
const embedding_model: embed.EmbeddingModel = @enumFromInt(@intFromEnum(config.embedding_model));
const VectorDB = vector.VectorDB(embedding_model);
const yield = std.Thread.yield;
