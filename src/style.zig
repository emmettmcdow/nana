//! The user's style file: `~/.config/nana/style.toml`.
//!
//! Everything about how the editor looks that is worth tuning — the light and dark palettes, the
//! lengths the layout is built from, the opacities the derived colors use — read from a file the
//! user edits in place and reloaded while the app runs. Save the file and the next frame draws
//! with it; there is nothing to restart and no menu to go through.
//!
//! The format is INI today and TOML-shaped on purpose: sections, `key = value`, `#` comments, and
//! quoted strings. Every TOML file this accepts means the same thing to a real TOML parser, so
//! growing into one later is additive rather than a migration.
//!
//! Nothing here can fail hard. A missing file is written out with the defaults in it, so there is
//! always something to edit; a malformed one keeps the values it could read and warns about the
//! rest. A style file being wrong should never be the reason the editor won't start — or, once a
//! good file has been loaded, the reason a save reverts it.

const DIR_UNDER_HOME = ".config/nana";
const FILE_NAME = "style.toml";
const MAX_BYTES = 64 * 1024;

/// How often the file is stat'd for changes. Reloading is driven from the frame loop, and 60
/// stats a second to catch an edit the user makes by hand is 59 too many.
const POLL_INTERVAL_MS: i64 = 250;

// ****************************************************************************************** Types
/// One `[light]` / `[dark]` section. The theme owns the shape — this file only fills it in.
pub const Palette = theme.Palette;

pub const Text = struct {
    /// Body type size. Null means "whatever the app's own font-size setting says" — the menu's
    /// increase/decrease commands write that, and a style file that doesn't mention size leaves
    /// them working. Setting it here pins the size and the menu stops having a visible effect.
    font_size: ?f64 = null,
};

pub const Style = struct {
    light: Palette = theme.light_palette,
    dark: Palette = theme.dark_palette,
    layout: theme.Metrics = .{},
    text: Text = .{},
    opacity: theme.Opacity = .{},

    /// Resolve to the theme the render tree draws with. `font_size` is the app's own setting,
    /// used unless the style file overrides it.
    pub fn toTheme(self: Style, is_dark: bool, font_size: f64) theme.Theme {
        const p = if (is_dark) self.dark else self.light;
        return theme.Theme.derive(p, self.text.font_size orelse font_size, self.opacity, self.layout);
    }

    /// Bring hand-edited values back into range. A style file is edited by hand by definition, so
    /// a typo'd zero or a stray extra digit is a normal thing to see — and neither should be able
    /// to produce an editor that can't be read or clicked in.
    pub fn sanitized(self: Style) Style {
        var s = self;
        s.layout.padding = clamp(s.layout.padding, 0, MAX_PADDING);
        s.layout.heading_margin_y = clamp(s.layout.heading_margin_y, 0, MAX_MARGIN);
        s.layout.code_margin_y = clamp(s.layout.code_margin_y, 0, MAX_MARGIN);
        s.layout.quote_margin_y = clamp(s.layout.quote_margin_y, 0, MAX_MARGIN);
        s.layout.quote_indent = clamp(s.layout.quote_indent, 0, MAX_MARGIN);
        s.layout.quote_rule_w = clamp(s.layout.quote_rule_w, 0, MAX_MARGIN);
        s.layout.heading_scale = clamp(s.layout.heading_scale, 1, MAX_HEADING_SCALE);
        s.layout.heading_step = clamp(s.layout.heading_step, 0, 1);
        if (s.text.font_size) |size| {
            s.text.font_size = clamp(size, theme.MIN_FONT_SIZE, theme.MAX_FONT_SIZE);
        }
        inline for (@typeInfo(theme.Opacity).@"struct".fields) |f| {
            @field(s.opacity, f.name) = std.math.clamp(@field(s.opacity, f.name), 0.0, 1.0);
        }
        return s;
    }
};

/// Bounds for `sanitized`. Generous — the point is to rule out the unusable, not to have an
/// opinion about taste.
const MAX_PADDING: f64 = 1000;
const MAX_MARGIN: f64 = 500;
const MAX_HEADING_SCALE: f64 = 8;

fn clamp(v: f64, lo: f64, hi: f64) f64 {
    // NaN survives `std.math.clamp` (every comparison against it is false), and one that reached
    // the layout would poison every length derived from it.
    if (std.math.isNan(v)) return lo;
    return std.math.clamp(v, lo, hi);
}

// ************************************************************************************ The Contents
/// Written out when there is no style file yet, so the user has something to edit rather than a
/// blank page and a guess at the key names. Every value here is the default, which
/// `defaults are what the shipped file says` below holds it to.
pub const TEMPLATE =
    \\# nana style
    \\#
    \\# Edited in place: save the file and the editor redraws with it, no restart.
    \\# Colors are "#rgb", "#rrggbb" or "#rrggbbaa". Lengths are in points.
    \\
    \\[light]
    \\background = "#e4e4e4"
    \\foreground = "#2f2f2f"
    \\# Links, quotes and the selection wash. Defaults to the foreground.
    \\tertiary   = "#2f2f2f"
    \\
    \\[dark]
    \\background = "#2f2f2f"
    \\foreground = "#e4e4e4"
    \\tertiary   = "#e4e4e4"
    \\
    \\[layout]
    \\# Space between the window edge and the text, on every side.
    \\padding = 100
    \\
    \\# Space above and below a block. Only the first and last row of a block gets it, so the
    \\# rows within one stay tight; two blocks meeting get the sum of the two.
    \\heading_margin_y = 0
    \\code_margin_y    = 0
    \\quote_margin_y   = 0
    \\
    \\# How far a level of quote nesting indents, and the rule drawn in the gutter it vacated.
    \\quote_indent   = 24
    \\quote_rule_w   = 3
    \\
    \\# An h1 is `heading_scale` times the body size; each level down steps by `heading_step`.
    \\# Never smaller than the body text.
    \\heading_scale = 2.0
    \\heading_step  = 0.2
    \\
    \\[text]
    \\# Body type size. Commented out means the app's own font-size setting (and the
    \\# increase/decrease menu commands) decide it. Uncomment to pin it here instead.
    \\# font_size = 20
    \\
    \\[opacity]
    \\# How the derived colors sit against the ones they come from.
    \\highlight  = 0.25
    \\code       = 0.85
    \\code_bg    = 0.12
    \\quote      = 0.70
    \\quote_rule = 0.35
    \\
;

// ***************************************************************************************** Parsing
/// Parse a style file. Unknown keys and unparseable values are warned about and skipped, so what
/// the file did get right still takes effect.
pub fn parse(text: []const u8) Style {
    var s = Style{};
    var section: []const u8 = "";

    var lines = std.mem.splitScalar(u8, text, '\n');
    var lineno: usize = 0;
    while (lines.next()) |raw| {
        lineno += 1;
        const line = std.mem.trim(u8, stripComment(raw), " \t\r");
        if (line.len == 0) continue;

        if (line[0] == '[') {
            const end = std.mem.indexOfScalar(u8, line, ']') orelse {
                warn(lineno, "unterminated section header", line);
                continue;
            };
            section = std.mem.trim(u8, line[1..end], " \t");
            if (!isSection(section)) warn(lineno, "no such section", section);
            continue;
        }

        const eq = std.mem.indexOfScalar(u8, line, '=') orelse {
            warn(lineno, "not a key = value", line);
            continue;
        };
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const value = unquote(std.mem.trim(u8, line[eq + 1 ..], " \t"));
        if (key.len == 0) {
            warn(lineno, "empty key", line);
            continue;
        }
        switch (applyTo(&s, section, key, value)) {
            .ok => {},
            .unknown_section => warn(lineno, "key outside any known section", key),
            .unknown_key => warn(lineno, "no such setting", key),
            .bad_value => warn(lineno, "value not understood", value),
        }
    }
    return s.sanitized();
}

const Outcome = enum { ok, unknown_section, unknown_key, bad_value };

/// Route `section.key = value` to the field that holds it.
///
/// Reflective rather than a hand-written table: the section structs *are* the schema, so a
/// setting added to `theme.Metrics` is one the file can set the same day, with no second list to
/// remember to update.
fn applyTo(s: *Style, section: []const u8, key: []const u8, value: []const u8) Outcome {
    inline for (@typeInfo(Style).@"struct".fields) |f| {
        if (std.mem.eql(u8, section, f.name)) {
            return assign(f.type, &@field(s, f.name), key, value);
        }
    }
    return .unknown_section;
}

fn isSection(name: []const u8) bool {
    inline for (@typeInfo(Style).@"struct".fields) |f| {
        if (std.mem.eql(u8, name, f.name)) return true;
    }
    return false;
}

fn assign(comptime T: type, target: *T, key: []const u8, value: []const u8) Outcome {
    inline for (@typeInfo(T).@"struct".fields) |f| {
        if (std.mem.eql(u8, key, f.name)) {
            const parsed = parseAs(f.type, value) orelse return .bad_value;
            @field(target, f.name) = parsed;
            return .ok;
        }
    }
    return .unknown_key;
}

fn parseAs(comptime T: type, value: []const u8) ?T {
    if (T == Color) return parseColor(value);
    if (T == f64 or T == f32) return std.fmt.parseFloat(T, value) catch null;
    // An optional setting takes the same values as the thing it wraps, plus the words that mean
    // "leave it to whoever else decides this".
    if (@typeInfo(T) == .optional) {
        const Child = @typeInfo(T).optional.child;
        if (std.mem.eql(u8, value, "default") or value.len == 0) return @as(T, null);
        const child = parseAs(Child, value) orelse return null;
        return @as(T, child);
    }
    @compileError("style: no parser for " ++ @typeName(T));
}

/// `#rgb`, `#rrggbb`, or `#rrggbbaa`. The leading `#` is optional, since a `#` inside a quoted
/// string is the one place this file's comment character isn't one.
fn parseColor(value: []const u8) ?Color {
    const hex = if (value.len > 0 and value[0] == '#') value[1..] else value;
    const chan = struct {
        fn f(digits: []const u8) ?f32 {
            const n = std.fmt.parseUnsigned(u8, digits, 16) catch return null;
            // A single digit is the shorthand: `f` means `ff`, not `0f`.
            const byte: u8 = if (digits.len == 1) n * 17 else n;
            return @as(f32, @floatFromInt(byte)) / 255.0;
        }
    }.f;

    return switch (hex.len) {
        3 => .{
            .r = chan(hex[0..1]) orelse return null,
            .g = chan(hex[1..2]) orelse return null,
            .b = chan(hex[2..3]) orelse return null,
        },
        6, 8 => .{
            .r = chan(hex[0..2]) orelse return null,
            .g = chan(hex[2..4]) orelse return null,
            .b = chan(hex[4..6]) orelse return null,
            .a = if (hex.len == 8) (chan(hex[6..8]) orelse return null) else 1.0,
        },
        else => null,
    };
}

/// Drop a trailing `# comment`, unless the `#` is inside a quoted value — which is where every
/// color in the file lives.
fn stripComment(line: []const u8) []const u8 {
    var in_quote: ?u8 = null;
    for (line, 0..) |c, i| {
        if (in_quote) |q| {
            if (c == q) in_quote = null;
        } else switch (c) {
            '"', '\'' => in_quote = c,
            '#', ';' => return line[0..i],
            else => {},
        }
    }
    return line;
}

fn unquote(value: []const u8) []const u8 {
    if (value.len >= 2 and (value[0] == '"' or value[0] == '\'') and value[value.len - 1] == value[0]) {
        return value[1 .. value.len - 1];
    }
    return value;
}

fn warn(lineno: usize, what: []const u8, detail: []const u8) void {
    std.log.warn("style.toml:{d}: {s}: '{s}'", .{ lineno, what, detail });
}

// ******************************************************************************* Loading & Watching
/// Absolute path to the style file. Caller owns the result.
pub fn filePath(alloc: Allocator) ![]u8 {
    const home = try std.process.getEnvVarOwned(alloc, "HOME");
    defer alloc.free(home);
    return std.fs.path.join(alloc, &.{ realHome(home), DIR_UNDER_HOME, FILE_NAME });
}

/// The user's actual home directory, given whatever `$HOME` says.
///
/// Under the app sandbox `$HOME` is the app's container — `~/Library/Containers/<id>/Data` —
/// which is where `settings.zig` and the default workspace belong and where this file does not.
/// A style file is something the user edits alongside their other dotfiles, so it lives in the
/// home directory they can actually see. Reaching it needs a sandbox exception as well as the
/// right path; see `mac/nana/nana.entitlements`.
///
/// Borrowed from `home`, so it lives exactly as long as what was passed in.
fn realHome(home: []const u8) []const u8 {
    const containers = "/Library/Containers/";
    const at = std.mem.indexOf(u8, home, containers) orelse return home;
    return home[0..at];
}

/// What a file looked like last time it was checked. Size as well as time because a mtime has
/// one-second resolution on some filesystems, and two saves inside one second are exactly what
/// tuning a value by hand looks like.
const Stamp = struct {
    mtime_ns: i128,
    size: u64,
};

fn stampOf(path: []const u8) ?Stamp {
    const st = std.fs.cwd().statFile(path) catch return null;
    return .{ .mtime_ns = st.mtime, .size = st.size };
}

/// The style in force, and enough about the file it came from to notice it changing.
///
/// Owned by whoever drives the frame loop: `init` once at startup, `poll` each frame. Reads are
/// through `current`, which is always a usable style — before the first load it is the defaults.
pub const Store = struct {
    current: Style = .{},
    /// The file being watched, owned by this store. Null when there was nowhere to look — no
    /// `$HOME` — in which case `current` stays at the defaults forever.
    path: ?[]u8 = null,
    stamp: ?Stamp = null,
    last_poll_ms: i64 = 0,

    /// Watch the user's style file, at `~/.config/nana/style.toml`.
    pub fn init(alloc: Allocator) Store {
        const path = filePath(alloc) catch {
            std.log.warn("no HOME: styling with the defaults", .{});
            return .{};
        };
        defer alloc.free(path);
        return initAt(alloc, path);
    }

    /// Watch `path` instead. Reads it now — writing out the template first if there is no file
    /// there yet — and `poll` takes over from there.
    pub fn initAt(alloc: Allocator, path: []const u8) Store {
        var s = Store{};
        s.path = alloc.dupe(u8, path) catch return s;
        writeTemplateIfAbsent(path);
        if (readFile(alloc, path)) |style| s.current = style;
        s.stamp = stampOf(path);
        s.last_poll_ms = std.time.milliTimestamp();
        return s;
    }

    pub fn deinit(self: *Store, alloc: Allocator) void {
        if (self.path) |p| alloc.free(p);
        self.path = null;
    }

    /// Reload if the file has changed since the last look. Returns whether `current` moved, so
    /// the caller can throw away whatever it had derived from the old one.
    ///
    /// Rate-limited internally, so calling it every frame is the intended use.
    pub fn poll(self: *Store, alloc: Allocator) bool {
        const now = std.time.milliTimestamp();
        if (now - self.last_poll_ms < POLL_INTERVAL_MS) return false;
        self.last_poll_ms = now;

        const path = self.path orelse return false;
        const stamp = stampOf(path) orelse {
            // The file went away. Keep drawing with what it last said rather than snapping back
            // to the defaults — a file being briefly absent is what some editors call a save.
            return false;
        };
        if (self.stamp) |prev| {
            if (prev.mtime_ns == stamp.mtime_ns and prev.size == stamp.size) return false;
        }
        self.stamp = stamp;

        const style = readFile(alloc, path) orelse return false;
        // A save that changed nothing we care about — a comment, a reformat — is not worth
        // making the caller relayout for.
        if (std.meta.eql(style, self.current)) return false;
        self.current = style;
        std.log.info("style reloaded", .{});
        return true;
    }
};

fn readFile(alloc: Allocator, path: []const u8) ?Style {
    const bytes = std.fs.cwd().readFileAlloc(alloc, path, MAX_BYTES) catch |err| {
        // Not-found is the ordinary case on a machine that has never had a style file, and the
        // template write above will have just handled it. Anything else is worth saying.
        if (err != error.FileNotFound) std.log.warn("could not read {s}: {}", .{ path, err });
        return null;
    };
    defer alloc.free(bytes);
    return parse(bytes);
}

/// Best-effort: a style file we can't write is not worth failing startup over, and the defaults
/// are what the editor would have used anyway.
fn writeTemplateIfAbsent(path: []const u8) void {
    const exists = if (std.fs.cwd().access(path, .{})) |_| true else |_| false;
    if (exists) return;

    if (std.fs.path.dirname(path)) |dir| {
        std.fs.cwd().makePath(dir) catch |err| {
            std.log.warn("could not create {s}: {}", .{ dir, err });
            return;
        };
    }
    std.fs.cwd().writeFile(.{ .sub_path = path, .data = TEMPLATE }) catch |err| {
        std.log.warn("could not write {s}: {}", .{ path, err });
    };
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const theme = @import("render/theme.zig");
const Color = @import("render/geom.zig").Color;

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

test "the shipped template says exactly what the defaults are" {
    // The template is documentation that the parser has to agree with. If a default moves and the
    // file still claims the old value, this is where that shows up.
    try expectEqual(Style{}, parse(TEMPLATE));
}

test "an empty or absent file is the defaults" {
    try expectEqual(Style{}, parse(""));
    try expectEqual(Style{}, parse("# nothing but a comment\n\n"));
}

test "colors parse in every accepted width" {
    const s = parse(
        \\[dark]
        \\background = "#000"
        \\foreground = "#ffffff"
        \\tertiary = "#ff000080"
    );
    try expectEqual(Color.rgb(0, 0, 0), s.dark.background);
    try expectEqual(Color.rgb(1, 1, 1), s.dark.foreground);
    try expect(s.dark.tertiary.r == 1.0 and s.dark.tertiary.g == 0.0);
    try expect(s.dark.tertiary.a > 0.5 and s.dark.tertiary.a < 0.51);
    // Shorthand expands by repeating the digit: #f00 is #ff0000, not #0f0000.
    try expectEqual(Color.rgb(1, 0, 0), parseColor("#f00").?);
    // The `#` is optional, and quotes are stripped before this ever sees the value.
    try expectEqual(Color.rgb(1, 1, 1), parseColor("ffffff").?);
}

test "lengths and opacities parse" {
    const s = parse(
        \\[layout]
        \\padding = 42
        \\quote_margin_y = 12.5
        \\[opacity]
        \\highlight = 0.5
    );
    try expectEqual(@as(f64, 42), s.layout.padding);
    try expectEqual(@as(f64, 12.5), s.layout.quote_margin_y);
    try expectEqual(@as(f32, 0.5), s.opacity.highlight);
}

test "a comment after a value is not part of it" {
    const s = parse(
        \\[layout]
        \\padding = 40 # the good one
        \\quote_indent = 8 ; and the other comment character
    );
    try expectEqual(@as(f64, 40), s.layout.padding);
    try expectEqual(@as(f64, 8), s.layout.quote_indent);
}

test "a '#' inside a quoted color is not a comment" {
    const s = parse(
        \\[light]
        \\background = "#123456" # trailing comment
    );
    try expect(s.light.background.r > 0.07 and s.light.background.r < 0.08);
}

test "what a bad file gets wrong does not cost it what it got right" {
    const s = parse(
        \\[layout
        \\padding = 40
        \\[layout]
        \\padding = not-a-number
        \\heading_margin_y = 30
        \\no_such_setting = 1
        \\[nonsense]
        \\code_margin_y = 99
    );
    // The good line took effect; the bad ones left their fields at the default.
    try expectEqual(@as(f64, 30), s.layout.heading_margin_y);
    try expectEqual((Style{}).layout.padding, s.layout.padding);
    try expectEqual((Style{}).layout.code_margin_y, s.layout.code_margin_y);
}

test "out-of-range values are clamped rather than honored" {
    const s = parse(
        \\[layout]
        \\padding = -50
        \\heading_scale = 0.1
        \\[opacity]
        \\quote = 4
        \\[text]
        \\font_size = 9999
    );
    try expectEqual(@as(f64, 0), s.layout.padding);
    try expectEqual(@as(f64, 1), s.layout.heading_scale); // never below body size
    try expectEqual(@as(f32, 1), s.opacity.quote);
    try expectEqual(theme.MAX_FONT_SIZE, s.text.font_size.?);
}

test "font size is the app's unless the file pins it" {
    const unset = parse("[text]\n");
    try expectEqual(@as(?f64, null), unset.text.font_size);
    try expectEqual(@as(f64, 17), unset.toTheme(true, 17).font_size);

    const pinned = parse("[text]\nfont_size = 30\n");
    try expectEqual(@as(f64, 30), pinned.toTheme(true, 17).font_size);
    // And `default` says so explicitly, for someone who'd rather write it than delete the line.
    try expectEqual(@as(?f64, null), parse("[text]\nfont_size = default\n").text.font_size);
}

test "the palette follows the appearance" {
    const s = parse(
        \\[light]
        \\background = "#ffffff"
        \\foreground = "#000000"
        \\tertiary = "#0000ff"
        \\[dark]
        \\background = "#000000"
        \\foreground = "#ffffff"
        \\tertiary = "#00ff00"
    );
    try expectEqual(Color.rgb(1, 1, 1), s.toTheme(false, 20).background);
    try expectEqual(Color.rgb(0, 0, 0), s.toTheme(true, 20).background);
    // The accent reaches the roles derived from it.
    try expect(s.toTheme(false, 20).link.b == 1.0);
    try expect(s.toTheme(true, 20).link.g == 1.0);
}

// ***************************************************************************** The watched file
/// A style file in a directory of its own, so the tests below can write to it as the user would.
const TmpFile = struct {
    dir: std.testing.TmpDir,
    path: []u8,

    fn init(alloc: Allocator) !TmpFile {
        var dir = std.testing.tmpDir(.{});
        errdefer dir.cleanup();
        const dir_path = try dir.dir.realpathAlloc(alloc, ".");
        defer alloc.free(dir_path);
        return .{ .dir = dir, .path = try std.fs.path.join(alloc, &.{ dir_path, FILE_NAME }) };
    }

    fn deinit(self: *TmpFile, alloc: Allocator) void {
        alloc.free(self.path);
        self.dir.cleanup();
    }

    fn write(self: *TmpFile, contents: []const u8) !void {
        try self.dir.dir.writeFile(.{ .sub_path = FILE_NAME, .data = contents });
    }
};

test "a first run leaves an editable file behind" {
    const alloc = std.testing.allocator;
    var tmp = try TmpFile.init(alloc);
    defer tmp.deinit(alloc);

    var store = Store.initAt(alloc, tmp.path);
    defer store.deinit(alloc);

    // Nothing was there, so the template was written — and what it says is what is in force.
    try expectEqual(Style{}, store.current);
    const written = try std.fs.cwd().readFileAlloc(alloc, tmp.path, MAX_BYTES);
    defer alloc.free(written);
    try std.testing.expectEqualStrings(TEMPLATE, written);
}

test "an existing file is not overwritten by the template" {
    const alloc = std.testing.allocator;
    var tmp = try TmpFile.init(alloc);
    defer tmp.deinit(alloc);
    try tmp.write("[layout]\npadding = 7\n");

    var store = Store.initAt(alloc, tmp.path);
    defer store.deinit(alloc);
    try expectEqual(@as(f64, 7), store.current.layout.padding);
}

test "saving the file changes what is in force" {
    const alloc = std.testing.allocator;
    var tmp = try TmpFile.init(alloc);
    defer tmp.deinit(alloc);
    try tmp.write("[layout]\npadding = 7\n");

    var store = Store.initAt(alloc, tmp.path);
    defer store.deinit(alloc);

    // Nothing has changed yet, so a poll is a no-op however often it is called.
    store.last_poll_ms = 0;
    try expect(!store.poll(alloc));

    try tmp.write("[layout]\npadding = 8\n");
    store.last_poll_ms = 0;
    try expect(store.poll(alloc));
    try expectEqual(@as(f64, 8), store.current.layout.padding);

    // And a save that says the same thing is not a change: the caller would relayout for nothing.
    try tmp.write("# reformatted\n[layout]\npadding = 8\n");
    store.last_poll_ms = 0;
    try expect(!store.poll(alloc));
}

test "polling is rate-limited, so a frame loop can call it freely" {
    const alloc = std.testing.allocator;
    var tmp = try TmpFile.init(alloc);
    defer tmp.deinit(alloc);
    try tmp.write("[layout]\npadding = 7\n");

    var store = Store.initAt(alloc, tmp.path);
    defer store.deinit(alloc);

    try tmp.write("[layout]\npadding = 8\n");
    // `initAt` just looked, so this one is inside the interval and does not touch the disk.
    try expect(!store.poll(alloc));
    try expectEqual(@as(f64, 7), store.current.layout.padding);
}

test "a file that goes missing leaves the last good style in force" {
    const alloc = std.testing.allocator;
    var tmp = try TmpFile.init(alloc);
    defer tmp.deinit(alloc);
    try tmp.write("[layout]\npadding = 7\n");

    var store = Store.initAt(alloc, tmp.path);
    defer store.deinit(alloc);

    try tmp.dir.dir.deleteFile(FILE_NAME);
    store.last_poll_ms = 0;
    try expect(!store.poll(alloc));
    // Not back to the defaults: an editor mid-save is briefly a file that isn't there, and the
    // editor flashing its default look on every save would be worse than ignoring it.
    try expectEqual(@as(f64, 7), store.current.layout.padding);
}

test "the style file lives in the real home, not the sandbox container" {
    try std.testing.expectEqualStrings(
        "/Users/me",
        realHome("/Users/me/Library/Containers/mcdow.nana/Data"),
    );
    // Unsandboxed, or run from a shell: `$HOME` is already the answer.
    try std.testing.expectEqualStrings("/Users/me", realHome("/Users/me"));
    try std.testing.expectEqualStrings("/root", realHome("/root"));
}

test "no HOME is the defaults rather than a crash" {
    const alloc = std.testing.allocator;
    var store = Store{};
    defer store.deinit(alloc);
    try expectEqual(Style{}, store.current);
    // With nowhere to look, polling stays a no-op forever.
    store.last_poll_ms = 0;
    try expect(!store.poll(alloc));
}

test "metrics reach the theme the render tree reads" {
    const s = parse(
        \\[layout]
        \\padding = 12
        \\code_margin_y = 7
        \\heading_scale = 3.0
    );
    const t = s.toTheme(true, 20);
    try expectEqual(@as(f64, 12), t.metrics.padding);
    try expectEqual(@as(f64, 7), t.metrics.code_margin_y);
    try expectEqual(@as(f64, 3.0), t.metrics.headingScale(1));
}
