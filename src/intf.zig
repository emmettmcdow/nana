var rt: nana.Runtime = undefined;
var init: bool = false;
var gpa = std.heap.GeneralPurposeAllocator(.{}){};
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

export fn nana_init(basedir: [*:0]const u8) c_int {
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

/// Creates a new note, writes the path to outbuf.
/// Returns path length on success, negative CError on failure.
export fn nana_create(outbuf: [*]u8, outbuf_len: c_uint) c_int {
    mutex.lock();
    defer mutex.unlock();
    std.log.info("nana_create", .{});
    if (!init) {
        return @intFromEnum(CError.NotInit);
    }

    const path = rt.create(outbuf[0..outbuf_len]) catch |err| {
        std.log.err("Failed to create note: {}\n", .{err});
        return @intFromEnum(CError.GenericFail);
    };

    outbuf[path.len] = 0;
    return @intCast(path.len);
}

/// Imports a file as a note. Writes the destination path to destPathBuf.
/// Returns path length on success, 0 if imported but not a note, negative CError on failure.
export fn nana_import(path: [*:0]const u8, destPathBuf: [*]u8, destPathBufLen: c_uint) c_int {
    mutex.lock();
    defer mutex.unlock();

    const path_slice = std.mem.sliceTo(path, 0);
    std.log.info("nana_import {s}", .{path_slice});

    if (!init) {
        return @intFromEnum(CError.NotInit);
    }

    const destBuf: []u8 = destPathBuf[0..destPathBufLen];

    const maybePath = rt.import(path_slice, destBuf) catch |err| {
        std.log.err("Failed to import note: {}\n", .{err});
        switch (err) {
            nana.Error.NotNote => return @intFromEnum(CError.InvalidFiletype),
            else => return @intFromEnum(CError.GenericFail),
        }
    };

    if (maybePath) |imported_path| {
        destPathBuf[imported_path.len] = 0;
        return @intCast(imported_path.len);
    } else {
        return 0;
    }
}

/// Input: path
/// Output: Create time in seconds, negative CError on failure
export fn nana_create_time(path: [*:0]const u8) c_long {
    mutex.lock();
    defer mutex.unlock();
    const path_slice = std.mem.sliceTo(path, 0);
    std.log.info("nana_create_time {s}", .{path_slice});

    const note = rt.get(path_slice) catch |err| {
        std.log.err("Failed to get note '{s}': {}\n", .{ path_slice, err });
        return @intFromEnum(CError.GenericFail);
    };

    return @intCast(@divTrunc(note.created, 1_000_000));
}

/// Input: path
/// Output: Mod time in seconds, negative CError on failure
export fn nana_mod_time(path: [*:0]const u8) c_long {
    mutex.lock();
    defer mutex.unlock();
    const path_slice = std.mem.sliceTo(path, 0);
    std.log.info("nana_mod_time {s}", .{path_slice});

    const note = rt.get(path_slice) catch |err| {
        std.log.err("Failed to get note '{s}': {}\n", .{ path_slice, err });
        return @intFromEnum(CError.GenericFail);
    };

    return @intCast(@divTrunc(note.modified, 1_000_000));
}

/// Semantic vector search all notes.
/// Results contain paths (via search result id -> path translation in Swift).
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
        std.log.err("Failed to search with query '{s}': {}\n", .{ convQuery, err });
        return @intFromEnum(CError.GenericFail);
    };

    for (tmp_buf[0..written], 0..) |sr, i| {
        outbuf[i] = sr.toC();
    }

    return @intCast(written);
}

/// Get matched area for search result.
// zlinter-disable
export fn nana_search_detail(
    path: [*:0]const u8,
    start_i: c_uint,
    end_i: c_uint,
    query: [*:0]const u8,
    output: *CSearchDetail,
    skip_highlights: bool,
) c_int {
    // zlinter-enable
    const zigPath: []const u8 = std.mem.sliceTo(path, 0);
    std.log.info(
        "nana_search_detail (path: {s}, start_i: {d}, end_i: {d}, query: '{s}')",
        .{ zigPath, start_i, end_i, query },
    );
    const zigQuery: []const u8 = std.mem.sliceTo(query, 0);
    const content_slice: []u8 = std.mem.sliceTo(@as([*:0]u8, @ptrCast(output.content)), 0);
    var detail = SearchDetail{
        .content = content_slice,
    };
    rt.searchDetail(
        .{ .path = zigPath, .start_i = start_i, .end_i = end_i },
        zigQuery,
        &detail,
        .{ .skip_highlights = skip_highlights },
    ) catch |err| {
        std.log.err(
            "Failed to get detail for path '{s}'({d}, {d}) with query '{s}': {}\n",
            .{ zigPath, start_i, end_i, query, err },
        );
        return @intFromEnum(CError.GenericFail);
    };
    for (detail.highlights, 0..) |h, i| {
        output.highlights[i] = @intCast(h);
    }
    return 0;
}

/// List in chronological order the n most recently modified notes.
/// Writes double-null-terminated paths: "path1\0path2\0\0"
export fn nana_index(outbuf: [*]u8, sz: c_uint, ignore: [*:0]const u8) c_int {
    mutex.lock();
    defer mutex.unlock();
    const ignore_slice = std.mem.sliceTo(ignore, 0);
    std.log.info("nana_index (ignore '{s}')", .{ignore_slice});

    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();

    var path_buf: [256][]const u8 = undefined;
    const ignore_param: ?[]const u8 = if (ignore_slice.len == 0) null else ignore_slice;

    const count = rt.index(&path_buf, ignore_param) catch |err| {
        std.log.err("Failed to index: {}\n", .{err});
        return @intFromEnum(CError.GenericFail);
    };
    defer for (path_buf[0..count]) |p| rt.allocator.free(p);

    var pos: usize = 0;
    for (path_buf[0..count]) |p| {
        if (pos + p.len + 1 >= sz) break;
        @memcpy(outbuf[pos .. pos + p.len], p);
        outbuf[pos + p.len] = 0;
        pos += p.len + 1;
    }
    if (pos < sz) {
        outbuf[pos] = 0;
    }

    return @intCast(count);
}

export fn nana_write_all(path: [*:0]const u8, content: [*:0]const u8) c_int {
    mutex.lock();
    defer mutex.unlock();
    const path_slice = std.mem.sliceTo(path, 0);
    const content_slice = std.mem.sliceTo(content, 0);
    std.log.info("nana_write_all {s}", .{path_slice});

    rt.writeAll(path_slice, content_slice) catch |err| switch (err) {
        error.FileNotFound, nana.Error.NotFound => {
            std.log.err("Failed to write note '{s}': {}\n", .{ path_slice, err });
            return @intFromEnum(CError.FileNotFound);
        },
        else => {
            std.log.err("Failed to write note '{s}': {}\n", .{ path_slice, err });
            return @intFromEnum(CError.GenericFail);
        },
    };
    return 0;
}

/// Atomically writes and returns the modified timestamp.
export fn nana_write_all_with_time(path: [*:0]const u8, content: [*:0]const u8) c_long {
    mutex.lock();
    defer mutex.unlock();
    const path_slice = std.mem.sliceTo(path, 0);
    const content_slice = std.mem.sliceTo(content, 0);
    std.log.info("nana_write_all_with_time {s}", .{path_slice});

    rt.writeAll(path_slice, content_slice) catch |err| switch (err) {
        error.FileNotFound, nana.Error.NotFound => {
            std.log.err("Failed to write note '{s}': {}\n", .{ path_slice, err });
            return @intFromEnum(CError.FileNotFound);
        },
        else => {
            std.log.err("Failed to write note '{s}': {}\n", .{ path_slice, err });
            return @intFromEnum(CError.GenericFail);
        },
    };

    const note = rt.get(path_slice) catch |err| {
        std.log.err("Failed to get note '{s}' after write: {}\n", .{ path_slice, err });
        return @intFromEnum(CError.GenericFail);
    };

    return @intCast(@divTrunc(note.modified, 1_000_000));
}

export fn nana_read_all(path: [*:0]const u8, outbuf: [*]u8, sz: c_uint) c_int {
    mutex.lock();
    defer mutex.unlock();
    const path_slice = std.mem.sliceTo(path, 0);
    std.log.info("nana_read_all {s}", .{path_slice});

    const written = rt.readAll(path_slice, outbuf[0..sz]) catch |err| {
        std.log.err("Failed to read note '{s}': {}\n", .{ path_slice, err });
        return @intFromEnum(CError.GenericFail);
    };

    return @intCast(written);
}

export fn nana_delete(path: [*:0]const u8) c_int {
    mutex.lock();
    defer mutex.unlock();
    const path_slice = std.mem.sliceTo(path, 0);
    std.log.info("nana_delete {s}", .{path_slice});

    rt.delete(path_slice) catch |err| {
        std.log.err("Failed to delete note '{s}': {}\n", .{ path_slice, err });
        return @intFromEnum(CError.GenericFail);
    };

    return 0;
}

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

export fn nana_title(path: [*:0]const u8, outbuf: [*:0]u8) [*:0]const u8 {
    mutex.lock();
    defer mutex.unlock();
    const path_slice = std.mem.sliceTo(path, 0);
    std.log.info("nana_title {s}", .{path_slice});

    var input_slice = std.mem.sliceTo(outbuf, 0);
    const output = rt.title(path_slice, input_slice[0..nana.TITLE_BUF_LEN]) catch |e| {
        std.log.err("Failed to get title: {}\n", .{e});
        input_slice[0] = 0;
        return input_slice;
    };

    input_slice[output.len] = 0;
    return @ptrCast(output.ptr);
}

export fn nana_doctor() c_int {
    mutex.lock();
    defer mutex.unlock();
    std.log.info("nana_doctor", .{});

    if (!init) {
        return @intFromEnum(CError.NotInit);
    }

    rt.doctor() catch |err| {
        std.log.err("Failed to run doctor: {}\n", .{err});
        return @intFromEnum(CError.GenericFail);
    };
    return @intFromEnum(CError.Success);
}

const std = @import("std");
const assert = std.debug.assert;
const PATH_MAX = std.posix.PATH_MAX;

const nana = @import("root.zig");
const SearchResult = nana.SearchResult;
const CSearchResult = nana.CSearchResult;
const SearchDetail = nana.SearchDetail;
const CSearchDetail = nana.CSearchDetail;
