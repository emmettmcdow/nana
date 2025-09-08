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

pub const Lexer = struct {
    i: usize,
    src: []const u8,
    tokens: ArrayList(Token),
    allocator: Allocator,

    const Self = @This();

    pub fn init(allocator: Allocator) Lexer {
        return .{
            .i = 0,
            .src = "",
            .tokens = ArrayList(Token).init(allocator),
            .allocator = allocator,
        };
    }

    /// Lexes the 'src'. Calling this invalidates(frees) the last returned list of tokens.
    pub fn lex(self: *Self, src: []const u8) []Token {
        self.i = 0;
        self.tokens.deinit();
        self.tokens = ArrayList(Token).init(self.allocator);
        self.src = src;

        while (self.i < self.src.len) {
            if (self.match(.HEADER)) |degree| {
                self.pushToken(.HEADER, degree);
                self.consumeUntil('\n');
                self.i += 1;
            } else {
                // Is PLAIN
                const isEmpty = self.tokens.getLastOrNull() == null;
                if (isEmpty or self.tokens.getLast().tType != .PLAIN) {
                    self.pushToken(.PLAIN, 1);
                }
                self.i += 1;
            }
        }
        self.pushToken(null, null);

        return self.tokens.items;
    }

    /// Completes the token at the end of the list and optionally adds a new one of type newType.
    fn pushToken(self: *Self, newType: ?TokenType, degree: ?u8) void {
        if (self.tokens.pop()) |token| {
            var copy = token;
            copy.endI = @min(self.i, self.src.len);
            copy.contents = self.src[copy.startI..copy.endI];
            self.tokens.append(copy) catch unreachable;
        }
        if (newType) |tt| {
            assert(degree != null);
            if (degree) |d| {
                self.tokens.append(
                    .{ .tType = tt, .startI = self.i, .endI = self.i + 1, .degree = d },
                ) catch unreachable;
            }
        }
    }

    /// Determines if this is the start of a token. Returns null if not a match, degree otherwise.
    fn match(self: Self, t: TokenType) ?u8 {
        switch (t) {
            .HEADER => {
                if (!self.isNewline()) return null;
                var i: u8 = 0;
                while (self.peek(i) == '#') i += 1;
                if (i < 1 or i > 6) return null;
                if (self.peek(i) != ' ') return null;
                return i;
            },
            else => unreachable,
        }
    }

    fn isNewline(self: Self) bool {
        return self.i == 0 or self.src[self.i - 1] == '\n';
    }

    fn thisCharIs(self: Self, c: u8) bool {
        return self.src[self.i] == c;
    }

    /// Check ahead without moving the write head.
    fn peek(self: Self, i: usize) u8 {
        if (self.i + i >= self.src.len) return 0;
        return self.src[self.i + i];
    }

    /// Moves the read-head forward until 'char' is found.
    fn consumeUntil(self: *Self, char: u8) void {
        while (self.i < self.src.len and self.src[self.i] != char) {
            self.i += 1;
        }
    }
};

test "header plain" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var l = Lexer.init(arena.allocator());

    try expectEqualDeep(&[_]Token{
        .{ .tType = .HEADER, .contents = "# Header\n", .startI = 0, .endI = 9 },
        .{ .tType = .PLAIN, .contents = "plain text.", .startI = 9, .endI = 20 },
    }, l.lex(
        \\# Header
        \\plain text.
    ));
    try expectEqualDeep(&[_]Token{
        .{ .tType = .HEADER, .contents = "# Header with # in the middle", .startI = 0, .endI = 29 },
    }, l.lex(
        \\# Header with # in the middle
    ));
    try expectEqualDeep(&[_]Token{
        .{ .tType = .PLAIN, .contents = "Plain with # in the middle", .startI = 0, .endI = 26 },
    }, l.lex(
        \\Plain with # in the middle
    ));
    try expectEqualDeep(&[_]Token{
        .{ .tType = .HEADER, .contents = "# A\n", .startI = 0, .endI = 4 },
        .{ .tType = .PLAIN, .contents = "B\n", .startI = 4, .endI = 6 },
        .{ .tType = .HEADER, .contents = "# C", .startI = 6, .endI = 9 },
    }, l.lex(
        \\# A
        \\B
        \\# C
    ));

    var i: usize = 0;
    try expectEqualDeep(&[_]Token{
        .{ .tType = .HEADER, .degree = 1, .contents = "# 1\n", .startI = i, .endI = a: {
            i += 4;
            break :a i;
        } },
        .{ .tType = .HEADER, .degree = 2, .contents = "## 2\n", .startI = i, .endI = b: {
            i += 5;
            break :b i;
        } },
        .{ .tType = .HEADER, .degree = 3, .contents = "### 3\n", .startI = i, .endI = c: {
            i += 6;
            break :c i;
        } },
        .{ .tType = .HEADER, .degree = 4, .contents = "#### 4\n", .startI = i, .endI = d: {
            i += 7;
            break :d i;
        } },
        .{ .tType = .HEADER, .degree = 5, .contents = "##### 5\n", .startI = i, .endI = e: {
            i += 8;
            break :e i;
        } },
        .{ .tType = .HEADER, .degree = 6, .contents = "###### 6\n", .startI = i, .endI = f: {
            i += 9;
            break :f i;
        } },
        .{ .tType = .PLAIN, .degree = 1, .contents = "####### plain", .startI = i, .endI = g: {
            i += 13;
            break :g i;
        } },
    }, l.lex(
        \\# 1
        \\## 2
        \\### 3
        \\#### 4
        \\##### 5
        \\###### 6
        \\####### plain
    ));
}

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const expect = std.expect;
const expectEqualDeep = std.testing.expectEqualDeep;

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
