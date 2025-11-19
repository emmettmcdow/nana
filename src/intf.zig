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

const PATH_MAX = 1000;

/// Output: CError
export fn nana_init(
    basedir: [*:0]const u8,
    basedir_sz: c_uint,
) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (init) {
        return @intFromEnum(CError.DoubleInit);
    }

    const basedir_str = basedir[0..basedir_sz :0];

    var buf: [PATH_MAX]u8 = undefined;
    var path: []const u8 = undefined;
    if (std.mem.eql(u8, basedir_str, "./")) {
        path = std.process.getCwd(&buf) catch return CError.FileNotFound;
    } else {
        path = std.Uri.percentDecodeBackwards(&buf, basedir_str);
    }

    const d = std.fs.openDirAbsolute(path, .{ .iterate = true }) catch |err| {
        std.log.err("Failed to access working directory '{s}': {}\n", .{ path, err });
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
export fn nana_deinit() c_int {
    mutex.lock();
    defer mutex.unlock();
    if (!init) {
        return @intFromEnum(CError.NotInit);
    }
    rt.deinit();
    return 0;
}

/// Output: CError on failure, NoteID if success
export fn nana_create() c_int {
    mutex.lock();
    defer mutex.unlock();
    if (!init) {
        return @intFromEnum(CError.NotInit);
    }
    const id = rt.create() catch |err| {
        std.log.err("Failed to create note: {}\n", .{err});
        return @intFromEnum(CError.GenericFail);
    };

    return @intCast(id);
}

/// Output: CError on failure, NoteID if success
export fn nana_import(path: [*:0]const u8, pathlen: c_uint) c_int {
    mutex.lock();
    defer mutex.unlock();
    if (!init) {
        return @intFromEnum(CError.NotInit);
    }
    const id = rt.import(path[0..pathlen], .{ .copy = true }) catch |err| {
        std.log.err("Failed to create note: {}\n", .{err});
        switch (err) {
            nana.Error.NotNote => {
                return @intFromEnum(CError.InvalidFiletype);
            },
            else => {
                return @intFromEnum(CError.GenericFail);
            },
        }
    };

    return @intCast(id);
}

/// Input: NoteID
/// Output: Create Time
export fn nana_create_time(noteID: c_int) c_long {
    mutex.lock();
    defer mutex.unlock();
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
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();

    const note = rt.get(@intCast(noteID), arena.allocator()) catch |err| {
        std.log.err("Failed to get note with id '{d}': {}\n", .{ noteID, err });
        return @intFromEnum(CError.GenericFail);
    };

    // micro to seconds
    return @intCast(@divTrunc(note.modified, 1_000_000));
}

export fn nana_search(query: [*:0]const u8, outbuf: [*c]c_int, sz: c_uint, ignore: c_int) c_int {
    mutex.lock();
    defer mutex.unlock();
    const convQuery: []const u8 = std.mem.sliceTo(query, 0);

    const igParam: ?u64 = if (ignore == -1) null else @intCast(ignore);
    const written = rt.search(convQuery, outbuf[0..sz], igParam) catch |err| {
        std.log.err("Failed to search with query '{s}': {}\n", .{ query, err });
        return @intFromEnum(CError.GenericFail);
    };

    return @intCast(written);
}

export fn nana_write_all(noteID: c_int, content: [*:0]const u8) c_int {
    mutex.lock();
    defer mutex.unlock();
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
    const zig_out = rt.parseMarkdown(std.mem.sliceTo(content, 0)) catch |err| switch (err) {
        else => {
            std.log.err("Failed to parse Markdown: {}\n", .{err});
            return "\x00";
        },
    };
    assert(zig_out[zig_out.len - 1] == 0);
    return @ptrCast(zig_out.ptr);
}

const std = @import("std");
const assert = std.debug.assert;

const nana = @import("root.zig");
