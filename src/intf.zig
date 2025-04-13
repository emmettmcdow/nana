const std = @import("std");
const nana = @import("root.zig");

var rt: nana.Runtime = undefined;
var init: bool = false;
var gpa = std.heap.GeneralPurposeAllocator(.{}){};

const CError = enum(c_int) { Success = 0, DoubleInit = -1, NotInit = -2, DirCreationFail = -3, InitFail = -4, DeinitFail = -5, CreateFail = -6, GetFail = -7, WriteFail = -8, SearchFail = -9, ReadFail = -10 };
// const RUNTIME_DIR = "data/";

pub const MXBAI_QUANTIZED_MODEL: *const [29:0]u8 = "zig-out/share/onnx/model.onnx";

// Output: CError
export fn nana_init() c_int {
    if (init) {
        return @intFromEnum(CError.DoubleInit);
    }
    var buf: [1000]u8 = undefined;
    const cwd = std.process.getCwd(&buf) catch unreachable;

    const d = std.fs.openDirAbsolute(cwd, .{ .iterate = true }) catch |err| {
        std.log.err("Failed to access working directory '{s}': {}\n", .{ cwd, err });
        return @intFromEnum(CError.DirCreationFail);
    };

    rt = nana.Runtime.init(gpa.allocator(), .{ .basedir = d, .model = MXBAI_QUANTIZED_MODEL }) catch |err| {
        std.log.err("Failed to initialize nana: {}\n", .{err});
        return @intFromEnum(CError.InitFail);
    };

    init = true;

    return @intFromEnum(CError.Success);
}

// Output: CError
export fn nana_deinit() c_int {
    if (!init) {
        return @intFromEnum(CError.NotInit);
    }
    rt.deinit();
    return 0;
}

// Output: CError on failure, NoteID if success
export fn nana_create() c_int {
    if (!init) {
        return @intFromEnum(CError.NotInit);
    }
    const id = rt.create() catch |err| {
        std.log.err("Failed to create note: {}\n", .{err});
        return @intFromEnum(CError.CreateFail);
    };

    return @intCast(id);
}

// Input: NoteID
// Output: Create/Mod Time
export fn nana_create_time(noteID: c_int) c_int {
    const note = rt.get(@intCast(noteID)) catch |err| {
        std.log.err("Failed to get note with id '{d}': {}\n", .{ noteID, err });
        return @intFromEnum(CError.GetFail);
    };

    // micro to seconds
    return @intCast(@divTrunc(note.created, 1_000_000));
}
export fn nana_mod_time(noteID: c_int) c_int {
    const note = rt.get(@intCast(noteID)) catch |err| {
        std.log.err("Failed to get note with id '{d}': {}\n", .{ noteID, err });
        return @intFromEnum(CError.GetFail);
    };

    // micro to seconds
    return @intCast(@divTrunc(note.modified, 1_000_000));
}

export fn nana_search(query: [*:0]const u8, outbuf: [*c]c_int, sz: c_uint, ignore: c_int) c_int {
    const convQuery: []const u8 = std.mem.sliceTo(query, 0);

    const igParam: ?u64 = if (ignore == -1) null else @intCast(ignore);
    const written = rt.search(convQuery, outbuf[0..sz], igParam) catch |err| {
        std.log.err("Failed to search with query '{s}': {}\n", .{ query, err });
        return @intFromEnum(CError.SearchFail);
    };

    return @intCast(written);
}

export fn nana_write_all(noteID: c_int, content: [*:0]const u8) c_int {
    const zigStyle: []const u8 = std.mem.sliceTo(content, 0);
    rt.writeAll(@intCast(noteID), zigStyle) catch |err| {
        std.log.err("Failed to write note with id '{d}': {}\n", .{ noteID, err });
        return @intFromEnum(CError.WriteFail);
    };
    return 0;
}

export fn nana_read_all(noteID: c_int, outbuf: [*c]u8, sz: c_uint) c_int {
    const written = rt.readAll(@intCast(noteID), outbuf[0..sz]) catch |err| {
        std.log.err("Failed to read all of note at id '{d}': {}\n", .{ noteID, err });
        return @intFromEnum(CError.ReadFail);
    };

    return @intCast(written);
}

// // Input: Search ID from nana_search, buffer, buffer size
// // Output: -1 if no more results, otherwise NoteID
// export fn nana_next_result(searchID: c_int) c_int {
//     _ = searchID;
//     return 0;
// }

// // Input: NoteID, buffer, buffer size
// // Output: -1 if failure, otherwise written bytes
// export fn nana_contents(noteID: c_int, buffer: [*]u8, bufSize: c_int) c_int {
//     _ = noteID;
//     _ = buffer;
//     _ = bufSize;
//     return 0;
// }

// // Input: NoteID, buffer, buffer size
// // Output: -1 if failure, 0 if success
// export fn nana_update(noteID: c_int, buffer: [*]u8, bufSize: c_int) c_int {
//     _ = noteID;
//     _ = buffer;
//     _ = bufSize;
//     return 0;
// }
