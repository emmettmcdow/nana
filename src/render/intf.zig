//! C ABI for the render scaffold. These `export fn`s are compiled into libnana.a
//! (referenced from src/intf.zig) and called by the Swift `NanaCanvasView`.
//!
//! The boundary is deliberately tiny: init once, frame() each display refresh with a
//! CGContext + size + input snapshot, deinit on teardown. All UTF-16 <-> UTF-8 index
//! conversion (when text editing arrives) belongs in render/utf.zig, not here.

const coretext = @import("coretext.zig");
const input_mod = @import("input.zig");
const app = @import("app.zig");
const runtime = @import("../runtime.zig");
const session = @import("../session.zig");
const settings = @import("../settings.zig");
const theme = @import("theme.zig");
const std = @import("std");

const AppState = app.AppState;
const CGContextRef = coretext.CGContextRef;

/// Mirror of the C `NanaInput` struct declared in include/nana.h. Field order and
/// types must match exactly (C ABI layout).
const NanaInput = extern struct {
    mouse_x: f64,
    mouse_y: f64,
    mouse_down: bool,
    modifiers: c_uint,
    /// Whether the host's window is currently in a dark appearance. Resolved host-side from
    /// the user's preference plus the system setting, since that same answer drives the
    /// titlebar; we just match our palette to it.
    system_dark: bool,
    scroll_dy: f64,
    /// Borrowed for the duration of the call. A pointer rather than a fixed array so a paste
    /// isn't capped at some arbitrary size. Null when `text_len` is 0.
    text_utf8: ?[*]const u8,
    text_len: c_uint,
    backspaces: c_uint,
    escapes: c_uint,
    ups: c_uint,
    downs: c_uint,
    lefts: c_uint,
    rights: c_uint,
};

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const GAP_BUF_SIZE = 4000; // 4Kb
var state: ?AppState = null;
/// The editor's cross-frame scratch, allocated once and kept for the life of the process. Held
/// here beside `state` because this is the layer that drives the frame loop, and `ted.frame` is
/// handed it rather than reaching for one of its own.
var layout: ?app.Layout = null;
var settings_store: settings.Settings = .{};

/// Menu commands that have come in since the last frame, folded into that frame's `Input` and
/// cleared once it has consumed them.
///
/// Accumulated here for the same reason the Swift host accumulates keystrokes: AppKit dispatches
/// a menu item whenever it likes, and the editor may only touch the document inside `frame`.
/// The redraw is timer-driven at 60Hz, so nothing waits longer than a frame.
var pending: input_mod.Commands = .{};

/// The note listing shown in the file list, rebuilt only when it could have changed — walking
/// the workspace every frame at 60Hz would be absurd.
const MAX_LISTED_NOTES = 512;
var note_entries: [MAX_LISTED_NOTES]app.NoteEntry = undefined;
var note_count: usize = 0;
var note_arena: ?std.heap.ArenaAllocator = null;
var notes_stale: bool = true;

/// When the query last changed, or null when it has already been acted on. Searching runs the
/// query through the embedder, which is far too expensive to do per keystroke — let alone the
/// sixty times a second an idle frame loop would otherwise manage.
var query_changed_ms: ?i64 = null;
const SEARCH_DEBOUNCE_MS: i64 = 200;

/// Rebuild the listing: everything in the workspace when there is no query, or the best
/// matches when there is.
fn refreshNotes(query: []const u8) void {
    if (note_arena == null) note_arena = std.heap.ArenaAllocator.init(gpa.allocator());
    _ = note_arena.?.reset(.retain_capacity);
    const arena = note_arena.?.allocator();

    note_count = blk: {
        if (query.len == 0) {
            break :blk session.listNotes(arena, &note_entries) catch |err| {
                std.log.err("could not list notes: {}", .{err});
                break :blk 0;
            };
        }
        break :blk session.searchNotes(arena, query, &note_entries) catch |err| {
            std.log.err("search for '{s}' failed: {}", .{ query, err });
            break :blk 0;
        };
    };
    notes_stale = false;
}

/// Workspace used until the user picks one. Resolved relative to `$HOME`, which under the app
/// sandbox is the container — where a sandboxed app should be writing anyway. Deliberately
/// resolved here rather than passed in, so the Swift shim needs no say in it.
const DEFAULT_WORKSPACE = "Documents/nana";

/// Open `dir_path` as the workspace and put a fresh note in the editor. Creates the directory
/// if it isn't there yet.
fn openWorkspace(dir_path: []const u8) !void {
    const allocator = gpa.allocator();

    // Intermediate components may not exist on a first run.
    std.fs.makeDirAbsolute(dir_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        error.FileNotFound => try std.fs.cwd().makePath(dir_path),
        else => return err,
    };

    {
        runtime.mutex.lock();
        defer runtime.mutex.unlock();
        if (!runtime.isOpen()) {
            var buf: [std.posix.PATH_MAX]u8 = undefined;
            runtime.open(try runtime.openDir(&buf, dir_path)) catch |err| {
                std.log.err("workspace '{s}' failed to open: {}", .{ dir_path, err });
                return err;
            };
        }
    }

    try session.openNew(allocator, &(state.?));
    notes_stale = true;
}

/// Where notes go when the user hasn't chosen anywhere. Caller owns the result.
fn defaultWorkspacePath(alloc: std.mem.Allocator) ![]u8 {
    const home = try std.process.getEnvVarOwned(alloc, "HOME");
    defer alloc.free(home);
    return std.fs.path.join(alloc, &.{ home, DEFAULT_WORKSPACE });
}

/// `path` null means "wherever the default is". The host passes a path when it has a workspace
/// the user picked earlier — handed in at init rather than switched to afterwards, so the
/// default directory is never touched for someone who doesn't use it.
export fn nana_render_init(path: ?[*:0]const u8) void {
    settings_store = settings.load(gpa.allocator());
    state = AppState.init(gpa.allocator().alloc(u8, GAP_BUF_SIZE) catch unreachable);
    layout = app.Layout.init(gpa.allocator()) catch unreachable;

    const allocator = gpa.allocator();
    const chosen: ?[]const u8 = if (path) |p| std.mem.sliceTo(p, 0) else null;
    const dir_path = chosen orelse (defaultWorkspacePath(allocator) catch {
        std.log.err("no workspace; edits will not be saved", .{});
        seedDemoDocument();
        return;
    });
    defer if (chosen == null) allocator.free(dir_path);

    openWorkspace(dir_path) catch |err| {
        std.log.err("no workspace; edits will not be saved: {}", .{err});
        seedDemoDocument();
    };
}

/// Switch to a different workspace. The host is responsible for having gained access to the
/// directory first — under the sandbox that means resolving a security-scoped bookmark, which
/// is Foundation's business and not ours.
///
/// Returns whether the switch took. On failure the editor is left with no workspace open rather
/// than silently still writing to the old one.
export fn nana_render_set_workspace(path: [*:0]const u8) bool {
    const allocator = gpa.allocator();
    const dir_path = std.mem.sliceTo(path, 0);

    if (state) |*s| {
        session.flush(s); // don't lose edits still inside the autosave quiet period
        app.deinitHistory(s, allocator); // undo must not reach into another workspace
    }
    session.close();
    {
        runtime.mutex.lock();
        defer runtime.mutex.unlock();
        runtime.close();
    }
    invalidateNotes();

    openWorkspace(dir_path) catch |err| {
        std.log.err("could not switch to workspace '{s}': {}", .{ dir_path, err });
        return false;
    };
    return true;
}

/// Drop the cached listing. Its strings live in an arena tied to the workspace that produced
/// them, so they must not outlive it.
fn invalidateNotes() void {
    if (note_arena) |*a| _ = a.reset(.retain_capacity);
    note_count = 0;
    notes_stale = true;
}

export fn nana_render_deinit() void {
    if (state) |*s| {
        session.flush(s);
        app.deinitHistory(s, gpa.allocator());
    }
    if (layout) |*l| l.deinit(gpa.allocator());
    layout = null;
    session.close();
    runtime.mutex.lock();
    defer runtime.mutex.unlock();
    runtime.close();
}

/// Fallback content for when no workspace could be opened, so the canvas still shows something
/// rather than a blank page with no explanation.
fn seedDemoDocument() void {
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

export fn nana_render_frame(ctx: CGContextRef, width: f64, height: f64, in: *const NanaInput) void {
    var backend = coretext.CoreTextCanvas{ .ctx = ctx };
    var canvas = backend.canvas(.{ .w = width, .h = height });

    const text: []const u8 = if (in.text_utf8) |p| p[0..@as(usize, in.text_len)] else &.{};

    const input = input_mod.Input{
        .mouse = .{ .x = @max(in.mouse_x, 0), .y = @max(in.mouse_y, 0) },
        .mouse_down = in.mouse_down,
        .modifiers = @intCast(in.modifiers),
        .scroll_dy = in.scroll_dy,
        .text = text,
        .backspaces = @intCast(in.backspaces),
        .escapes = @intCast(in.escapes),
        .ups = @intCast(in.ups),
        .downs = @intCast(in.downs),
        .lefts = @intCast(in.lefts),
        .rights = @intCast(in.rights),
        .cmds = pending,
    };
    // Handed off, so the queue starts empty again. Nothing accumulates across frames: a command
    // the editor accepts is applied by this frame — `applyCommands` runs unconditionally rather
    // than competing with the keyboard — and one it doesn't is meant to be thrown away.
    pending = .{};

    // Cheap enough to redo per frame, and it means an appearance change takes effect on the
    // next redraw with no invalidation to remember.
    theme.active = theme.forAppearance(in.system_dark, settings_store.font_size);

    // A settled query becomes a pending refresh.
    if (query_changed_ms) |t| {
        if (std.time.milliTimestamp() - t >= SEARCH_DEBOUNCE_MS) {
            notes_stale = true;
            query_changed_ms = null;
        }
    }
    // The listing is only rebuilt when the list is open and something has invalidated it.
    if (state.?.list_visible and notes_stale) refreshNotes(state.?.query());
    const notes = if (state.?.list_visible) note_entries[0..note_count] else &[_]app.NoteEntry{};

    const actions = app.frame(gpa.allocator(), &canvas, input, &(state.?), &(layout.?), notes) catch unreachable;
    // After the frame, so it sees this frame's edits.
    session.tick(&(state.?));

    applyActions(actions, notes);
}

/// Carry out what the frame asked for. This is the half of the editor that knows about files;
/// `app.zig` only knows that a button was clicked.
fn applyActions(actions: app.FrameActions, notes: []const app.NoteEntry) void {
    const s = &(state.?);
    const allocator = gpa.allocator();

    if (actions.open_note) |i| {
        if (i < notes.len) {
            // Flush first: switching away must not lose edits still inside the quiet period.
            session.flush(s);
            session.openPath(allocator, s, notes[i].path) catch |err| {
                std.log.err("could not open '{s}': {}", .{ notes[i].path, err });
            };
            app.deinitHistory(s, allocator); // undo does not reach across documents
        }
    }

    // Start (or restart) the quiet period rather than searching straight away.
    if (actions.query_changed) query_changed_ms = std.time.milliTimestamp();

    if (actions.new_note) {
        session.flush(s);
        session.openNew(allocator, s) catch |err| {
            std.log.err("could not create a note: {}", .{err});
        };
        app.deinitHistory(s, allocator);
        notes_stale = true; // a new note belongs in the listing
    }
}

// ── Selection access ─────────────────────────────────────────────────────────
//
// The host owns the pasteboard (an AppKit service); we own what "selected" means. These are
// called from AppKit action handlers, which run on the main thread — the same thread that
// drives the frame loop — so they never overlap with `nana_render_frame`.
//
// The two that only read answer immediately. The rest queue a command and let the next frame
// carry it out, so no edit lands where the layout cannot see it.

export fn nana_render_selection_len() c_uint {
    const s = state orelse return 0;
    return @intCast(app.selectionLen(s));
}

export fn nana_render_copy_selection(out: [*]u8, out_len: c_uint) c_int {
    const s = state orelse return 0;
    return @intCast(app.copySelection(s, out[0..@as(usize, out_len)]));
}

/// Whether the editor is accepting commands at all.
///
/// It is disabled while the note list is up — `app.frame` masks its input away entirely — and a
/// command queued now would be thrown out by the frame it reached. Refused here instead, so the
/// caller learns that nothing will happen rather than being told it will.
fn editorEnabled() bool {
    const s = state orelse return false;
    return !s.list_visible;
}

/// Copy the selection out and ask for it to be removed next frame.
///
/// The copy cannot wait: the host has a pasteboard to fill in this call and no way to be handed
/// the bytes later. The removal can, and does — it is the half that touches the document.
///
/// Both halves hang on the same check, and that is the point of doing it here rather than
/// leaving the frame to drop the command: copying without removing would silently turn a cut
/// into a copy. Nothing is queued unless the copy succeeded either, so a cut into too small a
/// buffer cannot lose text.
export fn nana_render_cut_selection(out: [*]u8, out_len: c_uint) c_int {
    if (!editorEnabled()) return 0;
    const n = app.copySelection(state.?, out[0..@as(usize, out_len)]);
    if (n == 0) return 0;
    pending.delete_selection = true;
    return @intCast(n);
}

export fn nana_render_select_all() void {
    if (!editorEnabled()) return;
    pending.select_all = true;
}

// ── Undo ─────────────────────────────────────────────────────────────────────
//
// Both return whether anything will be undone/redone, so the host can leave the system beep to
// AppKit when the stack is empty. Predicted rather than observed, since the work happens next
// frame — but nothing else can reach the stacks in between, so a run of presses in one direction
// is answered exactly. Interleaving an undo and a redo inside a single frame is not modelled,
// and is not something a person does in 16ms.

export fn nana_render_undo() bool {
    if (!editorEnabled()) return false;
    if (pending.undos >= state.?.history.undo_stack.items.len) return false;
    pending.undos += 1;
    return true;
}

export fn nana_render_redo() bool {
    if (!editorEnabled()) return false;
    if (pending.redos >= state.?.history.redo_stack.items.len) return false;
    pending.redos += 1;
    return true;
}

// ── Settings ─────────────────────────────────────────────────────────────────

export fn nana_render_font_size() f64 {
    return settings_store.font_size;
}

/// Set the type size and persist it. Clamped, so neither a runaway stepper nor a hand-edited
/// settings file can produce an unreadable editor.
export fn nana_render_set_font_size(size: f64) void {
    settings_store.font_size = std.math.clamp(size, theme.MIN_FONT_SIZE, theme.MAX_FONT_SIZE);
    settings.save(gpa.allocator(), settings_store);
}

/// Nudge the type size, for the menu's increase/decrease commands.
export fn nana_render_adjust_font_size(delta: f64) void {
    nana_render_set_font_size(settings_store.font_size + delta);
}
