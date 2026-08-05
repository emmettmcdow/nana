//! A headless `Canvas` that records instead of rasterising, and the harness that drives the
//! editor through it.
//!
//! The point is to test the editor the way it is actually used: real `ted.frame` calls, real
//! markdown parse, real layout, real caret arithmetic — with the drawing landing in a list of
//! operations rather than on a Core Graphics context. Nothing here reimplements any of that, so
//! there is no second layout to keep in step with the first. It is a tape recorder.
//!
//! Two ways to read what came out, and they answer different questions:
//!
//!   * `expectGrid` / `expectAttrs` — the ops rendered back into a character grid, compared
//!     against a picture of the screen. For wrapping, indentation, concealment, and where the
//!     caret and selection ended up. Reads like the thing it is testing.
//!   * `ops` — the recording itself, with exact coordinates, colors and fonts. For what a grid
//!     cannot express: sub-cell scroll offsets, panel geometry, draw order, which font a run
//!     was shaped in.
//!
//! ── The cell model ───────────────────────────────────────────────────────────────────────────
//!
//! Every character measures `CELL` points wide and every line `CELL` points tall, regardless of
//! font — the same trick the web platform tests play with the Ahem font, where every glyph is an
//! exact em square. Layout arithmetic then lands on cell boundaries and a test can state its
//! expectation as a picture instead of as a sum.
//!
//! `CELL` is 12 because the layout's own constants are in points and have to divide into it:
//! `QUOTE_INDENT_PX` (24) is exactly two cells, so an indented quote is legible in a grid rather
//! than being pushed 24 columns right. The decorations narrower than a cell — the 2pt caret, the
//! 3pt quote rule — mark the single cell they start in.
//!
//! Ignoring the font is a deliberate loss. A proportional fake would make grids unreadable, and
//! the tests that genuinely turn on per-font metrics belong in the op log, where the font of
//! each run is recorded exactly as it was requested.

const std = @import("std");
const Allocator = std.mem.Allocator;

const geom = @import("geom.zig");
const Canvas = @import("canvas.zig").Canvas;
const app = @import("app.zig");
const ted = @import("ted.zig");
const theme = @import("theme.zig");
const input = @import("input.zig");

pub const Input = input.Input;
pub const AppState = app.AppState;

/// Points per character cell. See the module comment for why 12.
pub const CELL: f64 = 12;

/// Canvas coordinate of the content area's top-left corner, re-exported so a test asserting on
/// raw op coordinates doesn't have to reach into `ted.zig` for it.
pub const MARGIN: f64 = ted.MARGIN_PX;

// ****************************************************************************** Recorded drawing
pub const Op = union(enum) {
    fill: Fill,
    text: Text,
    push_clip: geom.Rect,
    pop_clip,

    pub const Fill = struct {
        rect: geom.Rect,
        color: geom.Color,
    };

    pub const Text = struct {
        /// Where the run landed and how big it measured. `x`/`y` are the top-left of the text
        /// box, matching `Canvas.drawText`.
        rect: geom.Rect,
        /// Owned by the recorder's arena. The render pass draws slices of a scratch buffer that
        /// the next frame overwrites, so keeping the slice would be keeping a dangling view of
        /// last frame's document.
        utf8: []const u8,
        font: geom.Font,
        color: geom.Color,
    };
};

/// A `Canvas` that keeps the calls. Measurement is the cell model above; drawing is recorded.
pub const Recorder = struct {
    alloc: Allocator,
    /// Backs the copied run text. Reset per frame along with `ops`.
    arena: std.heap.ArenaAllocator,
    ops: std.ArrayList(Op) = .{},
    /// Whether a row's height follows its font. Off by default: every line is one cell tall, so
    /// a grid row is a document row and pictures stay dense. Turned on for the tests that are
    /// *about* vertical space — scrolling past a line taller than the viewport can't be posed
    /// at all when every line is the same height.
    scale_heights: bool = false,
    /// Set when an append failed. Checked by `frame`, so a test can never quietly assert against
    /// a truncated recording.
    oom: bool = false,

    pub fn init(alloc: Allocator) Recorder {
        return .{ .alloc = alloc, .arena = std.heap.ArenaAllocator.init(alloc) };
    }

    pub fn deinit(self: *Recorder) void {
        self.ops.deinit(self.alloc);
        self.arena.deinit();
    }

    pub fn reset(self: *Recorder) void {
        self.ops.clearRetainingCapacity();
        _ = self.arena.reset(.retain_capacity);
        self.oom = false;
    }

    /// The interface view of this recorder. Borrows `self`, so call it on a stable pointer —
    /// `Harness.frame` builds one per frame from `&self.recorder`.
    pub fn canvas(self: *Recorder, size: geom.Size) Canvas {
        return .{ .size = size, .ctx = self, .vtable = &vtable };
    }
};

const vtable = Canvas.VTable{
    .fillRect = fillRect,
    .pushClip = pushClip,
    .popClip = popClip,
    .drawText = drawText,
    .measureText = measureText,
    .measureTextAttributed = measureTextAttributed,
};

fn rec(ctx: *anyopaque) *Recorder {
    return @ptrCast(@alignCast(ctx));
}

fn push(self: *Recorder, op: Op) void {
    self.ops.append(self.alloc, op) catch {
        self.oom = true;
    };
}

fn fillRect(ctx: *anyopaque, rect: geom.Rect, color: geom.Color) void {
    push(rec(ctx), .{ .fill = .{ .rect = rect, .color = color } });
}

fn pushClip(ctx: *anyopaque, rect: geom.Rect) void {
    push(rec(ctx), .{ .push_clip = rect });
}

fn popClip(ctx: *anyopaque) void {
    push(rec(ctx), .pop_clip);
}

fn drawText(ctx: *anyopaque, utf8: []const u8, x: f64, y: f64, font: geom.Font, color: geom.Color) geom.Size {
    const self = rec(ctx);
    const size = geom.Size{ .w = @as(f64, @floatFromInt(cellLen(utf8))) * CELL, .h = CELL };
    const owned = self.arena.allocator().dupe(u8, utf8) catch {
        self.oom = true;
        return size;
    };
    push(self, .{ .text = .{
        .rect = .{ .x = x, .y = y, .w = size.w, .h = size.h },
        .utf8 = owned,
        .font = font,
        .color = color,
    } });
    return size;
}

fn measureText(ctx: *anyopaque, utf8: []const u8, font: geom.Font) geom.Size {
    if (utf8.len == 0) return geom.Size.zero;
    return .{ .w = @as(f64, @floatFromInt(cellLen(utf8))) * CELL, .h = rowHeight(rec(ctx), font) };
}

fn measureTextAttributed(ctx: *anyopaque, text: geom.AttributedText) geom.Size {
    // Matching the Core Text backend, which returns zero for a line with no glyphs on it — a row
    // of wholly concealed markup is not the same as a blank row wanting a blank row's height.
    if (text.isEmpty()) return geom.Size.zero;
    var cells: usize = 0;
    var h: f64 = 0;
    for (text.runs) |run| {
        cells += cellLen(run.text);
        // The tallest run sets the line's height, as ascent and descent are maxima taken over
        // the whole line rather than anything one run knows.
        h = @max(h, rowHeight(rec(ctx), run.font));
    }
    return .{ .w = @as(f64, @floatFromInt(cells)) * CELL, .h = h };
}

/// One cell, or the font's multiple of one when `scale_heights` is on. A 2x header is two rows
/// tall, which is the only way a test can put a line taller than the viewport on screen.
fn rowHeight(self: *const Recorder, font: geom.Font) f64 {
    if (!self.scale_heights) return CELL;
    return CELL * @round(font.size / test_theme.font_size);
}

/// Cells occupied by a run: characters, not bytes, so a multi-byte codepoint is one column.
fn cellLen(utf8: []const u8) usize {
    return std.unicode.utf8CountCodepoints(utf8) catch utf8.len;
}

comptime {
    // `dump` is a debugging aid, so nothing calls it on a green run — and an uncalled function in
    // a non-root module is never analysed, which is how it would quietly stop compiling and only
    // say so on the day someone reached for it. Referencing it here forces the analysis.
    _ = &Harness.dump;
}

// ******************************************************************************* The sentinel theme
/// A theme whose every role is a distinct color, so a recorded fill can be identified by what it
/// was drawn with.
///
/// The shipping themes cannot do this: `Theme.derive` builds most colors from the text color and
/// leaves several exactly equal — `caret`, `link` and `text` are all the same value — so a
/// reverse lookup from color to role would be ambiguous where it matters most.
pub const test_theme = theme.Theme{
    .background = mark(0),
    .text = mark(1),
    .highlight = mark(2),
    .code = mark(3),
    .code_bg = mark(4),
    .quote = mark(5),
    .quote_rule = mark(6),
    .link = mark(7),
    .caret = mark(8),
    .font_size = CELL,
};

fn mark(i: u8) geom.Color {
    return .{ .r = @as(f32, @floatFromInt(i)) / 255.0, .g = 0, .b = 0, .a = 1 };
}

fn isRole(c: geom.Color, role: geom.Color) bool {
    return std.meta.eql(c, role);
}

/// The theme role a color came from, for `Harness.dump`. Every field is checked, not just the
/// ones the attribute plane marks, so a fill drawn in an unexpected color is named rather than
/// silently reading as background.
fn roleName(c: geom.Color) []const u8 {
    inline for (@typeInfo(theme.Theme).@"struct".fields) |field| {
        if (field.type == geom.Color and isRole(c, @field(test_theme, field.name))) return field.name;
    }
    return "<unknown>";
}

/// A font as a compact tag: its size, then the traits it carries.
fn fontName(f: geom.Font) []const u8 {
    // Sizes are multiples of the cell under the sentinel theme, so the ratio names the role a
    // bare point size would not: body text is 1x, an h1 is 2x.
    const scale: usize = @intFromFloat(@round(f.size / CELL * 10));
    return switch (scale) {
        10 => if (f.bold and f.italic) "1.0x BI" else if (f.bold) "1.0x B" else if (f.italic) "1.0x I" else if (f.underline) "1.0x U" else "1.0x",
        12 => "1.2x",
        14 => "1.4x",
        16 => "1.6x",
        18 => "1.8x",
        20 => "2.0x",
        else => "?x",
    };
}

// ************************************************************************************* The grid
/// What a cell is covered by, in the attribute plane. Precedence when several apply is the order
/// of this enum — the caret is the most specific thing a test asks about, and a selection is
/// more interesting than the panel it sits on.
///
/// Precedence by role rather than by paint order on purpose: the shipping panels are translucent
/// and composite over what they cover, so "last one drawn" is not what the user sees either.
const Attr = enum(u8) {
    caret = 'I',
    selection = '#',
    quote_rule = '|',
    code_bg = 'c',
    none = '.',
};

/// How a cell's text was styled — the half of the render pass the text plane cannot show,
/// because a glyph looks the same in the grid whatever font drew it.
///
/// Read off the recorded draw call's font and color rather than from anything the layout kept,
/// so what a test asserts is what Core Text would have been asked for.
const StyleMark = enum(u8) {
    plain = 'p',
    bold = 'b',
    italic = 'i',
    emphasis = 'e',
    header = 'h',
    code = 'c',
    link = 'l',
    quote = 'q',
    none = '.',
};

fn styleOf(font: geom.Font, color: geom.Color) StyleMark {
    // Color first: `styleForToken` gives code, links and quotes a color of their own, and those
    // are what distinguish them. Only body text is left to be told apart by its font.
    if (isRole(color, test_theme.code)) return .code;
    if (isRole(color, test_theme.link)) return .link;
    if (isRole(color, test_theme.quote)) return .quote;
    // A header is body-colored and told apart by size, which scales off the theme's own.
    if (font.size != test_theme.font_size) return .header;
    if (font.bold and font.italic) return .emphasis;
    if (font.bold) return .bold;
    if (font.italic) return .italic;
    return .plain;
}

pub const Grid = struct {
    cols: usize,
    rows: usize,
    /// Codepoints, blank is ' '. A cell holds one character, which a `[]u8` could not.
    cells: []u21,
    attrs: []Attr,
    styles: []StyleMark,

    fn at(self: Grid, col: usize, row: usize) usize {
        return row * self.cols + col;
    }
};

// *********************************************************************************** The harness
pub const Harness = struct {
    alloc: Allocator,
    recorder: Recorder,
    state: AppState,
    /// One per harness rather than one per process, so a document laid out by one test cannot
    /// reach the next and every buffer has an owner the testing allocator can hold responsible.
    layout: ted.Layout,
    grid: Grid,
    saved_theme: theme.Theme,

    pub const Options = struct {
        /// Content width in cells. Note that a row holds at most `cols - 1` characters: the fit
        /// test in `maxFitLineEnd` is strict, so a row exactly filling the content width does
        /// not fit. Stated rather than papered over — it is the layout's behaviour, and hiding
        /// it in the harness would mean tests disagreed with the app by one column.
        cols: usize = 40,
        /// Viewport height in cells.
        rows: usize = 10,
        /// Gap buffer size. Only has to exceed the document plus whatever a test types.
        buf_len: usize = 4096,
        /// See `Recorder.scale_heights`.
        scale_heights: bool = false,
    };

    pub fn init(alloc: Allocator, opts: Options) !Harness {
        const gap_buf = try alloc.alloc(u8, opts.buf_len);
        errdefer alloc.free(gap_buf);
        const cells = try alloc.alloc(u21, opts.cols * opts.rows);
        errdefer alloc.free(cells);
        const attrs = try alloc.alloc(Attr, opts.cols * opts.rows);
        errdefer alloc.free(attrs);
        const styles = try alloc.alloc(StyleMark, opts.cols * opts.rows);
        errdefer alloc.free(styles);
        const layout = try ted.Layout.init(alloc);

        return .{
            .alloc = alloc,
            .recorder = blk: {
                var r = Recorder.init(alloc);
                r.scale_heights = opts.scale_heights;
                break :blk r;
            },
            .state = AppState.init(gap_buf),
            .layout = layout,
            .grid = .{ .cols = opts.cols, .rows = opts.rows, .cells = cells, .attrs = attrs, .styles = styles },
            // The editor reads the theme off a global. Saved so a test cannot leave the next one
            // running against sentinel colors.
            .saved_theme = theme.active,
        };
    }

    pub fn deinit(self: *Harness) void {
        ted.deinitHistory(&self.state, self.alloc);
        self.layout.deinit(self.alloc);
        self.recorder.deinit();
        self.alloc.free(self.state.gap_buf);
        self.alloc.free(self.grid.cells);
        self.alloc.free(self.grid.attrs);
        self.alloc.free(self.grid.styles);
        theme.active = self.saved_theme;
    }

    /// The canvas the editor draws into: the content area plus the margin on every side.
    fn canvasSize(self: *const Harness) geom.Size {
        return .{
            .w = (@as(f64, @floatFromInt(self.grid.cols)) * CELL) + (ted.MARGIN_PX * 2),
            .h = (@as(f64, @floatFromInt(self.grid.rows)) * CELL) + (ted.MARGIN_PX * 2),
        };
    }

    /// Load a document, with the caret at the start.
    ///
    /// The caret matters to what gets drawn: the source line it sits on shows its markdown
    /// delimiters and every other line conceals them. Tests move it with real input rather than
    /// by assignment, so the reveal they see is the one the editor would compute.
    pub fn open(self: *Harness, doc: []const u8) !void {
        ted.deinitHistory(&self.state, self.alloc);

        const buf = self.state.gap_buf;
        if (doc.len > buf.len) return error.DocumentTooLong;
        // Caret at the start means the gap is at the front and the document sits in the tail.
        @memcpy(buf[buf.len - doc.len ..], doc);
        self.state.cursor_i = 0;
        self.state.gap_end = buf.len - doc.len;
        self.state.text_len = doc.len;
        self.state.selection_anchor = null;
        self.state.scroll_y = 0;
        self.state.dirty = false;
        // Nothing of the previous document survives into this one. The buffers are reused —
        // they are this harness's own — but the layout laid out over them is not.
        self.layout.invalidate();
        self.state.assertInvariant();
    }

    /// One real frame. Everything else here is sugar over this.
    pub fn frame(self: *Harness, in: Input) !void {
        theme.active = test_theme;
        self.recorder.reset();
        var canvas = self.recorder.canvas(self.canvasSize());
        try ted.frame(self.alloc, &canvas, in, &self.state, &self.layout);
        if (self.recorder.oom) return error.OutOfMemory;
        self.rasterise();
    }

    /// A frame with nothing happening, to settle the view after a state change.
    pub fn idle(self: *Harness) !void {
        try self.frame(.{});
    }

    /// Type a string, one frame per character — which is how it arrives from the host, and what
    /// the undo coalescing rules are written against.
    pub fn typeText(self: *Harness, s: []const u8) !void {
        var it = (try std.unicode.Utf8View.init(s)).iterator();
        while (it.nextCodepointSlice()) |ch| try self.frame(.{ .text = ch });
    }

    /// Click at a character cell: press one frame, release the next.
    pub fn clickCell(self: *Harness, col: usize, row: usize) !void {
        try self.pressCell(col, row);
        try self.releaseCell(col, row);
    }

    /// Press at a cell and hold. The gesture is left open for `dragCell`/`releaseCell`.
    pub fn pressCell(self: *Harness, col: usize, row: usize) !void {
        try self.frame(.{ .mouse = self.cellOrigin(col, row), .mouse_down = true });
    }

    /// Move to a cell with the button still down — one frame, as a real drag arrives.
    pub fn dragCell(self: *Harness, col: usize, row: usize) !void {
        try self.frame(.{ .mouse = self.cellOrigin(col, row), .mouse_down = true });
    }

    pub fn releaseCell(self: *Harness, col: usize, row: usize) !void {
        try self.frame(.{ .mouse = self.cellOrigin(col, row), .mouse_down = false });
    }

    /// A point in canvas coordinates, for the clicks that deliberately land outside the text —
    /// the ones a cell index cannot name.
    pub fn clickPoint(self: *Harness, p: geom.Point) !void {
        try self.frame(.{ .mouse = p, .mouse_down = true });
        try self.frame(.{ .mouse = p, .mouse_down = false });
    }

    /// Canvas coordinates of a cell's top-left corner.
    pub fn cellOrigin(self: *const Harness, col: usize, row: usize) geom.Point {
        _ = self;
        return .{
            .x = ted.MARGIN_PX + (@as(f64, @floatFromInt(col)) * CELL),
            .y = ted.MARGIN_PX + (@as(f64, @floatFromInt(row)) * CELL),
        };
    }

    // ── Rendering the recording back into a grid ─────────────────────────────────────────────
    fn rasterise(self: *Harness) void {
        @memset(self.grid.cells, ' ');
        @memset(self.grid.attrs, .none);
        @memset(self.grid.styles, .none);

        for (self.recorder.ops.items) |op| switch (op) {
            .push_clip, .pop_clip => {},
            .fill => |f| self.rasteriseFill(f),
            .text => |t| self.rasteriseText(t),
        };
    }

    fn rasteriseFill(self: *Harness, f: Op.Fill) void {
        const attr: Attr = if (isRole(f.color, test_theme.caret))
            .caret
        else if (isRole(f.color, test_theme.highlight))
            .selection
        else if (isRole(f.color, test_theme.quote_rule))
            .quote_rule
        else if (isRole(f.color, test_theme.code_bg))
            .code_bg
        else
            return; // the page background, or something with no role: nothing to mark

        const row = self.rowOf(f.rect.y) orelse return;
        const col0 = self.colOf(f.rect.x) orelse return;
        // A decoration narrower than a cell marks the one cell it starts in. The caret is two
        // points wide and the quote rule three — they are positions, not spans, and rounding
        // their width up to a cell would smear them across columns they do not occupy.
        const span: usize = if (f.rect.w < CELL) 1 else @intFromFloat(@round(f.rect.w / CELL));

        for (0..span) |i| {
            const col = col0 + i;
            if (col >= self.grid.cols) break;
            const cell = self.grid.at(col, row);
            if (precedes(attr, self.grid.attrs[cell])) self.grid.attrs[cell] = attr;
        }
    }

    fn rasteriseText(self: *Harness, t: Op.Text) void {
        const row = self.rowOf(t.rect.y) orelse return;
        const col0 = self.colOf(t.rect.x) orelse return;

        const style = styleOf(t.font, t.color);
        var it = (std.unicode.Utf8View.init(t.utf8) catch return).iterator();
        var col = col0;
        while (it.nextCodepoint()) |cp| : (col += 1) {
            if (col >= self.grid.cols) break;
            self.grid.cells[self.grid.at(col, row)] = cp;
            self.grid.styles[self.grid.at(col, row)] = style;
        }
    }

    /// Cell row for a canvas y, or null when it falls outside the viewport. A row scrolled to a
    /// fractional offset lands between cells and is placed in the nearer one — the grid cannot
    /// express sub-cell offsets, which is what the op log is for.
    fn rowOf(self: *const Harness, y: f64) ?usize {
        const r = @round((y - ted.MARGIN_PX) / CELL);
        if (r < 0 or r >= @as(f64, @floatFromInt(self.grid.rows))) return null;
        return @intFromFloat(r);
    }

    fn colOf(self: *const Harness, x: f64) ?usize {
        const c = @round((x - ted.MARGIN_PX) / CELL);
        if (c < 0 or c >= @as(f64, @floatFromInt(self.grid.cols))) return null;
        return @intFromFloat(c);
    }

    // ── The recording ────────────────────────────────────────────────────────────────────────
    /// Every op from the last frame, in draw order.
    ///
    /// For the assertions a grid cannot make. A grid quantises to whole cells, so it is blind to
    /// exactly the things that matter when scrolling by points rather than by rows: a row half a
    /// cell above where it was still lands in the same cell. It also cannot show draw order, and
    /// it flattens a run's font down to one style mark.
    pub fn ops(self: *const Harness) []const Op {
        return self.recorder.ops.items;
    }

    /// The first run drawn with exactly this text, or null. Runs are the render pass's quanta,
    /// so a fragment split by a token boundary or a wrap is looked up by its own piece.
    pub fn findText(self: *const Harness, needle: []const u8) ?Op.Text {
        for (self.ops()) |op| switch (op) {
            .text => |t| if (std.mem.eql(u8, t.utf8, needle)) return t,
            else => {},
        };
        return null;
    }

    /// Where the caret was drawn, in canvas points. Null when it was not drawn at all — which is
    /// legitimate, a wheel scroll may leave it off screen.
    pub fn caret(self: *const Harness) ?geom.Rect {
        for (self.ops()) |op| switch (op) {
            .fill => |f| if (isRole(f.color, test_theme.caret)) return f.rect,
            else => {},
        };
        return null;
    }

    // ── Debugging ────────────────────────────────────────────────────────────────────────────
    /// Print both planes and the recording that produced them, to stderr.
    ///
    /// For when a grid assertion fails and the diff alone doesn't say why. The two planes are
    /// interleaved per row so text and decoration line up under one ruler, and every op is
    /// listed with its role resolved and its cell worked out.
    ///
    /// That last part is the reason this exists rather than being a `std.debug.print` in the
    /// test: an op landing outside the viewport is simply *absent* from the grid, which looks
    /// identical to one that was never drawn. Here it shows up as `OFF-GRID`, with the
    /// coordinates that put it there.
    pub fn dump(self: *const Harness) void {
        const p = std.debug.print;
        p("\n── harness ── doc={d}B caret={d} scroll_y={d:.2} ops={d}\n", .{
            self.state.text_len,
            self.state.cursor_i,
            self.state.scroll_y,
            self.recorder.ops.items.len,
        });

        // Column ruler: tens above, units below.
        p("        ", .{});
        for (0..self.grid.cols) |c| p("{c}", .{if (c % 10 == 0) @as(u8, '0') + @as(u8, @intCast((c / 10) % 10)) else ' '});
        p("\n        ", .{});
        for (0..self.grid.cols) |c| p("{d}", .{c % 10});
        p("\n", .{});

        for (0..self.grid.rows) |row| {
            p("  {d:>3} t |", .{row});
            for (0..self.grid.cols) |col| {
                var buf: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(self.grid.cells[self.grid.at(col, row)], &buf) catch 1;
                p("{s}", .{buf[0..n]});
            }
            p("|\n      a |", .{});
            for (0..self.grid.cols) |col| p("{c}", .{@intFromEnum(self.grid.attrs[self.grid.at(col, row)])});
            p("|\n      s |", .{});
            for (0..self.grid.cols) |col| p("{c}", .{@intFromEnum(self.grid.styles[self.grid.at(col, row)])});
            p("|\n", .{});
        }

        p("  ops:\n", .{});
        var buf: [64]u8 = undefined;
        for (self.recorder.ops.items) |op| switch (op) {
            .push_clip => |r| p("    clip+  {s:<10} {s}\n", .{ "", self.fmtRect(&buf, r) }),
            .pop_clip => p("    clip-\n", .{}),
            .fill => |f| p("    fill   {s:<10} {s}\n", .{ roleName(f.color), self.fmtRect(&buf, f.rect) }),
            .text => |t| p("    text   {s:<10} {s}  \"{s}\"\n", .{ fontName(t.font), self.fmtRect(&buf, t.rect), t.utf8 }),
        };
    }

    /// A rect as both its cell and its points, or `OFF-GRID` when its origin falls outside the
    /// viewport — which for a fill or a text run means it contributes nothing to either plane,
    /// and is the whole reason to look at this listing rather than at the grid.
    ///
    /// Writes into the caller's buffer so the result is exactly as long as it needs to be; the
    /// alignment belongs to the format string, not in here.
    fn fmtRect(self: *const Harness, buf: []u8, r: geom.Rect) []const u8 {
        const where = if (self.colOf(r.x)) |col| blk: {
            const row = self.rowOf(r.y) orelse break :blk null;
            break :blk .{ col, row };
        } else null;

        return if (where) |cell|
            std.fmt.bufPrint(buf, "cell({d:>2},{d:>2}) pt({d:.0},{d:.0} {d:.0}x{d:.0})", .{
                cell[0], cell[1], r.x, r.y, r.w, r.h,
            }) catch "?"
        else
            std.fmt.bufPrint(buf, "OFF-GRID     pt({d:.0},{d:.0} {d:.0}x{d:.0})", .{
                r.x, r.y, r.w, r.h,
            }) catch "?";
    }

    // ── Assertions ───────────────────────────────────────────────────────────────────────────
    /// The text plane: what the user would read off the screen.
    pub fn expectGrid(self: *Harness, want: []const u8) !void {
        var got: std.ArrayList(u8) = .{};
        defer got.deinit(self.alloc);
        for (0..self.grid.rows) |row| {
            if (row > 0) try got.append(self.alloc, '\n');
            for (0..self.grid.cols) |col| {
                var buf: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(self.grid.cells[self.grid.at(col, row)], &buf) catch 1;
                try got.appendSlice(self.alloc, buf[0..n]);
            }
        }
        try expectPicture(self.alloc, want, got.items, ' ');
    }

    /// The attribute plane: caret, selection, panels and rules, one character per cell. See
    /// `Attr` for the legend and the precedence rule.
    pub fn expectAttrs(self: *Harness, want: []const u8) !void {
        var got: std.ArrayList(u8) = .{};
        defer got.deinit(self.alloc);
        for (0..self.grid.rows) |row| {
            if (row > 0) try got.append(self.alloc, '\n');
            for (0..self.grid.cols) |col| {
                try got.append(self.alloc, @intFromEnum(self.grid.attrs[self.grid.at(col, row)]));
            }
        }
        try expectPicture(self.alloc, want, got.items, @intFromEnum(Attr.none));
    }

    /// The style plane: how each cell's text was drawn, one character per cell. See `StyleMark`
    /// for the legend.
    ///
    /// This is the half of the render pass the text plane cannot show — a bold `b` and a plain
    /// `b` are the same glyph in a grid. Marks come off the recorded draw call's font and color,
    /// so they are what the shaper would actually have been handed.
    pub fn expectStyles(self: *Harness, want: []const u8) !void {
        var got: std.ArrayList(u8) = .{};
        defer got.deinit(self.alloc);
        for (0..self.grid.rows) |row| {
            if (row > 0) try got.append(self.alloc, '\n');
            for (0..self.grid.cols) |col| {
                try got.append(self.alloc, @intFromEnum(self.grid.styles[self.grid.at(col, row)]));
            }
        }
        try expectPicture(self.alloc, want, got.items, @intFromEnum(StyleMark.none));
    }
};

/// Which of two attributes on the same cell is shown. Lower rank wins.
fn precedes(a: Attr, b: Attr) bool {
    return attrRank(a) < attrRank(b);
}

fn attrRank(a: Attr) usize {
    return switch (a) {
        .caret => 0,
        .selection => 1,
        .quote_rule => 2,
        .code_bg => 3,
        .none => 4,
    };
}

/// Compare two pictures, ignoring the padding a test should not have to write: `pad` runs at the
/// end of a row, and blank rows at the bottom of the grid. A test states the interesting
/// rectangle and nothing else.
fn expectPicture(alloc: Allocator, want: []const u8, got: []const u8, pad: u8) !void {
    const w = try trimPicture(alloc, want, pad);
    defer alloc.free(w);
    const g = try trimPicture(alloc, got, pad);
    defer alloc.free(g);
    try std.testing.expectEqualStrings(w, g);
}

fn trimPicture(alloc: Allocator, s: []const u8, pad: u8) ![]u8 {
    var rows: std.ArrayList([]const u8) = .{};
    defer rows.deinit(alloc);
    var it = std.mem.splitScalar(u8, s, '\n');
    while (it.next()) |row| try rows.append(alloc, std.mem.trimRight(u8, row, &[_]u8{pad}));

    var end = rows.items.len;
    while (end > 0 and rows.items[end - 1].len == 0) end -= 1;

    return std.mem.join(alloc, "\n", rows.items[0..end]);
}
