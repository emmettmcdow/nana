const std = @import("std");
const Allocator = std.mem.Allocator;

pub const WordPieceTokenizer = struct {
    vocab: std.StringHashMap(u32),
    allocator: Allocator,

    const Self = @This();

    pub const CLS_TOKEN = "[CLS]";
    pub const SEP_TOKEN = "[SEP]";
    pub const UNK_TOKEN = "[UNK]";
    pub const PAD_TOKEN = "[PAD]";
    pub const MASK_TOKEN = "[MASK]";

    const MAX_INPUT_CHARS_PER_WORD = 100;

    pub fn init(allocator: Allocator, vocab_json: []const u8) !Self {
        var self = Self{
            .vocab = std.StringHashMap(u32).init(allocator),
            .allocator = allocator,
        };

        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, vocab_json, .{});
        defer parsed.deinit();

        const vocab_obj = parsed.value.object.get("model").?.object.get("vocab").?.object;

        for (vocab_obj.keys(), vocab_obj.values()) |key, value| {
            const id: u32 = @intCast(value.integer);
            const key_copy = try allocator.dupe(u8, key);
            try self.vocab.put(key_copy, id);
        }

        return self;
    }

    pub fn deinit(self: *Self) void {
        var it = self.vocab.keyIterator();
        while (it.next()) |key| {
            self.allocator.free(key.*);
        }
        self.vocab.deinit();
    }

    pub fn tokenize(self: *Self, allocator: Allocator, text: []const u8) ![]u32 {
        var token_ids = std.ArrayList(u32).init(allocator);
        errdefer token_ids.deinit();

        try token_ids.append(self.vocab.get(CLS_TOKEN) orelse 101);

        const basic_tokens = try self.basicTokenize(allocator, text);
        defer allocator.free(basic_tokens);

        for (basic_tokens) |basic_token| {
            defer allocator.free(basic_token);
            const wordpiece_tokens = try self.wordpieceTokenize(allocator, basic_token);
            defer allocator.free(wordpiece_tokens);

            for (wordpiece_tokens) |wp_token| {
                defer allocator.free(wp_token);
                if (self.vocab.get(wp_token)) |id| {
                    try token_ids.append(id);
                } else {
                    try token_ids.append(self.vocab.get(UNK_TOKEN) orelse 100);
                }
            }
        }

        try token_ids.append(self.vocab.get(SEP_TOKEN) orelse 102);

        return token_ids.toOwnedSlice();
    }

    fn basicTokenize(self: *Self, allocator: Allocator, text: []const u8) ![][]const u8 {
        _ = self;
        var tokens = std.ArrayList([]const u8).init(allocator);
        errdefer {
            for (tokens.items) |t| allocator.free(t);
            tokens.deinit();
        }

        var current_token = std.ArrayList(u8).init(allocator);
        defer current_token.deinit();

        for (text) |c| {
            const lower_c = std.ascii.toLower(c);

            if (std.ascii.isAlphanumeric(lower_c)) {
                try current_token.append(lower_c);
            } else if (std.ascii.isWhitespace(c)) {
                if (current_token.items.len > 0) {
                    try tokens.append(try allocator.dupe(u8, current_token.items));
                    current_token.clearRetainingCapacity();
                }
            } else {
                if (current_token.items.len > 0) {
                    try tokens.append(try allocator.dupe(u8, current_token.items));
                    current_token.clearRetainingCapacity();
                }
                var punct: [1]u8 = .{lower_c};
                try tokens.append(try allocator.dupe(u8, &punct));
            }
        }

        if (current_token.items.len > 0) {
            try tokens.append(try allocator.dupe(u8, current_token.items));
        }

        return tokens.toOwnedSlice();
    }

    fn wordpieceTokenize(self: *Self, allocator: Allocator, word: []const u8) ![][]const u8 {
        if (word.len > MAX_INPUT_CHARS_PER_WORD) {
            var result = try allocator.alloc([]const u8, 1);
            result[0] = try allocator.dupe(u8, UNK_TOKEN);
            return result;
        }

        var sub_tokens = std.ArrayList([]const u8).init(allocator);
        errdefer {
            for (sub_tokens.items) |t| allocator.free(t);
            sub_tokens.deinit();
        }

        var start: usize = 0;
        while (start < word.len) {
            var end = word.len;
            var cur_substr: ?[]const u8 = null;

            while (start < end) {
                var substr_buf = std.ArrayList(u8).init(allocator);
                defer substr_buf.deinit();

                if (start > 0) {
                    try substr_buf.appendSlice("##");
                }
                try substr_buf.appendSlice(word[start..end]);

                if (self.vocab.contains(substr_buf.items)) {
                    cur_substr = try allocator.dupe(u8, substr_buf.items);
                    break;
                }
                end -= 1;
            }

            if (cur_substr == null) {
                var result = try allocator.alloc([]const u8, 1);
                result[0] = try allocator.dupe(u8, UNK_TOKEN);
                for (sub_tokens.items) |t| allocator.free(t);
                sub_tokens.deinit();
                return result;
            }

            try sub_tokens.append(cur_substr.?);
            start = end;
        }

        return sub_tokens.toOwnedSlice();
    }
};

test "tokenizer - basic" {
    const test_vocab =
        \\{"model":{"vocab":{"[PAD]":0,"[UNK]":100,"[CLS]":101,"[SEP]":102,"hello":7592,"world":2088,"##ing":2075}}}
    ;

    var tokenizer = try WordPieceTokenizer.init(std.testing.allocator, test_vocab);
    defer tokenizer.deinit();

    const tokens = try tokenizer.tokenize(std.testing.allocator, "hello world");
    defer std.testing.allocator.free(tokens);

    try std.testing.expectEqual(@as(usize, 4), tokens.len);
    try std.testing.expectEqual(@as(u32, 101), tokens[0]); // [CLS]
    try std.testing.expectEqual(@as(u32, 7592), tokens[1]); // hello
    try std.testing.expectEqual(@as(u32, 2088), tokens[2]); // world
    try std.testing.expectEqual(@as(u32, 102), tokens[3]); // [SEP]
}
