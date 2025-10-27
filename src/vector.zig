const VECTOR_DB_PATH = "vecs.db";

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
        const query_vec_slice = (try self.embedder.embed(query)) orelse {
            return 0;
        };
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

    // Uses vec_storage.Storage, Embedder, and model
    pub fn embedText(self: *Self, id: NoteID, content: []const u8) !void {
        const zone = tracy.beginZone(@src(), .{ .name = "root.zig:embedText" });
        defer zone.end();

        try self.clearVecsForNote(id);

        var it = self.embedder.split(content);
        while (it.next()) |chunk| {
            if (chunk.contents.len < 2) continue;
            const vec_slice = try self.embedder.embed(chunk.contents) orelse continue;
            defer self.allocator.free(vec_slice);
            const vec: Vector = vec_slice[0..vec_sz].*;
            try self.append(id, vec, chunk);
            self.relational.debugShowTable(.Vectors);
        }

        try self.vecs.save(VECTOR_DB_PATH);
    }

    fn clearVecsForNote(self: *Self, id: NoteID) !void {
        var vecs = try self.relational.vecsForNote(id);
        defer vecs.deinit();
        while (try vecs.next()) |v| try self.delete(v.vector_id);
    }

    fn delete(self: *Self, id: VectorID) !void {
        try self.relational.deleteVec(id);
        try self.vecs.rm(id);
    }

    fn append(self: *Self, id: NoteID, vec: Vector, chunk: embed.Sentence) !void {
        try self.relational.appendVector(id, try self.vecs.put(vec), chunk.start_i, chunk.end_i);
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
    try db.embedText(id, text);

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
    try db.embedText(id, text);
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

    try db.embedText(id, "hello");

    var buf: [1]c_int = undefined;
    try expectEqual(1, try db.search("hello", &buf));

    try db.embedText(id, "flatiron");
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
    _ = try db.embedText(noteID1, "pizza. pizza. pizza.");

    var buffer: [10]c_int = undefined;
    const n = try db.search("pizza", &buffer);
    try expectEqual(1, n);
    try expectEqual(@as(c_int, @intCast(noteID1)), buffer[0]);
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
const Vector = types.Vector;
const VectorID = types.VectorID;
const vec_sz = types.vec_sz;
const Note = model.Note;
const NoteID = model.NoteID;
