var rt: nana.Runtime = undefined;
var init: bool = false;
var gpa = std.heap.GeneralPurposeAllocator(.{}){};
var persistent_arena: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(gpa.allocator());
var mutex = std.Thread.Mutex{};

const CError = enum(c_int) {
    Success = 0,
    GenericFail = -8,
    DoubleInit = -9,
    NotInit = -10,
    PathTooLong = -11,
    FileNotFound = -12,
    InvalidFiletype = -13,
};

fn refresh_arena() void {
    persistent_arena.deinit();
    persistent_arena = std.heap.ArenaAllocator.init(gpa.allocator());
}

/// Output: CError
export fn nana_init(
    basedir: [*:0]const u8,
) c_int {
    mutex.lock();
    defer mutex.unlock();
    const basedir_slice = std.mem.sliceTo(basedir, 0);
    std.log.info("nana_init {s}", .{basedir_slice});
    if (init) {
        return @intFromEnum(CError.DoubleInit);
    }

    var buf: [PATH_MAX]u8 = undefined;
    const encoded_basedir = if (std.mem.eql(u8, basedir_slice, "./")) val: {
        break :val std.process.getCwd(&buf) catch return @intFromEnum(CError.FileNotFound);
    } else val: {
        break :val std.Uri.percentDecodeBackwards(&buf, basedir_slice);
    };

    const d = std.fs.openDirAbsolute(encoded_basedir, .{ .iterate = true }) catch |err| {
        std.log.err("Failed to access working directory '{s}': {}\n", .{ encoded_basedir, err });
        return @intFromEnum(CError.GenericFail);
    };

    rt = nana.Runtime.init(gpa.allocator(), .{ .basedir = d }) catch |err| {
        std.log.err("Failed to initialize nana: {}\n", .{err});
        return @intFromEnum(CError.GenericFail);
    };

    init = true;

    return @intFromEnum(CError.Success);
}

/// Output: CError
export fn nana_deinit() CError {
    mutex.lock();
    defer mutex.unlock();
    std.log.info("nana_deinit", .{});
    if (!init) {
        return CError.NotInit;
    }
    rt.deinit();
    init = false;
    return CError.Success;
}

/// Output: CError on failure, NoteID if success
export fn nana_create() c_int {
    mutex.lock();
    defer mutex.unlock();
    std.log.info("nana_create", .{});
    if (!init) {
        return @intFromEnum(CError.NotInit);
    }
    const id = rt.create() catch |err| {
        std.log.err("Failed to create note: {}\n", .{err});
        return @intFromEnum(CError.GenericFail);
    };

    return @intCast(id);
}

/// Output: CError on failure, NoteID if success, 0 if file was imported but is not a note
export fn nana_import(path: [*:0]const u8, destPathBuf: ?[*]u8, destPathBufLen: c_uint) c_int {
    mutex.lock();
    defer mutex.unlock();

    const path_slice = std.mem.sliceTo(path, 0);

    std.log.info("nana_import {s}", .{path_slice});
    if (!init) {
        return @intFromEnum(CError.NotInit);
    }

    const destBuf: ?[]u8 = if (destPathBuf) |buf| buf[0..destPathBufLen] else null;

    const maybeId = rt.import(path_slice, destBuf) catch |err| {
        std.log.err("Failed to import note: {}\n", .{err});
        switch (err) {
            nana.Error.NotNote => {
                return @intFromEnum(CError.InvalidFiletype);
            },
            else => {
                return @intFromEnum(CError.GenericFail);
            },
        }
    };

    if (maybeId) |id| {
        return @intCast(id);
    } else {
        return 0;
    }
}

/// Input: NoteID
/// Output: Create Time
export fn nana_create_time(noteID: c_int) c_long {
    mutex.lock();
    defer mutex.unlock();
    std.log.info("nana_create_time {d}", .{noteID});
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();

    const note = rt.get(@intCast(noteID), arena.allocator()) catch |err| {
        std.log.err("Failed to get note with id '{d}': {}\n", .{ noteID, err });
        return @intFromEnum(CError.GenericFail);
    };

    // micro to seconds
    return @intCast(@divTrunc(note.created, 1_000_000));
}

/// Input: NoteID
/// Output: Mod Time
export fn nana_mod_time(noteID: c_int) c_long {
    mutex.lock();
    defer mutex.unlock();
    std.log.info("nana_mod_time {d}", .{noteID});
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();

    const note = rt.get(@intCast(noteID), arena.allocator()) catch |err| {
        std.log.err("Failed to get note with id '{d}': {}\n", .{ noteID, err });
        return @intFromEnum(CError.GenericFail);
    };

    // micro to seconds
    return @intCast(@divTrunc(note.modified, 1_000_000));
}

/// Semantic vector search all notes.
export fn nana_search(query: [*:0]const u8, outbuf: [*c]CSearchResult, sz: c_uint) c_int {
    mutex.lock();
    defer mutex.unlock();
    const convQuery: []const u8 = std.mem.sliceTo(query, 0);
    std.log.info("nana_search {s}", .{convQuery});

    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    var tmp_buf = arena.allocator().alloc(SearchResult, sz) catch |err| {
        std.log.err("Failed alloc in search: {}\n", .{err});
        return @intFromEnum(CError.GenericFail);
    };

    const written = rt.search(convQuery, tmp_buf[0..sz]) catch |err| {
        std.log.err("Failed to search with query '{s}': {}\n", .{ query, err });
        return @intFromEnum(CError.GenericFail);
    };

    for (tmp_buf[0..written], 0..) |sr, i| {
        outbuf[i] = sr.toC();
    }

    return @intCast(written);
}

/// Get matched area for search result.
/// The output.content buffer must be initialized with a non-zero sentinel and null-terminated.
export fn nana_search_detail(
    id: NoteID,
    start_i: usize,
    end_i: usize,
    query: [*:0]const u8,
    output: *CSearchDetail,
    skip_highlights: bool,
) c_int {
    std.log.info(
        "nana_search_detail (id: {d}, start_i: {d}, end_i: {d}, query: '{s}')",
        .{ id, start_i, end_i, query },
    );
    const zigStyle: []const u8 = std.mem.sliceTo(query, 0);
    const content_slice: []u8 = std.mem.sliceTo(@as([*:0]u8, @ptrCast(output.content)), 0);
    var detail = SearchDetail{
        .content = content_slice,
    };
    rt.search_detail(
        .{ .id = id, .start_i = start_i, .end_i = end_i },
        zigStyle,
        &detail,
        .{ .skip_highlights = skip_highlights },
    ) catch |err| {
        std.log.err(
            "Failed to get preview for note #{d}({d}, {d}) with query '{s}': {}\n",
            .{ id, start_i, end_i, query, err },
        );
        return @intFromEnum(CError.GenericFail);
    };
    for (detail.highlights, 0..) |h, i| {
        output.highlights[i] = @intCast(h);
    }
    return 0;
}

/// List in chronological order the n most recently modified notes.
export fn nana_index(outbuf: [*c]c_int, sz: c_uint, ignore: c_int) c_int {
    std.log.info("nana_index (ignore {d})", .{ignore});

    const igParam: ?u64 = if (ignore == -1) null else @intCast(ignore);
    const written = rt.index(outbuf[0..sz], igParam) catch |err| {
        std.log.err("Failed to index: {}\n", .{err});
        return @intFromEnum(CError.GenericFail);
    };
    return @intCast(written);
}

export fn nana_write_all(noteID: c_int, content: [*:0]const u8) c_int {
    mutex.lock();
    defer mutex.unlock();
    std.log.info("nana_write_all {d}", .{noteID});
    const zigStyle: []const u8 = std.mem.sliceTo(content, 0);
    rt.writeAll(@intCast(noteID), zigStyle) catch |err| switch (err) {
        error.FileNotFound => {
            std.log.err("Failed to write note with id '{d}': {}\n", .{ noteID, err });
            return @intFromEnum(CError.FileNotFound);
        },
        else => {
            std.log.err("Failed to write note with id '{d}': {}\n", .{ noteID, err });
            return @intFromEnum(CError.GenericFail);
        },
    };
    return 0;
}

/// Atomically writes and returns the modified timestamp.
/// Input: NoteID, content
/// Output: Modified timestamp on success, negative CError on failure
export fn nana_write_all_with_time(noteID: c_int, content: [*:0]const u8) c_long {
    mutex.lock();
    defer mutex.unlock();
    std.log.info("nana_write_all_with_time {d}", .{noteID});
    const zigStyle: []const u8 = std.mem.sliceTo(content, 0);
    rt.writeAll(@intCast(noteID), zigStyle) catch |err| switch (err) {
        error.FileNotFound => {
            std.log.err("Failed to write note with id '{d}': {}\n", .{ noteID, err });
            return @intFromEnum(CError.FileNotFound);
        },
        else => {
            std.log.err("Failed to write note with id '{d}': {}\n", .{ noteID, err });
            return @intFromEnum(CError.GenericFail);
        },
    };

    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();

    const note = rt.get(@intCast(noteID), arena.allocator()) catch |err| {
        std.log.err("Failed to get note with id '{d}' after write: {}\n", .{ noteID, err });
        return @intFromEnum(CError.GenericFail);
    };

    return @intCast(@divTrunc(note.modified, 1_000_000));
}

export fn nana_read_all(noteID: c_int, outbuf: [*c]u8, sz: c_uint) c_int {
    mutex.lock();
    defer mutex.unlock();
    std.log.info("nana_read_all {d}", .{noteID});
    const written = rt.readAll(@intCast(noteID), outbuf[0..sz]) catch {
        return @intFromEnum(CError.GenericFail);
    };

    return @intCast(written);
}

/// Parses markdown text.
/// Successive calls to this function free the result of the previous call in memory.
/// Input: content
/// Output: JSON representing how the document should be styled.
export fn nana_parse_markdown(content: [*:0]const u8) [*:0]const u8 {
    mutex.lock();
    defer mutex.unlock();
    std.log.info("nana_parse_markdown", .{});
    const zig_out = rt.parseMarkdown(std.mem.sliceTo(content, 0)) catch |err| switch (err) {
        else => {
            std.log.err("Failed to parse Markdown: {}\n", .{err});
            return "\x00";
        },
    };
    assert(zig_out[zig_out.len - 1] == 0);
    return @ptrCast(zig_out.ptr);
}

/// Gets the first 64 non-empty characters of a file.
/// Note, make sure that the size of the buffer is at least 65.
/// Input: noteID, outbuf
/// Output: see description
export fn nana_title(noteID: c_int, outbuf: [*:0]u8) [*:0]const u8 {
    mutex.lock();
    defer mutex.unlock();
    std.log.info("nana_title {d}", .{noteID});

    var input_slice = std.mem.sliceTo(outbuf, 0);
    const output = rt.title(@intCast(noteID), input_slice[0..nana.TITLE_BUF_LEN]) catch |e| {
        std.log.err("Failed to get preview: {}\n", .{e});
        input_slice[0] = 0;
        return input_slice;
    };

    input_slice[output.len] = 0;
    return @ptrCast(output.ptr);
}

/// Resets metadata to a functioning state, returns list of notes to be re-imported.
/// Returns a double-null-terminated string: "path1\0path2\0\0"
export fn nana_doctor(basedir_path: [*:0]const u8) [*:0]const u8 {
    mutex.lock();
    defer mutex.unlock();
    std.log.info("nana_doctor {s}", .{std.mem.sliceTo(basedir_path, 0)});

    // Clear out data from a previous doctor run
    refresh_arena();

    // Get the size of the zero-sentinel string
    const basedir_sz = outer: {
        for (0..PATH_MAX + 1) |i| {
            const c: u8 = basedir_path[i];
            if (c == 0) {
                break :outer i;
            }
        }
        std.log.err("Provided path is too long\n", .{});
        return "\x00";
    };

    var buf: [PATH_MAX]u8 = undefined;
    const path: []const u8 = std.Uri.percentDecodeBackwards(&buf, basedir_path[0..basedir_sz :0]);
    const basedir = std.fs.openDirAbsolute(path, .{ .iterate = true }) catch |err| {
        std.log.err("Failed to access working directory '{s}': {}\n", .{ path, err });
        return "\x00";
    };

    const result = doctor(persistent_arena.allocator(), basedir) catch |err| {
        std.log.err("Failed to run doctor: {}\n", .{err});
        return "\x00";
    };
    return result.ptr;
}

/// Clear out data used during doctoring
export fn nana_doctor_finish() void {
    mutex.lock();
    defer mutex.unlock();
    refresh_arena();
}

const std = @import("std");
const assert = std.debug.assert;
const PATH_MAX = std.posix.PATH_MAX;

const nana = @import("root.zig");
const doctor = nana.doctor;
const model = @import("model.zig");
const NoteID = model.NoteID;
const SearchResult = nana.SearchResult;
const CSearchResult = nana.CSearchResult;
const SearchDetail = nana.SearchDetail;
const CSearchDetail = nana.CSearchDetail;
