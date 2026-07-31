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
    next: ?*Token = null,
    /// Next token in the sequence.
    child: ?*Token = null,
    /// First child. Blocks point at their inline sequence; leaf tokens stay null.
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

/// Flat, pointer-free view of a token, in document order. This is what renderers and the JSON
/// FFI consume: `parseMarkdown` builds a tree (blocks holding inline children), but every consumer
/// wants the leaves laid out contiguously. Serializes to the frontend's token schema.
pub const FlatToken = struct {
    tType: TokenType,
    startI: usize,
    endI: usize,
    contents: []const u8 = "",
    degree: u8 = 1,
    renderStart: usize = 0,
    renderEnd: usize = 0,
};

/// Parse `text` and flatten the resulting tree to its leaf tokens in document order. A block with
/// inline children contributes its children (a plain paragraph of `**b**` yields just the BOLD);
/// a leaf block (header, quote, list, block code) contributes itself. The returned slice tiles the
/// document contiguously — the shape the flat renderers and the JSON FFI expect.
///
/// Offsets are **byte** offsets into `text`. That is what a renderer wants: it slices the source
/// directly, so anything else would have to be converted back on every lookup. Consumers that
/// address text by visual position want `parseFlatCodepoints` instead.
pub fn parseFlat(alloc: Allocator, text: []const u8) ![]FlatToken {
    return flattenTree(alloc, try parseMarkdown(alloc, text));
}

/// As `parseFlat`, but every offset is a count of codepoints rather than bytes. For consumers
/// that index text by visual position and have no concept of a byte — the JSON FFI, and any
/// frontend on the other side of it.
pub fn parseFlatCodepoints(alloc: Allocator, text: []const u8) ![]FlatToken {
    const tree = try parseMarkdown(alloc, text);
    try unicodePostprocess(text, tree);
    return flattenTree(alloc, tree);
}

fn flattenTree(alloc: Allocator, tree: ?*Token) ![]FlatToken {
    var list = ArrayList(FlatToken){};
    try flattenLeaves(alloc, &list, tree);
    return list.toOwnedSlice(alloc);
}

fn flattenLeaves(alloc: Allocator, list: *ArrayList(FlatToken), node: ?*Token) !void {
    var curr = node;
    while (curr) |n| {
        if (n.child) |c| {
            try flattenLeaves(alloc, list, c);
        } else {
            try list.append(alloc, .{
                .tType = n.tType,
                .startI = n.startI,
                .endI = n.endI,
                .contents = n.contents,
                .degree = n.degree,
                .renderStart = n.renderStart,
                .renderEnd = n.renderEnd,
            });
        }
        curr = n.next;
    }
}

pub const ConsumeTokenRes = struct {
    t: *Token,
    i: usize,
};
pub const ConsumePartRes = struct {
    p: []const u8,
    i: usize,
};

pub fn parseMarkdown(alloc: Allocator, text: []const u8) !?*Token {
    var i: usize = 0;
    var root: Token = .{ .tType = .PLAIN, .startI = 0, .endI = 0 };
    var curr = &root;
    while (i < text.len) {
        if (try consumeHeader(alloc, text, i)) |res| {
            i = res.i;
            curr.next = res.t;
            curr = res.t;
            continue;
        } else if (try consumeQuote(alloc, text, i)) |res| {
            i = res.i;
            curr.next = res.t;
            curr = res.t;
            continue;
        } else if (try consumeCodeBlock(alloc, text, i)) |res| {
            i = res.i;
            curr.next = res.t;
            curr = res.t;
            continue;
        } else if (try consumeUnorderedList(alloc, text, i)) |res| {
            i = res.i;
            curr.next = res.t;
            curr = res.t;
            continue;
        } else if (try consumePlainBlock(alloc, text, i)) |res| {
            i = res.i;
            curr.next = res.t;
            curr = res.t;
            continue;
        }
        unreachable;
    }
    return root.next;
}

/// Rewrites every token's byte offsets (`startI`/`endI`) and byte-relative render offsets
/// (`renderStart`/`renderEnd`) as codepoint counts. Recurses through `child` and `next`.
///
/// Applied only by `parseFlatCodepoints`. The parser works in bytes throughout, so this is a
/// conversion for consumers that need it rather than something the tree carries by default.
fn unicodePostprocess(text: []const u8, list: ?*Token) !void {
    var maybe = list;
    while (maybe) |t| {
        const byteStart = t.startI;
        const byteEnd = t.endI;
        const renderStartByte = t.renderStart;
        const renderEndByte = t.renderEnd;
        t.startI = try utf8CountCodepoints(text[0..byteStart]);
        t.endI = try utf8CountCodepoints(text[0..byteEnd]);
        t.renderStart = try utf8CountCodepoints(text[byteStart .. byteStart + renderStartByte]);
        t.renderEnd = try utf8CountCodepoints(text[byteStart .. byteStart + renderEndByte]);
        try unicodePostprocess(text, t.child);
        maybe = t.next;
    }
}

const MAX_DEGREE: u8 = 6;

fn consumeHeader(alloc: Allocator, text: []const u8, off: usize) !?ConsumeTokenRes {
    var i = off;
    var degree: u8 = 0;
    while (consumeOne(text, i, '#')) |res| {
        i = res.i;
        degree += 1;
        if (degree > MAX_DEGREE) return null;
    }
    if (degree == 0) return null;

    while (true) {
        if (i >= text.len) break;
        if (text[i] == '\n') {
            i += 1;
            break;
        }
        i += 1;
    }
    const t = try alloc.create(Token);
    t.* = .{
        .tType = .HEADER,
        .startI = off,
        .endI = i,
        .contents = text[off..i],
        .degree = degree,
        .renderStart = degree + 1,
        .renderEnd = i - off,
    };
    return .{ .t = t, .i = i };
}

fn consumeCodeBlock(alloc: Allocator, text: []const u8, off: usize) !?ConsumeTokenRes {
    if (off + 3 > text.len) return null;
    if (!std.mem.eql(u8, text[off .. off + 3], "```")) return null;

    // Find a closing ``` that is followed by a newline or EOF (see the design note at the top:
    // the fence only closes at end-of-line so the frontend can render whole lines as code).
    var j = off + 3;
    while (j + 3 <= text.len) : (j += 1) {
        if (!std.mem.eql(u8, text[j .. j + 3], "```")) continue;
        const after = j + 3;
        if (after == text.len or text[after] == '\n') {
            const t = try alloc.create(Token);
            t.* = .{
                .tType = .BLOCK_CODE,
                .startI = off,
                .endI = after,
                .contents = text[off..after],
                .renderStart = 0,
                .renderEnd = after - off,
            };
            return .{ .t = t, .i = after };
        }
    }
    return null;
}

/// Matches a `- ` list item, optionally indented by tabs. Nesting depth is one per leading tab,
/// so `\t\t- x` is degree 3. The item runs to end of line.
fn consumeUnorderedList(alloc: Allocator, text: []const u8, off: usize) !?ConsumeTokenRes {
    var i = off;
    var degree: u8 = 1;
    while (i < text.len and text[i] == '\t') : (i += 1) {
        degree += 1;
        if (degree > MAX_DEGREE) return null;
    }
    if (i + 1 >= text.len) return null; // need room for "- "
    if (text[i] != '-' or text[i + 1] != ' ') return null;

    const end = endOfLine(text, i);
    const t = try alloc.create(Token);
    t.* = .{
        .tType = .UNORDERED_LIST,
        .startI = off,
        .endI = end,
        .contents = text[off..end],
        .degree = degree,
        .renderStart = degree + 1,
        .renderEnd = end - off,
    };
    return .{ .t = t, .i = end };
}

fn consumeQuote(alloc: Allocator, text: []const u8, off: usize) !?ConsumeTokenRes {
    var i = off;
    var degree: u8 = 0;
    while (consumeOne(text, i, '>')) |res| {
        i = res.i;
        degree += 1;
        if (degree > MAX_DEGREE) return null;
    }
    if (degree == 0) return null;

    while (true) {
        if (i >= text.len) break;
        if (text[i] == '\n') {
            i += 1;
            break;
        }
        i += 1;
    }
    const t = try alloc.create(Token);
    t.* = .{
        .tType = .QUOTE,
        .startI = off,
        .endI = i,
        .contents = text[off..i],
        .degree = degree,
        .renderStart = degree + 1,
        .renderEnd = i - off,
    };
    return .{ .t = t, .i = i };
}

/// A plain block is a maximal run of lines that no "hard" block (header, quote, block code, ...)
/// claims. It spans newlines and holds its formatting as a child inline sequence.
fn consumePlainBlock(alloc: Allocator, text: []const u8, off: usize) !?ConsumeTokenRes {
    // The caller only reaches here once the hard-block consumers have declined the line at `off`,
    // so the first line always belongs to us. Keep swallowing lines until one starts a hard block.
    var i = endOfLine(text, off);
    while (i < text.len and !lineStartsBlock(text, i)) {
        i = endOfLine(text, i);
    }
    const t = try alloc.create(Token);
    t.* = .{
        .tType = .PLAIN,
        .startI = off,
        .endI = i,
        .contents = text[off..i],
        .renderStart = 0,
        .renderEnd = i - off,
        .child = try parseInlines(alloc, text, off, i),
    };
    return .{ .t = t, .i = i };
}

/// Returns the index one past the next '\n' (inclusive of the newline), or text.len at EOF.
fn endOfLine(text: []const u8, off: usize) usize {
    var i = off;
    while (i < text.len and text[i] != '\n') : (i += 1) {}
    if (i < text.len) i += 1;
    return i;
}

/// Peek whether the line at `off` opens a hard block. Mirrors the consumers tried before
/// consumePlainBlock in parseMarkdown, so a plain block stops exactly where a real block starts.
fn lineStartsBlock(text: []const u8, off: usize) bool {
    if (std.mem.startsWith(u8, text[off..], "```")) return true;
    inline for ([_]u8{ '#', '>' }) |marker| {
        var i = off;
        var degree: u8 = 0;
        while (i < text.len and text[i] == marker) : (i += 1) degree += 1;
        if (degree >= 1 and degree <= MAX_DEGREE) return true;
    }
    {
        var i = off;
        var degree: u8 = 1;
        while (i < text.len and text[i] == '\t') : (i += 1) degree += 1;
        if (degree <= MAX_DEGREE and i + 1 < text.len and text[i] == '-' and text[i + 1] == ' ') return true;
    }
    return false;
}

/// The inline (second) phase: walk `text[start..end)`, emitting styled spans as we recognize them
/// and flushing the text between them as PLAIN runs. Returns the head of a `next`-linked sibling
/// list to hang on a block's `.child`.
fn parseInlines(alloc: Allocator, text: []const u8, start: usize, end: usize) !?*Token {
    var head: ?*Token = null;
    var tail: ?*Token = null;
    var i = start;
    var runStart = start; // start of the pending PLAIN run

    while (i < end) {
        // Order matters: *** must be tried before ** (it is a prefix of it).
        const matched: ?ConsumeTokenRes =
            (try consumeDelim(alloc, text, i, end, "***", .EMPHASIS)) orelse
            (try consumeDelim(alloc, text, i, end, "**", .BOLD)) orelse
            (try consumeDelim(alloc, text, i, end, "__", .ITALIC)) orelse
            (try consumeDelim(alloc, text, i, end, "`", .CODE)) orelse
            (try consumeLink(alloc, text, i, end));
        if (matched) |res| {
            try flushPlain(alloc, text, runStart, i, &head, &tail); // the run before this span
            appendInline(&head, &tail, res.t);
            i = res.i;
            runStart = i;
        } else {
            i += 1; // this byte belongs to the current PLAIN run
        }
    }
    try flushPlain(alloc, text, runStart, end, &head, &tail); // trailing run
    return head;
}

/// Matches a span opened and closed by the same delimiter (bold/italic/emphasis/code). The span
/// may not cross a newline — an unclosed opener stays plain text.
fn consumeDelim(
    alloc: Allocator,
    text: []const u8,
    off: usize,
    end: usize,
    delim: []const u8,
    tType: TokenType,
) !?ConsumeTokenRes {
    const dl = delim.len;
    if (off + dl > end) return null;
    if (!std.mem.eql(u8, text[off .. off + dl], delim)) return null;

    var j = off + dl;
    while (j + dl <= end) : (j += 1) {
        if (text[j] == '\n') return null;
        if (std.mem.eql(u8, text[j .. j + dl], delim)) {
            const endI = j + dl;
            const t = try alloc.create(Token);
            t.* = .{
                .tType = tType,
                .startI = off,
                .endI = endI,
                .contents = text[off..endI],
                .renderStart = dl,
                .renderEnd = (endI - off) - dl,
            };
            return .{ .t = t, .i = endI };
        }
    }
    return null;
}

/// Matches `[label](url)` on a single line.
fn consumeLink(alloc: Allocator, text: []const u8, off: usize, end: usize) !?ConsumeTokenRes {
    if (off >= end or text[off] != '[') return null;
    var j = off + 1;
    while (j < end and text[j] != '\n' and text[j] != ']') : (j += 1) {}
    if (j >= end or text[j] != ']') return null;
    const rbracket = j;
    if (rbracket + 1 >= end or text[rbracket + 1] != '(') return null;
    j = rbracket + 2;
    while (j < end and text[j] != '\n' and text[j] != ')') : (j += 1) {}
    if (j >= end or text[j] != ')') return null;
    const endI = j + 1;
    const t = try alloc.create(Token);
    t.* = .{
        .tType = .LINK,
        .startI = off,
        .endI = endI,
        .contents = text[off..endI],
        .renderStart = 1,
        .renderEnd = rbracket - off,
    };
    return .{ .t = t, .i = endI };
}

/// Emit a PLAIN token for `text[from..to)` if non-empty and append it to the inline list.
fn flushPlain(
    alloc: Allocator,
    text: []const u8,
    from: usize,
    to: usize,
    head: *?*Token,
    tail: *?*Token,
) !void {
    if (from >= to) return;
    const t = try alloc.create(Token);
    t.* = .{
        .tType = .PLAIN,
        .startI = from,
        .endI = to,
        .contents = text[from..to],
        .renderStart = 0,
        .renderEnd = to - from,
    };
    appendInline(head, tail, t);
}

/// O(1) append to a head/tail-tracked `next`-linked sibling list.
fn appendInline(head: *?*Token, tail: *?*Token, t: *Token) void {
    if (tail.*) |ta| {
        ta.next = t;
    } else {
        head.* = t;
    }
    tail.* = t;
}

fn consumeOne(text: []const u8, off: usize, c: u8) ?ConsumePartRes {
    const i = off;
    if (i >= text.len or text[i] != c) return null;
    return .{ .p = text[i .. i + 1], .i = i + 1 };
}

fn tokenListToArray(list: ?*Token, arr: []*Token) []*Token {
    var i: usize = 0;
    var maybe_curr = list;
    while (maybe_curr) |curr| {
        arr[i] = curr;
        i += 1;
        maybe_curr = curr.next;
    }
    return arr[0..i];
}

fn showTokenDiffList(expected: []const Token, got: []const Token, diff_i: usize) void {
    std.debug.print("Expected: ", .{});
    if (expected.len > 0) {
        std.debug.print("{s:^15}", .{@tagName(expected[0].tType)});
        if (expected.len > 1) {
            for (expected[1..expected.len]) |token| {
                std.debug.print("->{s:^15}", .{@tagName(token.tType)});
            }
        }
    } else {
        std.debug.print("[no tokens]", .{});
    }
    std.debug.print("\n", .{});

    std.debug.print("Got:      ", .{});
    if (got.len > 0) {
        std.debug.print("{s:^15}", .{@tagName(got[0].tType)});
        if (got.len > 1) {
            for (got[1..got.len]) |token| {
                std.debug.print("->{s:^15}", .{@tagName(token.tType)});
            }
        }
    } else {
        std.debug.print("[no tokens]", .{});
    }
    std.debug.print("\n", .{});

    std.debug.print("          ", .{});
    for (0..diff_i) |_| {
        std.debug.print("                 ", .{});
    }
    std.debug.print("/\\ diff here /\\\n", .{});
}

/// Compares the token linked list produced by `parseMarkdown` against a flat array of expected
/// tokens. The `next` links are ignored so expected literals can leave `next` at its default.
fn expectTokens(expected: []const Token, list: ?*Token) !void {
    var ptr_buf: [64]*Token = undefined;
    const actual = tokenListToArray(list, &ptr_buf);

    var val_buf: [64]Token = undefined;
    for (actual, 0..) |tok, idx| {
        val_buf[idx] = tok.*;
    }
    if (expected.len != actual.len) {
        showTokenDiffList(expected, val_buf[0..actual.len], @min(val_buf.len, actual.len));
        return error.TestExpectedEqual;
    }
    for (val_buf[0..actual.len], 0..) |item, i| {
        const e: ?error{TestExpectedEqual} = b: {
            expectEqual(expected[i].tType, item.tType) catch |e| break :b e;
            expectEqual(expected[i].startI, item.startI) catch |e| break :b e;
            expectEqual(expected[i].endI, item.endI) catch |e| break :b e;
            // expectEqual(expected[i].next, item.next) catch |e| break :b e;
            expectEqualStrings(expected[i].contents, item.contents) catch |e| break :b e;
            expectEqual(expected[i].degree, item.degree) catch |e| break :b e;
            expectEqual(expected[i].renderStart, item.renderStart) catch |e| break :b e;
            expectEqual(expected[i].renderEnd, item.renderEnd) catch |e| break :b e;
            break :b null;
        };
        if (e) |e_res| {
            showTokenDiffList(expected, val_buf[0..actual.len], i);
            std.debug.print("Change: {}\n", .{e_res});
            return e_res;
        }
    }
}

/// Recursive expected-tree literal. Unlike `expectTokens` (which only walks the top-level `next`
/// chain and ignores nesting), this checks `child` too, so nested inline spans can be asserted.
const Expect = struct {
    tType: TokenType,
    contents: []const u8 = "",
    startI: usize = 0,
    endI: usize = 0,
    degree: u8 = 1,
    renderStart: usize = 0,
    renderEnd: usize = 0,
    children: []const Expect = &.{},
};

fn expectNode(e: Expect, tok: *Token) !void {
    try expectEqual(e.tType, tok.tType);
    try expectEqualStrings(e.contents, tok.contents);
    try expectEqual(e.startI, tok.startI);
    try expectEqual(e.endI, tok.endI);
    try expectEqual(e.degree, tok.degree);
    try expectEqual(e.renderStart, tok.renderStart);
    try expectEqual(e.renderEnd, tok.renderEnd);
}

fn expectTree(expected: []const Expect, list: ?*Token) !void {
    var maybe = list;
    for (expected) |e| {
        const tok = maybe orelse {
            std.debug.print("expected {s} but the sibling list ended early\n", .{@tagName(e.tType)});
            return error.TestExpectedEqual;
        };
        expectNode(e, tok) catch |err| {
            std.debug.print(
                "node mismatch: expected {s} \"{s}\" got {s} \"{s}\"\n",
                .{ @tagName(e.tType), e.contents, @tagName(tok.tType), tok.contents },
            );
            return err;
        };
        try expectTree(e.children, tok.child);
        maybe = tok.next;
    }
    if (maybe) |extra| {
        std.debug.print("unexpected extra sibling: {s} \"{s}\"\n", .{ @tagName(extra.tType), extra.contents });
        return error.TestExpectedEqual;
    }
}

test "header plain" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    try expectTokens(&[_]Token{
        .{ .tType = .HEADER, .contents = "# Header\n", .startI = 0, .endI = 9, .renderStart = 2, .renderEnd = 9 },
        .{ .tType = .PLAIN, .contents = "plain text.", .startI = 9, .endI = 20, .renderStart = 0, .renderEnd = 11 },
    }, try parseMarkdown(alloc,
        \\# Header
        \\plain text.
    ));
    try expectTokens(&[_]Token{
        .{
            .tType = .HEADER,
            .contents = "# Header with # in the middle",
            .startI = 0,
            .endI = 29,
            .renderStart = 2,
            .renderEnd = 29,
        },
    }, try parseMarkdown(alloc,
        \\# Header with # in the middle
    ));
    try expectTokens(&[_]Token{
        .{ .tType = .PLAIN, .contents = "Plain with # in the middle", .startI = 0, .endI = 26, .renderStart = 0, .renderEnd = 26 },
    }, try parseMarkdown(alloc,
        \\Plain with # in the middle
    ));
    try expectTokens(&[_]Token{
        .{ .tType = .HEADER, .contents = "# A\n", .startI = 0, .endI = 4, .renderStart = 2, .renderEnd = 4 },
        .{ .tType = .PLAIN, .contents = "B\n", .startI = 4, .endI = 6, .renderStart = 0, .renderEnd = 2 },
        .{ .tType = .HEADER, .contents = "# C", .startI = 6, .endI = 9, .renderStart = 2, .renderEnd = 3 },
    }, try parseMarkdown(alloc,
        \\# A
        \\B
        \\# C
    ));

    var i: usize = 0;
    try expectTokens(&[_]Token{
        .{ .tType = .HEADER, .degree = 1, .contents = "# 1\n", .startI = i, .endI = plusEq(&i, 4), .renderStart = 2, .renderEnd = 4 },
        .{ .tType = .HEADER, .degree = 2, .contents = "## 2\n", .startI = i, .endI = plusEq(&i, 5), .renderStart = 3, .renderEnd = 5 },
        .{ .tType = .HEADER, .degree = 3, .contents = "### 3\n", .startI = i, .endI = plusEq(&i, 6), .renderStart = 4, .renderEnd = 6 },
        .{ .tType = .HEADER, .degree = 4, .contents = "#### 4\n", .startI = i, .endI = plusEq(&i, 7), .renderStart = 5, .renderEnd = 7 },
        .{ .tType = .HEADER, .degree = 5, .contents = "##### 5\n", .startI = i, .endI = plusEq(&i, 8), .renderStart = 6, .renderEnd = 8 },
        .{ .tType = .HEADER, .degree = 6, .contents = "###### 6\n", .startI = i, .endI = plusEq(&i, 9), .renderStart = 7, .renderEnd = 9 },
        .{ .tType = .PLAIN, .degree = 1, .contents = "####### plain", .startI = i, .endI = plusEq(&i, 13), .renderStart = 0, .renderEnd = 13 },
    }, try parseMarkdown(alloc,
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
    const alloc = arena.allocator();

    try expectTokens(&[_]Token{
        .{ .tType = .QUOTE, .contents = "> quote\n", .startI = 0, .endI = 8, .renderStart = 2, .renderEnd = 8 },
        .{ .tType = .PLAIN, .contents = "plain text.", .startI = 8, .endI = 19, .renderStart = 0, .renderEnd = 11 },
    }, try parseMarkdown(alloc,
        \\> quote
        \\plain text.
    ));
    try expectTokens(&[_]Token{
        .{
            .tType = .QUOTE,
            .contents = "> quote with > in the middle",
            .startI = 0,
            .endI = 28,
            .renderStart = 2,
            .renderEnd = 28,
        },
    }, try parseMarkdown(alloc,
        \\> quote with > in the middle
    ));
    try expectTokens(&[_]Token{
        .{ .tType = .PLAIN, .contents = "Plain with > in the middle", .startI = 0, .endI = 26, .renderStart = 0, .renderEnd = 26 },
    }, try parseMarkdown(alloc,
        \\Plain with > in the middle
    ));
    try expectTokens(&[_]Token{
        .{ .tType = .QUOTE, .contents = "> A\n", .startI = 0, .endI = 4, .renderStart = 2, .renderEnd = 4 },
        .{ .tType = .PLAIN, .contents = "B\n", .startI = 4, .endI = 6, .renderStart = 0, .renderEnd = 2 },
        .{ .tType = .QUOTE, .contents = "> C", .startI = 6, .endI = 9, .renderStart = 2, .renderEnd = 3 },
    }, try parseMarkdown(alloc,
        \\> A
        \\B
        \\> C
    ));

    var i: usize = 0;
    try expectTokens(&[_]Token{
        .{ .tType = .QUOTE, .degree = 1, .contents = "> 1\n", .startI = i, .endI = plusEq(&i, 4), .renderStart = 2, .renderEnd = 4 },
        .{ .tType = .QUOTE, .degree = 2, .contents = ">> 2\n", .startI = i, .endI = plusEq(&i, 5), .renderStart = 3, .renderEnd = 5 },
        .{ .tType = .QUOTE, .degree = 3, .contents = ">>> 3\n", .startI = i, .endI = plusEq(&i, 6), .renderStart = 4, .renderEnd = 6 },
        .{ .tType = .QUOTE, .degree = 4, .contents = ">>>> 4\n", .startI = i, .endI = plusEq(&i, 7), .renderStart = 5, .renderEnd = 7 },
        .{ .tType = .QUOTE, .degree = 5, .contents = ">>>>> 5\n", .startI = i, .endI = plusEq(&i, 8), .renderStart = 6, .renderEnd = 8 },
        .{ .tType = .QUOTE, .degree = 6, .contents = ">>>>>> 6\n", .startI = i, .endI = plusEq(&i, 9), .renderStart = 7, .renderEnd = 9 },
        .{ .tType = .PLAIN, .degree = 1, .contents = ">>>>>>> plain", .startI = i, .endI = plusEq(&i, 13), .renderStart = 0, .renderEnd = 13 },
    }, try parseMarkdown(alloc,
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
    const alloc = arena.allocator();

    // The whole string is one plain block; the styled spans hang off its `.child` chain.
    try expectTree(&[_]Expect{
        .{ .tType = .PLAIN, .contents = "a**b**c**d**e", .startI = 0, .endI = 13, .renderStart = 0, .renderEnd = 13, .children = &[_]Expect{
            .{ .tType = .PLAIN, .contents = "a", .startI = 0, .endI = 1, .renderStart = 0, .renderEnd = 1 },
            .{ .tType = .BOLD, .contents = "**b**", .startI = 1, .endI = 6, .renderStart = 2, .renderEnd = 3 },
            .{ .tType = .PLAIN, .contents = "c", .startI = 6, .endI = 7, .renderStart = 0, .renderEnd = 1 },
            .{ .tType = .BOLD, .contents = "**d**", .startI = 7, .endI = 12, .renderStart = 2, .renderEnd = 3 },
            .{ .tType = .PLAIN, .contents = "e", .startI = 12, .endI = 13, .renderStart = 0, .renderEnd = 1 },
        } },
    }, try parseMarkdown(alloc, "a**b**c**d**e"));

    // Unclosed `**`: no styled span, so the block holds a single plain child covering everything.
    try expectTree(&[_]Expect{
        .{ .tType = .PLAIN, .contents = "ab**cd", .startI = 0, .endI = 6, .renderStart = 0, .renderEnd = 6, .children = &[_]Expect{
            .{ .tType = .PLAIN, .contents = "ab**cd", .startI = 0, .endI = 6, .renderStart = 0, .renderEnd = 6 },
        } },
    }, try parseMarkdown(alloc, "ab**cd"));

    // A span may not cross a newline: the first `**` stays plain, and the plain run spans the line
    // break; only `**f**` on the second line is bold.
    try expectTree(&[_]Expect{
        .{ .tType = .PLAIN, .contents = "ab**\ne**f**g\n", .startI = 0, .endI = 13, .renderStart = 0, .renderEnd = 13, .children = &[_]Expect{
            .{ .tType = .PLAIN, .contents = "ab**\ne", .startI = 0, .endI = 6, .renderStart = 0, .renderEnd = 6 },
            .{ .tType = .BOLD, .contents = "**f**", .startI = 6, .endI = 11, .renderStart = 2, .renderEnd = 3 },
            .{ .tType = .PLAIN, .contents = "g\n", .startI = 11, .endI = 13, .renderStart = 0, .renderEnd = 2 },
        } },
    }, try parseMarkdown(alloc, "ab**\ne**f**g\n"));
}

test "italic" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    try expectTree(&[_]Expect{
        .{ .tType = .PLAIN, .contents = "a__b__c__d__e", .startI = 0, .endI = 13, .renderStart = 0, .renderEnd = 13, .children = &[_]Expect{
            .{ .tType = .PLAIN, .contents = "a", .startI = 0, .endI = 1, .renderStart = 0, .renderEnd = 1 },
            .{ .tType = .ITALIC, .contents = "__b__", .startI = 1, .endI = 6, .renderStart = 2, .renderEnd = 3 },
            .{ .tType = .PLAIN, .contents = "c", .startI = 6, .endI = 7, .renderStart = 0, .renderEnd = 1 },
            .{ .tType = .ITALIC, .contents = "__d__", .startI = 7, .endI = 12, .renderStart = 2, .renderEnd = 3 },
            .{ .tType = .PLAIN, .contents = "e", .startI = 12, .endI = 13, .renderStart = 0, .renderEnd = 1 },
        } },
    }, try parseMarkdown(alloc, "a__b__c__d__e"));

    try expectTree(&[_]Expect{
        .{ .tType = .PLAIN, .contents = "ab__cd", .startI = 0, .endI = 6, .renderStart = 0, .renderEnd = 6, .children = &[_]Expect{
            .{ .tType = .PLAIN, .contents = "ab__cd", .startI = 0, .endI = 6, .renderStart = 0, .renderEnd = 6 },
        } },
    }, try parseMarkdown(alloc, "ab__cd"));

    try expectTree(&[_]Expect{
        .{ .tType = .PLAIN, .contents = "ab__\ne__f__g\n", .startI = 0, .endI = 13, .renderStart = 0, .renderEnd = 13, .children = &[_]Expect{
            .{ .tType = .PLAIN, .contents = "ab__\ne", .startI = 0, .endI = 6, .renderStart = 0, .renderEnd = 6 },
            .{ .tType = .ITALIC, .contents = "__f__", .startI = 6, .endI = 11, .renderStart = 2, .renderEnd = 3 },
            .{ .tType = .PLAIN, .contents = "g\n", .startI = 11, .endI = 13, .renderStart = 0, .renderEnd = 2 },
        } },
    }, try parseMarkdown(alloc, "ab__\ne__f__g\n"));
}

test "emphasis" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    try expectTree(&[_]Expect{
        .{ .tType = .PLAIN, .contents = "a***b***c***d***e", .startI = 0, .endI = 17, .renderStart = 0, .renderEnd = 17, .children = &[_]Expect{
            .{ .tType = .PLAIN, .contents = "a", .startI = 0, .endI = 1, .renderStart = 0, .renderEnd = 1 },
            .{ .tType = .EMPHASIS, .contents = "***b***", .startI = 1, .endI = 8, .renderStart = 3, .renderEnd = 4 },
            .{ .tType = .PLAIN, .contents = "c", .startI = 8, .endI = 9, .renderStart = 0, .renderEnd = 1 },
            .{ .tType = .EMPHASIS, .contents = "***d***", .startI = 9, .endI = 16, .renderStart = 3, .renderEnd = 4 },
            .{ .tType = .PLAIN, .contents = "e", .startI = 16, .endI = 17, .renderStart = 0, .renderEnd = 1 },
        } },
    }, try parseMarkdown(alloc, "a***b***c***d***e"));

    try expectTree(&[_]Expect{
        .{ .tType = .PLAIN, .contents = "ab***cd", .startI = 0, .endI = 7, .renderStart = 0, .renderEnd = 7, .children = &[_]Expect{
            .{ .tType = .PLAIN, .contents = "ab***cd", .startI = 0, .endI = 7, .renderStart = 0, .renderEnd = 7 },
        } },
    }, try parseMarkdown(alloc, "ab***cd"));

    try expectTree(&[_]Expect{
        .{ .tType = .PLAIN, .contents = "ab***\ne***f***g\n", .startI = 0, .endI = 16, .renderStart = 0, .renderEnd = 16, .children = &[_]Expect{
            .{ .tType = .PLAIN, .contents = "ab***\ne", .startI = 0, .endI = 7, .renderStart = 0, .renderEnd = 7 },
            .{ .tType = .EMPHASIS, .contents = "***f***", .startI = 7, .endI = 14, .renderStart = 3, .renderEnd = 4 },
            .{ .tType = .PLAIN, .contents = "g\n", .startI = 14, .endI = 16, .renderStart = 0, .renderEnd = 2 },
        } },
    }, try parseMarkdown(alloc, "ab***\ne***f***g\n"));
}

test "inline code" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    try expectTree(&[_]Expect{
        .{ .tType = .PLAIN, .contents = "a`b`c`d`e", .startI = 0, .endI = 9, .renderStart = 0, .renderEnd = 9, .children = &[_]Expect{
            .{ .tType = .PLAIN, .contents = "a", .startI = 0, .endI = 1, .renderStart = 0, .renderEnd = 1 },
            .{ .tType = .CODE, .contents = "`b`", .startI = 1, .endI = 4, .renderStart = 1, .renderEnd = 2 },
            .{ .tType = .PLAIN, .contents = "c", .startI = 4, .endI = 5, .renderStart = 0, .renderEnd = 1 },
            .{ .tType = .CODE, .contents = "`d`", .startI = 5, .endI = 8, .renderStart = 1, .renderEnd = 2 },
            .{ .tType = .PLAIN, .contents = "e", .startI = 8, .endI = 9, .renderStart = 0, .renderEnd = 1 },
        } },
    }, try parseMarkdown(alloc, "a`b`c`d`e"));

    try expectTree(&[_]Expect{
        .{ .tType = .PLAIN, .contents = "ab`cd", .startI = 0, .endI = 5, .renderStart = 0, .renderEnd = 5, .children = &[_]Expect{
            .{ .tType = .PLAIN, .contents = "ab`cd", .startI = 0, .endI = 5, .renderStart = 0, .renderEnd = 5 },
        } },
    }, try parseMarkdown(alloc, "ab`cd"));

    try expectTree(&[_]Expect{
        .{ .tType = .PLAIN, .contents = "ab`\ne`f`g\n", .startI = 0, .endI = 10, .renderStart = 0, .renderEnd = 10, .children = &[_]Expect{
            .{ .tType = .PLAIN, .contents = "ab`\ne", .startI = 0, .endI = 5, .renderStart = 0, .renderEnd = 5 },
            .{ .tType = .CODE, .contents = "`f`", .startI = 5, .endI = 8, .renderStart = 1, .renderEnd = 2 },
            .{ .tType = .PLAIN, .contents = "g\n", .startI = 8, .endI = 10, .renderStart = 0, .renderEnd = 2 },
        } },
    }, try parseMarkdown(alloc, "ab`\ne`f`g\n"));
}

test "block code" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var i: usize = 0;
    try expectTokens(&[_]Token{
        .{
            .tType = .BLOCK_CODE,
            .contents = "```this is code\nsecond line of code\n```",
            .startI = i,
            .endI = plusEq(&i, 39),
            .renderStart = 0,
            .renderEnd = 39,
        },
    }, try parseMarkdown(alloc, "```this is code\nsecond line of code\n```"));

    i = 0;
    try expectTokens(&[_]Token{
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
    }, try parseMarkdown(alloc, "not code\n```\ncode with **no styling**\n```\nnot code again"));
}

test "unordered list" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var i: usize = 0;
    try expectTokens(&[_]Token{
        .{ .tType = .UNORDERED_LIST, .contents = "- uno\n", .startI = i, .endI = plusEq(&i, 6), .renderStart = 2, .renderEnd = 6 },
        .{ .tType = .UNORDERED_LIST, .contents = "- dos", .startI = i, .endI = plusEq(&i, 5), .renderStart = 2, .renderEnd = 5 },
    }, try parseMarkdown(alloc, "- uno\n- dos"));

    i = 0;
    try expectTokens(&[_]Token{
        .{ .tType = .UNORDERED_LIST, .contents = "- 1\n", .startI = i, .endI = plusEq(&i, 4), .degree = 1, .renderStart = 2, .renderEnd = 4 },
        .{ .tType = .UNORDERED_LIST, .contents = "\t- 2\n", .startI = i, .endI = plusEq(&i, 5), .degree = 2, .renderStart = 3, .renderEnd = 5 },
        .{ .tType = .UNORDERED_LIST, .contents = "\t\t- 3\n", .startI = i, .endI = plusEq(&i, 6), .degree = 3, .renderStart = 4, .renderEnd = 6 },
        .{ .tType = .UNORDERED_LIST, .contents = "\t\t\t- 4\n", .startI = i, .endI = plusEq(&i, 7), .degree = 4, .renderStart = 5, .renderEnd = 7 },
        .{ .tType = .UNORDERED_LIST, .contents = "\t\t\t\t- 5\n", .startI = i, .endI = plusEq(&i, 8), .degree = 5, .renderStart = 6, .renderEnd = 8 },
        .{ .tType = .UNORDERED_LIST, .contents = "\t\t\t\t\t- 6", .startI = i, .endI = plusEq(&i, 8), .degree = 6, .renderStart = 7, .renderEnd = 8 },
    }, try parseMarkdown(alloc, "- 1\n\t- 2\n\t\t- 3\n\t\t\t- 4\n\t\t\t\t- 5\n\t\t\t\t\t- 6"));
}

test "link" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    {
        const input = "[label](https://google.com)";
        try expectTree(&[_]Expect{
            .{ .tType = .PLAIN, .contents = input, .startI = 0, .endI = input.len, .renderStart = 0, .renderEnd = input.len, .children = &[_]Expect{
                .{ .tType = .LINK, .contents = input, .startI = 0, .endI = input.len, .renderStart = 1, .renderEnd = 6 },
            } },
        }, try parseMarkdown(alloc, input));
    }
    {
        // No closing `)`: the link opener stays plain text.
        const input = "foo[label](https://google.com";
        try expectTree(&[_]Expect{
            .{ .tType = .PLAIN, .contents = input, .startI = 0, .endI = input.len, .renderStart = 0, .renderEnd = input.len, .children = &[_]Expect{
                .{ .tType = .PLAIN, .contents = input, .startI = 0, .endI = input.len, .renderStart = 0, .renderEnd = input.len },
            } },
        }, try parseMarkdown(alloc, input));
    }
    {
        // A link may not span a newline between `]` and `(`.
        const input = "[label]\n(https://google.com)";
        try expectTree(&[_]Expect{
            .{ .tType = .PLAIN, .contents = input, .startI = 0, .endI = input.len, .renderStart = 0, .renderEnd = input.len, .children = &[_]Expect{
                .{ .tType = .PLAIN, .contents = input, .startI = 0, .endI = input.len, .renderStart = 0, .renderEnd = input.len },
            } },
        }, try parseMarkdown(alloc, input));
    }
}

test "failed reset to last position" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    {
        const input = "[label](https://google.com";
        var i: usize = 0;
        try expectTokens(&[_]Token{
            .{ .tType = .PLAIN, .contents = input, .startI = i, .endI = plusEq(&i, input.len), .renderStart = 0, .renderEnd = input.len },
        }, try parseMarkdown(alloc, input));
    }
    {
        const input = "**unclosed bold";
        var i: usize = 0;
        try expectTokens(&[_]Token{
            .{ .tType = .PLAIN, .contents = input, .startI = i, .endI = plusEq(&i, input.len), .renderStart = 0, .renderEnd = input.len },
        }, try parseMarkdown(alloc, input));
    }
    {
        const input = "__unclosed italic";
        var i: usize = 0;
        try expectTokens(&[_]Token{
            .{ .tType = .PLAIN, .contents = input, .startI = i, .endI = plusEq(&i, input.len), .renderStart = 0, .renderEnd = input.len },
        }, try parseMarkdown(alloc, input));
    }
    {
        const input = "***unclosed emphasis";
        var i: usize = 0;
        try expectTokens(&[_]Token{
            .{ .tType = .PLAIN, .contents = input, .startI = i, .endI = plusEq(&i, input.len), .renderStart = 0, .renderEnd = input.len },
        }, try parseMarkdown(alloc, input));
    }
    {
        const input = "`unclosed code";
        var i: usize = 0;
        try expectTokens(&[_]Token{
            .{ .tType = .PLAIN, .contents = input, .startI = i, .endI = plusEq(&i, input.len), .renderStart = 0, .renderEnd = input.len },
        }, try parseMarkdown(alloc, input));
    }
    {
        const input = "```unclosed block code";
        var i: usize = 0;
        try expectTokens(&[_]Token{
            .{ .tType = .PLAIN, .contents = input, .startI = i, .endI = plusEq(&i, input.len), .renderStart = 0, .renderEnd = input.len },
        }, try parseMarkdown(alloc, input));
    }
}

test "unicode shifts assertion off" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // "é" is 2 bytes (0xC3 0xA9), followed by '\n', so byte index 2 is '\n'.
    // After unicodePostprocess, the HEADER token's startI is codepoint 2,
    // which previously was being used as a byte index into src — landing on '\n'.
    _ = try parseMarkdown(alloc, "é\n# Header");
}

test "unicode handling" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    {
        const input = "**brave❤️**__good🐶__***🔗wax***";
        // `parseMarkdown` reports bytes: **brave (7) + ❤️ (6: 3-byte heart + 3-byte variation
        // selector) + ** (2) = 15; __good (6) + 🐶 (4) + __ (2) = 12; *** (3) + 🔗 (4) + wax*** (6) = 13.
        try expectTree(&[_]Expect{
            .{ .tType = .PLAIN, .contents = input, .startI = 0, .endI = 40, .renderStart = 0, .renderEnd = 40, .children = &[_]Expect{
                .{ .tType = .BOLD, .contents = "**brave❤️**", .startI = 0, .endI = 15, .renderStart = 2, .renderEnd = 13 },
                .{ .tType = .ITALIC, .contents = "__good🐶__", .startI = 15, .endI = 27, .renderStart = 2, .renderEnd = 10 },
                .{ .tType = .EMPHASIS, .contents = "***🔗wax***", .startI = 27, .endI = 40, .renderStart = 3, .renderEnd = 10 },
            } },
        }, try parseMarkdown(alloc, input));
    }
}

test "parseFlatCodepoints reports offsets in codepoints, parseFlat in bytes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const input = "**brave❤️**__good🐶__***🔗wax***";

    // Bytes: what the renderer slices the source with.
    try expectEqualDeep(&[_]FlatToken{
        .{ .tType = .BOLD, .contents = "**brave❤️**", .startI = 0, .endI = 15, .renderStart = 2, .renderEnd = 13 },
        .{ .tType = .ITALIC, .contents = "__good🐶__", .startI = 15, .endI = 27, .renderStart = 2, .renderEnd = 10 },
        .{ .tType = .EMPHASIS, .contents = "***🔗wax***", .startI = 27, .endI = 40, .renderStart = 3, .renderEnd = 10 },
    }, try parseFlat(alloc, input));

    // Codepoints: ❤️ counts as 2 (heart + variation selector), each emoji as 1.
    try expectEqualDeep(&[_]FlatToken{
        .{ .tType = .BOLD, .contents = "**brave❤️**", .startI = 0, .endI = 11, .renderStart = 2, .renderEnd = 9 },
        .{ .tType = .ITALIC, .contents = "__good🐶__", .startI = 11, .endI = 20, .renderStart = 2, .renderEnd = 7 },
        .{ .tType = .EMPHASIS, .contents = "***🔗wax***", .startI = 20, .endI = 30, .renderStart = 3, .renderEnd = 7 },
    }, try parseFlatCodepoints(alloc, input));
}

test "renderStart and renderEnd" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Plain text: renderStart=0, renderEnd=length (everything visible)
    {
        try expectTokens(&[_]Token{
            .{ .tType = .PLAIN, .contents = "hello world", .startI = 0, .endI = 11, .renderStart = 0, .renderEnd = 11 },
        }, try parseMarkdown(alloc, "hello world"));
    }

    // Headers: hide `## ` prefix
    {
        var i: usize = 0;
        try expectTokens(&[_]Token{
            .{ .tType = .HEADER, .degree = 1, .contents = "# Title\n", .startI = i, .endI = plusEq(&i, 8), .renderStart = 2, .renderEnd = 8 },
            .{ .tType = .HEADER, .degree = 2, .contents = "## Subtitle", .startI = i, .endI = plusEq(&i, 11), .renderStart = 3, .renderEnd = 11 },
        }, try parseMarkdown(alloc, "# Title\n## Subtitle"));
    }

    // Bold: hide `**` on each side
    {
        try expectTree(&[_]Expect{
            .{ .tType = .PLAIN, .contents = "a**bold**b", .startI = 0, .endI = 10, .renderStart = 0, .renderEnd = 10, .children = &[_]Expect{
                .{ .tType = .PLAIN, .contents = "a", .startI = 0, .endI = 1, .renderStart = 0, .renderEnd = 1 },
                .{ .tType = .BOLD, .contents = "**bold**", .startI = 1, .endI = 9, .renderStart = 2, .renderEnd = 6 },
                .{ .tType = .PLAIN, .contents = "b", .startI = 9, .endI = 10, .renderStart = 0, .renderEnd = 1 },
            } },
        }, try parseMarkdown(alloc, "a**bold**b"));
    }

    // Italic: hide `__` on each side
    {
        try expectTree(&[_]Expect{
            .{ .tType = .PLAIN, .contents = "a__italic__b", .startI = 0, .endI = 12, .renderStart = 0, .renderEnd = 12, .children = &[_]Expect{
                .{ .tType = .PLAIN, .contents = "a", .startI = 0, .endI = 1, .renderStart = 0, .renderEnd = 1 },
                .{ .tType = .ITALIC, .contents = "__italic__", .startI = 1, .endI = 11, .renderStart = 2, .renderEnd = 8 },
                .{ .tType = .PLAIN, .contents = "b", .startI = 11, .endI = 12, .renderStart = 0, .renderEnd = 1 },
            } },
        }, try parseMarkdown(alloc, "a__italic__b"));
    }

    // Emphasis: hide `***` on each side
    {
        try expectTree(&[_]Expect{
            .{ .tType = .PLAIN, .contents = "***wow***", .startI = 0, .endI = 9, .renderStart = 0, .renderEnd = 9, .children = &[_]Expect{
                .{ .tType = .EMPHASIS, .contents = "***wow***", .startI = 0, .endI = 9, .renderStart = 3, .renderEnd = 6 },
            } },
        }, try parseMarkdown(alloc, "***wow***"));
    }

    // Inline code: hide ` on each side
    {
        try expectTree(&[_]Expect{
            .{ .tType = .PLAIN, .contents = "a`code`b", .startI = 0, .endI = 8, .renderStart = 0, .renderEnd = 8, .children = &[_]Expect{
                .{ .tType = .PLAIN, .contents = "a", .startI = 0, .endI = 1, .renderStart = 0, .renderEnd = 1 },
                .{ .tType = .CODE, .contents = "`code`", .startI = 1, .endI = 7, .renderStart = 1, .renderEnd = 5 },
                .{ .tType = .PLAIN, .contents = "b", .startI = 7, .endI = 8, .renderStart = 0, .renderEnd = 1 },
            } },
        }, try parseMarkdown(alloc, "a`code`b"));
    }

    // Quote: hide `> ` prefix
    {
        try expectTokens(&[_]Token{
            .{ .tType = .QUOTE, .contents = "> quoted text", .startI = 0, .endI = 13, .renderStart = 2, .renderEnd = 13 },
        }, try parseMarkdown(alloc, "> quoted text"));
    }

    // Multi-level quote: hide `>>> ` prefix
    {
        try expectTokens(&[_]Token{
            .{ .tType = .QUOTE, .degree = 3, .contents = ">>> deep quote", .startI = 0, .endI = 14, .renderStart = 4, .renderEnd = 14 },
        }, try parseMarkdown(alloc, ">>> deep quote"));
    }

    // Unordered list: hide `- ` prefix
    {
        var i: usize = 0;
        try expectTokens(&[_]Token{
            .{ .tType = .UNORDERED_LIST, .contents = "- item one\n", .startI = i, .endI = plusEq(&i, 11), .renderStart = 2, .renderEnd = 11 },
            .{ .tType = .UNORDERED_LIST, .contents = "- item two", .startI = i, .endI = plusEq(&i, 10), .renderStart = 2, .renderEnd = 10 },
        }, try parseMarkdown(alloc, "- item one\n- item two"));
    }

    // Indented unordered list: hide `\t- ` prefix
    {
        var i: usize = 0;
        try expectTokens(&[_]Token{
            .{ .tType = .UNORDERED_LIST, .degree = 1, .contents = "- top\n", .startI = i, .endI = plusEq(&i, 6), .renderStart = 2, .renderEnd = 6 },
            .{ .tType = .UNORDERED_LIST, .degree = 2, .contents = "\t- nested", .startI = i, .endI = plusEq(&i, 9), .renderStart = 3, .renderEnd = 9 },
        }, try parseMarkdown(alloc, "- top\n\t- nested"));
    }

    // Link: hide `[` and `](url)`
    {
        const input = "[click here](https://example.com)";
        try expectTree(&[_]Expect{
            .{ .tType = .PLAIN, .contents = input, .startI = 0, .endI = input.len, .renderStart = 0, .renderEnd = input.len, .children = &[_]Expect{
                .{ .tType = .LINK, .contents = input, .startI = 0, .endI = input.len, .renderStart = 1, .renderEnd = 11 },
            } },
        }, try parseMarkdown(alloc, input));
    }

    // Block code: renderStart=0, renderEnd=length (no hiding for now)
    {
        const input = "```\nsome code\n```";
        try expectTokens(&[_]Token{
            .{ .tType = .BLOCK_CODE, .contents = input, .startI = 0, .endI = input.len, .renderStart = 0, .renderEnd = input.len },
        }, try parseMarkdown(alloc, input));
    }
}

test "parseFlat yields document-order leaves" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // A pure-plain paragraph collapses to its single leaf (no container wrapper).
    try expectEqualDeep(&[_]FlatToken{
        .{ .tType = .PLAIN, .contents = "foo", .startI = 0, .endI = 3, .renderStart = 0, .renderEnd = 3 },
    }, try parseFlat(alloc, "foo"));

    // A paragraph that is entirely one styled span yields just that span.
    try expectEqualDeep(&[_]FlatToken{
        .{ .tType = .BOLD, .contents = "**foo**", .startI = 0, .endI = 7, .renderStart = 2, .renderEnd = 5 },
    }, try parseFlat(alloc, "**foo**"));

    // Mixed inline runs flatten to contiguous leaves.
    try expectEqualDeep(&[_]FlatToken{
        .{ .tType = .PLAIN, .contents = "a", .startI = 0, .endI = 1, .renderStart = 0, .renderEnd = 1 },
        .{ .tType = .BOLD, .contents = "**b**", .startI = 1, .endI = 6, .renderStart = 2, .renderEnd = 3 },
    }, try parseFlat(alloc, "a**b**"));
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
const builtin = @import("builtin");
const expect = std.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualDeep = std.testing.expectEqualDeep;
const expectEqualStrings = std.testing.expectEqualStrings;
const expectEqualSlices = std.testing.expectEqualSlices;
const utf8CountCodepoints = std.unicode.utf8CountCodepoints;

const tracy = if (builtin.is_test)
stub: {
    break :stub struct {
        pub const StubZone = struct {
            pub fn end(self: StubZone) void {
                _ = self;
                return;
            }
        };
        pub const StubArgs = struct {
            name: []const u8,
        };
        pub fn beginZone(file: std.builtin.SourceLocation, args: StubArgs) StubZone {
            _ = file;
            _ = args;
            return StubZone{};
        }
    };
} else t: {
    break :t @import("tracy");
};
