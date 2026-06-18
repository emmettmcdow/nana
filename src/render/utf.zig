//! UTF-8 <-> UTF-16 offset conversion.
//!
//! macOS text APIs (NSRange, NSTextInputClient, Core Text indices) speak UTF-16
//! code units, while the Zig core stores text as UTF-8. This module is the single
//! place that bridges the two indexing schemes. Kept pure so it is fully testable.

const std = @import("std");

pub const Error = error{
    /// The requested UTF-16 offset falls in the middle of a surrogate pair (i.e.
    /// inside a single astral codepoint), so there is no valid UTF-8 boundary.
    SplitCodepoint,
    /// The requested UTF-16 offset is past the end of the text.
    OutOfBounds,
};

/// Number of UTF-16 code units needed to encode `utf8`.
/// (Codepoints above U+FFFF take two units; everything else takes one.)
pub fn utf16Len(utf8: []const u8) !usize {
    const view = try std.unicode.Utf8View.init(utf8);
    var it = view.iterator();
    var n: usize = 0;
    while (it.nextCodepoint()) |cp| {
        n += if (cp > 0xFFFF) 2 else 1;
    }
    return n;
}

/// Convert a UTF-8 byte offset (must be a codepoint boundary) to a UTF-16 offset.
pub fn utf8OffsetToUtf16(utf8: []const u8, byte_off: usize) !usize {
    std.debug.assert(byte_off <= utf8.len);
    return utf16Len(utf8[0..byte_off]);
}

/// Convert a UTF-16 code-unit offset to the corresponding UTF-8 byte offset.
pub fn utf16OffsetToUtf8(utf8: []const u8, u16_off: usize) !usize {
    const view = try std.unicode.Utf8View.init(utf8);
    var it = view.iterator();
    var seen: usize = 0;
    while (seen < u16_off) {
        const slice = it.nextCodepointSlice() orelse return Error.OutOfBounds;
        const cp = try std.unicode.utf8Decode(slice);
        const units: usize = if (cp > 0xFFFF) 2 else 1;
        if (seen + units > u16_off) return Error.SplitCodepoint;
        seen += units;
    }
    return it.i;
}

const expectEqual = std.testing.expectEqual;
const expectError = std.testing.expectError;

test "utf16Len ascii" {
    try expectEqual(@as(usize, 5), try utf16Len("hello"));
    try expectEqual(@as(usize, 0), try utf16Len(""));
}

test "utf16Len BMP (single unit each)" {
    // "café" + a CJK char: all <= U+FFFF -> 1 unit apiece.
    try expectEqual(@as(usize, 4), try utf16Len("café"));
    try expectEqual(@as(usize, 1), try utf16Len("中"));
}

test "utf16Len astral (two units each)" {
    // U+1F600 GRINNING FACE -> surrogate pair -> 2 units.
    try expectEqual(@as(usize, 2), try utf16Len("😀"));
    try expectEqual(@as(usize, 3), try utf16Len("a😀")); // 1 + 2
}

test "utf16Len combining marks count per codepoint" {
    // 'e' + U+0301 COMBINING ACUTE ACCENT = 2 codepoints, 2 UTF-16 units.
    try expectEqual(@as(usize, 2), try utf16Len("e\u{0301}"));
}

test "utf8OffsetToUtf16 round trips through an emoji" {
    const s = "a😀b"; // bytes: 1 + 4 + 1 = 6; utf16: 1 + 2 + 1 = 4
    try expectEqual(@as(usize, 0), try utf8OffsetToUtf16(s, 0));
    try expectEqual(@as(usize, 1), try utf8OffsetToUtf16(s, 1)); // after 'a'
    try expectEqual(@as(usize, 3), try utf8OffsetToUtf16(s, 5)); // after emoji
    try expectEqual(@as(usize, 4), try utf8OffsetToUtf16(s, 6)); // after 'b'
}

test "utf16OffsetToUtf8 maps back to byte offsets" {
    const s = "a😀b";
    try expectEqual(@as(usize, 0), try utf16OffsetToUtf8(s, 0));
    try expectEqual(@as(usize, 1), try utf16OffsetToUtf8(s, 1));
    try expectEqual(@as(usize, 5), try utf16OffsetToUtf8(s, 3)); // after the 2-unit emoji
    try expectEqual(@as(usize, 6), try utf16OffsetToUtf8(s, 4));
}

test "utf16OffsetToUtf8 rejects splitting a surrogate pair" {
    const s = "a😀b";
    try expectError(Error.SplitCodepoint, utf16OffsetToUtf8(s, 2)); // mid-emoji
}

test "utf16OffsetToUtf8 out of bounds" {
    try expectError(Error.OutOfBounds, utf16OffsetToUtf8("hi", 3));
}
