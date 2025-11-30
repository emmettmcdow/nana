const VECTOR_DB_PATH = "vecs.db";

const MAX_NOTE_LEN: usize = std.math.maxInt(u32);

pub const DB = struct {
    const Self = @This();

    embedder: embed.Embedder,
    relational: *model.DB,
    vecs: vec_storage.Storage,
    basedir: std.fs.Dir,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, basedir: std.fs.Dir, relational: *model.DB) !Self {
        var vecs = try vec_storage.Storage.init(allocator, basedir, .{});
        try vecs.load(VECTOR_DB_PATH);
        const embedder = try embed.Embedder.init(allocator);
        return .{
            .embedder = embedder,
            .relational = relational,
            .vecs = vecs,
            .basedir = basedir,
            .allocator = allocator,
        };
    }
    pub fn deinit(self: *Self) void {
        self.vecs.deinit();
        self.embedder.deinit();
    }

    pub fn search(self: *Self, query: []const u8, buf: []c_int) !usize {
        const zone = tracy.beginZone(@src(), .{ .name = "vector.zig:search" });
        defer zone.end();

        const query_vec_slice = (try self.embedder.embed(query)) orelse return 0;
        defer self.allocator.free(query_vec_slice);
        const query_vec: Vector = query_vec_slice[0..vec_sz].*;

        var vec_ids: [1000]VectorID = undefined;

        debugSearchHeader(query);
        const found_n = try self.vecs.search(query_vec, &vec_ids);
        try self.debugSearchRankedResults(vec_ids[0..found_n]);

        var unique_found_n: usize = 0;
        outer: for (0..@min(found_n, buf.len)) |i| {
            const noteID = @as(c_int, @intCast(try self.relational.vecToNote(vec_ids[i])));
            for (0..unique_found_n) |j| {
                if (buf[j] == noteID) continue :outer;
            }
            buf[unique_found_n] = noteID;
            unique_found_n += 1;
        }
        std.log.info("Found {d} results searching with {s}\n", .{ unique_found_n, query });
        return unique_found_n;
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

        const old_vecs = try self.relational.vecsForNote(arena.allocator(), note_id);
        var new_vecs = std.ArrayList(VectorRow).init(arena.allocator());

        var used_list = try self.allocator.alloc(bool, old_vecs.len);
        defer self.allocator.free(used_list);
        for (0..used_list.len) |i| used_list[i] = false;

        var embedded: usize = 0;
        var recycled: usize = 0;
        for ((try diffSplit(old_contents, new_contents, arena.allocator())).items) |sentence| {
            if (sentence.new) {
                embedded += 1;
                const vec_id = if (try self.embedder.embed(sentence.contents)) |vec_slice| block: {
                    defer self.allocator.free(vec_slice);
                    const new_vec: Vector = vec_slice[0..vec_sz].*;
                    break :block try self.vecs.put(new_vec);
                } else self.vecs.nullVec();

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
                self.vecs.rm(old_vecs[i].vector_id) catch |e| switch (e) {
                    MultipleRemove => continue,
                    else => unreachable,
                };
            }
        }
        try self.vecs.save(VECTOR_DB_PATH);

        const ratio: usize = blk: {
            const num: f64 = @floatFromInt(recycled);
            const denom: f64 = @floatFromInt(recycled + embedded);
            if (denom == 0) break :blk 100;
            break :blk @intFromFloat((num / denom) * 100);
        };
        std.log.info("Recycled Ratio: {d}%, Embedded: {d}, Recycled: {d}\n", .{ ratio, embedded, recycled });
        return;
    }

    fn delete(self: *Self, id: VectorID) !void {
        try self.relational.deleteVec(id);
    }

    fn debugSearchHeader(query: []const u8) void {
        if (!config.debug) return;
        std.debug.print("Checking similarity against '{s}':\n", .{query});
    }

    fn debugSearchRankedResults(self: *Self, ids: []VectorID) !void {
        if (!config.debug) return;
        const bufsz = 50;
        for (ids, 1..) |id, i| {
            var buf: [bufsz]u8 = undefined;
            const noteID = try self.relational.vecToNote(id);
            const sz = try self.readAll(
                noteID,
                &buf,
            );
            if (sz < 0) continue;
            std.debug.print("    {d}. ID({d})'{s}' \n", .{
                i,
                noteID,
                buf[0..@min(sz, bufsz)],
            });
        }
    }
};

test "embedText hello" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();
    var rel = try model.DB.init(arena.allocator(), .{ .mem = true, .basedir = tmpD.dir });
    defer rel.deinit();
    var db = try DB.init(arena.allocator(), tmpD.dir, &rel);
    defer db.deinit();

    const id = try rel.create();

    const text = "hello";
    try db.embedText(id, "", text);

    var buf: [1]c_int = undefined;
    const results = try db.search(text, &buf);

    try expectEqual(1, results);
    try expectEqual(@as(c_int, @intCast(id)), buf[0]);
}

test "embedText skip empties" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();
    var rel = try model.DB.init(arena.allocator(), .{ .mem = true, .basedir = tmpD.dir });
    defer rel.deinit();
    var db = try DB.init(arena.allocator(), tmpD.dir, &rel);
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
    var db = try DB.init(arena.allocator(), tmpD.dir, &rel);
    defer db.deinit();

    const id = try rel.create();

    try db.embedText(id, "", "hello");

    var buf: [1]c_int = undefined;
    try expectEqual(1, try db.search("hello", &buf));

    try db.embedText(id, "hello", "flatiron");
    try expectEqual(0, try db.search("hello", &buf));
}

test "search remove duplicates" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();
    var rel = try model.DB.init(arena.allocator(), .{ .mem = true, .basedir = tmpD.dir });
    defer rel.deinit();
    var db = try DB.init(arena.allocator(), tmpD.dir, &rel);
    defer db.deinit();

    const noteID1 = try rel.create();
    _ = try db.embedText(noteID1, "", "pizza. pizza. pizza.");

    var buffer: [10]c_int = undefined;
    const n = try db.search("pizza", &buffer);
    try expectEqual(1, n);
    try expectEqual(@as(c_int, @intCast(noteID1)), buffer[0]);
}

fn getVectorsForNote(db: *DB, rel: *model.DB, noteID: NoteID, vecs: []Vector) !usize {
    const vec_rows = try rel.vecsForNote(testing_allocator, noteID);
    defer testing_allocator.free(vec_rows);
    for (vec_rows, 0..) |v, i| {
        vecs[i] = db.vecs.get(v.vector_id);
    }
    return vec_rows.len;
}

test "embedText no update" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();
    var rel = try model.DB.init(arena.allocator(), .{ .mem = true, .basedir = tmpD.dir });
    defer rel.deinit();
    var db = try DB.init(arena.allocator(), tmpD.dir, &rel);
    defer db.deinit();

    const noteID = try rel.create();

    try db.embedText(noteID, "", "apple");
    var initial_vecs: [1]Vector = undefined;
    try expectEqual(1, try getVectorsForNote(&db, &rel, noteID, &initial_vecs));

    try db.embedText(noteID, "apple", "apple");
    var updated_vecs: [1]Vector = undefined;
    try expectEqual(1, try getVectorsForNote(&db, &rel, noteID, &updated_vecs));

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
    var db = try DB.init(arena.allocator(), tmpD.dir, &rel);
    defer db.deinit();

    const noteID = try rel.create();

    try db.embedText(noteID, "", "apple");
    var initial_vecs: [1]Vector = undefined;
    try expectEqual(1, try getVectorsForNote(&db, &rel, noteID, &initial_vecs));

    try db.embedText(noteID, "apple", "banana");
    var updated_vecs: [1]Vector = undefined;
    try expectEqual(1, try getVectorsForNote(&db, &rel, noteID, &updated_vecs));

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
    var db = try DB.init(arena.allocator(), tmpD.dir, &rel);
    defer db.deinit();

    const noteID = try rel.create();

    try db.embedText(noteID, "", "apple. banana.");
    var initial_vecs: [2]Vector = undefined;
    try expectEqual(2, try getVectorsForNote(&db, &rel, noteID, &initial_vecs));

    try db.embedText(noteID, "apple. banana.", "apple. orange.");
    var updated_vecs: [2]Vector = undefined;
    try expectEqual(2, try getVectorsForNote(&db, &rel, noteID, &updated_vecs));

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
    var db = try DB.init(arena.allocator(), tmpD.dir, &rel);
    defer db.deinit();

    const noteID = try rel.create();

    // Initial content: three one-word sentences
    const initial_content = "apple. banana. cherry.";
    try db.embedText(noteID, "", initial_content);

    var initial_vecs: [3]Vector = undefined;
    try expectEqual(3, try getVectorsForNote(&db, &rel, noteID, &initial_vecs));

    // Updated content: same first and last words, different middle word
    const updated_content = "apple. dragonfruit. cherry.";
    try db.embedText(noteID, initial_content, updated_content);

    var updated_vecs: [3]Vector = undefined;
    try expectEqual(3, try getVectorsForNote(&db, &rel, noteID, &updated_vecs));

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
    var db = try DB.init(arena.allocator(), tmpD.dir, &rel);
    defer db.deinit();

    const noteID = try rel.create();

    const initial_content = "apple.\nbanana.\ngrape.";
    try db.embedText(noteID, "", initial_content);

    var initial_vecs: [3]Vector = undefined;
    try expectEqual(3, try getVectorsForNote(&db, &rel, noteID, &initial_vecs));

    const updated_content = "apple.\norange.\ngrape.";
    try db.embedText(noteID, initial_content, updated_content);

    var updated_vecs: [3]Vector = undefined;
    try expectEqual(3, try getVectorsForNote(&db, &rel, noteID, &updated_vecs));

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
    var db = try DB.init(arena.allocator(), tmpD.dir, &rel);
    defer db.deinit();

    const noteID = try rel.create();

    const initial_content = "foo.\nfoo.\nfoo.";
    const updated_content = "bar.\nbar.\nbar.";
    try db.embedText(noteID, "", initial_content);
    try db.embedText(noteID, initial_content, initial_content);
    try db.embedText(noteID, initial_content, updated_content);
}

const std = @import("std");
const testing_allocator = std.testing.allocator;
const expectEqual = std.testing.expectEqual;
const assert = std.debug.assert;

const config = @import("config");
const tracy = @import("tracy");

const diff = @import("dmp.zig");
const diffSplit = diff.diffSplit;
const embed = @import("embed.zig");
const model = @import("model.zig");
const Note = model.Note;
const VectorRow = model.VectorRow;
const MultipleRemove = vec_storage.Error.MultipleRemove;
const NoteID = model.NoteID;
const types = @import("types.zig");
const Vector = types.Vector;
const VectorID = types.VectorID;
const vec_sz = types.vec_sz;
const vec_storage = @import("vec_storage.zig");
