const MAX_NOTE_LEN: usize = std.math.maxInt(u32);

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

    return struct {
        const Self = @This();
        const VecStorage = vec_storage.Storage(VEC_SZ, VEC_TYPE);

        embedder: embed.Embedder,
        relational: *model.DB,
        vec_storage: VecStorage,
        basedir: std.fs.Dir,
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator, basedir: std.fs.Dir, relational: *model.DB, embedder: embed.Embedder) !Self {
            var vecs = try VecStorage.init(allocator, basedir, .{});
            try vecs.load(embedder.path);
            return .{
                .embedder = embedder,
                .relational = relational,
                .vec_storage = vecs,
                .basedir = basedir,
                .allocator = allocator,
            };
        }
        pub fn deinit(self: *Self) void {
            self.vec_storage.deinit();
            self.embedder.deinit();
        }

        pub fn search(self: *Self, query: []const u8, buf: []SearchResult) !usize {
            const zone = tracy.beginZone(@src(), .{ .name = "vector.zig:search" });
            defer zone.end();

            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();

            const query_vec_union = (try self.embedder.embed(arena.allocator(), query)) orelse return 0;
            const query_vec = query_vec_union.apple_nlembedding.*;

            var search_results: [1000]vec_storage.SearchEntry = undefined;

            debugSearchHeader(query);
            const found_n = try self.vec_storage.search(
                query_vec,
                &search_results,
                self.embedder.threshold,
            );
            for (0..@min(found_n, buf.len)) |i| {
                const vec = try self.relational.getVec(search_results[i].id);
                buf[i] = SearchResult{
                    .id = vec.note_id,
                    .start_i = vec.start_i,
                    .end_i = vec.end_i,
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
            const query_vec = query_vec_union.apple_nlembedding.*;

            debugSearchHeader(query);
            var search_results: [1000]vec_storage.SearchEntry = undefined;
            const found_n = try self.vec_storage.search(
                query_vec,
                &search_results,
                self.embedder.threshold,
            );
            var unique_found_n: usize = 0;
            outer: for (0..@min(found_n, buf.len)) |i| {
                const vec = try self.relational.getVec(search_results[i].id);
                for (0..unique_found_n) |j| {
                    if (buf[j].id == vec.note_id) continue :outer;
                }
                buf[unique_found_n] = SearchResult{
                    .id = vec.note_id,
                    .start_i = vec.start_i,
                    .end_i = vec.end_i,
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
            const query_vec = query_vec_union.apple_nlembedding.*;

            var found: u8 = 0;
            var wordspliterator = embed.WordSpliterator.init(result_content);
            while (wordspliterator.next()) |word_chunk| {
                const chunk_vec_union = (try self.embedder.embed(
                    arena.allocator(),
                    word_chunk.contents,
                )) orelse continue;
                const chunk_vec = chunk_vec_union.apple_nlembedding.*;

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

        pub fn embedText(
            self: *Self,
            note_id: NoteID,
            old_contents: []const u8,
            new_contents: []const u8,
        ) !void {
            const zone = tracy.beginZone(@src(), .{ .name = "vector.zig:embedText" });
            defer zone.end();

            assert(new_contents.len < MAX_NOTE_LEN);
            assert(old_contents.len < MAX_NOTE_LEN);

            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            const allocator = arena.allocator();

            const old_vecs = try self.relational.vecsForNote(allocator, note_id);
            var new_vecs = std.ArrayList(VectorRow).init(allocator);
            errdefer new_vecs.deinit();

            var used_list = try allocator.alloc(bool, old_vecs.len);
            for (0..used_list.len) |i| used_list[i] = false;

            var embedded: usize = 0;
            var recycled: usize = 0;

            for ((try diffSplit(old_contents, new_contents, allocator)).items) |sentence| {
                if (sentence.new) {
                    embedded += 1;
                    const vec_id = if (try self.embedder.embed(
                        allocator,
                        sentence.contents,
                    )) |vec| block: {
                        break :block try self.vec_storage.put(vec.apple_nlembedding.*);
                    } else self.vec_storage.nullVec();

                    try new_vecs.append(.{
                        .vector_id = vec_id,
                        .note_id = note_id,
                        .start_i = sentence.off,
                        .end_i = sentence.off + sentence.contents.len,
                    });
                } else {
                    recycled += 1;
                    var found = false;
                    for (old_vecs, 0..) |old_v, i| {
                        const old_v_contents = old_contents[old_v.start_i..old_v.end_i];
                        if (!std.mem.eql(u8, sentence.contents, old_v_contents)) continue;
                        used_list[i] = true;
                        try new_vecs.append(VectorRow{
                            .vector_id = old_v.vector_id,
                            .note_id = note_id,
                            .start_i = sentence.off,
                            .end_i = sentence.off + sentence.contents.len,
                        });
                        found = true;
                        break;
                    }
                    assert(found);
                }
            }
            var last_vec_id: ?VectorID = null;
            for (0..new_vecs.items.len) |i| {
                new_vecs.items[i].last_vec_id = last_vec_id;
                last_vec_id = new_vecs.items[i].vector_id;
                if (i + 1 < new_vecs.items.len) {
                    new_vecs.items[i].next_vec_id = new_vecs.items[i].vector_id;
                }
            }

            try self.relational.setVectors(note_id, new_vecs.items);
            for (0..used_list.len) |i| {
                if (!used_list[i]) {
                    self.vec_storage.rm(old_vecs[i].vector_id) catch |e| switch (e) {
                        MultipleRemove => continue,
                        else => unreachable,
                    };
                }
            }
            try self.vec_storage.save(self.embedder.path);

            const ratio: usize = blk: {
                const num: f64 = @floatFromInt(recycled);
                const denom: f64 = @floatFromInt(recycled + embedded);
                if (denom == 0) break :blk 100;
                break :blk @intFromFloat((num / denom) * 100);
            };
            std.log.info("Recycled Ratio: {d}%, Embedded: {d}, Recycled: {d}\n", .{
                ratio,
                embedded,
                recycled,
            });
            return;
        }

        fn delete(self: *Self, id: VectorID) !void {
            try self.relational.deleteVec(id);
        }

        fn debugSearchHeader(query: []const u8) void {
            if (!config.debug) return;
            std.debug.print("Checking similarity against '{s}':\n", .{query});
        }
    };
}

const TestVecDB = VectorDB(.apple_nlembedding);
const TestVector = @Vector(NLEmbedder.VEC_SZ, NLEmbedder.VEC_TYPE);
fn getVectorsForNote(db: *TestVecDB, noteID: NoteID, buf: []TestVector) !usize {
    const vec_rows = try db.relational.vecsForNote(testing_allocator, noteID);
    defer testing_allocator.free(vec_rows);
    for (vec_rows, 0..) |v, i| {
        buf[i] = db.vec_storage.get(v.vector_id);
    }
    return vec_rows.len;
}

test "embedText hello" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();
    var rel = try model.DB.init(arena.allocator(), .{ .mem = true, .basedir = tmpD.dir });
    defer rel.deinit();
    const te = try testEmbedder(testing_allocator);
    defer testing_allocator.destroy(te.e);
    var db = try TestVecDB.init(arena.allocator(), tmpD.dir, &rel, te.iface);
    defer db.deinit();

    const id = try rel.create();

    const text = "hello";
    try db.embedText(id, "", text);

    var buf: [1]SearchResult = undefined;
    try expectEqual(1, try db.search(text, &buf));

    try expectSearchResultsIgnoresimilarity(&[_]SearchResult{
        .{ .id = id, .start_i = 0, .end_i = 5 },
    }, buf[0..1]);
}

test "embedText skip empties" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();
    var rel = try model.DB.init(arena.allocator(), .{ .mem = true, .basedir = tmpD.dir });
    defer rel.deinit();
    const te = try testEmbedder(testing_allocator);
    defer testing_allocator.destroy(te.e);
    var db = try TestVecDB.init(arena.allocator(), tmpD.dir, &rel, te.iface);
    defer db.deinit();

    const id = try rel.create();

    const text = "/hello/";
    try db.embedText(id, "", text);
}

test "embedText clear previous" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();
    var rel = try model.DB.init(arena.allocator(), .{ .mem = true, .basedir = tmpD.dir });
    defer rel.deinit();
    const te = try testEmbedder(testing_allocator);
    defer testing_allocator.destroy(te.e);
    var db = try TestVecDB.init(arena.allocator(), tmpD.dir, &rel, te.iface);
    defer db.deinit();

    const id = try rel.create();

    try db.embedText(id, "", "hello");

    var buf: [1]SearchResult = undefined;
    try expectEqual(1, try db.search("hello", &buf));
    try db.embedText(id, "hello", "flatiron");
    try expectEqual(0, try db.search("hello", &buf));
}

test "search" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();
    var rel = try model.DB.init(arena.allocator(), .{ .mem = true, .basedir = tmpD.dir });
    defer rel.deinit();
    const te = try testEmbedder(testing_allocator);
    defer testing_allocator.destroy(te.e);
    var db = try TestVecDB.init(arena.allocator(), tmpD.dir, &rel, te.iface);
    defer db.deinit();

    const noteID1 = try rel.create();
    _ = try db.embedText(noteID1, "", "pizza. pizza. pizza.");

    var buffer: [10]SearchResult = undefined;
    try expectEqual(3, try db.search("pizza", &buffer));
    try expectSearchResultsIgnoresimilarity(&[_]SearchResult{
        .{ .id = noteID1, .start_i = 0, .end_i = 5 },
        .{ .id = noteID1, .start_i = 6, .end_i = 12 },
        .{ .id = noteID1, .start_i = 13, .end_i = 19 },
    }, buffer[0..3]);
}

test "uniqueSearch" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();
    var rel = try model.DB.init(arena.allocator(), .{ .mem = true, .basedir = tmpD.dir });
    defer rel.deinit();
    const te = try testEmbedder(testing_allocator);
    defer testing_allocator.destroy(te.e);
    var db = try TestVecDB.init(arena.allocator(), tmpD.dir, &rel, te.iface);
    defer db.deinit();

    const noteID1 = try rel.create();
    _ = try db.embedText(noteID1, "", "pizza. pizza. pizza.");

    var buffer: [10]SearchResult = undefined;
    try expectEqual(1, try db.uniqueSearch("pizza", &buffer));
    try expectSearchResultsIgnoresimilarity(&[_]SearchResult{
        .{ .id = noteID1, .start_i = 0, .end_i = 5 },
    }, buffer[0..1]);
}

test "search returns results with similarity" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();
    var rel = try model.DB.init(arena.allocator(), .{ .mem = true, .basedir = tmpD.dir });
    defer rel.deinit();
    const te = try testEmbedder(testing_allocator);
    defer testing_allocator.destroy(te.e);
    var db = try TestVecDB.init(arena.allocator(), tmpD.dir, &rel, te.iface);
    defer db.deinit();

    const noteID1 = try rel.create();
    _ = try db.embedText(noteID1, "", "brick. tacos. pizza.");
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
}

test "uniqueSearch returns results with similarity" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();
    var rel = try model.DB.init(arena.allocator(), .{ .mem = true, .basedir = tmpD.dir });
    defer rel.deinit();
    const te = try testEmbedder(testing_allocator);
    defer testing_allocator.destroy(te.e);
    var db = try TestVecDB.init(arena.allocator(), tmpD.dir, &rel, te.iface);
    defer db.deinit();

    const noteID1 = try rel.create();
    try rel.update(noteID1);
    _ = try db.embedText(noteID1, "", "brick");
    const noteID2 = try rel.create();
    try rel.update(noteID2);
    _ = try db.embedText(noteID2, "", "tacos");
    const noteID3 = try rel.create();
    try rel.update(noteID3);
    _ = try db.embedText(noteID3, "", "pizza");
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

test "embedText no update" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();
    var rel = try model.DB.init(arena.allocator(), .{ .mem = true, .basedir = tmpD.dir });
    defer rel.deinit();
    const te = try testEmbedder(testing_allocator);
    defer testing_allocator.destroy(te.e);
    var db = try TestVecDB.init(arena.allocator(), tmpD.dir, &rel, te.iface);
    defer db.deinit();

    const noteID = try rel.create();

    try db.embedText(noteID, "", "apple");
    var initial_vecs: [1]TestVector = undefined;
    try expectEqual(1, try getVectorsForNote(&db, noteID, &initial_vecs));

    try db.embedText(noteID, "apple", "apple");
    var updated_vecs: [1]TestVector = undefined;
    try expectEqual(1, try getVectorsForNote(&db, noteID, &updated_vecs));

    // Vector should be different (apple != banana)
    try std.testing.expect(@reduce(.And, initial_vecs[0] == updated_vecs[0]));
}

test "embedText updates single word sentence" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();
    var rel = try model.DB.init(arena.allocator(), .{ .mem = true, .basedir = tmpD.dir });
    defer rel.deinit();
    const te = try testEmbedder(testing_allocator);
    defer testing_allocator.destroy(te.e);
    var db = try TestVecDB.init(arena.allocator(), tmpD.dir, &rel, te.iface);
    defer db.deinit();

    const noteID = try rel.create();

    try db.embedText(noteID, "", "apple");
    var initial_vecs: [1]TestVector = undefined;
    try expectEqual(1, try getVectorsForNote(&db, noteID, &initial_vecs));

    try db.embedText(noteID, "apple", "banana");
    var updated_vecs: [1]TestVector = undefined;
    try expectEqual(1, try getVectorsForNote(&db, noteID, &updated_vecs));

    // Vector should be different (apple != banana)
    try std.testing.expect(!@reduce(.And, initial_vecs[0] == updated_vecs[0]));
}

test "embedText updates last sentence" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();
    var rel = try model.DB.init(arena.allocator(), .{ .mem = true, .basedir = tmpD.dir });
    defer rel.deinit();
    const te = try testEmbedder(testing_allocator);
    defer testing_allocator.destroy(te.e);
    var db = try TestVecDB.init(arena.allocator(), tmpD.dir, &rel, te.iface);
    defer db.deinit();

    const noteID = try rel.create();

    try db.embedText(noteID, "", "apple. banana.");
    var initial_vecs: [2]TestVector = undefined;
    try expectEqual(2, try getVectorsForNote(&db, noteID, &initial_vecs));

    try db.embedText(noteID, "apple. banana.", "apple. orange.");
    var updated_vecs: [2]TestVector = undefined;
    try expectEqual(2, try getVectorsForNote(&db, noteID, &updated_vecs));

    // First vector should be the same (apple == apple)
    try std.testing.expect(@reduce(.And, initial_vecs[0] == updated_vecs[0]));

    // Last vector should be different (banana != orange)
    try std.testing.expect(!@reduce(.And, initial_vecs[1] == updated_vecs[1]));
}

test "embedText updates only changed sentences" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();
    var rel = try model.DB.init(arena.allocator(), .{ .mem = true, .basedir = tmpD.dir });
    defer rel.deinit();
    const te = try testEmbedder(testing_allocator);
    defer testing_allocator.destroy(te.e);
    var db = try TestVecDB.init(arena.allocator(), tmpD.dir, &rel, te.iface);
    defer db.deinit();

    const noteID = try rel.create();

    // Initial content: three one-word sentences
    const initial_content = "apple. banana. cherry.";
    try db.embedText(noteID, "", initial_content);

    var initial_vecs: [3]TestVector = undefined;
    try expectEqual(3, try getVectorsForNote(&db, noteID, &initial_vecs));

    // Updated content: same first and last words, different middle word
    const updated_content = "apple. dragonfruit. cherry.";
    try db.embedText(noteID, initial_content, updated_content);

    var updated_vecs: [3]TestVector = undefined;
    try expectEqual(3, try getVectorsForNote(&db, noteID, &updated_vecs));

    try std.testing.expect(@reduce(.And, initial_vecs[0] == updated_vecs[0]));
    try std.testing.expect(!@reduce(.And, initial_vecs[1] == updated_vecs[1]));
    try std.testing.expect(@reduce(.And, initial_vecs[2] == updated_vecs[2]));
}

test "embedText handle newlines" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();
    var rel = try model.DB.init(arena.allocator(), .{ .mem = true, .basedir = tmpD.dir });
    defer rel.deinit();
    const te = try testEmbedder(testing_allocator);
    defer testing_allocator.destroy(te.e);
    var db = try TestVecDB.init(arena.allocator(), tmpD.dir, &rel, te.iface);
    defer db.deinit();

    const noteID = try rel.create();

    const initial_content = "apple.\nbanana.\ngrape.";
    try db.embedText(noteID, "", initial_content);

    var initial_vecs: [3]TestVector = undefined;
    try expectEqual(3, try getVectorsForNote(&db, noteID, &initial_vecs));

    const updated_content = "apple.\norange.\ngrape.";
    try db.embedText(noteID, initial_content, updated_content);

    var updated_vecs: [3]TestVector = undefined;
    try expectEqual(3, try getVectorsForNote(&db, noteID, &updated_vecs));

    try std.testing.expect(@reduce(.And, initial_vecs[0] == updated_vecs[0]));
    try std.testing.expect(!@reduce(.And, initial_vecs[1] == updated_vecs[1]));
    try std.testing.expect(@reduce(.And, initial_vecs[2] == updated_vecs[2]));
}

test "handle multiple remove gracefully" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();
    var rel = try model.DB.init(arena.allocator(), .{ .mem = true, .basedir = tmpD.dir });
    defer rel.deinit();
    const te = try testEmbedder(testing_allocator);
    defer testing_allocator.destroy(te.e);
    var db = try TestVecDB.init(arena.allocator(), tmpD.dir, &rel, te.iface);
    defer db.deinit();

    const noteID = try rel.create();

    const initial_content = "foo.\nfoo.\nfoo.";
    const updated_content = "bar.\nbar.\nbar.";
    try db.embedText(noteID, "", initial_content);
    try db.embedText(noteID, initial_content, initial_content);
    try db.embedText(noteID, initial_content, updated_content);
}

test "populateHighlights" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();
    var rel = try model.DB.init(arena.allocator(), .{ .mem = true, .basedir = tmpD.dir });
    defer rel.deinit();
    const te = try testEmbedder(testing_allocator);
    defer testing_allocator.destroy(te.e);
    var db = try TestVecDB.init(arena.allocator(), tmpD.dir, &rel, te.iface);
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
}

const std = @import("std");
const testing_allocator = std.testing.allocator;
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;
const assert = std.debug.assert;

const config = @import("config");
const tracy = @import("tracy");

const diff = @import("dmp.zig");
const diffSplit = diff.diffSplit;
const embed = @import("embed.zig");
const EmbeddingModel = embed.EmbeddingModel;
const model = @import("model.zig");
const Note = model.Note;
const VectorRow = model.VectorRow;
const MultipleRemove = vec_storage.Error.MultipleRemove;
const NoteID = model.NoteID;
const NLEmbedder = embed.NLEmbedder;
const JinaEmbedder = embed.JinaEmbedder;
const types = @import("types.zig");
const VectorID = types.VectorID;
const vec_storage = @import("vec_storage.zig");
