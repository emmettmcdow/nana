// // Each test in the benchmark has a top score of 100. Each test will add 100 to this variable.
var max_score: usize = 0;
// Each test will add to the score depending on how close to 'correct' it is.
var score: usize = 0;

test "binary single words" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();

    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();

    const te = try testEmbedder(testing_allocator);
    defer testing_allocator.destroy(te.e);
    var db = try TestVecDB.init(arena.allocator(), tmpD.dir, te.iface);
    defer db.deinit();

    var searchBuf: [10]SearchResult = undefined;

    const path1 = "night.md";
    try db.embedText(path1, "night");
    const path2 = "day.md";
    try db.embedText(path2, "day");

    var n_out = try db.uniqueSearch("moon", &searchBuf);
    if (n_out > 0) {
        if (std.mem.eql(u8, searchBuf[0].path, path1)) score += 50;
        if (n_out == 1) score += 50;
    }
    max_score += 100;

    const path3 = "mouse.md";
    try db.embedText(path3, "mouse");
    const path4 = "dog.md";
    try db.embedText(path4, "dog");
    n_out = try db.uniqueSearch("computer", &searchBuf);
    if (n_out > 0) {
        if (std.mem.eql(u8, searchBuf[0].path, path3)) score += 50;
        if (n_out == 1) score += 50;
    }
    max_score += 100;

    const path5 = "soccer.md";
    try db.embedText(path5, "soccer");
    const path6 = "sushi.md";
    try db.embedText(path6, "sushi");
    n_out = try db.uniqueSearch("sport", &searchBuf);
    if (n_out > 0) {
        if (std.mem.eql(u8, searchBuf[0].path, path5)) score += 50;
        if (n_out == 1) score += 50;
    }
    max_score += 100;
}

test "grok-generated semantic-similarity" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();

    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();

    const te = try testEmbedder(testing_allocator);
    defer testing_allocator.destroy(te.e);
    var db = try TestVecDB.init(arena.allocator(), tmpD.dir, te.iface);
    defer db.deinit();

    var searchBuf: [20]SearchResult = undefined;

    const query = "Best strategies for learning programming";

    const path1 = "note1.md";
    try db.embedText(path1, "Top techniques for mastering coding skills quickly.");

    const path2 = "note2.md";
    try db.embedText(path2, "How to improve your skills in software development.");

    const path3 = "note3.md";
    try db.embedText(path3, "The ultimate guide to becoming a better programmer");

    const path4 = "note4.md";
    try db.embedText(path4, "Why learning to code is easier with these tips");

    const path5 = "note5.md";
    try db.embedText(path5, "Practice your coding skills");

    const path6 = "note6.md";
    try db.embedText(path6, "What to eat for a healthy breakfast.");

    const path7 = "note7.md";
    try db.embedText(path7, "She sells sea shells by the sea shore");

    const path8 = "note8.md";
    try db.embedText(path8, "My dog likes to play with dogs");

    const path9 = "note9.md";
    try db.embedText(path9, "Also sometimes cats");

    const path10 = "note10.md";
    try db.embedText(path10, "Do you touch type or hunt and peck?");

    const n_out = try db.uniqueSearch(query, &searchBuf);
    if (n_out > 0) {
        if (outputContains(searchBuf[0..n_out], path1)) score += 20;
        if (outputContains(searchBuf[0..n_out], path2)) score += 20;
        if (outputContains(searchBuf[0..n_out], path3)) score += 20;
        if (outputContains(searchBuf[0..n_out], path4)) score += 20;
        if (outputContains(searchBuf[0..n_out], path5)) score += 20;

        if (!outputContains(searchBuf[0..n_out], path6)) score += 20;
        if (!outputContains(searchBuf[0..n_out], path7)) score += 20;
        if (!outputContains(searchBuf[0..n_out], path8)) score += 20;
        if (!outputContains(searchBuf[0..n_out], path9)) score += 20;
        if (!outputContains(searchBuf[0..n_out], path10)) score += 20;
    }

    max_score += 200;
}

test "sentence splitting - 1/3 match" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();

    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();

    const te = try testEmbedder(testing_allocator);
    defer testing_allocator.destroy(te.e);
    var db = try TestVecDB.init(arena.allocator(), tmpD.dir, te.iface);
    defer db.deinit();

    var searchBuf: [20]SearchResult = undefined;

    const query = "Eating food";

    const path1 = "note1.md";
    try db.embedText(path1, "I rode bikes with my friends. We ate hot dogs. Then we went home.");

    const path2 = "note2.md";
    try db.embedText(path2, "I graduated college last week. Lots of people had a party. My parents took me to dinner.");

    const path3 = "note3.md";
    try db.embedText(path3, "I woke up. I brushed my teeth vigorously! I drove to work.");

    const n_out = try db.uniqueSearch(query, &searchBuf);
    if (n_out > 0) {
        if (outputContains(searchBuf[0..n_out], path1)) score += 34;
        if (outputContains(searchBuf[0..n_out], path2)) score += 33;
        if (!outputContains(searchBuf[0..n_out], path3)) score += 33;
    }

    max_score += 100;
}

test "show results" {
    std.debug.print("---- Search Scores ----\n", .{});
    std.debug.print("Got {d} points out of a max of {d}.\n", .{ score, max_score });
    std.debug.print("-----------------------\n\n", .{});
}

test "debug view embedding splitting" {
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

const std = @import("std");
const testing_allocator = std.testing.allocator;

const config = @import("config");
const embed = @import("embed.zig");
const vector = @import("vector.zig");
const SearchResult = vector.SearchResult;
const embedding_model: embed.EmbeddingModel = @enumFromInt(@intFromEnum(config.embedding_model));
const TestVecDB = vector.VectorDB(embedding_model);

const Embedder = switch (embedding_model) {
    .apple_nlembedding => embed.NLEmbedder,
    .jina_embedding => embed.JinaEmbedder,
};

fn testEmbedder(allocator: std.mem.Allocator) !struct { e: *Embedder, iface: embed.Embedder } {
    const e = try allocator.create(Embedder);
    e.* = try Embedder.init();
    return .{ .e = e, .iface = e.embedder() };
}
