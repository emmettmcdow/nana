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
        .{ .a = "peasant", .b = "queen", .query = "royalty", .want = "b" },
        .{ .a = "soccer", .b = "sushi", .query = "sport", .want = "a" },
        .{ .a = "world", .b = "calculator", .query = "earth", .want = "a" },
        .{ .a = "night", .b = "day", .query = "moon", .want = "a" },
        .{ .a = "mouse", .b = "dog", .query = "computer", .want = "a" },
        // Additional cases
        .{ .a = "hammer", .b = "paintbrush", .query = "construction", .want = "a" },
        .{ .a = "violin", .b = "trumpet", .query = "strings", .want = "a" },
        .{ .a = "ocean", .b = "desert", .query = "water", .want = "a" },
        .{ .a = "winter", .b = "summer", .query = "cold", .want = "a" },
        .{ .a = "doctor", .b = "lawyer", .query = "medicine", .want = "a" },
    };
    inline for (binary_cases) |case| {
        curr_max_score += 40;
        try db.embedText("a", case.a);
        defer db.removePath("a") catch unreachable;
        try db.embedText("b", case.b);
        defer db.removePath("b") catch unreachable;
        var searchBuf: [10]SearchResult = undefined;
        const n_out = try db.uniqueSearch(case.query, &searchBuf);
        if (n_out > 0) {
            if (std.mem.eql(u8, searchBuf[0].path, case.want)) {
                curr_score += 20;
                if (n_out == 1) curr_score += 20;
            }
        }
    }
}

const SentenceCase = struct {
    query: []const u8,
    to_include: []const []const u8,
    no_include: []const []const u8,
};

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

    const all_docs = [_]TextEntry{
        // Programming-related
        .{ .path = "1", .contents = "Top techniques for mastering coding skills quickly." },
        .{ .path = "2", .contents = "How to improve your skills in software development." },
        .{ .path = "3", .contents = "The ultimate guide to becoming a better programmer" },
        .{ .path = "4", .contents = "Why learning to code is easier with these tips" },
        .{ .path = "5", .contents = "Practice your coding skills" },
        // Food-related
        .{ .path = "6", .contents = "What to eat for a healthy breakfast." },
        .{ .path = "7", .contents = "The best recipes for homemade pasta dishes" },
        .{ .path = "8", .contents = "Nutrition tips for athletes and fitness enthusiasts" },
        // Misc unrelated
        .{ .path = "9", .contents = "She sells sea shells by the sea shore" },
        .{ .path = "10", .contents = "My dog likes to play with other dogs" },
        .{ .path = "11", .contents = "Do you touch type or hunt and peck?" },
        // Travel-related
        .{ .path = "12", .contents = "Best destinations for a summer vacation in Europe" },
        .{ .path = "13", .contents = "How to pack light for international travel" },
        .{ .path = "14", .contents = "Budget tips for backpacking through Asia" },
    };
    for (all_docs) |doc| try db.embedText(doc.path, doc.contents);

    const cases = [_]SentenceCase{
        .{
            .query = "Best strategies for learning programming",
            .to_include = &.{ "1", "2", "3", "4", "5" },
            .no_include = &.{ "6", "7", "8", "9", "10", "11", "12", "13", "14" },
        },
        .{
            .query = "Cooking and meal preparation",
            .to_include = &.{ "6", "7" },
            .no_include = &.{ "1", "2", "3", "4", "5", "9", "10", "11", "12", "13", "14" },
        },
        .{
            .query = "Planning a trip abroad",
            .to_include = &.{ "12", "13", "14" },
            .no_include = &.{ "1", "2", "3", "4", "5", "6", "7", "9", "10", "11" },
        },
    };

    const case_weight: usize = 10; // 40 items × 10 = 400 max
    for (cases) |case| {
        const n_out = try db.uniqueSearch(case.query, &searchBuf);
        for (case.to_include) |path| {
            curr_max_score += case_weight;
            if (outputContains(searchBuf[0..n_out], path)) curr_score += case_weight;
        }
        for (case.no_include) |path| {
            curr_max_score += case_weight;
            if (!outputContains(searchBuf[0..n_out], path)) curr_score += case_weight;
        }
    }
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

    const all_docs = [_]TextEntry{
        .{ .path = "1", .contents = "I rode bikes with my friends. We ate hot dogs. Then we went home." },
        .{ .path = "2", .contents = "I graduated college last week. Lots of people had a party. My parents took me to dinner." },
        .{ .path = "3", .contents = "I woke up. I brushed my teeth vigorously! I drove to work." },
        .{ .path = "4", .contents = "The cat slept all day. It played with yarn. Then it ate its dinner." },
        .{ .path = "5", .contents = "We hiked up the mountain. The view was incredible. We took many photos." },
        .{ .path = "6", .contents = "She studied for the exam. Her notes were extensive. The test was difficult." },
    };
    for (all_docs) |doc| try db.embedText(doc.path, doc.contents);

    const cases = [_]SentenceCase{
        .{
            .query = "Eating food",
            .to_include = &.{ "1", "2", "4" },
            .no_include = &.{ "3", "5", "6" },
        },
        .{
            .query = "Physical outdoor activity",
            .to_include = &.{ "1", "5" },
            .no_include = &.{ "3", "6" },
        },
        .{
            .query = "Academic study",
            .to_include = &.{ "2", "6" },
            .no_include = &.{ "1", "3", "4", "5" },
        },
    };

    const case_weight: usize = 25; // 16 items × 25 = 400 max
    for (cases) |case| {
        const n_out = try db.search(case.query, &searchBuf);
        for (case.to_include) |path| {
            curr_max_score += case_weight;
            if (n_out > 0 and outputContains(searchBuf[0..n_out], path)) curr_score += case_weight;
        }
        for (case.no_include) |path| {
            curr_max_score += case_weight;
            if (n_out == 0 or !outputContains(searchBuf[0..n_out], path)) curr_score += case_weight;
        }
    }
}

const t4 = "query length parity";
test t4 {
    var curr_max_score: usize = 0;
    var curr_score: usize = 0;
    defer reportTest(t4, curr_score, curr_max_score);

    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();
    const te = try testEmbedder(testing_allocator);
    defer testing_allocator.destroy(te.e);
    var db = try TestVecDB.init(arena.allocator(), tmpD.dir, te.iface);
    defer db.deinit();

    var searchBuf: [20]SearchResult = undefined;

    const all_docs = [_]TextEntry{
        .{ .path = "auth", .contents = "User authentication and login system" },
        .{ .path = "database", .contents = "PostgreSQL database connection and query handling" },
        .{ .path = "api", .contents = "REST API endpoints for the web application" },
        .{ .path = "cache", .contents = "Redis caching layer for performance optimization" },
        .{ .path = "logging", .contents = "Application logging and error tracking system" },
    };
    for (all_docs) |doc| try db.embedText(doc.path, doc.contents);

    const QueryCase = struct { query: []const u8, expected: []const u8 };
    const cases = [_]QueryCase{
        // Single word queries
        .{ .query = "authentication", .expected = "auth" },
        .{ .query = "database", .expected = "database" },
        .{ .query = "caching", .expected = "cache" },
        // Short phrase queries (should match same docs as single words)
        .{ .query = "user login authentication", .expected = "auth" },
        .{ .query = "database connection", .expected = "database" },
        .{ .query = "caching performance", .expected = "cache" },
        // Longer queries (should still match correctly)
        .{ .query = "how does user authentication work", .expected = "auth" },
        .{ .query = "setting up database connections and queries", .expected = "database" },
        .{ .query = "implementing a caching layer for better performance", .expected = "cache" },
    };

    const case_weight: usize = 44; // 9 cases × 44 = 396 max (≈400)
    for (cases) |case| {
        curr_max_score += case_weight;
        const n_out = try db.uniqueSearch(case.query, &searchBuf);
        if (n_out > 0 and std.mem.eql(u8, searchBuf[0].path, case.expected)) {
            curr_score += case_weight;
        }
    }
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
    .mpnet_embedding => embed.MpnetEmbedder,
};

fn testEmbedder(allocator: std.mem.Allocator) !struct { e: *Embedder, iface: embed.Embedder } {
    const e = try allocator.create(Embedder);
    e.* = try Embedder.init();
    return .{ .e = e, .iface = e.embedder() };
}

fn reportTest(label: []const u8, got: usize, total: usize) void {
    var buf: [50]u8 = undefined;
    const frac = std.fmt.bufPrint(&buf, "{d} / {d}", .{ got, total }) catch @panic("don't care");
    std.debug.print("{s:<26} | {s:^13} | {d:.1}% \n", .{
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
