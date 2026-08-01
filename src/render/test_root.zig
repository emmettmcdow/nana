//! Aggregator for the pure-logic render tests (`zig build test-render`).
//! Only modules with zero platform dependencies belong here. The Core Text /
//! Core Graphics paths in canvas.zig are exercised by the (future) offscreen
//! snapshot harness, not by these headless unit tests.

comptime {
    _ = @import("utf.zig");
    _ = @import("geom.zig");
    _ = @import("app.zig");
    _ = @import("ted.zig");
    _ = @import("overlay.zig");
    _ = @import("markdown.zig");
    _ = @import("theme.zig");
    _ = @import("ui.zig");
}
