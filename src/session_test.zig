//! End-to-end check that edits reach disk. Lives outside test_root.zig on purpose: it needs the
//! real Runtime (vector DB + embedder), which the pure-logic render tests must stay free of.
const std = @import("std");
const runtime = @import("runtime.zig");
const session = @import("session.zig");
const app = @import("render/app.zig");
const expectEqualStrings = std.testing.expectEqualStrings;
const expectEqual = std.testing.expectEqual;
const expect = std.testing.expect;

test "an edited document is written back to its note" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const alloc = std.testing.allocator;

    runtime.mutex.lock();
    try runtime.open(tmp.dir);
    runtime.mutex.unlock();
    defer {
        session.close();
        runtime.mutex.lock();
        runtime.close();
        runtime.mutex.unlock();
    }

    var state = app.AppState.init(try alloc.alloc(u8, 64));
    defer alloc.free(state.gap_buf);

    try session.openNew(alloc, &state);
    const path = session.currentPath().?;
    try std.testing.expect(path.len > 0);

    // Type into the buffer the way handleInput does.
    const typed = "hello from the editor";
    for (typed) |b| {
        state.gap_buf[state.cursor_i] = b;
        state.cursor_i += 1;
        state.text_len += 1;
    }
    state.dirty = true;

    // tick() sees the edit and starts the quiet period rather than saving immediately.
    session.tick(&state);
    var read_buf: [256]u8 = undefined;
    {
        runtime.mutex.lock();
        defer runtime.mutex.unlock();
        const n = try runtime.get().?.readAll(path, &read_buf);
        try expectEqual(@as(usize, 0), n); // nothing written yet — still "typing"
    }

    // flush() forces the pending write out.
    session.flush(&state);
    {
        runtime.mutex.lock();
        defer runtime.mutex.unlock();
        const n = try runtime.get().?.readAll(path, &read_buf);
        try expectEqualStrings(typed, read_buf[0..n]);
    }
}

test "a document round-trips through openPath, gap included" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const alloc = std.testing.allocator;

    runtime.mutex.lock();
    try runtime.open(tmp.dir);
    runtime.mutex.unlock();
    defer {
        session.close();
        runtime.mutex.lock();
        runtime.close();
        runtime.mutex.unlock();
    }

    var state = app.AppState.init(try alloc.alloc(u8, 8)); // deliberately too small
    defer alloc.free(state.gap_buf);

    try session.openNew(alloc, &state);
    var path_buf: [std.posix.PATH_MAX]u8 = undefined;
    const path = path_buf[0..session.currentPath().?.len];
    @memcpy(path, session.currentPath().?);

    // Longer than the initial gap buffer, so this also exercises the grow path.
    const body = "# Title\n\nA line of prose that is comfortably longer than eight bytes.\n";
    {
        runtime.mutex.lock();
        defer runtime.mutex.unlock();
        try runtime.get().?.writeAll(path, body);
    }

    try session.openPath(alloc, &state, path);
    try expectEqual(body.len, state.text_len);
    try expectEqual(body.len, state.cursor_i); // cursor lands at the end
    try expectEqual(state.gap_buf.len, state.gap_end); // ...so the gap is the whole tail
    try expectEqualStrings(body, state.gap_buf[0..body.len]);

    // Put the cursor mid-document so the gap sits in the middle, then confirm the save path
    // stitches both halves back together rather than writing only the head.
    state.cursor_i = 4;
    const tail_len = state.text_len - state.cursor_i;
    state.gap_end = state.gap_buf.len - tail_len;
    std.mem.copyBackwards(u8, state.gap_buf[state.gap_end..], body[4..]);
    state.dirty = true;
    session.tick(&state);
    session.flush(&state);

    var read_buf: [256]u8 = undefined;
    {
        runtime.mutex.lock();
        defer runtime.mutex.unlock();
        const n = try runtime.get().?.readAll(path, &read_buf);
        try expectEqualStrings(body, read_buf[0..n]);
    }
}

test "listNotes finds the workspace's notes, and they can be opened by path" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const alloc = std.testing.allocator;

    runtime.mutex.lock();
    try runtime.open(tmp.dir);
    runtime.mutex.unlock();
    defer {
        session.close();
        runtime.mutex.lock();
        runtime.close();
        runtime.mutex.unlock();
    }

    var state = app.AppState.init(try alloc.alloc(u8, 64));
    defer alloc.free(state.gap_buf);

    // Two notes with distinct content, each saved.
    try session.openNew(alloc, &state);
    var first_path_buf: [std.posix.PATH_MAX]u8 = undefined;
    const first_path = first_path_buf[0..session.currentPath().?.len];
    @memcpy(first_path, session.currentPath().?);
    for ("# Alpha") |b| {
        state.gap_buf[state.cursor_i] = b;
        state.cursor_i += 1;
        state.text_len += 1;
    }
    state.dirty = true;
    session.tick(&state);
    session.flush(&state);

    try session.openNew(alloc, &state);
    const second_path = session.currentPath().?;
    try expect(!std.mem.eql(u8, first_path, second_path));

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    var entries: [16]app.NoteEntry = undefined;
    const n = try session.listNotes(arena.allocator(), &entries);

    // Only the note with content. `create` reserves a name without writing a file, and the
    // store's index skips empty ones — so a brand-new note stays out of the list until it has
    // something in it, rather than littering it with blanks.
    try expectEqual(@as(usize, 1), n);
    try expect(!std.mem.eql(u8, entries[0].path, second_path));

    // The listed note carries the title drawn from its heading.
    var found: ?app.NoteEntry = null;
    for (entries[0..n]) |e| {
        if (std.mem.eql(u8, e.path, first_path)) found = e;
    }
    try expect(found != null);
    try expectEqualStrings("Alpha", found.?.title);

    // Opening it from the listing brings its content back into the editor.
    try session.openPath(alloc, &state, found.?.path);
    try expectEqual(@as(usize, 7), state.text_len);
    try expectEqualStrings("# Alpha", state.gap_buf[0..7]);
}

test "searchNotes returns entries with paths and titles filled in" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const alloc = std.testing.allocator;

    runtime.mutex.lock();
    try runtime.open(tmp.dir);
    runtime.mutex.unlock();
    defer {
        session.close();
        runtime.mutex.lock();
        runtime.close();
        runtime.mutex.unlock();
    }

    // Whether a given query ranks a given note highly is the vector store's business, and
    // root.zig covers it. What matters here is the wiring: that a hit comes back as a
    // NoteEntry the file list can actually draw. So drop the similarity thresholds and assert
    // on the shape of the result rather than on relevance.
    runtime.get().?.vectors.embedder.threshold = 0.0;
    runtime.get().?.vectors.embedder.strict_threshold = 0.0;

    var state = app.AppState.init(try alloc.alloc(u8, 512));
    defer alloc.free(state.gap_buf);

    try session.openNew(alloc, &state);
    const body = "# Sourdough\nMixing flour and water to bake bread at home.";
    for (body) |b| {
        state.gap_buf[state.cursor_i] = b;
        state.cursor_i += 1;
        state.text_len += 1;
    }
    state.dirty = true;
    session.tick(&state);
    session.flush(&state);

    // Embedding is asynchronous — `writeAll` hands off to `embedTextAsync` and returns. A note
    // is therefore not searchable the instant it is saved, which is worth knowing about the
    // feature and not only about this test.
    std.Thread.sleep(2 * std.time.ns_per_s);

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    var entries: [16]app.NoteEntry = undefined;
    const n = try session.searchNotes(arena.allocator(), "baking bread", &entries);

    try expect(n >= 1);
    try expectEqualStrings("Sourdough", entries[0].title);
    try expect(std.mem.endsWith(u8, entries[0].path, ".md"));
}

test "a multi-chunk note appears once in the results, not once per chunk" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const alloc = std.testing.allocator;

    runtime.mutex.lock();
    try runtime.open(tmp.dir);
    runtime.mutex.unlock();
    defer {
        session.close();
        runtime.mutex.lock();
        runtime.close();
        runtime.mutex.unlock();
    }
    runtime.get().?.vectors.embedder.threshold = 0.0;
    runtime.get().?.vectors.embedder.strict_threshold = 0.0;

    var state = app.AppState.init(try alloc.alloc(u8, 8192));
    defer alloc.free(state.gap_buf);

    // Long enough to be embedded as several chunks. Each chunk is its own vector, so a
    // chunk-level search returns this one note over and over.
    try session.openNew(alloc, &state);
    const para =
        "Mixing flour and water to bake bread at home takes patience. " ++
        "The starter needs feeding every day before it is lively enough to raise a loaf. " ++
        "Shaping the dough well matters as much as the bake itself. ";
    for (0..8) |_| {
        for (para) |b| {
            state.gap_buf[state.cursor_i] = b;
            state.cursor_i += 1;
            state.text_len += 1;
        }
    }
    state.dirty = true;
    session.tick(&state);
    session.flush(&state);

    std.Thread.sleep(2 * std.time.ns_per_s); // embedding is async

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    var entries: [64]app.NoteEntry = undefined;
    const n = try session.searchNotes(arena.allocator(), "baking bread", &entries);
    try expect(n >= 1);

    // No path may repeat: one row per note is the whole point of a file list.
    for (entries[0..n], 0..) |a, i| {
        for (entries[0..n], 0..) |b, j| {
            if (i == j) continue;
            try expect(!std.mem.eql(u8, a.path, b.path));
        }
    }
}

test "switching workspaces leaves the old one's notes behind" {
    var a_dir = std.testing.tmpDir(.{ .iterate = true });
    defer a_dir.cleanup();
    var b_dir = std.testing.tmpDir(.{ .iterate = true });
    defer b_dir.cleanup();
    const alloc = std.testing.allocator;

    var state = app.AppState.init(try alloc.alloc(u8, 512));
    defer alloc.free(state.gap_buf);

    // Workspace A: one saved note.
    runtime.mutex.lock();
    try runtime.open(a_dir.dir);
    runtime.mutex.unlock();

    try session.openNew(alloc, &state);
    for ("# In workspace A") |b| {
        state.gap_buf[state.cursor_i] = b;
        state.cursor_i += 1;
        state.text_len += 1;
    }
    state.dirty = true;
    session.tick(&state);
    session.flush(&state);

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    var entries: [16]app.NoteEntry = undefined;
    try expectEqual(@as(usize, 1), try session.listNotes(arena.allocator(), &entries));

    // The switch, as `nana_render_set_workspace` performs it.
    session.flush(&state);
    session.close();
    runtime.mutex.lock();
    runtime.close();
    runtime.mutex.unlock();

    runtime.mutex.lock();
    try runtime.open(b_dir.dir);
    runtime.mutex.unlock();
    defer {
        session.close();
        runtime.mutex.lock();
        runtime.close();
        runtime.mutex.unlock();
    }
    try session.openNew(alloc, &state);

    // B is its own workspace: A's note must not be listed here, and the editor starts blank.
    _ = arena.reset(.retain_capacity);
    try expectEqual(@as(usize, 0), try session.listNotes(arena.allocator(), &entries));
    try expectEqual(@as(usize, 0), state.text_len);

    // ...and A still has its note when we go back.
    session.close();
    runtime.mutex.lock();
    runtime.close();
    try runtime.open(a_dir.dir);
    runtime.mutex.unlock();
    _ = arena.reset(.retain_capacity);
    const n = try session.listNotes(arena.allocator(), &entries);
    try expectEqual(@as(usize, 1), n);
    try expectEqualStrings("In workspace A", entries[0].title);
}
