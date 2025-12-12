//! # Design notes
//! ## Principles
//! 1. Be opinionated. There's one and only one way to render Markdown. We will not support all.
//! 2. Don't try to modify the source in order to make the text renderable.
//! 3. Favor usability over correctness.
//!
//! ## Tabs Instead of Spaces
//! For code I generally lean towards spaces over tabs. However, I don't want users to have to fool
//! around with getting indentation just right for the parser to pick up certain elements.
//!
//! We need a solution for this on mobile. There is no way to insert a tab on an iPhone.
//!
//! ## 6 is the max degree
//! Why would you need more than 6 levels of indentation?
//!
//! ## Closing Code Blocks
//! Only count the end of the block if the closing parentheses are followed by a newline.
//! This is to make rendering more simple. So we can just tell the frontend "render
//! as code line X through line Y". Otherwise we would have to do something funky
//! like:
//!     1. Kick the text following the close out to the next line. Breaking rule 2.
//!     2. Render line X through Y as code. But then the user sees an unexpected
//!        tail of text which is rendered as code, but is not code.
//!     3. Hide the tail. This too is confusing to the user.
//!
//! This might be something we could throw errors for? If we choose to throw errors.

pub const TokenType = enum {
    HEADER,
    HORZ_RULE,
    QUOTE,
    ORDERED_LIST,
    UNORDERED_LIST,
    BOLD,
    ITALIC,
    EMPHASIS,
    CODE,
    BLOCK_CODE,
    LINK,
    PLAIN,
};

pub const Token = struct {
    tType: TokenType,
    /// Location in the source text for the beginning of this token. Inclusive.
    startI: usize,
    /// Location in the source text for the end of this token. Exclusive.
    endI: usize,
    /// The entirety of the token, including start and end delimiters.
    contents: []const u8 = "",
    /// Specifies which level of indentation or size a token is.
    /// HEADER with a degree of 2 is a `##`.
    /// *LIST with a degree of 2 is a singly indented sub-list.
    degree: u8 = 1,
};

pub const Markdown = struct {
    i: usize,
    src: []const u8,
    tokens: ArrayList(Token),
    allocator: Allocator,

    const Self = @This();

    pub fn init(allocator: Allocator) Markdown {
        return .{
            .i = 0,
            .src = "",
            .tokens = ArrayList(Token).init(allocator),
            .allocator = allocator,
        };
    }

    /// Parses the 'src'. Calling this invalidates(frees) the last returned list of tokens.
    pub fn parse(self: *Self, src: []const u8) ![]Token {
        const parse_zone = tracy.beginZone(@src(), .{ .name = "markdown.zig:parse" });
        defer parse_zone.end();

        self.i = 0;
        self.tokens.deinit();
        self.tokens = ArrayList(Token).init(self.allocator);
        self.src = src;

        while (self.i < self.src.len) {
            if (self.match(.HEADER)) |degree| {
                try self.pushToken(.HEADER, degree);
                _ = self.consumeUntil("\n", .{});
            } else if (self.match(.QUOTE)) |degree| {
                try self.pushToken(.QUOTE, degree);
                _ = self.consumeUntil("\n", .{});
            } else if (self.match(.EMPHASIS)) |_| {
                try self.pushToken(.EMPHASIS, 1);
                const found = self.consumeUntil("***", .{ .newlineBreak = true });
                if (!found) {
                    try self.resetAndAddPlain();
                }
            } else if (self.match(.BOLD)) |_| {
                try self.pushToken(.BOLD, 1);
                const found = self.consumeUntil("**", .{ .newlineBreak = true });
                if (!found) {
                    try self.resetAndAddPlain();
                }
            } else if (self.match(.ITALIC)) |_| {
                try self.pushToken(.ITALIC, 1);
                const found = self.consumeUntil("__", .{ .newlineBreak = true });
                if (!found) {
                    try self.resetAndAddPlain();
                }
            } else if (self.match(.CODE)) |_| {
                try self.pushToken(.CODE, 1);
                const found = self.consumeUntil("`", .{ .newlineBreak = true });
                if (!found) {
                    try self.resetAndAddPlain();
                }
            } else if (self.match(.BLOCK_CODE)) |_| {
                try self.pushToken(.BLOCK_CODE, 1);
                const found = self.consumeUntil("```", .{});
                if (!found or !self.startOrEndLine()) { // See #closing-code-blocks
                    try self.resetAndAddPlain();
                }
            } else if (self.match(.UNORDERED_LIST)) |degree| {
                try self.pushToken(.UNORDERED_LIST, degree);
                _ = self.consumeUntil("\n", .{ .newlineBreak = true });
            } else if (self.match(.LINK)) |_| {
                try self.pushToken(.LINK, 1);
                const found = self.consumeUntil(")", .{ .newlineBreak = true });
                if (!found) {
                    try self.resetAndAddPlain();
                }
            } else {
                // Is PLAIN
                const isEmpty = self.tokens.getLastOrNull() == null;
                if (isEmpty or self.tokens.getLast().tType != .PLAIN) {
                    try self.pushToken(.PLAIN, 1);
                }
                self.i += 1;
            }
        }
        try self.pushToken(null, null);

        try self.unicodePostprocess();
        return self.tokens.items;
    }

    fn unicodePostprocess(self: *Self) !void {
        var byteIndex: usize = 0;
        var codepointIndex: usize = 0;

        for (self.tokens.items) |*token| {
            // Advance to this token's start
            while (byteIndex < token.startI) {
                const byte = self.src[byteIndex];
                // Only count leading bytes (not continuation bytes 10xxxxxx)
                if (byte & 0xC0 != 0x80) {
                    codepointIndex += 1;
                }
                byteIndex += 1;
            }
            token.startI = codepointIndex;

            // Advance to this token's end
            while (byteIndex < token.endI) {
                const byte = self.src[byteIndex];
                if (byte & 0xC0 != 0x80) {
                    codepointIndex += 1;
                }
                byteIndex += 1;
            }
            token.endI = codepointIndex;
        }
    }

    /// Completes the token at the end of the list and optionally adds a new one of type newType.
    fn pushToken(self: *Self, newType: ?TokenType, degree: ?u8) !void {
        const push_zone = tracy.beginZone(@src(), .{ .name = "markdown.zig:pushToken" });
        defer push_zone.end();

        if (self.tokens.pop()) |token| {
            var copy = token;
            copy.endI = @min(self.i, self.src.len);
            copy.contents = self.src[copy.startI..copy.endI];
            try self.tokens.append(copy);
        }
        if (newType) |tt| {
            assert(degree != null);
            if (degree) |d| {
                try self.tokens.append(
                    .{ .tType = tt, .startI = self.i, .endI = self.i + 1, .degree = d },
                );
            }
        }
    }

    /// Removes the top element from the list without checking it.
    fn popToken(self: *Self) void {
        const pop_zone = tracy.beginZone(@src(), .{ .name = "markdown.zig:popToken" });
        defer pop_zone.end();
        _ = self.tokens.pop();
    }

    fn resetAndAddPlain(self: *Self) !void {
        const failed = self.tokens.pop();
        assert(failed != null);
        self.i = failed.?.startI;

        const isEmpty = self.tokens.getLastOrNull() == null;
        if (isEmpty or self.tokens.getLast().tType != .PLAIN) {
            try self.pushToken(.PLAIN, 1);
        }
        self.i += 1;
    }

    /// Determines if this is the start of a token. Returns null if not a match, degree otherwise.
    fn match(self: Self, t: TokenType) ?u8 {
        const match_zone = tracy.beginZone(@src(), .{ .name = "markdown.zig:match" });
        defer match_zone.end();

        switch (t) {
            .HEADER => {
                if (!self.startOrEndLine()) return null;
                var i: u8 = 0;
                while (self.peek(i) == '#') i += 1;
                if (i < 1 or i > 6) return null;
                if (self.peek(i) != ' ') return null;
                return i;
            },
            .QUOTE => {
                if (!self.startOrEndLine()) return null;
                var i: u8 = 0;
                while (self.peek(i) == '>') i += 1;
                if (i < 1 or i > 6) return null;
                if (self.peek(i) != ' ') return null;
                return i;
            },
            .EMPHASIS => {
                if (self.peek(0) != '*') return null;
                if (self.peek(1) != '*') return null;
                if (self.peek(2) != '*') return null;
                return 1;
            },
            .BOLD => {
                if (self.peek(0) != '*') return null;
                if (self.peek(1) != '*') return null;
                if (self.peek(2) == '*') return null; // Emphasis, not bold
                return 1;
            },
            .ITALIC => {
                if (self.peek(0) != '_') return null;
                if (self.peek(1) != '_') return null;
                if (self.peek(2) == '_') return null; // Emphasis, not italic
                return 1;
            },
            .CODE => {
                if (self.peek(0) != '`') return null;
                if (self.peek(1) == '`') return null; // Either block code or closed immediately
                return 1;
            },
            .BLOCK_CODE => {
                if (!self.startOrEndLine()) return null;
                if (self.peek(0) != '`') return null;
                if (self.peek(1) != '`') return null;
                if (self.peek(2) != '`') return null;
                return 1;
            },
            .UNORDERED_LIST => {
                if (!self.startOrEndLine()) return null;
                var i: u8 = 0;
                while (self.peek(i) == '\t') i += 1;
                if (i > 5) return null;
                const degree = i + 1;

                if (self.peek(i) != '-') return null;
                if (self.peek(i + 1) != ' ') return null;
                return degree;
            },
            .LINK => {
                if (self.peek(0) != '[') return null;
                for (1..std.math.maxInt(usize)) |i| {
                    switch (self.peek(i)) {
                        ']' => {
                            if (self.peek(i + 1) == '(') return 1 else return null;
                        },
                        '\n' => return null,
                        0 => return null,
                        else => continue,
                    }
                }
                unreachable;
            },
            else => unreachable,
        }
    }

    fn startOrEndLine(self: Self) bool {
        const nl_zone = tracy.beginZone(@src(), .{ .name = "markdown.zig:startOrEndLine" });
        defer nl_zone.end();

        const startOfLine = self.i == 0 or self.src[self.i - 1] == '\n';
        const endOfLine = self.i >= self.src.len or self.src[self.i] == '\n';
        return endOfLine or startOfLine;
    }

    /// Check ahead without moving the write head.
    fn peek(self: Self, i: usize) u8 {
        const peek_zone = tracy.beginZone(@src(), .{ .name = "markdown.zig:peek" });
        defer peek_zone.end();

        if (self.i + i >= self.src.len) return 0;
        return self.src[self.i + i];
    }

    const ConsumeOpts = struct {
        newlineBreak: bool = false,
    };

    /// Moves the read-head forward until 'str' is found. Returns whether it was found.
    fn consumeUntil(self: *Self, str: []const u8, consumeOpts: ConsumeOpts) bool {
        const peek_zone = tracy.beginZone(@src(), .{ .name = "markdown.zig:consumeUntil" });
        defer peek_zone.end();

        while (self.i + 1 + str.len <= self.src.len) {
            self.i += 1;
            if (consumeOpts.newlineBreak and self.src[self.i] == '\n') {
                self.i += 1;
                return false;
            }
            if (std.mem.eql(u8, self.src[self.i .. self.i + str.len], str)) {
                self.i += str.len;
                return true;
            }
        }
        self.i += str.len;
        return false;
    }
};

test "header plain" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var l = Markdown.init(arena.allocator());

    try expectEqualDeep(&[_]Token{
        .{ .tType = .HEADER, .contents = "# Header\n", .startI = 0, .endI = 9 },
        .{ .tType = .PLAIN, .contents = "plain text.", .startI = 9, .endI = 20 },
    }, try l.parse(
        \\# Header
        \\plain text.
    ));
    try expectEqualSlices(Token, &[_]Token{
        .{
            .tType = .HEADER,
            .contents = "# Header with # in the middle",
            .startI = 0,
            .endI = 29,
        },
    }, try l.parse(
        \\# Header with # in the middle
    ));
    try expectEqualDeep(&[_]Token{
        .{ .tType = .PLAIN, .contents = "Plain with # in the middle", .startI = 0, .endI = 26 },
    }, try l.parse(
        \\Plain with # in the middle
    ));
    try expectEqualDeep(&[_]Token{
        .{ .tType = .HEADER, .contents = "# A\n", .startI = 0, .endI = 4 },
        .{ .tType = .PLAIN, .contents = "B\n", .startI = 4, .endI = 6 },
        .{ .tType = .HEADER, .contents = "# C", .startI = 6, .endI = 9 },
    }, try l.parse(
        \\# A
        \\B
        \\# C
    ));

    var i: usize = 0;
    try expectEqualDeep(&[_]Token{
        .{ .tType = .HEADER, .degree = 1, .contents = "# 1\n", .startI = i, .endI = plusEq(&i, 4) },
        .{ .tType = .HEADER, .degree = 2, .contents = "## 2\n", .startI = i, .endI = plusEq(&i, 5) },
        .{ .tType = .HEADER, .degree = 3, .contents = "### 3\n", .startI = i, .endI = plusEq(&i, 6) },
        .{ .tType = .HEADER, .degree = 4, .contents = "#### 4\n", .startI = i, .endI = plusEq(&i, 7) },
        .{ .tType = .HEADER, .degree = 5, .contents = "##### 5\n", .startI = i, .endI = plusEq(&i, 8) },
        .{ .tType = .HEADER, .degree = 6, .contents = "###### 6\n", .startI = i, .endI = plusEq(&i, 9) },
        .{ .tType = .PLAIN, .degree = 1, .contents = "####### plain", .startI = i, .endI = plusEq(&i, 13) },
    }, try l.parse(
        \\# 1
        \\## 2
        \\### 3
        \\#### 4
        \\##### 5
        \\###### 6
        \\####### plain
    ));
}

test "quote plain" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var l = Markdown.init(arena.allocator());

    try expectEqualDeep(&[_]Token{
        .{ .tType = .QUOTE, .contents = "> quote\n", .startI = 0, .endI = 8 },
        .{ .tType = .PLAIN, .contents = "plain text.", .startI = 8, .endI = 19 },
    }, try l.parse(
        \\> quote
        \\plain text.
    ));
    try expectEqualSlices(Token, &[_]Token{
        .{
            .tType = .QUOTE,
            .contents = "> quote with > in the middle",
            .startI = 0,
            .endI = 28,
        },
    }, try l.parse(
        \\> quote with > in the middle
    ));
    try expectEqualDeep(&[_]Token{
        .{ .tType = .PLAIN, .contents = "Plain with > in the middle", .startI = 0, .endI = 26 },
    }, try l.parse(
        \\Plain with > in the middle
    ));
    try expectEqualDeep(&[_]Token{
        .{ .tType = .QUOTE, .contents = "> A\n", .startI = 0, .endI = 4 },
        .{ .tType = .PLAIN, .contents = "B\n", .startI = 4, .endI = 6 },
        .{ .tType = .QUOTE, .contents = "> C", .startI = 6, .endI = 9 },
    }, try l.parse(
        \\> A
        \\B
        \\> C
    ));

    var i: usize = 0;
    try expectEqualDeep(&[_]Token{
        .{ .tType = .QUOTE, .degree = 1, .contents = "> 1\n", .startI = i, .endI = plusEq(&i, 4) },
        .{ .tType = .QUOTE, .degree = 2, .contents = ">> 2\n", .startI = i, .endI = plusEq(&i, 5) },
        .{ .tType = .QUOTE, .degree = 3, .contents = ">>> 3\n", .startI = i, .endI = plusEq(&i, 6) },
        .{ .tType = .QUOTE, .degree = 4, .contents = ">>>> 4\n", .startI = i, .endI = plusEq(&i, 7) },
        .{ .tType = .QUOTE, .degree = 5, .contents = ">>>>> 5\n", .startI = i, .endI = plusEq(&i, 8) },
        .{ .tType = .QUOTE, .degree = 6, .contents = ">>>>>> 6\n", .startI = i, .endI = plusEq(&i, 9) },
        .{ .tType = .PLAIN, .degree = 1, .contents = ">>>>>>> plain", .startI = i, .endI = plusEq(&i, 13) },
    }, try l.parse(
        \\> 1
        \\>> 2
        \\>>> 3
        \\>>>> 4
        \\>>>>> 5
        \\>>>>>> 6
        \\>>>>>>> plain
    ));
}

test "bold" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var l = Markdown.init(arena.allocator());

    var i: usize = 0;
    var output = try l.parse("a**b**c**d**e");
    try expectEqualDeep(&[_]Token{
        .{ .tType = .PLAIN, .contents = "a", .startI = i, .endI = plusEq(&i, 1) },
        .{ .tType = .BOLD, .contents = "**b**", .startI = i, .endI = plusEq(&i, 5) },
        .{ .tType = .PLAIN, .contents = "c", .startI = i, .endI = plusEq(&i, 1) },
        .{ .tType = .BOLD, .contents = "**d**", .startI = i, .endI = plusEq(&i, 5) },
        .{ .tType = .PLAIN, .contents = "e", .startI = i, .endI = plusEq(&i, 1) },
    }, output);

    i = 0;
    output = try l.parse("ab**cd");
    try expectEqualDeep(&[_]Token{
        .{ .tType = .PLAIN, .contents = "ab**cd", .startI = i, .endI = plusEq(&i, 6) },
    }, output);

    i = 0;
    output = try l.parse("ab**\ne**f**g\n");
    try expectEqualDeep(&[_]Token{
        .{ .tType = .PLAIN, .contents = "ab**\ne", .startI = i, .endI = plusEq(&i, 6) },
        .{ .tType = .BOLD, .contents = "**f**", .startI = i, .endI = plusEq(&i, 5) },
        .{ .tType = .PLAIN, .contents = "g\n", .startI = i, .endI = plusEq(&i, 2) },
    }, output);
}

test "italic" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var l = Markdown.init(arena.allocator());

    var i: usize = 0;
    var output = try l.parse("a__b__c__d__e");
    try expectEqualDeep(&[_]Token{
        .{ .tType = .PLAIN, .contents = "a", .startI = i, .endI = plusEq(&i, 1) },
        .{ .tType = .ITALIC, .contents = "__b__", .startI = i, .endI = plusEq(&i, 5) },
        .{ .tType = .PLAIN, .contents = "c", .startI = i, .endI = plusEq(&i, 1) },
        .{ .tType = .ITALIC, .contents = "__d__", .startI = i, .endI = plusEq(&i, 5) },
        .{ .tType = .PLAIN, .contents = "e", .startI = i, .endI = plusEq(&i, 1) },
    }, output);

    i = 0;
    output = try l.parse("ab__cd");
    try expectEqualDeep(&[_]Token{
        .{ .tType = .PLAIN, .contents = "ab__cd", .startI = i, .endI = plusEq(&i, 6) },
    }, output);

    i = 0;
    output = try l.parse("ab__\ne__f__g\n");
    try expectEqualDeep(&[_]Token{
        .{ .tType = .PLAIN, .contents = "ab__\ne", .startI = i, .endI = plusEq(&i, 6) },
        .{ .tType = .ITALIC, .contents = "__f__", .startI = i, .endI = plusEq(&i, 5) },
        .{ .tType = .PLAIN, .contents = "g\n", .startI = i, .endI = plusEq(&i, 2) },
    }, output);
}

test "emphasis" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var l = Markdown.init(arena.allocator());

    var i: usize = 0;
    var output = try l.parse("a***b***c***d***e");
    try expectEqualDeep(&[_]Token{
        .{ .tType = .PLAIN, .contents = "a", .startI = i, .endI = plusEq(&i, 1) },
        .{ .tType = .EMPHASIS, .contents = "***b***", .startI = i, .endI = plusEq(&i, 7) },
        .{ .tType = .PLAIN, .contents = "c", .startI = i, .endI = plusEq(&i, 1) },
        .{ .tType = .EMPHASIS, .contents = "***d***", .startI = i, .endI = plusEq(&i, 7) },
        .{ .tType = .PLAIN, .contents = "e", .startI = i, .endI = plusEq(&i, 1) },
    }, output);

    i = 0;
    output = try l.parse("ab***cd");
    try expectEqualDeep(&[_]Token{
        .{ .tType = .PLAIN, .contents = "ab***cd", .startI = i, .endI = plusEq(&i, 7) },
    }, output);

    i = 0;
    output = try l.parse("ab***\ne***f***g\n");
    try expectEqualDeep(&[_]Token{
        .{ .tType = .PLAIN, .contents = "ab***\ne", .startI = i, .endI = plusEq(&i, 7) },
        .{ .tType = .EMPHASIS, .contents = "***f***", .startI = i, .endI = plusEq(&i, 7) },
        .{ .tType = .PLAIN, .contents = "g\n", .startI = i, .endI = plusEq(&i, 2) },
    }, output);
}

test "inline code" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var l = Markdown.init(arena.allocator());

    var i: usize = 0;
    var output = try l.parse("a`b`c`d`e");
    try expectEqualDeep(&[_]Token{
        .{ .tType = .PLAIN, .contents = "a", .startI = i, .endI = plusEq(&i, 1) },
        .{ .tType = .CODE, .contents = "`b`", .startI = i, .endI = plusEq(&i, 3) },
        .{ .tType = .PLAIN, .contents = "c", .startI = i, .endI = plusEq(&i, 1) },
        .{ .tType = .CODE, .contents = "`d`", .startI = i, .endI = plusEq(&i, 3) },
        .{ .tType = .PLAIN, .contents = "e", .startI = i, .endI = plusEq(&i, 1) },
    }, output);

    i = 0;
    output = try l.parse("ab`cd");
    try expectEqualDeep(&[_]Token{
        .{ .tType = .PLAIN, .contents = "ab`cd", .startI = i, .endI = plusEq(&i, 5) },
    }, output);

    i = 0;
    output = try l.parse("ab`\ne`f`g\n");
    try expectEqualDeep(&[_]Token{
        .{ .tType = .PLAIN, .contents = "ab`\ne", .startI = i, .endI = plusEq(&i, 5) },
        .{ .tType = .CODE, .contents = "`f`", .startI = i, .endI = plusEq(&i, 3) },
        .{ .tType = .PLAIN, .contents = "g\n", .startI = i, .endI = plusEq(&i, 2) },
    }, output);
}

test "block code" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var l = Markdown.init(arena.allocator());

    var i: usize = 0;
    var output = try l.parse("```this is code\nsecond line of code\n```");
    try expectEqualDeep(&[_]Token{
        .{
            .tType = .BLOCK_CODE,
            .contents = "```this is code\nsecond line of code\n```",
            .startI = i,
            .endI = plusEq(&i, 39),
        },
    }, output);

    i = 0;
    output = try l.parse("not code\n```\ncode with **no styling**\n```\nnot code again");
    try expectEqualDeep(&[_]Token{
        .{ .tType = .PLAIN, .contents = "not code\n", .startI = i, .endI = plusEq(&i, 9) },
        .{
            .tType = .BLOCK_CODE,
            .contents = "```\ncode with **no styling**\n```",
            .startI = i,
            .endI = plusEq(&i, 32),
        },
        .{ .tType = .PLAIN, .contents = "\nnot code again", .startI = i, .endI = plusEq(&i, 15) },
    }, output);
}

test "unordered list" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var l = Markdown.init(arena.allocator());

    var i: usize = 0;
    var output = try l.parse("- uno\n- dos");
    try expectEqualDeep(&[_]Token{
        .{ .tType = .UNORDERED_LIST, .contents = "- uno\n", .startI = i, .endI = plusEq(&i, 6) },
        .{ .tType = .UNORDERED_LIST, .contents = "- dos", .startI = i, .endI = plusEq(&i, 5) },
    }, output);

    i = 0;
    output = try l.parse("- 1\n\t- 2\n\t\t- 3\n\t\t\t- 4\n\t\t\t\t- 5\n\t\t\t\t\t- 6");
    try expectEqualDeep(&[_]Token{
        .{ .tType = .UNORDERED_LIST, .contents = "- 1\n", .startI = i, .endI = plusEq(&i, 4), .degree = 1 },
        .{ .tType = .UNORDERED_LIST, .contents = "\t- 2\n", .startI = i, .endI = plusEq(&i, 5), .degree = 2 },
        .{ .tType = .UNORDERED_LIST, .contents = "\t\t- 3\n", .startI = i, .endI = plusEq(&i, 6), .degree = 3 },
        .{ .tType = .UNORDERED_LIST, .contents = "\t\t\t- 4\n", .startI = i, .endI = plusEq(&i, 7), .degree = 4 },
        .{ .tType = .UNORDERED_LIST, .contents = "\t\t\t\t- 5\n", .startI = i, .endI = plusEq(&i, 8), .degree = 5 },
        .{ .tType = .UNORDERED_LIST, .contents = "\t\t\t\t\t- 6", .startI = i, .endI = plusEq(&i, 8), .degree = 6 },
    }, output);
}

test "link" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var l = Markdown.init(arena.allocator());

    {
        const input = "[label](https://google.com)";
        const output = try l.parse(input);
        var i: usize = 0;
        try expectEqualDeep(&[_]Token{
            .{ .tType = .LINK, .contents = input, .startI = i, .endI = plusEq(&i, input.len) },
        }, output);
    }
    {
        const input = "foo[label](https://google.com";
        const output = try l.parse(input);
        var i: usize = 0;
        try expectEqualDeep(&[_]Token{
            .{ .tType = .PLAIN, .contents = input, .startI = i, .endI = plusEq(&i, input.len) },
        }, output);
    }
    {
        const input = "[label]\n(https://google.com)";
        const output = try l.parse(input);
        var i: usize = 0;
        try expectEqualDeep(&[_]Token{
            .{ .tType = .PLAIN, .contents = input, .startI = i, .endI = plusEq(&i, input.len) },
        }, output);
    }
}

test "failed reset to last position" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var l = Markdown.init(arena.allocator());

    {
        const input = "[label](https://google.com";
        const output = try l.parse(input);
        var i: usize = 0;
        try expectEqualDeep(&[_]Token{
            .{ .tType = .PLAIN, .contents = input, .startI = i, .endI = plusEq(&i, input.len) },
        }, output);
    }
    {
        const input = "**unclosed bold";
        const output = try l.parse(input);
        var i: usize = 0;
        try expectEqualDeep(&[_]Token{
            .{ .tType = .PLAIN, .contents = input, .startI = i, .endI = plusEq(&i, input.len) },
        }, output);
    }
    {
        const input = "__unclosed italic";
        const output = try l.parse(input);
        var i: usize = 0;
        try expectEqualDeep(&[_]Token{
            .{ .tType = .PLAIN, .contents = input, .startI = i, .endI = plusEq(&i, input.len) },
        }, output);
    }
    {
        const input = "***unclosed emphasis";
        const output = try l.parse(input);
        var i: usize = 0;
        try expectEqualDeep(&[_]Token{
            .{ .tType = .PLAIN, .contents = input, .startI = i, .endI = plusEq(&i, input.len) },
        }, output);
    }
    {
        const input = "`unclosed code";
        const output = try l.parse(input);
        var i: usize = 0;
        try expectEqualDeep(&[_]Token{
            .{ .tType = .PLAIN, .contents = input, .startI = i, .endI = plusEq(&i, input.len) },
        }, output);
    }
    {
        const input = "```unclosed block code";
        const output = try l.parse(input);
        var i: usize = 0;
        try expectEqualDeep(&[_]Token{
            .{ .tType = .PLAIN, .contents = input, .startI = i, .endI = plusEq(&i, input.len) },
        }, output);
    }
}

test "unicode handling" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var l = Markdown.init(arena.allocator());

    {
        const input = "**brave❤️**__good🐶__***🔗wax***";
        const output = try l.parse(input);
        var i: usize = 0;
        // Codepoint counts: **brave (7) + ❤️ (2: heart + variation selector) + ** (2) = 11
        // __good (6) + 🐶 (1) + __ (2) = 9
        // *** (3) + 🔗 (1) + wax*** (6) = 10
        try expectEqualDeep(&[_]Token{
            .{ .tType = .BOLD, .contents = "**brave❤️**", .startI = i, .endI = plusEq(&i, 11) },
            .{ .tType = .ITALIC, .contents = "__good🐶__", .startI = i, .endI = plusEq(&i, 9) },
            .{ .tType = .EMPHASIS, .contents = "***🔗wax***", .startI = i, .endI = plusEq(&i, 10) },
        }, output);
    }
}

fn plusEq(a: *usize, b: usize) usize {
    a.* += b;
    return a.*;
}

// Notes
//
// Syntax is markdown inspired, not pure markdown.
// No nested elements for now.
//
// Stack of elements. If the next character or series of characters:
//     - Closes out the head token, pop it
//     - Opens a new token push the new token
//     - Otherwise continue adding to the current token
//
// type            |   start   |   end
// header          |   #       |   \n
// horizontal rule |   ---     |   \n
// quote           |   >       |   \n
// ordered list    |   [0-9]+. |   \n
// unordered list  |   -       |   \n
// bold            |   **      |   **
// italic          |   __      |   __
// emphasis        |   ***     |   ***
// inline code     |   `       |   `
// block code      |   ```     |   ```
//
// Not implementing links or images for now.
//
// To be more accurate to the actual Markdown spec, the line elements would actually end with a
// double new line, which is displayed as a blank line. We aren't going to do it that way. We want
// a format which is easy to type, not one which is necessarily compatible with everything.
//
// Maybe we can add an export option which adds in the silly little extra newlines.
//
// Maybe we break the rule for the quote? Seems like we might want to enforce a double newline for
// quote. Seems a little odd.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const expect = std.expect;
const expectEqualDeep = std.testing.expectEqualDeep;
const expectEqualSlices = std.testing.expectEqualSlices;
const utf8CountCodepoints = std.unicode.utf8CountCodepoints;

const tracy = @import("tracy");
