pub const NoteID = u64;
const MANIFEST_FILENAME = ".nana_note_ids";
const MANIFEST_VERSION: u32 = 1;

pub const Error = error{
    NotFound,
    CorruptManifest,
};

pub const NoteIdMap = struct {
    path_to_id: std.StringHashMap(NoteID),
    id_to_path: std.AutoHashMap(NoteID, []u8),
    next_id: NoteID,
    allocator: std.mem.Allocator,
    basedir: std.fs.Dir,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, basedir: std.fs.Dir) !Self {
        var self = Self{
            .path_to_id = std.StringHashMap(NoteID).init(allocator),
            .id_to_path = std.AutoHashMap(NoteID, []u8).init(allocator),
            .next_id = 1,
            .allocator = allocator,
            .basedir = basedir,
        };

        self.load() catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };

        return self;
    }

    pub fn deinit(self: *Self) void {
        var it = self.id_to_path.valueIterator();
        while (it.next()) |path_ptr| {
            self.allocator.free(path_ptr.*);
        }
        self.path_to_id.deinit();
        self.id_to_path.deinit();
    }

    pub fn getOrCreateId(self: *Self, path: []const u8) !NoteID {
        if (self.path_to_id.get(path)) |id| {
            return id;
        }

        const id = self.next_id;
        self.next_id += 1;

        const path_copy = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(path_copy);

        try self.path_to_id.put(path_copy, id);
        try self.id_to_path.put(id, path_copy);

        try self.save();

        return id;
    }

    pub fn getId(self: *Self, path: []const u8) ?NoteID {
        return self.path_to_id.get(path);
    }

    pub fn getPath(self: *Self, id: NoteID) ?[]const u8 {
        return self.id_to_path.get(id);
    }

    pub fn removePath(self: *Self, path: []const u8) !void {
        const id = self.path_to_id.get(path) orelse return;

        const owned_path = self.id_to_path.get(id) orelse return;
        _ = self.path_to_id.remove(owned_path);
        _ = self.id_to_path.remove(id);
        self.allocator.free(owned_path);

        self.save() catch |e| {
            std.log.err(
                "Failed to save mapping after removing path '{s}', with error: {}\n",
                .{ path, e },
            );
            return e;
        };
    }

    pub fn renamePath(self: *Self, old_path: []const u8, new_path: []const u8) !void {
        const id = self.path_to_id.get(old_path) orelse return error.NotFound;

        _ = self.path_to_id.remove(old_path);

        if (self.id_to_path.getPtr(id)) |path_ptr| {
            self.allocator.free(path_ptr.*);
            path_ptr.* = try self.allocator.dupe(u8, new_path);
            try self.path_to_id.put(path_ptr.*, id);
        }

        try self.save();
    }

    pub fn count(self: *Self) usize {
        return self.path_to_id.count();
    }

    // Possibly update the save and load to use SOA. We want to write the fields of the struct all
    // at once, we should be able to call one syscall to write all of the data.
    fn load(self: *Self) !void {
        const zone = tracy.beginZone(@src(), .{ .name = "note_id_map.zig:load" });
        defer zone.end();

        const file = try self.basedir.openFile(MANIFEST_FILENAME, .{});
        defer file.close();

        var reader = file.reader();

        const version = try reader.readInt(u32, .little);
        if (version != MANIFEST_VERSION) return error.CorruptManifest;

        self.next_id = try reader.readInt(u64, .little);
        const entry_count = try reader.readInt(u64, .little);

        for (0..entry_count) |_| {
            const id = try reader.readInt(u64, .little);
            const path_len = try reader.readInt(u32, .little);

            const path = try self.allocator.alloc(u8, path_len);
            errdefer self.allocator.free(path);

            const bytes_read = try reader.read(path);
            if (bytes_read != path_len) {
                self.allocator.free(path);
                return error.CorruptManifest;
            }

            try self.path_to_id.put(path, id);
            try self.id_to_path.put(id, path);
        }
    }

    fn save(self: *Self) !void {
        const zone = tracy.beginZone(@src(), .{ .name = "note_id_map.zig:save" });
        defer zone.end();

        const tmp_name = MANIFEST_FILENAME ++ ".tmp";

        const file = try self.basedir.createFile(tmp_name, .{});
        errdefer self.basedir.deleteFile(tmp_name) catch {}; // zlinter-disable-current-line

        var writer = file.writer();

        try writer.writeInt(u32, MANIFEST_VERSION, .little);
        try writer.writeInt(u64, self.next_id, .little);
        try writer.writeInt(u64, self.id_to_path.count(), .little);

        var it = self.id_to_path.iterator();
        while (it.next()) |entry| {
            try writer.writeInt(u64, entry.key_ptr.*, .little);
            try writer.writeInt(u32, @intCast(entry.value_ptr.len), .little);
            try writer.writeAll(entry.value_ptr.*);
        }

        try file.sync();
        file.close();

        try self.basedir.rename(tmp_name, MANIFEST_FILENAME);
    }

    pub fn pruneOrphanedPaths(self: *Self, basedir: std.fs.Dir) !void {
        var to_remove = std.ArrayList(NoteID).init(self.allocator);
        defer to_remove.deinit();

        var it = self.path_to_id.iterator();
        while (it.next()) |entry| {
            basedir.access(entry.key_ptr.*, .{}) catch |err| switch (err) {
                error.FileNotFound => {
                    try to_remove.append(entry.value_ptr.*);
                },
                else => {},
            };
        }

        for (to_remove.items) |id| {
            if (self.id_to_path.get(id)) |path| {
                try self.removePath(path);
            }
        }
    }
};

const testing_allocator = std.testing.allocator;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;

test "getOrCreateId creates new id" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();

    var map = try NoteIdMap.init(testing_allocator, tmpD.dir);
    defer map.deinit();

    const id1 = try map.getOrCreateId("note1.md");
    const id2 = try map.getOrCreateId("note2.md");

    try expect(id1 != id2);
    try expectEqual(id1, map.getId("note1.md").?);
    try expectEqual(id2, map.getId("note2.md").?);
}

test "getOrCreateId returns existing id" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();

    var map = try NoteIdMap.init(testing_allocator, tmpD.dir);
    defer map.deinit();

    const id1 = try map.getOrCreateId("note1.md");
    const id2 = try map.getOrCreateId("note1.md");

    try expectEqual(id1, id2);
}

test "getPath returns path for id" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();

    var map = try NoteIdMap.init(testing_allocator, tmpD.dir);
    defer map.deinit();

    const id = try map.getOrCreateId("mypath.md");
    const path = map.getPath(id);

    try expectEqualStrings("mypath.md", path.?);
}

test "removePath removes mapping" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();

    var map = try NoteIdMap.init(testing_allocator, tmpD.dir);
    defer map.deinit();

    const id = try map.getOrCreateId("note.md");
    try map.removePath("note.md");

    try expect(map.getId("note.md") == null);
    try expect(map.getPath(id) == null);
}

test "persistence across restarts" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();

    const id1: NoteID = blk: {
        var map = try NoteIdMap.init(testing_allocator, tmpD.dir);
        defer map.deinit();
        break :blk try map.getOrCreateId("persistent.md");
    };

    var map2 = try NoteIdMap.init(testing_allocator, tmpD.dir);
    defer map2.deinit();

    try expectEqual(id1, map2.getId("persistent.md").?);
    try expectEqualStrings("persistent.md", map2.getPath(id1).?);

    const id2 = try map2.getOrCreateId("new.md");
    try expect(id2 > id1);
}

test "renamePath preserves id" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();

    var map = try NoteIdMap.init(testing_allocator, tmpD.dir);
    defer map.deinit();

    const id = try map.getOrCreateId("old.md");
    try map.renamePath("old.md", "new.md");

    try expect(map.getId("old.md") == null);
    try expectEqual(id, map.getId("new.md").?);
    try expectEqualStrings("new.md", map.getPath(id).?);
}

test "pruneOrphanedPaths removes missing files" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();

    (try tmpD.dir.createFile("exists.md", .{})).close();

    var map = try NoteIdMap.init(testing_allocator, tmpD.dir);
    defer map.deinit();

    _ = try map.getOrCreateId("exists.md");
    _ = try map.getOrCreateId("missing.md");

    try expectEqual(@as(usize, 2), map.count());

    try map.pruneOrphanedPaths(tmpD.dir);

    try expectEqual(@as(usize, 1), map.count());
    try expect(map.getId("exists.md") != null);
    try expect(map.getId("missing.md") == null);
}

const std = @import("std");
const tracy = @import("tracy");
