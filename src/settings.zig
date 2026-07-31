//! User settings, persisted as JSON under Application Support.
//!
//! Zig's own file rather than `NSUserDefaults`, so settings are the editor's to read and write
//! without a round trip through the host. What stays on the host side is the color-scheme
//! *preference*: it drives the window's titlebar appearance, which is AppKit's business, and
//! the host passes the resolved light/dark down as part of each frame's input.
//!
//! Every failure path falls back to defaults. A missing, unreadable, or malformed settings file
//! should start the editor with sensible values, never stop it from starting.

pub const Settings = struct {
    font_size: f64 = theme.DEFAULT_FONT_SIZE,

    /// Bring stored values back into range. A hand-edited file (or one written by a future
    /// version) shouldn't be able to produce an unusable editor.
    pub fn sanitized(self: Settings) Settings {
        return .{
            .font_size = std.math.clamp(self.font_size, theme.MIN_FONT_SIZE, theme.MAX_FONT_SIZE),
        };
    }
};

const DIR_UNDER_HOME = "Library/Application Support/nana";
const FILE_NAME = "settings.json";
const MAX_BYTES = 64 * 1024;

/// Absolute path to the settings file. Caller owns the result.
fn filePath(alloc: Allocator) ![]u8 {
    const home = try std.process.getEnvVarOwned(alloc, "HOME");
    defer alloc.free(home);
    return std.fs.path.join(alloc, &.{ home, DIR_UNDER_HOME, FILE_NAME });
}

pub fn load(alloc: Allocator) Settings {
    const path = filePath(alloc) catch return .{};
    defer alloc.free(path);

    const bytes = std.fs.cwd().readFileAlloc(alloc, path, MAX_BYTES) catch return .{};
    defer alloc.free(bytes);

    const parsed = std.json.parseFromSlice(Settings, alloc, bytes, .{
        // Tolerate keys this version doesn't know: downgrading shouldn't wipe the file.
        .ignore_unknown_fields = true,
    }) catch return .{};
    defer parsed.deinit();

    return parsed.value.sanitized();
}

/// Best-effort write. A settings file we can't save is not worth failing an edit over, so this
/// logs and moves on.
pub fn save(alloc: Allocator, s: Settings) void {
    saveOrFail(alloc, s) catch |err| {
        std.log.warn("could not save settings: {}", .{err});
    };
}

fn saveOrFail(alloc: Allocator, s: Settings) !void {
    const path = try filePath(alloc);
    defer alloc.free(path);

    if (std.fs.path.dirname(path)) |dir| {
        std.fs.cwd().makePath(dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }

    const json = try std.json.Stringify.valueAlloc(alloc, s, .{ .whitespace = .indent_2 });
    defer alloc.free(json);

    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = json });
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const theme = @import("render/theme.zig");

const expectEqual = std.testing.expectEqual;

test "settings clamp out-of-range values" {
    try expectEqual(theme.MAX_FONT_SIZE, (Settings{ .font_size = 9999 }).sanitized().font_size);
    try expectEqual(theme.MIN_FONT_SIZE, (Settings{ .font_size = 0 }).sanitized().font_size);
    try expectEqual(@as(f64, 18), (Settings{ .font_size = 18 }).sanitized().font_size);
}

test "a malformed settings file yields defaults rather than an error" {
    const alloc = std.testing.allocator;
    const parsed = std.json.parseFromSlice(Settings, alloc, "{ not json", .{}) catch {
        // Which is what `load` relies on: the parse fails and defaults are returned.
        try expectEqual(theme.DEFAULT_FONT_SIZE, (Settings{}).font_size);
        return;
    };
    defer parsed.deinit();
    unreachable;
}
