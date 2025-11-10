const ITERATIONS = 10;
pub fn main() !void {
    const stdin = std.io.getStdIn().reader();
    var buf: [1]u8 = undefined;
    var note_ids: [ITERATIONS]NoteID = undefined;

    std.debug.print("Press any key to start profiling init...\n", .{});
    _ = try stdin.read(&buf);
    var tmpD = std.testing.tmpDir(.{ .iterate = true });
    defer tmpD.cleanup();
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    var rt = try root.Runtime.init(arena.allocator(), .{
        .mem = true,
        .basedir = tmpD.dir,
    });
    defer rt.deinit();

    std.debug.print("Press any key to start profiling create...\n", .{});
    _ = try stdin.read(&buf);
    for (0..ITERATIONS) |i| {
        note_ids[i] = try rt.create();
    }

    std.debug.print("Press any key to start profiling writeAll...\n", .{});
    _ = try stdin.read(&buf);
    for (note_ids) |id| {
        try rt.writeAll(id, try randomNote(arena.allocator()));
    }

    std.debug.print("Press any key to start profiling search...\n", .{});
    _ = try stdin.read(&buf);
    var dontcare: [1000]c_int = undefined;
    for (0..ITERATIONS) |_| {
        _ = try rt.search(randomWord(), dontcare[0..1000], null);
    }

    std.debug.print("Press any key to end profiling...\n", .{});
    _ = try stdin.read(&buf);
}

const words = [_][]const u8{
    "apple",
    "banana",
    "cherry",
    "dog",
    "elephant",
    "flower",
    "guitar",
    "happy",
    "island",
    "jungle",
    "kitchen",
    "lemon",
    "mountain",
    "notebook",
    "ocean",
    "pencil",
    "quiet",
    "rainbow",
    "sunset",
    "tiger",
    "umbrella",
    "valley",
    "window",
    "xylophone",
    "yellow",
    "zebra",
    "adventure",
    "bridge",
    "castle",
    "dream",
    "energy",
    "freedom",
    "galaxy",
    "harmony",
    "journey",
    "knowledge",
    "lantern",
    "mystery",
    "nature",
    "opportunity",
    "passion",
    "question",
    "reflection",
    "serenity",
    "treasure",
    "universe",
    "victory",
    "wisdom",
    "explore",
    "zephyr",
    "bicycle",
    "candle",
    "dragon",
    "emerald",
    "feather",
    "garden",
    "horizon",
    "imagine",
    "jewel",
    "kindness",
    "library",
    "meadow",
    "nightfall",
    "orchestra",
    "painting",
    "quartz",
    "river",
    "starlight",
    "thunder",
    "uplift",
    "voyage",
    "waterfall",
    "xenial",
    "yearning",
    "zenith",
    "anchor",
    "butterfly",
    "compass",
    "dolphin",
    "eclipse",
    "fountain",
    "glacier",
    "hurricane",
    "infinity",
    "jasmine",
    "kaleidoscope",
    "lighthouse",
    "moonbeam",
    "nightingale",
    "opal",
    "phoenix",
    "quicksilver",
    "radiance",
    "symphony",
    "tempest",
    "utopia",
    "velvet",
    "whirlwind",
    "xanadu",
    "yonder",
};
fn randomWord() []const u8 {
    return words[rand_inst.intRangeAtMost(usize, 0, 99)];
}
fn randomSentence(allocator: std.mem.Allocator) ![]const u8 {
    const n_words = rand_inst.intRangeAtMost(usize, 3, 15);

    var sentence = std.ArrayList(u8).init(allocator);
    defer sentence.deinit();

    var i: usize = 0;
    while (i < n_words) : ({
        i += 1;
    }) {
        if (i > 0) try sentence.append(' ');
        try sentence.appendSlice(randomWord());
    }

    try sentence.append('.');
    return try allocator.dupe(u8, sentence.items);
}
fn randomNote(allocator: std.mem.Allocator) ![]const u8 {
    const n_sentences = rand_inst.intRangeAtMost(usize, 3, 100);

    var note = std.ArrayList(u8).init(allocator);
    defer note.deinit();

    var i: usize = 0;
    while (i < n_sentences) : ({
        i += 1;
    }) {
        if (i > 0) try note.append(' ');
        try note.appendSlice(try randomSentence(allocator));
    }

    return try allocator.dupe(u8, note.items);
}

var xosh = rand.init(69);
const rand_inst = xosh.random();

const std = @import("std");
const rand = std.Random.Xoshiro256;

const model = @import("model.zig");
const NoteID = model.NoteID;
const root = @import("root.zig");
