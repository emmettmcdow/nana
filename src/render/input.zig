//! Per-frame input snapshot handed to `app.frame`. Immediate-mode: this is the
//! complete input state for the current frame, rebuilt each tick by the host.

const geom = @import("geom.zig");

/// Modifier-key bitmask values. Must match the bits the Swift host packs into
/// `NanaInput.modifiers`.
pub const mod_shift: u32 = 1 << 0;
pub const mod_control: u32 = 1 << 1;
pub const mod_option: u32 = 1 << 2;
pub const mod_command: u32 = 1 << 3;

pub const Input = struct {
    /// Cursor position in top-left-origin canvas points.
    mouse: geom.Point = .{ .x = 0, .y = 0 },
    /// Whether the primary mouse button is currently held.
    mouse_down: bool = false,
    /// Active modifier keys (see `mod_*` masks above).
    modifiers: u32 = 0,
    /// UTF-8 text entered during this frame (empty if none). Borrowed; valid only
    /// for the duration of the frame call.
    text: []const u8 = &.{},
    /// Scroll wheel / trackpad movement this frame, in points. Positive means the content
    /// should move down the screen, i.e. toward the top of the document — matching AppKit's
    /// `scrollingDeltaY`.
    scroll_dy: f64 = 0,
    /// Number of {backspace,up,down,left,right} key presses during this frame.
    backspaces: u32 = 0,
    /// Escape presses. Dismisses whatever is open rather than entering anything.
    escapes: u32 = 0,
    ups: u32 = 0,
    downs: u32 = 0,
    lefts: u32 = 0,
    rights: u32 = 0,

    pub fn has(self: Input, mask: u32) bool {
        return (self.modifiers & mask) != 0;
    }
};
