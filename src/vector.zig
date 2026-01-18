const MAX_NOTE_LEN: usize = std.math.maxInt(u32);
pub const Error = error{
    NotQueuedShuttingDown,
};

pub const CSearchResult = extern struct {
    id: c_uint,
    start_i: c_uint,
    end_i: c_uint,
    similarity: f32,
};

pub const SearchResult = struct {
    id: NoteID,
    start_i: usize,
    end_i: usize,
    similarity: f32 = 0.0,

    const Self = @This();

    pub fn toC(self: Self) CSearchResult {
        return CSearchResult{
            .id = @as(c_uint, @intCast(self.id)),
            .start_i = @as(c_uint, @intCast(self.start_i)),
            .end_i = @as(c_uint, @intCast(self.end_i)),
            .similarity = self.similarity,
        };
    }
};

pub fn VectorDB(embedding_model: EmbeddingModel) type {
    const VEC_SZ = switch (embedding_model) {
        .apple_nlembedding => NLEmbedder.VEC_SZ,
        .jina_embedding => JinaEmbedder.VEC_SZ,
    };
    const VEC_TYPE = switch (embedding_model) {
        .apple_nlembedding => NLEmbedder.VEC_TYPE,
        .jina_embedding => JinaEmbedder.VEC_TYPE,
    };

    const EmbedJob = struct {
        note_id: NoteID,
        contents: []const u8,

        pub fn id(self: @This()) NoteID {
            return self.note_id;
        }
    };

    return struct {
        const Self = @This();
        pub const VecStorage = vec_storage.Storage(VEC_SZ, VEC_TYPE);

        const WorkQueue = UniqueCircularBuffer(EmbedJob, NoteID, EmbedJob.id);

        embedder: embed.Embedder,
        vec_storage: VecStorage,
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
            const self = try allocator.create(Self);
            self.* = .{
                .embedder = embedder,
                .vec_storage = vecs,
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

        pub fn search(self: *Self, query: []const u8, buf: []SearchResult) !usize {
            const zone = tracy.beginZone(@src(), .{ .name = "vector.zig:search" });
            defer zone.end();

            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();

            const query_vec_union = (try self.embedder.embed(arena.allocator(), query)) orelse return 0;
            const query_vec = @field(query_vec_union, @tagName(embedding_model)).*;

            var search_results: [1000]VecStorage.SearchEntry = undefined;

            debugSearchHeader(query);
            const found_n = try self.vec_storage.search(
                query_vec,
                &search_results,
                self.embedder.threshold,
            );
            for (0..@min(found_n, buf.len)) |i| {
                buf[i] = SearchResult{
                    .id = search_results[i].row.note_id,
                    .start_i = search_results[i].row.start_i,
                    .end_i = search_results[i].row.end_i,
                    .similarity = search_results[i].similarity,
                };
            }

            std.log.info("Found {d} results searching with {s}\n", .{ found_n, query });
            return found_n;
        }

        pub fn uniqueSearch(self: *Self, query: []const u8, buf: []SearchResult) !usize {
            const zone = tracy.beginZone(@src(), .{ .name = "vector.zig:uniqueSearch" });
            defer zone.end();

            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();

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
                for (0..unique_found_n) |j| {
                    if (buf[j].id == row.note_id) continue :outer;
                }
                buf[unique_found_n] = SearchResult{
                    .id = row.note_id,
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
                self.embedText(job.note_id, job.contents) catch |err| {
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
            note_id: NoteID,
            contents: []const u8,
        ) !void {
            const zone = tracy.beginZone(@src(), .{ .name = "vector.zig:embedText" });
            defer zone.end();

            assert(contents.len < MAX_NOTE_LEN);

            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            const allocator = arena.allocator();

            const embedded_sentences = try self.embedNewText(allocator, contents);
            try self.replaceVectors(allocator, note_id, embedded_sentences);

            std.log.info("Embedded {d} sentences\n", .{embedded_sentences.len});
        }

        pub fn embedTextAsync(
            self: *Self,
            note_id: NoteID,
            contents: []const u8,
        ) !void {
            {
                self.work_queue_mutex.lock();
                defer self.work_queue_mutex.unlock();
                if (!self.work_queue_running) return error.NotQueuedShuttingDown;
            }
            const owned_contents = try self.allocator.alloc(u8, contents.len);
            @memcpy(owned_contents, contents);
            try self.work_queue.push(.{ .note_id = note_id, .contents = owned_contents });
            self.work_queue_condition.signal();
        }

        fn embedNewText(
            self: *Self,
            allocator: std.mem.Allocator,
            contents: []const u8,
        ) ![]EmbeddedSentence {
            var embedded = std.ArrayList(EmbeddedSentence).init(allocator);
            errdefer embedded.deinit();

            var spliterator = embed.SentenceSpliterator.init(contents);
            while (spliterator.next()) |sentence| {
                const vec: ?*const [VEC_SZ]VEC_TYPE =
                    if (whitespaceOnly(sentence.contents) or !wordlike(sentence.contents))
                        null
                    else if (try self.embedder.embed(allocator, sentence.contents)) |v|
                        @field(v, @tagName(embedding_model))
                    else
                        null;

                try embedded.append(.{
                    .vec = vec,
                    .start_i = sentence.start_i,
                    .end_i = sentence.end_i,
                });
            }

            return embedded.toOwnedSlice();
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
                    _ = try self.vec_storage.put(.{
                        .note_id = note_id,
                        .start_i = sentence.start_i,
                        .end_i = sentence.end_i,
                        .vec = v.*,
                    });
                }
            }

            for (old_vecs) |old_v| {
                self.vec_storage.rm(old_v.id) catch |e| switch (e) {
                    vec_storage.Error.MultipleRemove => continue,
                    vec_storage.Error.OverlappingVectors => unreachable,
                };
            }
            try self.vec_storage.save(self.embedder.path);
        }

        pub fn validate(self: *Self) !void {
            try self.vec_storage.validate();
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
fn getVectorsForNote(db: *TestVecDB, noteID: NoteID, buf: []TestVector) !usize {
    const vec_rows = try db.vec_storage.vecsForNote(testing_allocator, noteID);
    defer testing_allocator.free(vec_rows);
    for (vec_rows, 0..) |v, i| {
        buf[i] = v.row.vec;
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

    const id: NoteID = 1;

    const text = "hello";
    try db.embedText(id, text);

    var buf: [1]SearchResult = undefined;
    try expectEqual(1, try db.search(text, &buf));

    try expectSearchResultsIgnoresimilarity(&[_]SearchResult{
        .{ .id = id, .start_i = 0, .end_i = 5 },
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

    const id: NoteID = 1;

    const text = "/hello/";
    try db.embedText(id, text);

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

    const id: NoteID = 1;

    try db.embedText(id, "hello");

    var buf: [1]SearchResult = undefined;
    try expectEqual(1, try db.search("hello", &buf));
    try db.embedText(id, "flatiron");
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

    const noteID1: NoteID = 1;
    try db.embedText(noteID1, "pizza. pizza. pizza.");

    var buffer: [10]SearchResult = undefined;
    try expectEqual(3, try db.search("pizza", &buffer));
    try expectSearchResultsIgnoresimilarity(&[_]SearchResult{
        .{ .id = noteID1, .start_i = 0, .end_i = 5 },
        .{ .id = noteID1, .start_i = 6, .end_i = 12 },
        .{ .id = noteID1, .start_i = 13, .end_i = 19 },
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

    const noteID1: NoteID = 1;
    try db.embedText(noteID1, "pizza. pizza. pizza.");

    var buffer: [10]SearchResult = undefined;
    try expectEqual(1, try db.uniqueSearch("pizza", &buffer));
    try expectSearchResultsIgnoresimilarity(&[_]SearchResult{
        .{ .id = noteID1, .start_i = 0, .end_i = 5 },
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

    const noteID1: NoteID = 1;
    try db.embedText(noteID1, "brick. tacos. pizza.");
    db.embedder.threshold = 0.0;

    var buffer: [10]SearchResult = undefined;
    try expectEqual(3, try db.search("pizza", &buffer));

    try expectSearchResultsIgnoresimilarity(&[_]SearchResult{
        .{ .id = noteID1, .start_i = 13, .end_i = 19 },
        .{ .id = noteID1, .start_i = 6, .end_i = 12 },
        .{ .id = noteID1, .start_i = 0, .end_i = 5 },
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

    const noteID1: NoteID = 1;
    try db.embedText(noteID1, "brick");
    const noteID2: NoteID = 2;
    try db.embedText(noteID2, "tacos");
    const noteID3: NoteID = 3;
    try db.embedText(noteID3, "pizza");
    db.embedder.threshold = 0.0;

    var buffer: [10]SearchResult = undefined;
    try expectEqual(3, try db.search("pizza", &buffer));

    try expectSearchResultsIgnoresimilarity(&[_]SearchResult{
        .{ .id = noteID3, .start_i = 0, .end_i = 5 },
        .{ .id = noteID2, .start_i = 0, .end_i = 5 },
        .{ .id = noteID1, .start_i = 0, .end_i = 5 },
    }, buffer[0..3]);

    try std.testing.expect(buffer[0].similarity > 0);
    try std.testing.expect(buffer[1].similarity > 0);
    try std.testing.expect(buffer[2].similarity > 0);
    try std.testing.expect(buffer[0].similarity >= buffer[1].similarity);
    try std.testing.expect(buffer[1].similarity >= buffer[2].similarity);

    try db.validate();
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
        if (e.id != a.id or e.start_i != a.start_i or e.end_i != a.end_i) {
            std.debug.print(
                "index {d}: expected {{ .id = {d}, .start_i = {d}, .end_i = {d} }}, found {{ .id = {d}, .start_i = {d}, .end_i = {d} }}\n",
                .{ i, e.id, e.start_i, e.end_i, a.id, a.start_i, a.end_i },
            );
            return error.TestExpectedEqual;
        }
    }
}

fn testEmbedder(allocator: std.mem.Allocator) !struct { e: *NLEmbedder, iface: embed.Embedder } {
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

    const noteID: NoteID = 1;

    try db.embedText(noteID, "apple");
    var initial_vecs: [1]TestVector = undefined;
    try expectEqual(1, try getVectorsForNote(db, noteID, &initial_vecs));

    try db.embedText(noteID, "apple");
    var updated_vecs: [1]TestVector = undefined;
    try expectEqual(1, try getVectorsForNote(db, noteID, &updated_vecs));

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

    const noteID: NoteID = 1;

    try db.embedText(noteID, "apple");
    var initial_vecs: [1]TestVector = undefined;
    try expectEqual(1, try getVectorsForNote(db, noteID, &initial_vecs));

    try db.embedText(noteID, "banana");
    var updated_vecs: [1]TestVector = undefined;
    try expectEqual(1, try getVectorsForNote(db, noteID, &updated_vecs));

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

    const noteID: NoteID = 1;

    // Initial content: three one-word sentences (only embeddable words get stored)
    const initial_content = "apple. banana. cherry.";
    try db.embedText(noteID, initial_content);

    var initial_vecs: [3]TestVector = undefined;
    try expectEqual(3, try getVectorsForNote(db, noteID, &initial_vecs));

    // Updated content: same first and last words, different middle word
    const updated_content = "apple. dragonfruit. cherry.";
    try db.embedText(noteID, updated_content);

    var updated_vecs: [3]TestVector = undefined;
    try expectEqual(3, try getVectorsForNote(db, noteID, &updated_vecs));

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

    const noteID: NoteID = 1;

    const initial_content = "foo.\nfoo.\nfoo.";
    const updated_content = "bar.\nbar.\nbar.";
    try db.embedText(noteID, "");
    try db.embedText(noteID, initial_content);
    try db.embedText(noteID, updated_content);

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
    // Disabled due to CoreML crash on cleanup (signal 4 - SIGILL)
    // The test logic passes but cleanup crashes on some architectures
    if (true) return error.SkipZigTest;

    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();
    var e = try JinaEmbedder.init();
    var db = try VectorDB(.jina_embedding).init(arena.allocator(), tmpD.dir, e.embedder());
    defer db.deinit();

    {
        const query = " ";
        const contents = " ";
        const noteID: NoteID = 1;
        try db.embedText(noteID, contents);
        var buffer: [10]SearchResult = undefined;
        try expectEqual(0, try db.search(query, &buffer));
    }
    {
        const query = " ";
        const contents = "  ";
        const noteID: NoteID = 2;
        try db.embedText(noteID, contents);
        var buffer: [10]SearchResult = undefined;
        try expectEqual(0, try db.search(query, &buffer));
    }
    {
        const query = " ";
        const contents = " \n\r\t ";
        const noteID: NoteID = 3;
        try db.embedText(noteID, contents);
        var buffer: [10]SearchResult = undefined;
        try expectEqual(0, try db.search(query, &buffer));
    }
    {
        const query = "a";
        const contents = "a#";
        const noteID: NoteID = 4;
        try db.embedText(noteID, contents);
        var buffer: [10]SearchResult = undefined;
        try expectEqual(0, try db.search(query, &buffer));
    }
    {
        const query = "a";
        const contents = "aa#";
        const noteID: NoteID = 5;
        try db.embedText(noteID, contents);
        var buffer: [10]SearchResult = undefined;
        try expectEqual(1, try db.search(query, &buffer));
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

    const noteID1: NoteID = 1;
    const noteID2: NoteID = 2;
    const noteID3: NoteID = 3;

    try db.embedTextAsync(noteID1, "pizza");
    try db.embedTextAsync(noteID2, "pizza");
    try db.embedTextAsync(noteID3, "pizza");

    std.time.sleep(2 * std.time.ns_per_s);

    var buffer: [10]SearchResult = undefined;
    const found = try db.search("pizza", &buffer);
    try expectEqual(3, found);

    try db.validate();
}

test "embedTextAsync drains queue on shutdown" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();
    const te = try testEmbedder(testing_allocator);
    defer testing_allocator.destroy(te.e);
    var db = try TestVecDB.init(arena.allocator(), tmpD.dir, te.iface);
    defer db.deinit();

    const N = 60;

    for (0..N) |i| {
        const noteID: NoteID = @intCast(i + 1);
        try db.embedTextAsync(noteID, "pizza");
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

    const noteID: NoteID = 1;
    db.shutdown();
    try expectEqual(Error.NotQueuedShuttingDown, db.embedTextAsync(noteID, "pizza"));
}

const std = @import("std");
const testing_allocator = std.testing.allocator;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;
const assert = std.debug.assert;

const config = @import("config");
const tracy = @import("tracy");

const embed = @import("embed.zig");
const expect = std.testing.expect;
const EmbeddingModel = embed.EmbeddingModel;
const MultipleRemove = vec_storage.Error.MultipleRemove;
const NoteID = vec_storage.NoteID;
const NLEmbedder = embed.NLEmbedder;
const JinaEmbedder = embed.JinaEmbedder;
const spawn = Thread.spawn;
const Thread = std.Thread;
const types = @import("types.zig");
const UniqueCircularBuffer = util.UniqueCircularBuffer;
const util = @import("util.zig");
const VectorID = types.VectorID;
const vec_storage = @import("vec_storage.zig");
