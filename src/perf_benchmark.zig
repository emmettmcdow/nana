const sentences = [_][]const u8{
    "Hello world",
    "for god so loved the world",
    "I pledge allegience to the flag",
    "a quick brown fox jumped over the lazy dog",
    "my dear aunt sally",
    "I could eat tacos every day",
    "a burrito a day keeps the doctor away",
    "i love programming",
    "i'm so three thousand and eight, you're so two thousand and late",
    "the nana notes app is a breath of fresh air",
};

test "consecutive nlembed" {
    var dbg_alloc = DebugAllocator(.{ .thread_safe = true, .never_unmap = true }).init;

    const nl_embedder = try dbg_alloc.allocator().create(embed.NLEmbedder);
    nl_embedder.* = try embed.NLEmbedder.init();
    var embedder = nl_embedder.embedder();

    var lock = Mutex{};
    for (sentences) |sentence| {
        _ = try threadEmbed(dbg_alloc.allocator(), &embedder, sentence, &lock);
    }
}

fn threadEmbed(allocator: Allocator, embedder: *Embedder, data: []const u8, lock: *Mutex) !void {
    lock.lock();
    defer lock.unlock();

    _ = try embedder.embed(allocator, data);
}

test "parallel nlembed" {
    var dbg_alloc = DebugAllocator(.{ .thread_safe = true, .never_unmap = true }).init;

    const nl_embedder = try dbg_alloc.allocator().create(embed.NLEmbedder);
    nl_embedder.* = try embed.NLEmbedder.init();
    var embedder = nl_embedder.embedder();

    var threads: [10]Thread = undefined;

    var lock = Mutex{};
    for (sentences, 0..) |sentence, i| {
        threads[i] = try Thread.spawn(.{}, threadEmbed, .{ dbg_alloc.allocator(), &embedder, sentence, &lock });
    }

    for (threads) |t| {
        t.join();
    }
}

const std = @import("std");
const embed = @import("embed.zig");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const Embedder = embed.Embedder;
const DebugAllocator = std.heap.DebugAllocator;
const Thread = std.Thread;
const Mutex = std.Thread.Mutex;
