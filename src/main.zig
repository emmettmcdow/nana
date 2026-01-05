const MAX_FILESIZE_BYTES = 1_000_000;

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var tmp_dir = std.testing.tmpDir(.{ .iterate = true });
    defer tmp_dir.cleanup();
    const tmp_cwd = std.fs.cwd();
    var cwd = try tmp_cwd.openDir(".", .{ .iterate = true });
    defer cwd.close();

    var runtime = try root.Runtime.init(arena.allocator(), .{
        .basedir = tmp_dir.dir,
        .mem = true,
    });
    defer runtime.deinit();

    var map = std.hash_map.AutoHashMap(model.NoteID, []const u8).init(arena.allocator());

    {
        var embed_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer embed_arena.deinit();
        var walker = try cwd.walk(arena.allocator());
        defer walker.deinit();
        while (try walker.next()) |file| {
            if (file.kind != .file) continue;
            if (file.path[0] == '.') continue;

            std.debug.print("Embedding `{s}`\n", .{file.path});
            const note_id = try runtime.create();
            try map.put(note_id, try arena.allocator().dupe(u8, file.path));

            const f = try cwd.openFile(file.path, .{});
            defer f.close();
            const contents = try f.readToEndAlloc(embed_arena.allocator(), MAX_FILESIZE_BYTES);
            try runtime.writeAll(note_id, contents);
        }
    }

    var stdin = std.io.getStdIn();
    var stdin_reader = stdin.reader();
    while (true) {
        var buf: [100]u8 = undefined;
        std.debug.print("\n> ", .{});
        const input = try stdin_reader.readUntilDelimiterOrEof(&buf, '\n');
        if (input) |query| {
            var results: [10000]root.SearchResult = undefined;
            const found_n = try runtime.search(query, &results);
            std.debug.print("Found {d} results:\n", .{found_n});
            for (results[0..found_n]) |result| {
                const text_len = result.end_i - result.start_i;
                var detail = root.SearchDetail{
                    .content = try arena.allocator().alloc(u8, text_len + 1),
                };
                try runtime.search_detail(result, query, &detail, .{});
                std.debug.print("{}\n", .{result});
                std.debug.print("({d:.2}%){s}: '{s}'\n", .{
                    result.similarity * 100.0,
                    map.get(result.id).?,
                    detail.content[0..text_len],
                });
            }
        }
    }
}

pub const std_options = std.Options{
    .log_level = .err,
};

const std = @import("std");
const root = @import("root.zig");
const model = @import("model.zig");
