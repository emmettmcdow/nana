//! Integration tests for the editor, driven through `testing.Harness`.
//!
//! Every test here loads a document, feeds real input, and asserts on what the render pass drew.
//! Nothing reaches inside `ted.zig` — no `Line`, no `Fragment`, no `Measurer`. That is the point:
//! these should survive the layout being rewritten underneath them, and only fail when what the
//! user would see actually changes.
//!
//! The example-based tests still in `ted.zig` are the ones about pure helpers, plus the ones not
//! yet migrated.

const std = @import("std");
const testing = @import("testing.zig");
const Harness = testing.Harness;
const alloc = std.testing.allocator;
const mod_shift = @import("input.zig").mod_shift;

// ****************************************************************************** Wrapping / layout
test "a run wider than the content column soft-wraps" {
    // 4 cells of content width holds 3 characters — the fit test is strict, so a row exactly
    // filling the column does not fit. See `Harness.Options.cols`.
    var h = try Harness.init(alloc, .{ .cols = 4, .rows = 4 });
    defer h.deinit();

    try h.open("abcdef");
    try h.idle();
    try h.expectGrid(
        \\abc
        \\def
    );
}

test "one long line wraps across as many rows as it takes" {
    var h = try Harness.init(alloc, .{ .cols = 4, .rows = 6 });
    defer h.deinit();

    try h.open("abcdefgh");
    try h.idle();
    try h.expectGrid(
        \\abc
        \\def
        \\gh
    );
}

test "a hard newline breaks a row even when there is room left" {
    var h = try Harness.init(alloc, .{ .cols = 20, .rows = 4 });
    defer h.deinit();

    try h.open("ab\ncd");
    try h.idle();
    try h.expectGrid(
        \\ab
        \\cd
    );
}

// ********************************************************************************** Concealment
test "markdown delimiters are concealed off the caret's line and shown on it" {
    var h = try Harness.init(alloc, .{ .cols = 20, .rows = 6 });
    defer h.deinit();

    // The caret opens at the start, so line 1 keeps its markup and the rest lose theirs.
    try h.open("a**b**c\n# H\nx`y`z");
    try h.idle();
    try h.expectGrid(
        \\a**b**c
        \\H
        \\xyz
    );

    // Walk the caret onto the header. Its delimiters come back, and line 1's go.
    try h.frame(.{ .downs = 1 });
    try h.expectGrid(
        \\abc
        \\# H
        \\xyz
    );
}

test "a link shows its label and hides its target" {
    var h = try Harness.init(alloc, .{ .cols = 30, .rows = 4 });
    defer h.deinit();

    try h.open("x\nsee [label](https://example.com) here");
    try h.idle();
    try h.expectGrid(
        \\x
        \\see label here
    );
}

test "concealing markup lets more text fit on a row" {
    var h = try Harness.init(alloc, .{ .cols = 9, .rows = 8 });
    defer h.deinit();

    // Ten bold letters: 10 drawn characters, 50 bytes of source. Concealed, 8 fit on the first
    // row; revealed, the same budget holds 8 bytes of source and the line needs many more rows.
    try h.open("z\n**a****b****c****d****e****f****g****h****i****j**");
    try h.idle();
    try h.expectGrid(
        \\z
        \\abcdefgh
        \\ij
    );
}

// ***************************************************************************** Quotes and lists
test "a quote is indented and stands a rule in the gutter it vacated" {
    var h = try Harness.init(alloc, .{ .cols = 20, .rows = 6 });
    defer h.deinit();

    try h.open("plain\n> one\n>> two\nplain again");
    try h.idle();
    try h.expectGrid(
        \\plain
        \\  one
        \\    two
        \\plain again
    );
    // One rule per nesting level, each standing where the text used to start. Row 0 carries the
    // caret, which opens at the start of the document.
    try h.expectAttrs(
        \\I
        \\|
        \\|.|
    );
}

test "a wrapped list item hangs under its own text" {
    var h = try Harness.init(alloc, .{ .cols = 12, .rows = 6 });
    defer h.deinit();

    // The caret is on the item, so the marker is shown: the first row sits flush and the
    // continuations hang under where the text began.
    try h.open("- aaaaaaaaaaaaaaaaaa");
    try h.idle();
    try h.expectGrid(
        \\- aaaaaaaaa
        \\  aaaaaaaaa
    );
}

// ************************************************************************** Caret and selection
test "typing puts the caret after what was typed" {
    var h = try Harness.init(alloc, .{ .cols = 12, .rows = 4 });
    defer h.deinit();

    try h.open("");
    try h.typeText("hi");
    try h.expectGrid("hi");
    try h.expectAttrs(
        \\..I
    );
}

test "shift+right extends a selection and the caret leads it" {
    var h = try Harness.init(alloc, .{ .cols = 12, .rows = 4 });
    defer h.deinit();

    try h.open("abcdef");
    try h.frame(.{ .rights = 1, .modifiers = mod_shift });
    try h.frame(.{ .rights = 1, .modifiers = mod_shift });
    try h.expectGrid("abcdef");
    // Two cells selected, caret at the leading edge.
    try h.expectAttrs(
        \\##I
    );
}

test "a click places the caret at the cell that was clicked" {
    var h = try Harness.init(alloc, .{ .cols = 12, .rows = 4 });
    defer h.deinit();

    try h.open("ab\ncd");
    try h.clickCell(1, 1); // between 'c' and 'd'
    try h.expectGrid(
        \\ab
        \\cd
    );
    try h.expectAttrs(
        \\............
        \\.I
    );
}

// ***************************************************************************** Code and panels
test "a fenced block paints a panel across the column, blank rows included" {
    var h = try Harness.init(alloc, .{ .cols = 8, .rows = 8 });
    defer h.deinit();

    // The blank line between "a" and "b" is inside the fence. It draws no text, so the panel on
    // that row can only come from the block that owns it — a hole here is the bug.
    try h.open("z\n```\na\n\nb\n```");
    try h.idle();
    try h.expectAttrs(
        \\I
        \\cccccccc
        \\cccccccc
        \\cccccccc
        \\cccccccc
        \\cccccccc
    );
}

test "a trailing newline leaves a blank row the caret can reach" {
    var h = try Harness.init(alloc, .{ .cols = 12, .rows = 4 });
    defer h.deinit();

    try h.open("ab\n");
    try h.frame(.{ .rights = 3 }); // past 'a', 'b', and the newline
    try h.expectGrid("ab");
    // The blank row is a row: the caret sits on it rather than at the end of "ab".
    try h.expectAttrs(
        \\
        \\I
    );
}

test "wrap offsets stay in step across a hard break" {
    var h = try Harness.init(alloc, .{ .cols = 4, .rows = 6 });
    defer h.deinit();

    // The first logical line wraps, then a newline ends it. A row that mistook the '\n' for
    // content would push everything after it one column right.
    try h.open("abcd\nef");
    try h.idle();
    try h.expectGrid(
        \\abc
        \\d
        \\ef
    );
}

test "a soft-wrapped quote keeps its indent on every continuation row" {
    var h = try Harness.init(alloc, .{ .cols = 12, .rows = 6 });
    defer h.deinit();

    try h.open("x\n> aaaaaaaaaaaaaaaaaa");
    try h.idle();
    try h.expectGrid(
        \\x
        \\  aaaaaaaaa
        \\  aaaaaaaaa
    );
    // The rule stands on every row of the quote, not just its first.
    try h.expectAttrs(
        \\I
        \\|
        \\|
    );
}

test "a nested list keeps its content column whether or not the marker is shown" {
    var h = try Harness.init(alloc, .{ .cols = 16, .rows = 5 });
    defer h.deinit();

    // Concealing a list marker also conceals the tabs that were doing the indenting, so the
    // indent has to be supplied instead. Content must land in the same column either way — a
    // reftest, so neither rendering has to state a magic column number.
    try h.open("\t\t- three\nx");
    try h.frame(.{ .rights = 1 }); // caret on the item: marker shown
    try h.expectGrid("\t\t- three\nx");

    try h.frame(.{ .downs = 1 }); // caret off it: marker concealed, indent supplied
    try h.expectGrid("    three\nx");
}

test "a wrapped nested item hangs under its own marker" {
    var h = try Harness.init(alloc, .{ .cols = 14, .rows = 6 });
    defer h.deinit();

    // Marker is "\t\t- ", four cells. Continuations hang under where the text began.
    try h.open("\t\t- aaaaaaaaaaaaaaaaaaaa");
    try h.idle();
    try h.expectGrid("\t\t- aaaaaaaaa\n    aaaaaaaaa\n    aa");
}

test "each token is drawn in its own font" {
    var h = try Harness.init(alloc, .{ .cols = 16, .rows = 4 });
    defer h.deinit();

    // Off the caret's line the delimiters go, but the styling they described stays.
    try h.open("x\nfoo**bar**baz");
    try h.idle();
    try h.expectGrid(
        \\x
        \\foobarbaz
    );
    try h.expectStyles(
        \\p
        \\pppbbbppp
    );
}

test "a header scales its font and hides its hashes" {
    var h = try Harness.init(alloc, .{ .cols = 16, .rows = 4 });
    defer h.deinit();

    try h.open("x\n## Head");
    try h.idle();
    try h.expectGrid(
        \\x
        \\Head
    );
    try h.expectStyles(
        \\p
        \\hhhh
    );
}

test "selection width follows what is drawn, not what is stored" {
    var h = try Harness.init(alloc, .{ .cols = 16, .rows = 4 });
    defer h.deinit();

    // Line 1 conceals its asterisks, so it draws "abc". The selection over it must be measured
    // against those three columns and not against the seven bytes of source.
    //
    // It has to be a *middle* line: the caret reveals whatever line it sits on, so a selection
    // ending on the concealed line would un-conceal the very thing under test.
    try h.open("xy\na**b**c\nz");
    try h.frame(.{ .downs = 1, .modifiers = mod_shift });
    try h.frame(.{ .downs = 1, .modifiers = mod_shift });
    try h.expectGrid(
        \\xy
        \\abc
        \\z
    );
    try h.expectAttrs(
        \\##
        \\###
        \\I
    );
}

// ***************************************************************************** Mouse selection
test "a drag selects from where it began to where it ended" {
    var h = try Harness.init(alloc, .{ .cols = 12, .rows = 4 });
    defer h.deinit();

    try h.open("abcde");
    try h.pressCell(1, 0);
    try h.dragCell(4, 0);
    try h.releaseCell(4, 0);
    try h.expectAttrs(
        \\.###I
    );
}

test "the caret tracks the pointer while held and the anchor stays put" {
    var h = try Harness.init(alloc, .{ .cols = 12, .rows = 4 });
    defer h.deinit();

    try h.open("abcde");
    try h.pressCell(3, 0);
    try h.dragCell(5, 0);
    try h.expectAttrs(
        \\...##I
    );

    // Dragging back past the anchor flips the selection to its left; the anchor does not move,
    // so what is selected is now [0,3) and the caret leads it from the other end.
    try h.dragCell(0, 0);
    try h.expectAttrs(
        \\I##
    );
}

test "a fresh click discards the selection a drag left behind" {
    var h = try Harness.init(alloc, .{ .cols = 12, .rows = 4 });
    defer h.deinit();

    try h.open("abcde");
    try h.pressCell(1, 0);
    try h.dragCell(4, 0);
    try h.releaseCell(4, 0);

    try h.clickCell(0, 0);
    try h.expectAttrs(
        \\I
    );
}

test "clicks outside the text clamp to the nearest row and column" {
    var h = try Harness.init(alloc, .{ .cols = 12, .rows = 4 });
    defer h.deinit();

    try h.open("ab\ncd");

    // Below and right of everything: the end of the last row.
    try h.clickPoint(.{ .x = 10_000, .y = 10_000 });
    try h.expectAttrs(
        \\
        \\..I
    );

    // Above and left of everything: the start of the first row.
    try h.clickPoint(.{ .x = -10_000, .y = -10_000 });
    try h.expectAttrs(
        \\I
    );
}
