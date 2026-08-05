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
