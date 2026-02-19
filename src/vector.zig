const MAX_NOTE_LEN: usize = std.math.maxInt(u32);
const PATH_MAX = std.posix.PATH_MAX;

pub const Error = error{NotQueuedShuttingDown};

/// Runs the doctor routine: deletes the database and re-embeds all notes.
pub fn doctor(
    comptime model: EmbeddingModel,
    allocator: std.mem.Allocator,
    basedir: std.fs.Dir,
) !void {
    // 1. Delete all db files and note id map
    try deleteAllMeta(basedir);

    // 2. Create embedder and fresh vector db
    const Embedder = if (model == .mpnet_embedding) MpnetEmbedder else NLEmbedder;
    const embedder_ptr = try allocator.create(Embedder);
    errdefer allocator.destroy(embedder_ptr);
    embedder_ptr.* = try Embedder.init();

    var db = try VectorDB(model).init(allocator, basedir, embedder_ptr.embedder());
    defer db.deinit();

    // 3. Iterate over all note files and re-embed them
    var it = basedir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!hasNoteExtension(entry.name)) continue;

        const contents = basedir.readFileAlloc(allocator, entry.name, MAX_NOTE_LEN) catch |err| {
            std.log.warn("Failed to read {s}: {}\n", .{ entry.name, err });
            continue;
        };
        defer allocator.free(contents);

        db.embedText(entry.name, contents) catch |err| {
            std.log.warn("Failed to embed {s}: {}\n", .{ entry.name, err });
            continue;
        };
    }
}

fn deleteAllMeta(basedir: std.fs.Dir) !void {
    var it = basedir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".db")) {
            basedir.deleteFile(entry.name) catch |e| {
                std.log.err("Failed to delete file '{s}' with error: {}", .{ entry.name, e });
                continue;
            };
        }
    }
    basedir.deleteFile(".nana_note_ids") catch {}; // zlinter-disable-current-line
    basedir.deleteFile(".nana_note_ids.tmp") catch {}; // zlinter-disable-current-line
}

const NOTE_EXT = [_][]const u8{ ".md", ".txt" };
fn hasNoteExtension(path: []const u8) bool {
    for (NOTE_EXT) |ext| {
        if (path.len >= ext.len and std.mem.eql(u8, path[path.len - ext.len ..], ext)) {
            return true;
        }
    }
    return false;
}

pub const CSearchResult = extern struct {
    path: [PATH_MAX]u8,
    start_i: c_uint,
    end_i: c_uint,
    similarity: f32,
};

pub const SearchResult = struct {
    path: []const u8,
    start_i: usize,
    end_i: usize,
    similarity: f32 = 0.0,

    const Self = @This();

    pub fn toC(self: Self) CSearchResult {
        var c_result = CSearchResult{
            .path = std.mem.zeroes([PATH_MAX]u8),
            .start_i = @as(c_uint, @intCast(self.start_i)),
            .end_i = @as(c_uint, @intCast(self.end_i)),
            .similarity = self.similarity,
        };
        const copy_len = @min(self.path.len, PATH_MAX - 1);
        @memcpy(c_result.path[0..copy_len], self.path[0..copy_len]);
        return c_result;
    }
};

fn stripQuery(query: []const u8) []const u8 {
    var start_i: usize = 0;
    var end_i = query.len;
    for (query, 0..) |c, i| {
        start_i = i;
        if (isAlphanumeric(c)) {
            break;
        }
    }
    const new_len = end_i - start_i;
    if (start_i == end_i - 1) return query[0..0];
    for (1..new_len + 1) |neg_i| {
        const i = query.len - neg_i;
        const c = query[i];
        if (isAlphanumeric(c)) {
            break;
        }
        end_i = i;
    }
    assert(start_i <= end_i);
    return query[start_i..end_i];
}

pub fn VectorDB(embedding_model: EmbeddingModel) type {
    const VEC_SZ = switch (embedding_model) {
        .apple_nlembedding => NLEmbedder.VEC_SZ,
        .mpnet_embedding => MpnetEmbedder.VEC_SZ,
    };
    const VEC_TYPE = switch (embedding_model) {
        .apple_nlembedding => NLEmbedder.VEC_TYPE,
        .mpnet_embedding => MpnetEmbedder.VEC_TYPE,
    };

    const EmbedJob = struct {
        path: []const u8,
        contents: []const u8,

        pub fn id(self: @This()) u64 {
            return std.hash.Wyhash.hash(0, self.path);
        }
    };

    return struct {
        const Self = @This();
        pub const VecStorage = vec_storage.Storage(VEC_SZ, VEC_TYPE);

        const WorkQueue = UniqueCircularBuffer(EmbedJob, u64, EmbedJob.id);

        embedder: embed.Embedder,
        vec_storage: VecStorage,
        note_id_map: *NoteIdMap,
        basedir: std.fs.Dir,
        allocator: std.mem.Allocator,
        work_queue: *WorkQueue,
        work_queue_thread: Thread,
        work_queue_mutex: Thread.Mutex = .{},
        work_queue_condition: Thread.Condition = .{},
        work_queue_running: bool,

        pub fn init(
            allocator: std.mem.Allocator,
            basedir: std.fs.Dir,
            embedder: embed.Embedder,
        ) !*Self {
            var vecs = try VecStorage.init(allocator, basedir, .{});
            try vecs.load(embedder.path);
            const wq = try WorkQueue.init(allocator, 64);

            const note_id_map = try allocator.create(NoteIdMap);
            errdefer allocator.destroy(note_id_map);
            note_id_map.* = try NoteIdMap.init(allocator, basedir);

            const self = try allocator.create(Self);
            self.* = .{
                .embedder = embedder,
                .vec_storage = vecs,
                .note_id_map = note_id_map,
                .basedir = basedir,
                .allocator = allocator,
                .work_queue = wq,
                .work_queue_thread = try spawn(.{}, Self.workQueueRun, .{self}),
                .work_queue_running = true,
            };
            return self;
        }
        pub fn deinit(self: *Self) void {
            if (self.work_queue_running) {
                self.shutdown();
            }
            self.vec_storage.deinit();
            self.embedder.deinit();
            self.work_queue.deinit();
            self.note_id_map.deinit();
            self.allocator.destroy(self.note_id_map);
            self.allocator.destroy(self);
        }
        pub fn shutdown(self: *Self) void {
            {
                self.work_queue_mutex.lock();
                defer self.work_queue_mutex.unlock();
                self.work_queue_running = false;
            }
            self.work_queue_condition.signal();
            self.work_queue_thread.join();
        }

        pub fn search(self: *Self, raw_query: []const u8, buf: []SearchResult) !usize {
            const zone = tracy.beginZone(@src(), .{ .name = "vector.zig:search" });
            defer zone.end();
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();

            const max_results = buf.len;

            const query = stripQuery(raw_query);
            if (query.len == 0) return 0;

            const query_vec_union = (try self.embedder.embed(arena.allocator(), query)) orelse {
                return 0;
            };
            const query_vec = @field(query_vec_union, @tagName(embedding_model)).*;
            const vec_res = try arena.allocator().alloc(VecStorage.SearchEntry, max_results);

            debugSearchHeader(query);
            const found_n = try self.vec_storage.search(
                query_vec,
                vec_res,
                self.embedder.threshold,
            );
            for (0..found_n) |i| {
                const p = self.note_id_map.getPath(vec_res[i].row.note_id) orelse continue;
                buf[i] = SearchResult{
                    .path = p,
                    .start_i = vec_res[i].row.start_i,
                    .end_i = vec_res[i].row.end_i,
                    .similarity = vec_res[i].similarity,
                };
            }

            std.log.info("Found {d} results searching with `{s}`", .{ found_n, query });
            return found_n;
        }

        pub fn uniqueSearch(self: *Self, raw_query: []const u8, buf: []SearchResult) !usize {
            const zone = tracy.beginZone(@src(), .{ .name = "vector.zig:uniqueSearch" });
            defer zone.end();
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();

            const query = stripQuery(raw_query);
            if (query.len == 0) return 0;

            const query_vec_union = (try self.embedder.embed(arena.allocator(), query)) orelse return 0;
            const query_vec = @field(query_vec_union, @tagName(embedding_model)).*;

            debugSearchHeader(query);
            var search_results: [1000]VecStorage.SearchEntry = undefined;
            const found_n = try self.vec_storage.search(
                query_vec,
                &search_results,
                self.embedder.threshold,
            );
            var unique_found_n: usize = 0;
            outer: for (0..@min(found_n, buf.len)) |i| {
                const row = search_results[i].row;
                const path = self.note_id_map.getPath(row.note_id) orelse continue;
                for (0..unique_found_n) |j| {
                    if (std.mem.eql(u8, buf[j].path, path)) continue :outer;
                }
                buf[unique_found_n] = SearchResult{
                    .path = path,
                    .start_i = row.start_i,
                    .end_i = row.end_i,
                    .similarity = search_results[i].similarity,
                };
                unique_found_n += 1;
            }

            std.log.info(
                "Condensed {d} duplicate results to {d} duplicate searching with {s}\n",
                .{ found_n, unique_found_n, query },
            );
            return unique_found_n;
        }

        pub fn populateHighlights(
            self: *Self,
            query: []const u8,
            result_content: []const u8,
            highlights: []usize,
        ) !void {
            const zone = tracy.beginZone(@src(), .{ .name = "vector.zig:populateHighlights" });
            defer zone.end();

            const max_highlights = @divExact(highlights.len, 2);

            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();

            const query_vec_union = (try self.embedder.embed(arena.allocator(), query)) orelse return;
            const query_vec = @field(query_vec_union, @tagName(embedding_model)).*;

            var found: u8 = 0;
            var wordspliterator = embed.WordSpliterator.init(result_content);
            while (wordspliterator.next()) |word_chunk| {
                const chunk_vec_union = (try self.embedder.embed(
                    arena.allocator(),
                    word_chunk.contents,
                )) orelse continue;
                const chunk_vec = @field(chunk_vec_union, @tagName(embedding_model)).*;

                const similar = vec_storage.cosine_similarity(
                    VEC_SZ,
                    VEC_TYPE,
                    chunk_vec,
                    query_vec,
                );
                if (similar > self.embedder.strict_threshold) {
                    highlights[found * 2] = word_chunk.start_i;
                    highlights[found * 2 + 1] = word_chunk.end_i;
                    found += 1;
                    if (found >= max_highlights) return;
                }
            }
            return;
        }

        pub fn workQueueRun(self: *@This()) !void {
            while (true) {
                self.work_queue_mutex.lock();
                const job = while (true) {
                    if (self.work_queue.pop()) |j| {
                        self.work_queue_mutex.unlock();
                        break j;
                    }
                    if (!self.work_queue_running) {
                        self.work_queue_mutex.unlock();
                        return;
                    }
                    self.work_queue_condition.wait(&self.work_queue_mutex);
                };
                defer self.allocator.free(job.contents);
                defer self.allocator.free(job.path);
                self.embedTextInternal(job.path, job.contents) catch |err| {
                    std.log.err("embedText error: {}", .{err});
                };
            }
        }

        const EmbeddedSentence = struct {
            vec: ?*const [VEC_SZ]VEC_TYPE,
            start_i: usize,
            end_i: usize,
        };

        pub fn embedText(
            self: *Self,
            path: []const u8,
            contents: []const u8,
        ) !void {
            return self.embedTextInternal(path, contents);
        }

        fn embedTextInternal(
            self: *Self,
            path: []const u8,
            contents: []const u8,
        ) !void {
            const zone = tracy.beginZone(@src(), .{ .name = "vector.zig:embedText" });
            defer zone.end();
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            const allocator = arena.allocator();
            assert(contents.len < MAX_NOTE_LEN);

            var embedded_sentence_list = std.ArrayList(EmbeddedSentence).init(allocator);
            errdefer embedded_sentence_list.deinit();
            var spliterator = embed.SentenceSpliterator.init(contents);
            while (spliterator.next()) |sentence| {
                const vec: ?*const [VEC_SZ]VEC_TYPE =
                    if (whitespaceOnly(sentence.contents) or !wordlike(sentence.contents))
                        null
                    else if (try self.embedder.embed(allocator, sentence.contents)) |v|
                        @field(v, @tagName(embedding_model))
                    else
                        null;

                try embedded_sentence_list.append(.{
                    .vec = vec,
                    .start_i = sentence.start_i,
                    .end_i = sentence.end_i,
                });
            }
            const embedded_sentences = try embedded_sentence_list.toOwnedSlice();
            const note_id = try self.note_id_map.getOrCreateId(path);
            try self.replaceVectors(allocator, note_id, embedded_sentences);

            std.log.info("Embedded {d} sentences\n", .{embedded_sentences.len});
        }

        pub fn embedTextAsync(
            self: *Self,
            path: []const u8,
            contents: []const u8,
        ) !void {
            {
                self.work_queue_mutex.lock();
                defer self.work_queue_mutex.unlock();
                if (!self.work_queue_running) return error.NotQueuedShuttingDown;
            }
            const owned_path = try self.allocator.dupe(u8, path);
            errdefer self.allocator.free(owned_path);
            const owned_contents = try self.allocator.alloc(u8, contents.len);
            @memcpy(owned_contents, contents);
            try self.work_queue.push(.{ .path = owned_path, .contents = owned_contents });
            self.work_queue_condition.signal();
        }

        fn replaceVectors(
            self: *Self,
            allocator: std.mem.Allocator,
            note_id: NoteID,
            embedded_sentences: []const EmbeddedSentence,
        ) !void {
            const old_vecs = try self.vec_storage.vecsForNote(allocator, note_id);
            defer allocator.free(old_vecs);

            for (embedded_sentences) |sentence| {
                if (sentence.vec) |v| {
                    _ = try self.vec_storage.put(note_id, sentence.start_i, sentence.end_i, v.*);
                }
            }

            for (old_vecs) |old_v| {
                self.vec_storage.rm(old_v.id) catch |e| switch (e) {
                    vec_storage.Error.MultipleRemove => continue,
                    else => unreachable,
                };
            }
            try self.vec_storage.save(self.embedder.path);
        }

        pub fn validate(self: *Self) !void {
            try self.vec_storage.validate();
        }

        pub fn removePath(self: *Self, path: []const u8) !void {
            if (self.note_id_map.getId(path)) |note_id| {
                self.vec_storage.rmByNoteId(note_id);
            }
            try self.note_id_map.removePath(path);
        }

        pub fn renamePath(self: *Self, old_path: []const u8, new_path: []const u8) !void {
            try self.note_id_map.renamePath(old_path, new_path);
        }

        pub fn getPath(self: *Self, note_id: NoteID) ?[]const u8 {
            return self.note_id_map.getPath(note_id);
        }

        pub fn pruneOrphanedPaths(self: *Self, basedir: std.fs.Dir) !void {
            try self.note_id_map.pruneOrphanedPaths(basedir);
        }

        fn debugSearchHeader(query: []const u8) void {
            if (!config.debug) return;
            std.debug.print("Checking similarity against '{s}':\n", .{query});
        }
    };
}

fn whitespaceOnly(contents: []const u8) bool {
    for (contents) |c| {
        if (!std.ascii.isWhitespace(c)) return false;
    }
    return true;
}

fn wordlike(contents: []const u8) bool {
    var n_alphanumeral: usize = 0;
    for (contents) |c| {
        if (std.ascii.isAlphanumeric(c)) {
            n_alphanumeral += 1;
            if (n_alphanumeral > 1) return true;
        }
    }
    return false;
}

const TestVecDB = VectorDB(.apple_nlembedding);
const TestVector = @Vector(NLEmbedder.VEC_SZ, NLEmbedder.VEC_TYPE);
fn getVectorsForPath(db: *TestVecDB, path: []const u8, buf: []TestVector) !usize {
    const note_id = db.note_id_map.getId(path) orelse return 0;
    const vec_rows = try db.vec_storage.vecsForNote(testing_allocator, note_id);
    defer testing_allocator.free(vec_rows);
    for (vec_rows, 0..) |v, i| {
        buf[i] = db.vec_storage.getVec(v.row.vec_id);
    }
    return vec_rows.len;
}

test "embedText hello" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();
    const te = try testEmbedder(testing_allocator);
    defer testing_allocator.destroy(te.e);
    var db = try TestVecDB.init(arena.allocator(), tmpD.dir, te.iface);
    defer db.deinit();

    const path = "test.md";
    const text = "hello";
    try db.embedText(path, text);

    var buf: [1]SearchResult = undefined;
    try expectEqual(1, try db.search(text, &buf));

    try expectSearchResultsIgnoresimilarity(&[_]SearchResult{
        .{ .path = path, .start_i = 0, .end_i = 5 },
    }, buf[0..1]);

    try db.validate();
}

test "embedText skip empties" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();
    const te = try testEmbedder(testing_allocator);
    defer testing_allocator.destroy(te.e);
    var db = try TestVecDB.init(arena.allocator(), tmpD.dir, te.iface);
    defer db.deinit();

    const path = "test.md";
    const text = "/hello/";
    try db.embedText(path, text);

    try db.validate();
}

test "embedText clear previous" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();
    const te = try testEmbedder(testing_allocator);
    defer testing_allocator.destroy(te.e);
    var db = try TestVecDB.init(arena.allocator(), tmpD.dir, te.iface);
    defer db.deinit();

    const path = "test.md";
    try db.embedText(path, "hello");

    var buf: [1]SearchResult = undefined;
    try expectEqual(1, try db.search("hello", &buf));
    try db.embedText(path, "flatiron");
    try expectEqual(0, try db.search("hello", &buf));

    try db.validate();
}

test "search" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();
    const te = try testEmbedder(testing_allocator);
    defer testing_allocator.destroy(te.e);
    var db = try TestVecDB.init(arena.allocator(), tmpD.dir, te.iface);
    defer db.deinit();

    const path = "test.md";
    try db.embedText(path, "pizza. pizza. pizza.");

    var buffer: [10]SearchResult = undefined;
    try expectEqual(3, try db.search("pizza", &buffer));
    try expectSearchResultsIgnoresimilarity(&[_]SearchResult{
        .{ .path = path, .start_i = 0, .end_i = 5 },
        .{ .path = path, .start_i = 7, .end_i = 12 },
        .{ .path = path, .start_i = 14, .end_i = 19 },
    }, buffer[0..3]);

    try db.validate();
}

test "search mpnet" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();
    var e = try MpnetEmbedder.init();
    var db = try VectorDB(.mpnet_embedding).init(arena.allocator(), tmpD.dir, e.embedder());
    defer db.deinit();

    const path = "test.md";
    try db.embedText(path, "pizza. pizza. pizza.");

    var buffer: [10]SearchResult = undefined;
    try expectEqual(3, try db.search("pizza", &buffer));
    try expectSearchResultsIgnoresimilarity(&[_]SearchResult{
        .{ .path = path, .start_i = 0, .end_i = 5 },
        .{ .path = path, .start_i = 7, .end_i = 12 },
        .{ .path = path, .start_i = 14, .end_i = 19 },
    }, buffer[0..3]);

    try db.validate();
}

test "uniqueSearch" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();
    const te = try testEmbedder(testing_allocator);
    defer testing_allocator.destroy(te.e);
    var db = try TestVecDB.init(arena.allocator(), tmpD.dir, te.iface);
    defer db.deinit();

    const path = "test.md";
    try db.embedText(path, "pizza. pizza. pizza.");

    var buffer: [10]SearchResult = undefined;
    try expectEqual(1, try db.uniqueSearch("pizza", &buffer));
    try expectSearchResultsIgnoresimilarity(&[_]SearchResult{
        .{ .path = path, .start_i = 0, .end_i = 5 },
    }, buffer[0..1]);

    try db.validate();
}

test "search returns results with similarity" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();
    const te = try testEmbedder(testing_allocator);
    defer testing_allocator.destroy(te.e);
    var db = try TestVecDB.init(arena.allocator(), tmpD.dir, te.iface);
    defer db.deinit();

    const path = "test.md";
    try db.embedText(path, "brick. tacos. pizza.");
    db.embedder.threshold = 0.0;

    var buffer: [10]SearchResult = undefined;
    try expectEqual(3, try db.search("pizza", &buffer));

    try expectSearchResultsIgnoresimilarity(&[_]SearchResult{
        .{ .path = path, .start_i = 14, .end_i = 19 },
        .{ .path = path, .start_i = 7, .end_i = 12 },
        .{ .path = path, .start_i = 0, .end_i = 5 },
    }, buffer[0..3]);

    try std.testing.expect(buffer[0].similarity > 0);
    try std.testing.expect(buffer[1].similarity > 0);
    try std.testing.expect(buffer[2].similarity > 0);
    try std.testing.expect(buffer[0].similarity >= buffer[1].similarity);
    try std.testing.expect(buffer[1].similarity >= buffer[2].similarity);

    try db.validate();
}

test "uniqueSearch returns results with similarity" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();
    const te = try testEmbedder(testing_allocator);
    defer testing_allocator.destroy(te.e);
    var db = try TestVecDB.init(arena.allocator(), tmpD.dir, te.iface);
    defer db.deinit();

    const path1 = "test1.md";
    try db.embedText(path1, "brick");
    const path2 = "test2.md";
    try db.embedText(path2, "tacos");
    const path3 = "test3.md";
    try db.embedText(path3, "pizza");
    db.embedder.threshold = 0.0;

    var buffer: [10]SearchResult = undefined;
    try expectEqual(3, try db.search("pizza", &buffer));

    try expectSearchResultsIgnoresimilarity(&[_]SearchResult{
        .{ .path = path3, .start_i = 0, .end_i = 5 },
        .{ .path = path2, .start_i = 0, .end_i = 5 },
        .{ .path = path1, .start_i = 0, .end_i = 5 },
    }, buffer[0..3]);

    try std.testing.expect(buffer[0].similarity > 0);
    try std.testing.expect(buffer[1].similarity > 0);
    try std.testing.expect(buffer[2].similarity > 0);
    try std.testing.expect(buffer[0].similarity >= buffer[1].similarity);
    try std.testing.expect(buffer[1].similarity >= buffer[2].similarity);

    try db.validate();
}

test "embed chunk cleanup" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();
    const te = try testEmbedder(testing_allocator);
    defer testing_allocator.destroy(te.e);
    var db = try TestVecDB.init(arena.allocator(), tmpD.dir, te.iface);
    defer db.deinit();

    // Make the threshold strict, results should be exact matches.
    db.embedder.threshold = 0.95;

    const cases = [_]struct { name: []const u8, query: []const u8, entry: []const u8 }{
        .{
            .name = "link-removal",
            .query = "dogs",
            .entry = "dogs https://en.wikipedia.org/wiki/Dog",
        },
        .{
            .name = "space-removal",
            .query = "dogs",
            .entry = "        dogs          ",
        },
        .{
            .name = "h1-removal",
            .query = "dogs",
            .entry = "# dogs",
        },
        .{
            .name = "hN-removal",
            .query = "dogs",
            .entry = "###### dogs",
        },
        .{
            .name = "garbage-removal",
            .query = "dogs",
            .entry = "@ #$%^&*()_+<>:\"{}|,/;'[]\\dogs@ #$%^&*()_+<>:\"{}|,/;'[]\\",
        },
    };
    for (cases) |case| {
        try db.embedText(case.name, case.entry);
        defer db.removePath(case.name) catch @panic("this should not happen!");
        var result: [1]SearchResult = undefined;
        try expectEqualCase(1, try db.search(case.query, &result), case.name);
        try expectEqualCase(1, try db.uniqueSearch(case.query, &result), case.name);
    }
}

fn expectEqualCase(a: anytype, b: anytype, case: []const u8) !void {
    expectEqual(a, b) catch |e| {
        std.debug.print("... on case: {s}\n", .{case});
        return e;
    };
}

test "search cap results" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();
    const te = try testEmbedder(testing_allocator);
    defer testing_allocator.destroy(te.e);
    var db = try TestVecDB.init(arena.allocator(), tmpD.dir, te.iface);
    defer db.deinit();

    for (0..150) |i| {
        var buf: [10]u8 = undefined;
        try db.embedText(try bufPrint(&buf, "{d}", .{i}), "brick");
    }
    var results: [100]SearchResult = undefined;
    try expectEqual(100, try db.search("brick", &results));
    try expectEqual(100, try db.uniqueSearch("brick", &results));
}

test "search strip queries" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();
    const te = try testEmbedder(testing_allocator);
    defer testing_allocator.destroy(te.e);
    var db = try TestVecDB.init(arena.allocator(), tmpD.dir, te.iface);
    defer db.deinit();

    var results: [1]SearchResult = undefined;
    _ = try db.search("??foo??", &results);
    _ = try db.uniqueSearch("??foo??", &results);
}

fn expectSearchResultsIgnoresimilarity(expected: []const SearchResult, actual: []const SearchResult) !void {
    if (expected.len != actual.len) {
        std.debug.print(
            "slice lengths differ: expected {d}, found {d}\n",
            .{ expected.len, actual.len },
        );
        return error.TestExpectedEqual;
    }
    for (expected, actual, 0..) |e, a, i| {
        if (!std.mem.eql(u8, e.path, a.path) or e.start_i != a.start_i or e.end_i != a.end_i) {
            std.debug.print(
                "index {d}: expected {{ .path = {s}, .start_i = {d}, .end_i = {d} }}, found {{ .path = {s}, .start_i = {d}, .end_i = {d} }}\n",
                .{ i, e.path, e.start_i, e.end_i, a.path, a.start_i, a.end_i },
            );
            return error.TestExpectedEqual;
        }
    }
}

pub fn testEmbedder(allocator: std.mem.Allocator) !struct { e: *NLEmbedder, iface: embed.Embedder } {
    const e = try allocator.create(NLEmbedder);
    e.* = try NLEmbedder.init();
    return .{ .e = e, .iface = e.embedder() };
}

test "embedText same input same result" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();
    const te = try testEmbedder(testing_allocator);
    defer testing_allocator.destroy(te.e);
    var db = try TestVecDB.init(arena.allocator(), tmpD.dir, te.iface);
    defer db.deinit();

    const path = "test.md";
    try db.embedText(path, "apple");
    var initial_vecs: [1]TestVector = undefined;
    try expectEqual(1, try getVectorsForPath(db, path, &initial_vecs));

    try db.embedText(path, "apple");
    var updated_vecs: [1]TestVector = undefined;
    try expectEqual(1, try getVectorsForPath(db, path, &updated_vecs));

    try std.testing.expect(@reduce(.And, initial_vecs[0] == updated_vecs[0]));

    try db.validate();
}

test "embedText different input different result" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();
    const te = try testEmbedder(testing_allocator);
    defer testing_allocator.destroy(te.e);
    var db = try TestVecDB.init(arena.allocator(), tmpD.dir, te.iface);
    defer db.deinit();

    const path = "test.md";
    try db.embedText(path, "apple");
    var initial_vecs: [1]TestVector = undefined;
    try expectEqual(1, try getVectorsForPath(db, path, &initial_vecs));

    try db.embedText(path, "banana");
    var updated_vecs: [1]TestVector = undefined;
    try expectEqual(1, try getVectorsForPath(db, path, &updated_vecs));

    // Vector should be different (apple != banana)
    try std.testing.expect(!@reduce(.And, initial_vecs[0] == updated_vecs[0]));

    try db.validate();
}

test "embedText updates only changed sentences" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();
    const te = try testEmbedder(testing_allocator);
    defer testing_allocator.destroy(te.e);
    var db = try TestVecDB.init(arena.allocator(), tmpD.dir, te.iface);
    defer db.deinit();

    const path = "test.md";
    // Initial content: three one-word sentences (only embeddable words get stored)
    const initial_content = "apple. banana. cherry.";
    try db.embedText(path, initial_content);

    var initial_vecs: [3]TestVector = undefined;
    try expectEqual(3, try getVectorsForPath(db, path, &initial_vecs));

    // Updated content: same first and last words, different middle word
    const updated_content = "apple. dragonfruit. cherry.";
    try db.embedText(path, updated_content);

    var updated_vecs: [3]TestVector = undefined;
    try expectEqual(3, try getVectorsForPath(db, path, &updated_vecs));

    try std.testing.expect(@reduce(.And, initial_vecs[0] == updated_vecs[0]));
    try std.testing.expect(!@reduce(.And, initial_vecs[1] == updated_vecs[1]));
    try std.testing.expect(@reduce(.And, initial_vecs[2] == updated_vecs[2]));

    try db.validate();
}

test "embedText handle multiple remove gracefully" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();
    const te = try testEmbedder(testing_allocator);
    defer testing_allocator.destroy(te.e);
    var db = try TestVecDB.init(arena.allocator(), tmpD.dir, te.iface);
    defer db.deinit();

    const path = "test.md";
    const initial_content = "foo.\nfoo.\nfoo.";
    const updated_content = "bar.\nbar.\nbar.";
    try db.embedText(path, "");
    try db.embedText(path, initial_content);
    try db.embedText(path, updated_content);

    try db.validate();
}

test "populateHighlights" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();
    const te = try testEmbedder(testing_allocator);
    defer testing_allocator.destroy(te.e);
    var db = try TestVecDB.init(arena.allocator(), tmpD.dir, te.iface);
    defer db.deinit();

    {
        const query = "hello";
        const contents = "bah hello";
        var highlights: [10]usize = .{0} ** 10;
        try db.populateHighlights(query, contents, &highlights);
        try expectEqualSlices(usize, &[10]usize{ 4, 9, 0, 0, 0, 0, 0, 0, 0, 0 }, &highlights);
    }
    { // Multiple hits
        const query = "hello";
        const contents = "hello; hello ";
        var highlights: [10]usize = .{0} ** 10;
        try db.populateHighlights(query, contents, &highlights);
        try expectEqualSlices(usize, &[10]usize{ 0, 5, 7, 12, 0, 0, 0, 0, 0, 0 }, &highlights);
    }

    try db.validate();
}

test "embed skip low-value" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();
    var e = try MpnetEmbedder.init();
    var db = try VectorDB(.mpnet_embedding).init(arena.allocator(), tmpD.dir, e.embedder());
    defer db.deinit();
    db.embedder.threshold = 0;

    {
        const query = " ";
        const contents = " ";
        const path = "test1.md";
        try db.embedText(path, contents);
        var buffer: [10]SearchResult = undefined;
        try expectEqual(0, try db.search(query, &buffer));
    }
    {
        const query = " ";
        const contents = "  ";
        const path = "test2.md";
        try db.embedText(path, contents);
        var buffer: [10]SearchResult = undefined;
        try expectEqual(0, try db.search(query, &buffer));
    }
    {
        const query = " ";
        const contents = " \n\r\t ";
        const path = "test3.md";
        try db.embedText(path, contents);
        var buffer: [10]SearchResult = undefined;
        try expectEqual(0, try db.search(query, &buffer));
    }
    {
        const query = "a";
        const contents = "a#";
        const path = "test4.md";
        try db.embedText(path, contents);
        var buffer: [10]SearchResult = undefined;
        try expectEqual(0, try db.search(query, &buffer));
    }
    try db.validate();
}

test "embedTextAsync" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();
    const te = try testEmbedder(testing_allocator);
    defer testing_allocator.destroy(te.e);
    var db = try TestVecDB.init(arena.allocator(), tmpD.dir, te.iface);
    defer db.deinit();

    const path1 = "test1.md";
    const path2 = "test2.md";
    const path3 = "test3.md";

    try db.embedTextAsync(path1, "pizza");
    try db.embedTextAsync(path2, "pizza");
    try db.embedTextAsync(path3, "pizza");

    std.time.sleep(2 * std.time.ns_per_s);

    var buffer: [10]SearchResult = undefined;
    const found = try db.search("pizza", &buffer);
    try expectEqual(3, found);

    try db.validate();
}

test "embedTextAsync drains queue on shutdown" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    const te = try testEmbedder(testing_allocator);
    defer testing_allocator.destroy(te.e);
    var db = try TestVecDB.init(testing_allocator, tmpD.dir, te.iface);
    defer db.deinit();

    const N = 60;

    for (0..N) |i| {
        var path_buf: [16]u8 = undefined;
        const path = bufPrint(&path_buf, "test{d}.md", .{i + 1}) catch unreachable;
        try db.embedTextAsync(path, "pizza");
    }
    db.shutdown();

    var buffer: [N]SearchResult = undefined;
    const found = try db.search("pizza", &buffer);
    try expectEqual(N, found);

    try db.validate();
}

test "embedTextAsync rejects after shutdown" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();
    const te = try testEmbedder(testing_allocator);
    defer testing_allocator.destroy(te.e);
    var db = try TestVecDB.init(arena.allocator(), tmpD.dir, te.iface);
    defer db.deinit();

    const path = "test.md";
    db.shutdown();
    try expectEqual(Error.NotQueuedShuttingDown, db.embedTextAsync(path, "pizza"));
}

test "doctor deletes db files" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();

    // Create some db files that should be deleted
    (try tmpD.dir.createFile("vectors.db", .{})).close();
    (try tmpD.dir.createFile("metadata.db", .{})).close();
    // Create note files that should NOT be deleted
    (try tmpD.dir.createFile("note1.md", .{})).close();
    (try tmpD.dir.createFile("note2.txt", .{})).close();

    try doctor(.apple_nlembedding, arena.allocator(), tmpD.dir);

    // DB files should be deleted
    try std.testing.expectError(error.FileNotFound, tmpD.dir.access("vectors.db", .{}));
    try std.testing.expectError(error.FileNotFound, tmpD.dir.access("metadata.db", .{}));
    // Note files should still exist
    try tmpD.dir.access("note1.md", .{});
    try tmpD.dir.access("note2.txt", .{});
}

test "doctor with mpnet" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();

    {
        const f1 = try tmpD.dir.createFile("note1.md", .{});
        defer f1.close();
        try f1.writeAll("apple banana");
    }

    try doctor(.mpnet_embedding, arena.allocator(), tmpD.dir);
}

test "doctor re-embeds all notes" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();

    // Create note files with content
    {
        const f1 = try tmpD.dir.createFile("note1.md", .{});
        defer f1.close();
        try f1.writeAll("apple banana");
    }
    {
        const f2 = try tmpD.dir.createFile("note2.txt", .{});
        defer f2.close();
        try f2.writeAll("cherry dragonfruit");
    }

    try doctor(.apple_nlembedding, arena.allocator(), tmpD.dir);

    // After doctor, we should be able to search and find the notes
    const te = try testEmbedder(testing_allocator);
    defer testing_allocator.destroy(te.e);
    var db = try TestVecDB.init(arena.allocator(), tmpD.dir, te.iface);
    defer db.deinit();

    var results: [10]SearchResult = undefined;
    const found = try db.search("apple", &results);
    try expect(found >= 1);
    try std.testing.expectEqualStrings("note1.md", results[0].path);
}

const std = @import("std");
const testing_allocator = std.testing.allocator;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;
const assert = std.debug.assert;

const config = @import("config");
const tracy = @import("tracy");

const bufPrint = std.fmt.bufPrint;
const embed = @import("embed.zig");
const expect = std.testing.expect;
const EmbeddingModel = embed.EmbeddingModel;
const isAlphanumeric = std.ascii.isAlphanumeric;
const note_id_map_mod = @import("note_id_map.zig");
const NoteID = note_id_map_mod.NoteID;
const NoteIdMap = note_id_map_mod.NoteIdMap;
const NLEmbedder = embed.NLEmbedder;
const MpnetEmbedder = embed.MpnetEmbedder;
const spawn = Thread.spawn;
const Thread = std.Thread;
const types = @import("types.zig");
const UniqueCircularBuffer = util.UniqueCircularBuffer;
const util = @import("util.zig");
const VectorID = types.VectorID;
const vec_storage = @import("vec_storage.zig");
