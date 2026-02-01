var max_score: usize = 0;
var score: usize = 0;

const TextEntry = struct { path: []const u8, contents: []const u8 };

const t1 = "binary single words";
test t1 {
    var curr_max_score: usize = 0;
    var curr_score: usize = 0;
    defer reportTest(t1, curr_score, curr_max_score);

    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();
    const te = try testEmbedder(testing_allocator);
    defer testing_allocator.destroy(te.e);
    var db = try TestVecDB.init(arena.allocator(), tmpD.dir, te.iface);
    defer db.deinit();

    const BiCase = struct { a: []const u8, b: []const u8, query: []const u8, want: []const u8 };
    const binary_cases = [_]BiCase{
        .{ .a = "night", .b = "day", .query = "moon", .want = "a" },
        .{ .a = "mouse", .b = "dog", .query = "computer", .want = "a" },
        .{ .a = "soccer", .b = "sushi", .query = "sport", .want = "a" },
        .{ .a = "peasant", .b = "queen", .query = "royalty", .want = "b" },
    };
    inline for (binary_cases) |case| {
        curr_max_score += 100;
        try db.embedText("a", case.a);
        defer db.removePath("a") catch unreachable;
        try db.embedText("b", case.b);
        defer db.removePath("b") catch unreachable;
        var searchBuf: [10]SearchResult = undefined;
        const n_out = try db.uniqueSearch("computer", &searchBuf);
        if (n_out > 0) {
            if (std.mem.eql(u8, searchBuf[0].path, case.want)) curr_score += 50;
            if (n_out == 1) curr_score += 50;
        }
    }
}

const t2 = "sentence similarity";
test t2 {
    var curr_max_score: usize = 0;
    var curr_score: usize = 0;
    defer reportTest(t2, curr_score, curr_max_score);

    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();
    const te = try testEmbedder(testing_allocator);
    defer testing_allocator.destroy(te.e);
    var db = try TestVecDB.init(arena.allocator(), tmpD.dir, te.iface);
    defer db.deinit();

    var searchBuf: [20]SearchResult = undefined;

    const to_include = [_]struct { path: []const u8, contents: []const u8 }{
        .{ .path = "1", .contents = "Top techniques for mastering coding skills quickly." },
        .{ .path = "2", .contents = "How to improve your skills in software development." },
        .{ .path = "3", .contents = "The ultimate guide to becoming a better programmer" },
        .{ .path = "4", .contents = "Why learning to code is easier with these tips" },
        .{ .path = "5", .contents = "Practice your coding skills" },
    };
    for (to_include) |case| try db.embedText(case.path, case.contents);
    const no_include = [_]struct { path: []const u8, contents: []const u8 }{
        .{ .path = "6", .contents = "What to eat for a healthy breakfast." },
        .{ .path = "7", .contents = "She sells sea shells by the sea shore" },
        .{ .path = "8", .contents = "My dog likes to play with dogs" },
        .{ .path = "9", .contents = "Also sometimes cats" },
        .{ .path = "10", .contents = "Do you touch type or hunt and peck?" },
    };
    for (no_include) |case| try db.embedText(case.path, case.contents);

    const case_weight: usize = 20;
    const query = "Best strategies for learning programming";
    const n_out = try db.uniqueSearch(query, &searchBuf);
    for (to_include) |case| {
        if (outputContains(searchBuf[0..n_out], case.path)) curr_score += case_weight;
    }
    for (no_include) |case| {
        if (!outputContains(searchBuf[0..n_out], case.path)) curr_score += case_weight;
    }
    curr_max_score += (to_include.len + no_include.len) * case_weight;
}

const t3 = "sentence split - 1/3 match";
test t3 {
    var curr_max_score: usize = 0;
    var curr_score: usize = 0;
    defer reportTest(t3, curr_score, curr_max_score);

    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();
    const te = try testEmbedder(testing_allocator);
    defer testing_allocator.destroy(te.e);
    var db = try TestVecDB.init(arena.allocator(), tmpD.dir, te.iface);
    defer db.deinit();

    var searchBuf: [20]SearchResult = undefined;

    const to_include = [_]TextEntry{
        .{ .path = "1", .contents = "I rode bikes with my friends. We ate hot dogs. Then we went home." },
        .{ .path = "2", .contents = "I graduated college last week. Lots of people had a party. My parents took me to dinner." },
    };
    for (to_include) |case| try db.embedText(case.path, case.contents);
    const no_include = [_]TextEntry{
        .{ .path = "3", .contents = "I woke up. I brushed my teeth vigorously! I drove to work." },
    };
    for (no_include) |case| try db.embedText(case.path, case.contents);

    const case_weight: usize = 33;
    const query = "Eating food";
    const n_out = try db.search(query, &searchBuf);
    if (n_out > 0) {
        for (to_include) |case| {
            if (outputContains(searchBuf[0..n_out], case.path)) curr_score += case_weight;
        }
        for (no_include) |case| {
            if (!outputContains(searchBuf[0..n_out], case.path)) curr_score += case_weight;
        }
    } else {
        curr_score += case_weight * no_include.len;
    }
    // displaySearchResults(searchBuf[0..n_out], query, &to_include ++ &no_include);
    curr_max_score += (to_include.len + no_include.len) * case_weight;
}

test "show results" {
    reportTest("all", score, max_score);
}

test "debug view embedding splitting" {
    if (true) return error.SkipZigTest; // Skipping as this is not something we need always
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();

    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();

    const te = try testEmbedder(testing_allocator);
    defer testing_allocator.destroy(te.e);
    var db = try TestVecDB.init(arena.allocator(), tmpD.dir, te.iface);
    defer db.deinit();

    std.debug.print("--- Embedding Split ---\n", .{});
    var it = db.embedder.split(EXAMPLE_NOTE_1);
    var n: f32 = 0;
    var n_split: f32 = 0;
    while (it.next()) |chunk| {
        var embedded = chunk.contents.len > 2;
        const embedding = try db.embedder.embed(arena.allocator(), chunk.contents);
        embedded = embedded and (embedding != null);
        n_split += if (embedded) 1.0 else 0.0;
        n += 1.0;
        std.debug.print("({}, {s})\n", .{ embedded, chunk.contents });
    }
    const percentage = (n_split / n) * 100;
    std.debug.print("{d:.2}% Embedded\n", .{percentage});
    std.debug.print("-----------------------\n\n", .{});
}

fn outputContains(output: []SearchResult, path: []const u8) bool {
    for (output) |out_item| {
        if (std.mem.eql(u8, out_item.path, path)) return true;
    }
    return false;
}

// zlinter-disable
fn displaySearchResults(
    results: []SearchResult,
    query: []const u8,
    sources: []const TextEntry,
) void {
    std.debug.print("\n---\n", .{});
    std.debug.print("Query: \"{s}\"\n", .{query});
    std.debug.print("---\n", .{});

    if (results.len == 0) {
        std.debug.print("No results found.\n", .{});
    } else {
        for (results, 0..) |result, i| {
            const similarity_pct = result.similarity * 100.0;
            const text = getTextForResult(result, sources);
            std.debug.print("[{d}] Path: {s}\n", .{ i + 1, result.path });
            std.debug.print("    Similarity: {d:.2}%\n", .{similarity_pct});
            std.debug.print("    Text: \"{s}\"\n", .{text});
            if (i < results.len - 1) {
                std.debug.print("---", .{});
            }
        }
    }
    std.debug.print("---\n\n", .{});
}
// zlinter-enable

fn getTextForResult(result: SearchResult, sources: []const TextEntry) []const u8 {
    for (sources) |entry| {
        if (std.mem.eql(u8, entry.path, result.path)) {
            if (result.end_i <= entry.contents.len) {
                return entry.contents[result.start_i..result.end_i];
            }
        }
    }
    return "<not found>";
}

const EXAMPLE_NOTE_1 =
    \\Web Manager
    \\
    \\## Functionality
    \\- Generate NGINX config
    \\- Start / Stop Containers
    \\- Manage available ports
    \\- Manage volumes / Persistent storage
    \\- Update applications
    \\
    \\## Thoughts
    \\
    \\How do we want to configure the worker?
    \\It would be nice to have the ingress server be its own container. The only problem I can think of is the fact that we would need to be able to access ports which may be present only on the host.
    \\
    \\It should be possible to create a network, then have my various containers use it.
    \\
    \\I need to clear out kamal stuff on my server
    \\
    \\## Important commands
    \\```
    \\# Network
    \\docker network create -d bridge test-network
    \\
    \\# Server
    \\docker run --network=test-network -p 8082:8082 --name=nginx-server -d nginx-test:1
    \\
    \\# Client
    \\docker run --network=test-network -it ubuntu:latest
    \\
    \\# Within the client
    \\curl nginx-server:8082
    \\```
;

const Embedder = switch (embedding_model) {
    .apple_nlembedding => embed.NLEmbedder,
    .jina_embedding => embed.JinaEmbedder,
};

fn testEmbedder(allocator: std.mem.Allocator) !struct { e: *Embedder, iface: embed.Embedder } {
    const e = try allocator.create(Embedder);
    e.* = try Embedder.init();
    return .{ .e = e, .iface = e.embedder() };
}

fn reportTest(label: []const u8, got: usize, total: usize) void {
    var buf: [50]u8 = undefined;
    const frac = std.fmt.bufPrint(&buf, "{d} / {d}", .{ got, total }) catch @panic("don't care");
    std.debug.print("{s:<26} | {s:^9} | {d:.1}% \n", .{
        label,
        frac,
        (@as(f32, @floatFromInt(got)) / @as(f32, @floatFromInt(total))) * 100,
    });
    score += got;
    max_score += total;
}

const std = @import("std");
const testing_allocator = std.testing.allocator;

const config = @import("config");
const embed = @import("embed.zig");
const vector = @import("vector.zig");
const SearchResult = vector.SearchResult;
const embedding_model: embed.EmbeddingModel = @enumFromInt(@intFromEnum(config.embedding_model));
const TestVecDB = vector.VectorDB(embedding_model);
