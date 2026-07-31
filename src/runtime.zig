//! Process-wide ownership of the nana `Runtime`.
//!
//! The runtime holds a vector DB and an embedder over one workspace directory, so there must be
//! exactly one of it. Two consumers need it — `intf.zig`'s C ABI (for anything still calling in
//! from outside) and `session.zig` (the editor's own note handling) — and neither can own it
//! without the other importing it and forming a cycle. It lives here instead, and both import
//! this module.

var rt: nana.Runtime = undefined;
var initialized: bool = false;

pub var gpa = std.heap.GeneralPurposeAllocator(.{}){};

/// Guards the runtime against concurrent use. The C ABI is callable from any thread, and the
/// render loop touches the same runtime from the main thread.
pub var mutex = std.Thread.Mutex{};

/// The live runtime, or null before `open` and after `close`. Callers already holding `mutex`
/// use this to avoid the double-lock that calling through the C ABI would cause.
pub fn get() ?*nana.Runtime {
    return if (initialized) &rt else null;
}

pub fn isOpen() bool {
    return initialized;
}

/// Open `dir` as the workspace. Takes ownership of `dir`. Caller must hold `mutex`.
pub fn open(dir: std.fs.Dir) !void {
    std.debug.assert(!initialized);
    rt = try nana.Runtime.init(gpa.allocator(), .{ .basedir = dir });
    initialized = true;
}

/// Caller must hold `mutex`.
pub fn close() void {
    if (!initialized) return;
    rt.deinit();
    initialized = false;
}

/// Resolve `path` to a directory, creating it if absent. `"./"` means the process's cwd.
///
/// `buf` must outlive nothing — the opened `Dir` does not borrow from it.
pub fn openDir(buf: []u8, path: []const u8) !std.fs.Dir {
    const decoded = if (std.mem.eql(u8, path, "./"))
        try std.process.getCwd(buf)
    else
        std.Uri.percentDecodeBackwards(buf, path);

    return std.fs.openDirAbsolute(decoded, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => blk: {
            try std.fs.makeDirAbsolute(decoded);
            break :blk try std.fs.openDirAbsolute(decoded, .{ .iterate = true });
        },
        else => err,
    };
}

const std = @import("std");
const nana = @import("root.zig");
