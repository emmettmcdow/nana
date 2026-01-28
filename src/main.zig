const MAX_FILESIZE_BYTES = 1_000_000;

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var tmp_dir = std.testing.tmpDir(.{ .iterate = true });
    defer tmp_dir.cleanup();
    const tmp_cwd = std.fs.cwd();
    var cwd = try tmp_cwd.openDir(".", .{ .iterate = true });
    defer cwd.close();

    const Embedder = if (embedding_model == .jina_embedding)
        embed.JinaEmbedder
    else
        embed.NLEmbedder;

    const embedder_ptr = try arena.allocator().create(Embedder);
    embedder_ptr.* = try Embedder.init();

    var db = try VectorDB.init(arena.allocator(), tmp_dir.dir, embedder_ptr.embedder());
    defer db.deinit();

    {
        var embed_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer embed_arena.deinit();
        var walker = try cwd.walk(arena.allocator());
        defer walker.deinit();
        while (try walker.next()) |file| {
            if (file.kind != .file) continue;
            if (file.path[0] == '.') continue;
            if (endsWith(file.path, ".db")) continue;

            std.debug.print("Embedding `{s}`\n", .{file.path});

            const f = try cwd.openFile(file.path, .{});
            defer f.close();
            const contents = try f.readToEndAlloc(embed_arena.allocator(), MAX_FILESIZE_BYTES);
            try db.embedTextAsync(file.path, contents);
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
            const found_n = try db.search(query, &results);
            std.debug.print("Found {d} results:\n", .{found_n});
            for (results[0..found_n]) |result| {
                std.debug.print("({d:.2}%){s}: [{d}..{d}]\n", .{
                    result.similarity * 100.0,
                    result.path,
                    result.start_i,
                    result.end_i,
                });
            }
        }
    }
}

fn endsWith(path: []const u8, ext: []const u8) bool {
    return path.len >= ext.len and std.mem.eql(u8, path[path.len - ext.len ..], ext);
}

pub const std_options = std.Options{
    .log_level = .err,
};

const std = @import("std");
const config = @import("config");
const embedding_model: embed.EmbeddingModel = @enumFromInt(@intFromEnum(config.embedding_model));
const embed = @import("embed.zig");
const vector = @import("vector.zig");
const VectorDB = vector.VectorDB(.apple_nlembedding);
