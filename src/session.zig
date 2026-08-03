//! The editing session: which note is open, and getting it on and off disk.
//!
//! This is the layer between the renderer and the note store. `render/app.zig` stays a pure
//! text editor over a gap buffer and knows nothing about files; `root.zig` stays a note store
//! and knows nothing about cursors. Neither imports the other — this module imports both, which
//! is also what keeps `zig build test-render` free of the vector DB and the embedder.
//!
//! Saving is deferred rather than immediate. Every keystroke mutating a file would mean a write
//! (and an embed) per character, so edits are collected and flushed once typing pauses.

/// How long the document must go unmodified before it is written back.
const AUTOSAVE_QUIET_MS: i64 = 1000;

/// Notes are capped by what the store's own read path accepts.
const MAX_NOTE_BYTES: usize = 1024 * 1024;

/// Slack allocated past a loaded note's length, so the first edits don't immediately realloc.
const GAP_HEADROOM: usize = 4096;

var current_path_buf: [std.posix.PATH_MAX]u8 = undefined;
var current_path_len: usize = 0;

/// Wall-clock time of the last observed edit, or null when there is nothing unsaved. Doubles as
/// the "dirty" flag: the document is unsaved exactly when this is set.
var last_edit_ms: ?i64 = null;

var open_note: bool = false;

/// The note currently being edited, or null when none is open.
pub fn currentPath() ?[]const u8 {
    return if (open_note) current_path_buf[0..current_path_len] else null;
}

/// Create a fresh note and load it into `state`, replacing whatever was there.
///
/// Matches the behaviour on main, which created a new note on every launch — so a launch always
/// starts on a blank page, with earlier notes reachable through the file list.
pub fn openNew(allocator: Allocator, state: *AppState) !void {
    runtime.mutex.lock();
    defer runtime.mutex.unlock();
    const rt = runtime.get() orelse return error.NotInitialized;

    const path = try rt.create(&current_path_buf);
    current_path_len = path.len;
    open_note = true;
    last_edit_ms = null;

    // A freshly created note is empty, so there is nothing to read back into the buffer.
    try setDocument(allocator, state, "");
}

/// Open an existing note by path, loading its contents into `state`.
pub fn openPath(allocator: Allocator, state: *AppState, path: []const u8) !void {
    runtime.mutex.lock();
    defer runtime.mutex.unlock();
    const rt = runtime.get() orelse return error.NotInitialized;

    if (path.len > current_path_buf.len) return error.PathTooLong;

    var read_buf = try allocator.alloc(u8, MAX_NOTE_BYTES);
    defer allocator.free(read_buf);
    const n = try rt.readAll(path, read_buf);

    @memcpy(current_path_buf[0..path.len], path);
    current_path_len = path.len;
    open_note = true;
    last_edit_ms = null;

    try setDocument(allocator, state, read_buf[0..n]);
}

/// Every note in the workspace, newest listing first, written into `out`. Returns how many
/// were filled in. Paths and titles are copied into `arena`, which the caller resets when it
/// wants the listing gone — the entries borrow from it.
pub fn listNotes(arena: Allocator, out: []NoteEntry) !usize {
    runtime.mutex.lock();
    defer runtime.mutex.unlock();
    const rt = runtime.get() orelse return 0;

    const paths = try arena.alloc([]const u8, out.len);
    // No note is excluded: the one being edited should still appear in its own list. Note that
    // `index` omits empty files, so a freshly created note stays out of the listing until it
    // has something in it.
    const n = try rt.index(paths, null);
    // `index` hands back paths allocated from the runtime's own allocator, not ours.
    defer for (paths[0..@min(n, out.len)]) |p| rt.allocator.free(p);

    var count: usize = 0;
    for (paths[0..@min(n, out.len)]) |path| {
        var title_buf: [nana.TITLE_BUF_LEN]u8 = undefined;
        const title = rt.title(path, &title_buf) catch "";
        out[count] = .{
            .path = try arena.dupe(u8, path),
            .title = try arena.dupe(u8, title),
        };
        count += 1;
    }
    return count;
}

/// Notes matching `query`, best first, written into `out`. Same ownership rule as `listNotes`:
/// the entries borrow from `arena`.
pub fn searchNotes(arena: Allocator, query: []const u8, out: []NoteEntry) !usize {
    runtime.mutex.lock();
    defer runtime.mutex.unlock();
    const rt = runtime.get() orelse return 0;

    const hits = try arena.alloc(nana.SearchResult, out.len);
    // Deliberately the unique variant. Plain `search` returns a hit per matching *chunk*, and a
    // note is embedded in several — so one note comes back repeatedly, which reads as the same
    // row duplicated down the list once you show titles rather than per-chunk excerpts.
    const n = try rt.searchUnique(query, hits);

    var count: usize = 0;
    for (hits[0..@min(n, out.len)]) |hit| {
        var title_buf: [nana.TITLE_BUF_LEN]u8 = undefined;
        const title = rt.title(hit.path, &title_buf) catch "";
        out[count] = .{
            .path = try arena.dupe(u8, hit.path),
            .title = try arena.dupe(u8, title),
        };
        count += 1;
    }
    return count;
}

/// Call once per frame, after `app.frame`. Notices edits and writes the document back once
/// typing has been quiet for `AUTOSAVE_QUIET_MS`.
pub fn tick(state: *AppState) void {
    if (!open_note) return;

    if (state.dirty) {
        state.dirty = false;
        last_edit_ms = std.time.milliTimestamp();
        return; // still typing — restart the quiet period
    }

    const since_edit = last_edit_ms orelse return;
    if (std.time.milliTimestamp() - since_edit < AUTOSAVE_QUIET_MS) return;

    save(state) catch |err| {
        // A failed autosave must not take the frame loop down: the edit is still in the buffer
        // and the next quiet period will try again.
        std.log.err("autosave failed for '{s}': {}", .{ current_path_buf[0..current_path_len], err });
    };
    last_edit_ms = null;
}

/// Write the document out now, if there is anything unsaved. Call before teardown — `tick`
/// alone can leave up to one quiet period's worth of edits on the floor.
pub fn flush(state: *AppState) void {
    if (!open_note or last_edit_ms == null) return;
    save(state) catch |err| {
        std.log.err("final save failed for '{s}': {}", .{ current_path_buf[0..current_path_len], err });
    };
    last_edit_ms = null;
}

/// Forget the open note. The caller is responsible for having flushed first.
pub fn close() void {
    open_note = false;
    current_path_len = 0;
    last_edit_ms = null;
}

fn save(state: *AppState) !void {
    runtime.mutex.lock();
    defer runtime.mutex.unlock();
    const rt = runtime.get() orelse return error.NotInitialized;

    // `writeAll` takes the document as one slice, but a gap buffer stores it in two pieces
    // either side of the cursor. Stitch them into a scratch buffer to hand over.
    const doc = try contiguous(rt.allocator, state.*);
    defer rt.allocator.free(doc);
    try rt.writeAll(current_path_buf[0..current_path_len], doc);
}

/// The document as one slice. Caller owns the result.
fn contiguous(allocator: Allocator, state: AppState) ![]u8 {
    const out = try allocator.alloc(u8, state.text_len);
    errdefer allocator.free(out);
    @memcpy(out[0..state.cursor_i], state.gap_buf[0..state.cursor_i]);
    const tail_len = state.gap_buf.len - state.gap_end;
    if (tail_len > 0) {
        @memcpy(out[state.cursor_i..][0..tail_len], state.gap_buf[state.gap_end..]);
    }
    return out;
}

/// Replace the editor's document with `content`, growing the gap buffer if it doesn't fit.
/// The cursor lands at the end, so the gap is the whole tail of the buffer.
fn setDocument(allocator: Allocator, state: *AppState, content: []const u8) !void {
    if (state.gap_buf.len < content.len + GAP_HEADROOM) {
        const grown = try allocator.alloc(u8, content.len + GAP_HEADROOM);
        allocator.free(state.gap_buf);
        state.gap_buf = grown;
    }
    @memcpy(state.gap_buf[0..content.len], content);
    state.cursor_i = content.len;
    state.text_len = content.len;
    state.gap_end = state.gap_buf.len;
    state.selection_anchor = null;
    state.scroll_y = 0;
    state.dirty = false;
    state.clear_view = false;
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const runtime = @import("runtime.zig");
const nana = @import("root.zig");
const app = @import("render/app.zig");
const AppState = app.AppState;
const NoteEntry = app.NoteEntry;
