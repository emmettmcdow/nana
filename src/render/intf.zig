//! C ABI for the render scaffold. These `export fn`s are compiled into libnana.a
//! (referenced from src/intf.zig) and called by the Swift `NanaCanvasView`.
//!
//! The boundary is deliberately tiny: init once, frame() each display refresh with a
//! CGContext + size + input snapshot, deinit on teardown. All UTF-16 <-> UTF-8 index
//! conversion (when text editing arrives) belongs in render/utf.zig, not here.

const canvas_mod = @import("canvas.zig");
const input_mod = @import("input.zig");
const app = @import("app.zig");
const std = @import("std");

const AppState = app.AppState;
const CGContextRef = canvas_mod.CGContextRef;

/// Mirror of the C `NanaInput` struct declared in include/nana.h. Field order and
/// types must match exactly (C ABI layout).
const NanaInput = extern struct {
    mouse_x: f64,
    mouse_y: f64,
    mouse_down: bool,
    modifiers: c_uint,
    text_utf8: [64]u8,
    text_len: c_uint,
    backspaces: c_uint,
    ups: c_uint,
    downs: c_uint,
    lefts: c_uint,
    rights: c_uint,
};

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const GAP_BUF_SIZE = 4000; // 4Kb
var state: ?AppState = null;

export fn nana_render_init() void {
    state = AppState.init(gpa.allocator().alloc(u8, GAP_BUF_SIZE) catch unreachable);
    const text: []const u8 =
        \\# Header 1
        \\Here is some __italicized text__.
        \\## Header 2
        \\Here is some **bold text**.
        \\### Header 3
        \\Here is some ***emphasized text***.
        \\Here is a [link](https://google.com).
        \\#### Header 4
        \\Here is a `code snippet`.
        \\
        \\- list item #1
        \\- list item #2
        \\- list item #3
        \\
        \\1. ordered
        \\2. ordered
        \\3. ordered
        \\
        \\##### Header 5
        \\The following is a quote:
        \\> you miss every shot you don't take.
        \\> - michael scott
        \\###### Header 6
        \\Here is a code block:
        \\```bash
        \\$ curl ifconfig.me
        \\2601:645:8400:2fb0:5832:3f5a:ba00:29b
        \\```
    ;
    @memcpy(state.?.gap_buf[0..text.len], text);
    // Cursor starts at the end of the seeded text, so the tail is empty: leave
    // `gap_end` at `gap_buf.len` (set by AppState.init). Setting it to `text.len`
    // would collapse the gap and treat the rest of the buffer as document tail.
    state.?.cursor_i = text.len;
    state.?.text_len = text.len;
}

export fn nana_render_deinit() void {}

export fn nana_render_frame(ctx: CGContextRef, width: f64, height: f64, in: *const NanaInput) void {
    var canvas = canvas_mod.Canvas{
        .ctx = ctx,
        .size = .{ .w = width, .h = height },
    };

    const max_len: usize = in.text_utf8.len;
    const text_len: usize = @min(@as(usize, in.text_len), max_len);

    const input = input_mod.Input{
        .mouse = .{ .x = @max(in.mouse_x, 0), .y = @max(in.mouse_y, 0) },
        .mouse_down = in.mouse_down,
        .modifiers = @intCast(in.modifiers),
        .text = in.text_utf8[0..text_len],
        .backspaces = @intCast(in.backspaces),
        .ups = @intCast(in.ups),
        .downs = @intCast(in.downs),
        .lefts = @intCast(in.lefts),
        .rights = @intCast(in.rights),
    };

    app.frame(gpa.allocator(), &canvas, input, &(state.?)) catch unreachable;
}
