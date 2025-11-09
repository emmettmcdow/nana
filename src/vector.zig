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
        const query_vec_slice = (try self.embedder.embed(query)) orelse return 0;
        defer self.allocator.free(query_vec_slice);
        const query_vec: Vector = query_vec_slice[0..vec_sz].*;

        var vec_ids: [1000]VectorID = undefined;

        debugSearchHeader(query);
        const found_n = try self.vecs.search(query_vec, &vec_ids);
        self.debugSearchRankedResults(vec_ids[0..found_n]);

        var unique_found_n: usize = 0;
        outer: for (0..@min(found_n, buf.len)) |i| {
            // TODO: create scoring system for multiple results in one note
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
        const zone = tracy.beginZone(@src(), .{ .name = "root.zig:embedText" });
        defer zone.end();

        assert(new_contents.len < MAX_NOTE_LEN);
        assert(old_contents.len < MAX_NOTE_LEN);

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();

        const old_vecs = try self.relational.vecsForNote(arena.allocator(), note_id);
        var new_vecs = std.ArrayList(VectorRow).init(arena.allocator());
        var old_vecs_idx: usize = 0;

        for ((try diffSplit(old_contents, new_contents, arena.allocator())).items) |sentence| {
            if (sentence.mod) {
                if (sentence.contents.len < 2) continue;
                const vec_slice = try self.embedder.embed(sentence.contents) orelse unreachable;
                const new_vec: Vector = vec_slice[0..vec_sz].*;
                try new_vecs.append(.{
                    .vector_id = try self.vecs.put(new_vec),
                    .note_id = note_id,
                    .start_i = sentence.off,
                    .end_i = sentence.off + sentence.contents.len,
                });
            } else {
                var found = false;
                while (old_vecs_idx < old_vecs.len) : (old_vecs_idx += 1) {
                    const old_v = old_vecs[old_vecs_idx];
                    const old_v_contents = old_contents[old_v.start_i..old_v.end_i];
                    assert(old_v_contents.len > 1);
                    if (!std.mem.eql(u8, sentence.contents, old_v_contents)) continue;
                    try new_vecs.append(VectorRow{
                        .vector_id = try self.vecs.copy(old_v.vector_id),
                        .note_id = note_id,
                        .start_i = sentence.off,
                        .end_i = sentence.off + sentence.contents.len,
                    });
                    found = true;
                    old_vecs_idx += 1;
                    break;
                }
                assert(found);
            }
        }
        try self.clearVecsForNote(note_id);
        for (new_vecs.items) |v| {
            try self.relational.appendVector(v.note_id, v.vector_id, v.start_i, v.end_i);
        }
        try self.vecs.save(VECTOR_DB_PATH);

        return;
    }

    fn clearVecsForNote(self: *Self, id: NoteID) !void {
        const vecs = try self.relational.vecsForNote(self.allocator, id);
        defer self.allocator.free(vecs);
        for (vecs) |v| try self.delete(v.vector_id);
    }

    fn delete(self: *Self, id: VectorID) !void {
        try self.relational.deleteVec(id);
        try self.vecs.rm(id);
    }

    fn debugSearchHeader(query: []const u8) void {
        if (!config.debug) return;
        std.debug.print("Checking similarity against '{s}':\n", .{query});
    }

    fn debugSearchRankedResults(self: *Self, ids: []VectorID) void {
        if (!config.debug) return;
        const bufsz = 50;
        for (ids, 1..) |id, i| {
            var buf: [bufsz]u8 = undefined;
            const noteID = self.relational.vecToNote(id) catch unreachable;
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

const std = @import("std");

const tracy = @import("tracy");

const testing_allocator = std.testing.allocator;
const expectEqual = std.testing.expectEqual;
const embed = @import("embed.zig");
const config = @import("config");
const storage = @import("vec_storage.zig");
const model = @import("model.zig");
const types = @import("types.zig");
const vec_storage = @import("vec_storage.zig");
const util = @import("util.zig");
const root = @import("root.zig");
const diff = @import("dmp.zig");
const diffSplit = diff.diffSplit;
const assert = std.debug.assert;
const OutOfMemory = std.mem.Allocator.Error.OutOfMemory;

const Vector = types.Vector;
const VectorID = types.VectorID;
const vec_sz = types.vec_sz;
const Note = model.Note;
const VectorRow = model.VectorRow;
const NoteID = model.NoteID;
