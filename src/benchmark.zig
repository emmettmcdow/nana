const std = @import("std");
const testing_allocator = std.testing.allocator;

const root = @import("root.zig");
const model = @import("model.zig");
const embed = @import("embed.zig");

const NoteID = model.NoteID;
const Note = model.Note;

const embed_model = embed.MXBAI_QUANTIZED_MODEL;

// // Each test in the benchmark has a top score of 100. Each test will add 100 to this variable.
var max_score: usize = 0;
// Each test will add to the score depending on how close to 'correct' it is.
var score: usize = 0;

test "binary single words" {
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var rt = try root.Runtime.init(testing_allocator, .{
        .mem = true,
        .basedir = tmpD.dir,
        .model = embed_model,
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

test "show results" {
    std.debug.print("Got {d} points out of a max of {d}.\n", .{ score, max_score });
}
