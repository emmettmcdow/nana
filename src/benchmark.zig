// // Each test in the benchmark has a top score of 100. Each test will add 100 to this variable.
var max_score: usize = 0;
// Each test will add to the score depending on how close to 'correct' it is.
var score: usize = 0;

test "binary single words" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();

    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();

    var rt = try root.Runtime.init(arena.allocator(), .{
        .mem = true,
        .basedir = tmpD.dir,
    });
    defer rt.deinit();

    var searchBuf: [10]c_int = undefined;
    @memset(&searchBuf, 0);

    const id1 = try rt.create();
    _ = try rt.writeAll(id1, "night");
    const id2 = try rt.create();
    _ = try rt.writeAll(id2, "day");

    var n_out = try rt.search("moon", &searchBuf, null);
    if (n_out > 0) {
        if (searchBuf[0] == id1) score += 50;
        if (n_out == 1) score += 50;
    }
    max_score += 100;

    const id3 = try rt.create();
    _ = try rt.writeAll(id3, "mouse");
    const id4 = try rt.create();
    _ = try rt.writeAll(id4, "dog");
    n_out = try rt.search("computer", &searchBuf, null);
    if (n_out > 0) {
        if (searchBuf[0] == id3) score += 50;
        if (n_out == 1) score += 50;
    }
    max_score += 100;

    const id5 = try rt.create();
    _ = try rt.writeAll(id5, "soccer");
    const id6 = try rt.create();
    _ = try rt.writeAll(id6, "sushi");
    n_out = try rt.search("sport", &searchBuf, null);
    if (n_out > 0) {
        if (searchBuf[0] == id5) score += 50;
        if (n_out == 1) score += 50;
    }
    max_score += 100;
}

test "grok-generated semantic-similarity" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();

    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();

    var rt = try root.Runtime.init(arena.allocator(), .{
        .mem = true,
        .basedir = tmpD.dir,
    });
    defer rt.deinit();

    var searchBuf: [20]c_int = undefined;
    @memset(&searchBuf, 0);

    const query = "Best strategies for learning programming";

    const id1 = try rt.create();
    _ = try rt.writeAll(id1, "Top techniques for mastering coding skills quickly.");

    const id2 = try rt.create();
    _ = try rt.writeAll(id2, "How to improve your skills in software development.");

    const id3 = try rt.create();
    _ = try rt.writeAll(id3, "The ultimate guide to becoming a better programmer");

    const id4 = try rt.create();
    _ = try rt.writeAll(id4, "Why learning to code is easier with these tips");

    const id5 = try rt.create();
    _ = try rt.writeAll(id5, "Practice your coding skills");

    const id6 = try rt.create();
    _ = try rt.writeAll(id6, "What to eat for a healthy breakfast.");

    const id7 = try rt.create();
    _ = try rt.writeAll(id7, "She sells sea shells by the sea shore");

    const id8 = try rt.create();
    _ = try rt.writeAll(id8, "My dog likes to play with dogs");

    const id9 = try rt.create();
    _ = try rt.writeAll(id9, "Also sometimes cats");

    const id10 = try rt.create();
    _ = try rt.writeAll(id10, "Do you touch type or hunt and peck?");

    const n_out = try rt.search(query, &searchBuf, null);
    if (n_out > 0) {
        if (outputContains(searchBuf[0..n_out], id1)) score += 20;
        if (outputContains(searchBuf[0..n_out], id2)) score += 20;
        if (outputContains(searchBuf[0..n_out], id3)) score += 20;
        if (outputContains(searchBuf[0..n_out], id4)) score += 20;
        if (outputContains(searchBuf[0..n_out], id5)) score += 20;

        if (!outputContains(searchBuf[0..n_out], id6)) score += 20;
        if (!outputContains(searchBuf[0..n_out], id7)) score += 20;
        if (!outputContains(searchBuf[0..n_out], id8)) score += 20;
        if (!outputContains(searchBuf[0..n_out], id9)) score += 20;
        if (!outputContains(searchBuf[0..n_out], id10)) score += 20;
    }

    max_score += 200;
}

test "sentence splitting - 1/3 match" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();

    var arena = std.heap.ArenaAllocator.init(testing_allocator);
    defer arena.deinit();

    var rt = try root.Runtime.init(arena.allocator(), .{
        .mem = true,
        .basedir = tmpD.dir,
    });
    defer rt.deinit();

    var searchBuf: [20]c_int = undefined;
    @memset(&searchBuf, 0);

    const query = "Eating food";

    const id1 = try rt.create();
    _ = try rt.writeAll(id1, "I rode bikes with my friends. We ate hot dogs. Then we went home.");

    const id2 = try rt.create();
    _ = try rt.writeAll(id2, "I graduated college last week. Lots of people had a party. My parents took me to dinner.");

    const id3 = try rt.create();
    _ = try rt.writeAll(id3, "I woke up. I brushed my teeth vigorously! I drove to work.");

    const n_out = try rt.search(query, &searchBuf, null);
    if (n_out > 0) {
        if (outputContains(searchBuf[0..n_out], id1)) score += 34;
        if (outputContains(searchBuf[0..n_out], id2)) score += 33;
        if (!outputContains(searchBuf[0..n_out], id3)) score += 33;
    }

    max_score += 100;
}

fn outputContains(output: []c_int, item: NoteID) bool {
    for (output) |out_item| {
        if (out_item == item) return true;
    }
    return false;
}

test "show results" {
    std.debug.print("Got {d} points out of a max of {d}.\n", .{ score, max_score });
}

const std = @import("std");
const testing_allocator = std.testing.allocator;

const root = @import("root.zig");
const model = @import("model.zig");
const embed = @import("embed.zig");

const NoteID = model.NoteID;
const Note = model.Note;
