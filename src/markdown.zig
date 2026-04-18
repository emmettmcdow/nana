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
    /// Offset from startI where the rendered content begins (hides leading delimiters).
    renderStart: usize = 0,
    /// Offset from startI where the rendered content ends (hides trailing delimiters).
    renderEnd: usize = 0,
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
            .tokens = ArrayList(Token){},
            .allocator = allocator,
        };
    }

    /// Parses the 'src'. Calling this invalidates(frees) the last returned list of tokens.
    pub fn parse(self: *Self, src: []const u8) ![]Token {
        const parse_zone = tracy.beginZone(@src(), .{ .name = "markdown.zig:parse" });
        defer parse_zone.end();

        self.i = 0;
        self.tokens.deinit(self.allocator);
        self.tokens = ArrayList(Token){};
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

        // self.newlinePostprocess();
        try self.unicodePostprocess();
        self.postprocessAssertions();
        return self.tokens.items;
    }

    fn postprocessAssertions(self: *Self) void {
        for (self.tokens.items) |token| {
            if (token.tType != .PLAIN and token.endI > token.startI) {
                assert(self.src[token.startI] != '\n');
            }
        }
    }

    fn newlinePostprocess(self: *Self) void {
        for (self.tokens.items) |*token| {
            while (token.endI > token.startI and self.src[token.endI - 1] == '\n') {
                token.endI -= 1;
            }
            token.contents = self.src[token.startI..token.endI];
            if (token.renderEnd > token.endI) {
                token.renderEnd = token.endI;
            }
        }
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

            // Convert renderStart/renderEnd from absolute byte positions
            // to codepoint offsets relative to startI.
            // We walk through the token's bytes and track codepoint offsets.
            var renderStartCp: usize = 0;
            var renderEndCp: usize = 0;
            var tokenCpOffset: usize = 0;

            // Advance to this token's end, converting render positions along the way
            while (byteIndex < token.endI) {
                if (byteIndex == token.renderStart) {
                    renderStartCp = tokenCpOffset;
                }
                if (byteIndex == token.renderEnd) {
                    renderEndCp = tokenCpOffset;
                }
                const byte = self.src[byteIndex];
                if (byte & 0xC0 != 0x80) {
                    codepointIndex += 1;
                    tokenCpOffset += 1;
                }
                byteIndex += 1;
            }
            // Handle renderEnd == endI (common case)
            if (token.renderEnd == token.endI) {
                renderEndCp = tokenCpOffset;
            }
            // Handle renderStart == endI (degenerate case)
            if (token.renderStart == token.endI) {
                renderStartCp = tokenCpOffset;
            }
            token.endI = codepointIndex;
            token.renderStart = renderStartCp;
            token.renderEnd = renderEndCp;
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
            computeRenderRange(&copy);
            try self.tokens.append(self.allocator, copy);
        }
        if (newType) |tt| {
            assert(degree != null);
            if (degree) |d| {
                try self.tokens.append(
                    self.allocator,
                    .{ .tType = tt, .startI = self.i, .endI = self.i + 1, .degree = d },
                );
            }
        }
    }

    /// Computes renderStart and renderEnd as absolute byte positions.
    /// These are converted to codepoint offsets from startI during unicodePostprocess.
    fn computeRenderRange(token: *Token) void {
        const len = token.endI - token.startI;
        switch (token.tType) {
            .HEADER => {
                // `## text` — degree # chars + 1 space
                const prefix: usize = @as(usize, token.degree) + 1;
                token.renderStart = token.startI + @min(prefix, len);
                token.renderEnd = token.endI;
            },
            .QUOTE => {
                // `>> text` — degree > chars + 1 space
                const prefix: usize = @as(usize, token.degree) + 1;
                token.renderStart = token.startI + @min(prefix, len);
                token.renderEnd = token.endI;
            },
            .BOLD => {
                // `**text**`
                token.renderStart = token.startI + 2;
                token.renderEnd = token.endI - 2;
            },
            .ITALIC => {
                // `__text__`
                token.renderStart = token.startI + 2;
                token.renderEnd = token.endI - 2;
            },
            .EMPHASIS => {
                // `***text***`
                token.renderStart = token.startI + 3;
                token.renderEnd = token.endI - 3;
            },
            .CODE => {
                // `` `text` ``
                token.renderStart = token.startI + 1;
                token.renderEnd = token.endI - 1;
            },
            .UNORDERED_LIST => {
                // `\t...- text` — (degree-1) tabs + `- `
                const prefix: usize = @as(usize, token.degree) - 1 + 2;
                token.renderStart = token.startI + @min(prefix, len);
                token.renderEnd = token.endI;
            },
            .LINK => {
                // `[text](url)` — hide `[` prefix, hide from `]` to end
                token.renderStart = token.startI + 1; // skip `[`
                // Find `]` in contents
                const contents = token.contents;
                var close_bracket: usize = len;
                for (contents, 0..) |c, idx| {
                    if (c == ']') {
                        close_bracket = idx;
                        break;
                    }
                }
                token.renderEnd = token.startI + close_bracket;
            },
            .PLAIN, .BLOCK_CODE, .HORZ_RULE => {
                token.renderStart = token.startI;
                token.renderEnd = token.endI;
            },
            .ORDERED_LIST => {
                token.renderStart = token.startI;
                token.renderEnd = token.endI;
            },
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
        .{ .tType = .HEADER, .contents = "# Header\n", .startI = 0, .endI = 9, .renderStart = 2, .renderEnd = 9 },
        .{ .tType = .PLAIN, .contents = "plain text.", .startI = 9, .endI = 20, .renderStart = 0, .renderEnd = 11 },
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
            .renderStart = 2,
            .renderEnd = 29,
        },
    }, try l.parse(
        \\# Header with # in the middle
    ));
    try expectEqualDeep(&[_]Token{
        .{ .tType = .PLAIN, .contents = "Plain with # in the middle", .startI = 0, .endI = 26, .renderStart = 0, .renderEnd = 26 },
    }, try l.parse(
        \\Plain with # in the middle
    ));
    try expectEqualDeep(&[_]Token{
        .{ .tType = .HEADER, .contents = "# A\n", .startI = 0, .endI = 4, .renderStart = 2, .renderEnd = 4 },
        .{ .tType = .PLAIN, .contents = "B\n", .startI = 4, .endI = 6, .renderStart = 0, .renderEnd = 2 },
        .{ .tType = .HEADER, .contents = "# C", .startI = 6, .endI = 9, .renderStart = 2, .renderEnd = 3 },
    }, try l.parse(
        \\# A
        \\B
        \\# C
    ));

    var i: usize = 0;
    try expectEqualDeep(&[_]Token{
        .{ .tType = .HEADER, .degree = 1, .contents = "# 1\n", .startI = i, .endI = plusEq(&i, 4), .renderStart = 2, .renderEnd = 4 },
        .{ .tType = .HEADER, .degree = 2, .contents = "## 2\n", .startI = i, .endI = plusEq(&i, 5), .renderStart = 3, .renderEnd = 5 },
        .{ .tType = .HEADER, .degree = 3, .contents = "### 3\n", .startI = i, .endI = plusEq(&i, 6), .renderStart = 4, .renderEnd = 6 },
        .{ .tType = .HEADER, .degree = 4, .contents = "#### 4\n", .startI = i, .endI = plusEq(&i, 7), .renderStart = 5, .renderEnd = 7 },
        .{ .tType = .HEADER, .degree = 5, .contents = "##### 5\n", .startI = i, .endI = plusEq(&i, 8), .renderStart = 6, .renderEnd = 8 },
        .{ .tType = .HEADER, .degree = 6, .contents = "###### 6\n", .startI = i, .endI = plusEq(&i, 9), .renderStart = 7, .renderEnd = 9 },
        .{ .tType = .PLAIN, .degree = 1, .contents = "####### plain", .startI = i, .endI = plusEq(&i, 13), .renderStart = 0, .renderEnd = 13 },
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
        .{ .tType = .QUOTE, .contents = "> quote\n", .startI = 0, .endI = 8, .renderStart = 2, .renderEnd = 8 },
        .{ .tType = .PLAIN, .contents = "plain text.", .startI = 8, .endI = 19, .renderStart = 0, .renderEnd = 11 },
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
            .renderStart = 2,
            .renderEnd = 28,
        },
    }, try l.parse(
        \\> quote with > in the middle
    ));
    try expectEqualDeep(&[_]Token{
        .{ .tType = .PLAIN, .contents = "Plain with > in the middle", .startI = 0, .endI = 26, .renderStart = 0, .renderEnd = 26 },
    }, try l.parse(
        \\Plain with > in the middle
    ));
    try expectEqualDeep(&[_]Token{
        .{ .tType = .QUOTE, .contents = "> A\n", .startI = 0, .endI = 4, .renderStart = 2, .renderEnd = 4 },
        .{ .tType = .PLAIN, .contents = "B\n", .startI = 4, .endI = 6, .renderStart = 0, .renderEnd = 2 },
        .{ .tType = .QUOTE, .contents = "> C", .startI = 6, .endI = 9, .renderStart = 2, .renderEnd = 3 },
    }, try l.parse(
        \\> A
        \\B
        \\> C
    ));

    var i: usize = 0;
    try expectEqualDeep(&[_]Token{
        .{ .tType = .QUOTE, .degree = 1, .contents = "> 1\n", .startI = i, .endI = plusEq(&i, 4), .renderStart = 2, .renderEnd = 4 },
        .{ .tType = .QUOTE, .degree = 2, .contents = ">> 2\n", .startI = i, .endI = plusEq(&i, 5), .renderStart = 3, .renderEnd = 5 },
        .{ .tType = .QUOTE, .degree = 3, .contents = ">>> 3\n", .startI = i, .endI = plusEq(&i, 6), .renderStart = 4, .renderEnd = 6 },
        .{ .tType = .QUOTE, .degree = 4, .contents = ">>>> 4\n", .startI = i, .endI = plusEq(&i, 7), .renderStart = 5, .renderEnd = 7 },
        .{ .tType = .QUOTE, .degree = 5, .contents = ">>>>> 5\n", .startI = i, .endI = plusEq(&i, 8), .renderStart = 6, .renderEnd = 8 },
        .{ .tType = .QUOTE, .degree = 6, .contents = ">>>>>> 6\n", .startI = i, .endI = plusEq(&i, 9), .renderStart = 7, .renderEnd = 9 },
        .{ .tType = .PLAIN, .degree = 1, .contents = ">>>>>>> plain", .startI = i, .endI = plusEq(&i, 13), .renderStart = 0, .renderEnd = 13 },
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
        .{ .tType = .PLAIN, .contents = "a", .startI = i, .endI = plusEq(&i, 1), .renderStart = 0, .renderEnd = 1 },
        .{ .tType = .BOLD, .contents = "**b**", .startI = i, .endI = plusEq(&i, 5), .renderStart = 2, .renderEnd = 3 },
        .{ .tType = .PLAIN, .contents = "c", .startI = i, .endI = plusEq(&i, 1), .renderStart = 0, .renderEnd = 1 },
        .{ .tType = .BOLD, .contents = "**d**", .startI = i, .endI = plusEq(&i, 5), .renderStart = 2, .renderEnd = 3 },
        .{ .tType = .PLAIN, .contents = "e", .startI = i, .endI = plusEq(&i, 1), .renderStart = 0, .renderEnd = 1 },
    }, output);

    i = 0;
    output = try l.parse("ab**cd");
    try expectEqualDeep(&[_]Token{
        .{ .tType = .PLAIN, .contents = "ab**cd", .startI = i, .endI = plusEq(&i, 6), .renderStart = 0, .renderEnd = 6 },
    }, output);

    i = 0;
    output = try l.parse("ab**\ne**f**g\n");
    try expectEqualDeep(&[_]Token{
        .{ .tType = .PLAIN, .contents = "ab**\ne", .startI = i, .endI = plusEq(&i, 6), .renderStart = 0, .renderEnd = 6 },
        .{ .tType = .BOLD, .contents = "**f**", .startI = i, .endI = plusEq(&i, 5), .renderStart = 2, .renderEnd = 3 },
        .{ .tType = .PLAIN, .contents = "g\n", .startI = i, .endI = plusEq(&i, 2), .renderStart = 0, .renderEnd = 2 },
    }, output);
}

test "italic" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var l = Markdown.init(arena.allocator());

    var i: usize = 0;
    var output = try l.parse("a__b__c__d__e");
    try expectEqualDeep(&[_]Token{
        .{ .tType = .PLAIN, .contents = "a", .startI = i, .endI = plusEq(&i, 1), .renderStart = 0, .renderEnd = 1 },
        .{ .tType = .ITALIC, .contents = "__b__", .startI = i, .endI = plusEq(&i, 5), .renderStart = 2, .renderEnd = 3 },
        .{ .tType = .PLAIN, .contents = "c", .startI = i, .endI = plusEq(&i, 1), .renderStart = 0, .renderEnd = 1 },
        .{ .tType = .ITALIC, .contents = "__d__", .startI = i, .endI = plusEq(&i, 5), .renderStart = 2, .renderEnd = 3 },
        .{ .tType = .PLAIN, .contents = "e", .startI = i, .endI = plusEq(&i, 1), .renderStart = 0, .renderEnd = 1 },
    }, output);

    i = 0;
    output = try l.parse("ab__cd");
    try expectEqualDeep(&[_]Token{
        .{ .tType = .PLAIN, .contents = "ab__cd", .startI = i, .endI = plusEq(&i, 6), .renderStart = 0, .renderEnd = 6 },
    }, output);

    i = 0;
    output = try l.parse("ab__\ne__f__g\n");
    try expectEqualDeep(&[_]Token{
        .{ .tType = .PLAIN, .contents = "ab__\ne", .startI = i, .endI = plusEq(&i, 6), .renderStart = 0, .renderEnd = 6 },
        .{ .tType = .ITALIC, .contents = "__f__", .startI = i, .endI = plusEq(&i, 5), .renderStart = 2, .renderEnd = 3 },
        .{ .tType = .PLAIN, .contents = "g\n", .startI = i, .endI = plusEq(&i, 2), .renderStart = 0, .renderEnd = 2 },
    }, output);
}

test "emphasis" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var l = Markdown.init(arena.allocator());

    var i: usize = 0;
    var output = try l.parse("a***b***c***d***e");
    try expectEqualDeep(&[_]Token{
        .{ .tType = .PLAIN, .contents = "a", .startI = i, .endI = plusEq(&i, 1), .renderStart = 0, .renderEnd = 1 },
        .{ .tType = .EMPHASIS, .contents = "***b***", .startI = i, .endI = plusEq(&i, 7), .renderStart = 3, .renderEnd = 4 },
        .{ .tType = .PLAIN, .contents = "c", .startI = i, .endI = plusEq(&i, 1), .renderStart = 0, .renderEnd = 1 },
        .{ .tType = .EMPHASIS, .contents = "***d***", .startI = i, .endI = plusEq(&i, 7), .renderStart = 3, .renderEnd = 4 },
        .{ .tType = .PLAIN, .contents = "e", .startI = i, .endI = plusEq(&i, 1), .renderStart = 0, .renderEnd = 1 },
    }, output);

    i = 0;
    output = try l.parse("ab***cd");
    try expectEqualDeep(&[_]Token{
        .{ .tType = .PLAIN, .contents = "ab***cd", .startI = i, .endI = plusEq(&i, 7), .renderStart = 0, .renderEnd = 7 },
    }, output);

    i = 0;
    output = try l.parse("ab***\ne***f***g\n");
    try expectEqualDeep(&[_]Token{
        .{ .tType = .PLAIN, .contents = "ab***\ne", .startI = i, .endI = plusEq(&i, 7), .renderStart = 0, .renderEnd = 7 },
        .{ .tType = .EMPHASIS, .contents = "***f***", .startI = i, .endI = plusEq(&i, 7), .renderStart = 3, .renderEnd = 4 },
        .{ .tType = .PLAIN, .contents = "g\n", .startI = i, .endI = plusEq(&i, 2), .renderStart = 0, .renderEnd = 2 },
    }, output);
}

test "inline code" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var l = Markdown.init(arena.allocator());

    var i: usize = 0;
    var output = try l.parse("a`b`c`d`e");
    try expectEqualDeep(&[_]Token{
        .{ .tType = .PLAIN, .contents = "a", .startI = i, .endI = plusEq(&i, 1), .renderStart = 0, .renderEnd = 1 },
        .{ .tType = .CODE, .contents = "`b`", .startI = i, .endI = plusEq(&i, 3), .renderStart = 1, .renderEnd = 2 },
        .{ .tType = .PLAIN, .contents = "c", .startI = i, .endI = plusEq(&i, 1), .renderStart = 0, .renderEnd = 1 },
        .{ .tType = .CODE, .contents = "`d`", .startI = i, .endI = plusEq(&i, 3), .renderStart = 1, .renderEnd = 2 },
        .{ .tType = .PLAIN, .contents = "e", .startI = i, .endI = plusEq(&i, 1), .renderStart = 0, .renderEnd = 1 },
    }, output);

    i = 0;
    output = try l.parse("ab`cd");
    try expectEqualDeep(&[_]Token{
        .{ .tType = .PLAIN, .contents = "ab`cd", .startI = i, .endI = plusEq(&i, 5), .renderStart = 0, .renderEnd = 5 },
    }, output);

    i = 0;
    output = try l.parse("ab`\ne`f`g\n");
    try expectEqualDeep(&[_]Token{
        .{ .tType = .PLAIN, .contents = "ab`\ne", .startI = i, .endI = plusEq(&i, 5), .renderStart = 0, .renderEnd = 5 },
        .{ .tType = .CODE, .contents = "`f`", .startI = i, .endI = plusEq(&i, 3), .renderStart = 1, .renderEnd = 2 },
        .{ .tType = .PLAIN, .contents = "g\n", .startI = i, .endI = plusEq(&i, 2), .renderStart = 0, .renderEnd = 2 },
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
            .renderStart = 0,
            .renderEnd = 39,
        },
    }, output);

    i = 0;
    output = try l.parse("not code\n```\ncode with **no styling**\n```\nnot code again");
    try expectEqualDeep(&[_]Token{
        .{ .tType = .PLAIN, .contents = "not code\n", .startI = i, .endI = plusEq(&i, 9), .renderStart = 0, .renderEnd = 9 },
        .{
            .tType = .BLOCK_CODE,
            .contents = "```\ncode with **no styling**\n```",
            .startI = i,
            .endI = plusEq(&i, 32),
            .renderStart = 0,
            .renderEnd = 32,
        },
        .{ .tType = .PLAIN, .contents = "\nnot code again", .startI = i, .endI = plusEq(&i, 15), .renderStart = 0, .renderEnd = 15 },
    }, output);
}

test "unordered list" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var l = Markdown.init(arena.allocator());

    var i: usize = 0;
    var output = try l.parse("- uno\n- dos");
    try expectEqualDeep(&[_]Token{
        .{ .tType = .UNORDERED_LIST, .contents = "- uno\n", .startI = i, .endI = plusEq(&i, 6), .renderStart = 2, .renderEnd = 6 },
        .{ .tType = .UNORDERED_LIST, .contents = "- dos", .startI = i, .endI = plusEq(&i, 5), .renderStart = 2, .renderEnd = 5 },
    }, output);

    i = 0;
    output = try l.parse("- 1\n\t- 2\n\t\t- 3\n\t\t\t- 4\n\t\t\t\t- 5\n\t\t\t\t\t- 6");
    try expectEqualDeep(&[_]Token{
        .{ .tType = .UNORDERED_LIST, .contents = "- 1\n", .startI = i, .endI = plusEq(&i, 4), .degree = 1, .renderStart = 2, .renderEnd = 4 },
        .{ .tType = .UNORDERED_LIST, .contents = "\t- 2\n", .startI = i, .endI = plusEq(&i, 5), .degree = 2, .renderStart = 3, .renderEnd = 5 },
        .{ .tType = .UNORDERED_LIST, .contents = "\t\t- 3\n", .startI = i, .endI = plusEq(&i, 6), .degree = 3, .renderStart = 4, .renderEnd = 6 },
        .{ .tType = .UNORDERED_LIST, .contents = "\t\t\t- 4\n", .startI = i, .endI = plusEq(&i, 7), .degree = 4, .renderStart = 5, .renderEnd = 7 },
        .{ .tType = .UNORDERED_LIST, .contents = "\t\t\t\t- 5\n", .startI = i, .endI = plusEq(&i, 8), .degree = 5, .renderStart = 6, .renderEnd = 8 },
        .{ .tType = .UNORDERED_LIST, .contents = "\t\t\t\t\t- 6", .startI = i, .endI = plusEq(&i, 8), .degree = 6, .renderStart = 7, .renderEnd = 8 },
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
            .{ .tType = .LINK, .contents = input, .startI = i, .endI = plusEq(&i, input.len), .renderStart = 1, .renderEnd = 6 },
        }, output);
    }
    {
        const input = "foo[label](https://google.com";
        const output = try l.parse(input);
        var i: usize = 0;
        try expectEqualDeep(&[_]Token{
            .{ .tType = .PLAIN, .contents = input, .startI = i, .endI = plusEq(&i, input.len), .renderStart = 0, .renderEnd = input.len },
        }, output);
    }
    {
        const input = "[label]\n(https://google.com)";
        const output = try l.parse(input);
        var i: usize = 0;
        try expectEqualDeep(&[_]Token{
            .{ .tType = .PLAIN, .contents = input, .startI = i, .endI = plusEq(&i, input.len), .renderStart = 0, .renderEnd = input.len },
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
            .{ .tType = .PLAIN, .contents = input, .startI = i, .endI = plusEq(&i, input.len), .renderStart = 0, .renderEnd = input.len },
        }, output);
    }
    {
        const input = "**unclosed bold";
        const output = try l.parse(input);
        var i: usize = 0;
        try expectEqualDeep(&[_]Token{
            .{ .tType = .PLAIN, .contents = input, .startI = i, .endI = plusEq(&i, input.len), .renderStart = 0, .renderEnd = input.len },
        }, output);
    }
    {
        const input = "__unclosed italic";
        const output = try l.parse(input);
        var i: usize = 0;
        try expectEqualDeep(&[_]Token{
            .{ .tType = .PLAIN, .contents = input, .startI = i, .endI = plusEq(&i, input.len), .renderStart = 0, .renderEnd = input.len },
        }, output);
    }
    {
        const input = "***unclosed emphasis";
        const output = try l.parse(input);
        var i: usize = 0;
        try expectEqualDeep(&[_]Token{
            .{ .tType = .PLAIN, .contents = input, .startI = i, .endI = plusEq(&i, input.len), .renderStart = 0, .renderEnd = input.len },
        }, output);
    }
    {
        const input = "`unclosed code";
        const output = try l.parse(input);
        var i: usize = 0;
        try expectEqualDeep(&[_]Token{
            .{ .tType = .PLAIN, .contents = input, .startI = i, .endI = plusEq(&i, input.len), .renderStart = 0, .renderEnd = input.len },
        }, output);
    }
    {
        const input = "```unclosed block code";
        const output = try l.parse(input);
        var i: usize = 0;
        try expectEqualDeep(&[_]Token{
            .{ .tType = .PLAIN, .contents = input, .startI = i, .endI = plusEq(&i, input.len), .renderStart = 0, .renderEnd = input.len },
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
            .{ .tType = .BOLD, .contents = "**brave❤️**", .startI = i, .endI = plusEq(&i, 11), .renderStart = 2, .renderEnd = 9 },
            .{ .tType = .ITALIC, .contents = "__good🐶__", .startI = i, .endI = plusEq(&i, 9), .renderStart = 2, .renderEnd = 7 },
            .{ .tType = .EMPHASIS, .contents = "***🔗wax***", .startI = i, .endI = plusEq(&i, 10), .renderStart = 3, .renderEnd = 7 },
        }, output);
    }
}

test "renderStart and renderEnd" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var l = Markdown.init(arena.allocator());

    // Plain text: renderStart=0, renderEnd=length (everything visible)
    {
        const output = try l.parse("hello world");
        try expectEqualDeep(&[_]Token{
            .{ .tType = .PLAIN, .contents = "hello world", .startI = 0, .endI = 11, .renderStart = 0, .renderEnd = 11 },
        }, output);
    }

    // Headers: hide `## ` prefix
    {
        var i: usize = 0;
        const output = try l.parse("# Title\n## Subtitle");
        try expectEqualDeep(&[_]Token{
            .{ .tType = .HEADER, .degree = 1, .contents = "# Title\n", .startI = i, .endI = plusEq(&i, 8), .renderStart = 2, .renderEnd = 8 },
            .{ .tType = .HEADER, .degree = 2, .contents = "## Subtitle", .startI = i, .endI = plusEq(&i, 11), .renderStart = 3, .renderEnd = 11 },
        }, output);
    }

    // Bold: hide `**` on each side
    {
        var i: usize = 0;
        const output = try l.parse("a**bold**b");
        try expectEqualDeep(&[_]Token{
            .{ .tType = .PLAIN, .contents = "a", .startI = i, .endI = plusEq(&i, 1), .renderStart = 0, .renderEnd = 1 },
            .{ .tType = .BOLD, .contents = "**bold**", .startI = i, .endI = plusEq(&i, 8), .renderStart = 2, .renderEnd = 6 },
            .{ .tType = .PLAIN, .contents = "b", .startI = i, .endI = plusEq(&i, 1), .renderStart = 0, .renderEnd = 1 },
        }, output);
    }

    // Italic: hide `__` on each side
    {
        var i: usize = 0;
        const output = try l.parse("a__italic__b");
        try expectEqualDeep(&[_]Token{
            .{ .tType = .PLAIN, .contents = "a", .startI = i, .endI = plusEq(&i, 1), .renderStart = 0, .renderEnd = 1 },
            .{ .tType = .ITALIC, .contents = "__italic__", .startI = i, .endI = plusEq(&i, 10), .renderStart = 2, .renderEnd = 8 },
            .{ .tType = .PLAIN, .contents = "b", .startI = i, .endI = plusEq(&i, 1), .renderStart = 0, .renderEnd = 1 },
        }, output);
    }

    // Emphasis: hide `***` on each side
    {
        var i: usize = 0;
        const output = try l.parse("***wow***");
        try expectEqualDeep(&[_]Token{
            .{ .tType = .EMPHASIS, .contents = "***wow***", .startI = i, .endI = plusEq(&i, 9), .renderStart = 3, .renderEnd = 6 },
        }, output);
    }

    // Inline code: hide ` on each side
    {
        var i: usize = 0;
        const output = try l.parse("a`code`b");
        try expectEqualDeep(&[_]Token{
            .{ .tType = .PLAIN, .contents = "a", .startI = i, .endI = plusEq(&i, 1), .renderStart = 0, .renderEnd = 1 },
            .{ .tType = .CODE, .contents = "`code`", .startI = i, .endI = plusEq(&i, 6), .renderStart = 1, .renderEnd = 5 },
            .{ .tType = .PLAIN, .contents = "b", .startI = i, .endI = plusEq(&i, 1), .renderStart = 0, .renderEnd = 1 },
        }, output);
    }

    // Quote: hide `> ` prefix
    {
        const output = try l.parse("> quoted text");
        try expectEqualDeep(&[_]Token{
            .{ .tType = .QUOTE, .contents = "> quoted text", .startI = 0, .endI = 13, .renderStart = 2, .renderEnd = 13 },
        }, output);
    }

    // Multi-level quote: hide `>>> ` prefix
    {
        const output = try l.parse(">>> deep quote");
        try expectEqualDeep(&[_]Token{
            .{ .tType = .QUOTE, .degree = 3, .contents = ">>> deep quote", .startI = 0, .endI = 14, .renderStart = 4, .renderEnd = 14 },
        }, output);
    }

    // Unordered list: hide `- ` prefix
    {
        var i: usize = 0;
        const output = try l.parse("- item one\n- item two");
        try expectEqualDeep(&[_]Token{
            .{ .tType = .UNORDERED_LIST, .contents = "- item one\n", .startI = i, .endI = plusEq(&i, 11), .renderStart = 2, .renderEnd = 11 },
            .{ .tType = .UNORDERED_LIST, .contents = "- item two", .startI = i, .endI = plusEq(&i, 10), .renderStart = 2, .renderEnd = 10 },
        }, output);
    }

    // Indented unordered list: hide `\t- ` prefix
    {
        var i: usize = 0;
        const output = try l.parse("- top\n\t- nested");
        try expectEqualDeep(&[_]Token{
            .{ .tType = .UNORDERED_LIST, .degree = 1, .contents = "- top\n", .startI = i, .endI = plusEq(&i, 6), .renderStart = 2, .renderEnd = 6 },
            .{ .tType = .UNORDERED_LIST, .degree = 2, .contents = "\t- nested", .startI = i, .endI = plusEq(&i, 9), .renderStart = 3, .renderEnd = 9 },
        }, output);
    }

    // Link: hide `[` and `](url)`
    {
        const input = "[click here](https://example.com)";
        const output = try l.parse(input);
        try expectEqualDeep(&[_]Token{
            .{ .tType = .LINK, .contents = input, .startI = 0, .endI = input.len, .renderStart = 1, .renderEnd = 11 },
        }, output);
    }

    // Block code: renderStart=0, renderEnd=length (no hiding for now)
    {
        const input = "```\nsome code\n```";
        const output = try l.parse(input);
        try expectEqualDeep(&[_]Token{
            .{ .tType = .BLOCK_CODE, .contents = input, .startI = 0, .endI = input.len, .renderStart = 0, .renderEnd = input.len },
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
