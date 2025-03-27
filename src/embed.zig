const std = @import("std");

const parseFromSliceLeaky = std.json.parseFromSliceLeaky;

const Tokens = struct {
    input_ids: []const u16,
    attention_mask: []const u8,
    token_type_ids: []const u8,
};

const Config = struct {
    map: std.StringHashMap(u16),
};

fn toLower(str: []const u8, buf: []u8) []u8 {
    if (str.len >= MAX_TOKEN_LENGTH) unreachable;
    for (str, 0..) |c, i| {
        // TODO: handle non-ascii?
        if (!std.ascii.isAscii(c)) unreachable;
        buf[i] = std.ascii.toLower(c);
    }
    return buf[0..str.len];
}

// TODO: max token length can likely be shorter
const MAX_TOKEN_LENGTH = 64;
const MAX_SENTENCE_TOKENS = 64;
pub fn tokenize(input: []const u8, cfg: Config, alloc: std.mem.Allocator) !Tokens {
    var input_buf = try alloc.alloc(u16, MAX_SENTENCE_TOKENS);
    @memset(input_buf, 0);
    var attention_buf = try alloc.alloc(u8, MAX_SENTENCE_TOKENS);
    @memset(attention_buf, 0);
    // This will not change. Zeros only for now
    var type_buf = try alloc.alloc(u8, MAX_SENTENCE_TOKENS);
    @memset(type_buf, 0);

    // First token will always be 101
    // TODO: update this to read from the Config
    input_buf[0] = 101;
    attention_buf[0] = 1;

    var it = std.mem.splitSequence(u8, input, " ");
    var tok: u16 = undefined;
    var i: usize = 1;
    while (it.next()) |word| {
        var wordbuf: [MAX_TOKEN_LENGTH]u8 = undefined;
        const lowerWord = toLower(word, &wordbuf);
        tok = cfg.map.get(lowerWord).?;
        input_buf[i] = tok;
        attention_buf[i] = 1;
        i += 1;
        if (i >= MAX_SENTENCE_TOKENS) unreachable;
    }

    // Last token will always be 102
    // TODO: update this to read from the Config
    input_buf[i] = 102;
    attention_buf[i] = 1;
    i += 1;

    return Tokens{ .input_ids = input_buf[0..i], .attention_mask = attention_buf[0..i], .token_type_ids = type_buf[0..i] };
}

const MEGABYTE = 1000000;
fn load_config(allocator: std.mem.Allocator) !Config {
    // FYI for tests - cwd() is relative to the dir that the `zig build test` command was called
    // from. NOT the source file directory OR the binary directory
    const wholeFile = try std.fs.cwd().readFileAlloc(allocator, "src/tokenizer.json", MEGABYTE);
    // Leaky is needed because we will be using arena
    const rawJson = try parseFromSliceLeaky(std.json.Value, allocator, wholeFile, .{ .ignore_unknown_fields = true });

    const rawMap = rawJson.object.get("model").?.object.get("vocab").?.object;

    var rawMapIt = rawMap.iterator();

    var cfg = Config{ .map = std.StringHashMap(u16).init(allocator) };

    while (rawMapIt.next()) |item| {
        try cfg.map.put(item.key_ptr.*, @intCast(item.value_ptr.*.integer));
    }

    return cfg;
}

const expect = std.testing.expect;
const expectEqualSlices = std.testing.expectEqualSlices;
test "hello" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const cfg = try load_config(allocator);

    const input: []const u8 = "hello";
    const expected = Tokens{ .input_ids = &.{ 101, 7592, 102 }, .attention_mask = &.{ 1, 1, 1 }, .token_type_ids = &.{ 0, 0, 0 } };

    const output = try tokenize(input, cfg, allocator);
    try expectEqualSlices(u16, output.input_ids, expected.input_ids);
    try expectEqualSlices(u8, output.attention_mask, expected.attention_mask);
    try expectEqualSlices(u8, output.token_type_ids, expected.token_type_ids);
}

test "yes sir" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const cfg = try load_config(allocator);

    const input: []const u8 = "yes sir";
    const expected = Tokens{ .input_ids = &.{ 101, 2748, 2909, 102 }, .attention_mask = &.{ 1, 1, 1, 1 }, .token_type_ids = &.{ 0, 0, 0, 0 } };

    const output = try tokenize(input, cfg, allocator);
    try expectEqualSlices(u16, output.input_ids, expected.input_ids);
    try expectEqualSlices(u8, output.attention_mask, expected.attention_mask);
    try expectEqualSlices(u8, output.token_type_ids, expected.token_type_ids);
}

test "YES SIR" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const cfg = try load_config(allocator);

    const input: []const u8 = "YES SIR";
    const expected = Tokens{ .input_ids = &.{ 101, 2748, 2909, 102 }, .attention_mask = &.{ 1, 1, 1, 1 }, .token_type_ids = &.{ 0, 0, 0, 0 } };

    const output = try tokenize(input, cfg, allocator);
    try expectEqualSlices(u16, output.input_ids, expected.input_ids);
    try expectEqualSlices(u8, output.attention_mask, expected.attention_mask);
    try expectEqualSlices(u8, output.token_type_ids, expected.token_type_ids);
}
