const MAX_FILESIZE_BYTES = 1_000_000;
pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var tmp_dir = std.testing.tmpDir(.{ .iterate = true });
    defer tmp_dir.cleanup();
    const tmp_cwd = std.fs.cwd();
    var cwd = try tmp_cwd.openDir(".", .{ .iterate = true });
    defer cwd.close();
    var rel = try model.DB.init(arena.allocator(), .{ .mem = true, .basedir = tmp_dir.dir });
    defer rel.deinit();

    var e = try embed.NLEmbedder.init();
    var vec_db = try vector.VectorDB(.apple_nlembedding).init(
        arena.allocator(),
        tmp_dir.dir,
        &rel,
        e.embedder(),
    );

    var map = std.hash_map.AutoHashMap(usize, []const u8).init(arena.allocator());

    {
        var embed_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer embed_arena.deinit();
        var walker = try cwd.walk(arena.allocator());
        defer walker.deinit();
        while (try walker.next()) |file| {
            if (file.kind != .file) continue;
            if (file.path[0] == '.') continue;
            const file_id = try rel.create();
            try rel.update(file_id);

            std.debug.print("Embedding `{s}`\n", .{file.path});
            try map.put(file_id, try arena.allocator().dupe(u8, file.path));
            const f = try cwd.openFile(file.path, .{});
            defer f.close();
            const contents = try f.readToEndAlloc(embed_arena.allocator(), MAX_FILESIZE_BYTES);
            try vec_db.embedText(file_id, "", contents);
        }
    }

    var stdin = std.io.getStdIn();
    var stdin_reader = stdin.reader();
    while (true) {
        var buf: [100]u8 = undefined;
        std.debug.print("\n> ", .{});
        const input = try stdin_reader.readUntilDelimiterOrEof(&buf, '\n');
        if (input) |query| {
            var results: [10000]vector.SearchResult = undefined;
            const found_n = try vec_db.search(query, &results);
            std.debug.print("Found {d} results:\n", .{found_n});
            for (results[0..found_n]) |result| {
                std.debug.print("{s}\n", .{map.get(result.id).?});
            }
        }
    }
}

pub const std_options = std.Options{
    .log_level = .err,
};

const std = @import("std");
const vector = @import("vector.zig");
const model = @import("model.zig");
const NoteID = model.NoteID;
const embed = @import("embed.zig");
