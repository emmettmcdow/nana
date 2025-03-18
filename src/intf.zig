const std = @import("std");
const nana = @import("root.zig");

var rt: nana.Runtime = undefined;
var init: bool = false;

const CError = enum(c_int) { Success = 0, DoubleInit = -1, NotInit = -2, DirCreationFail = -3, InitFail = -4, DeinitFail = -5, CreateFail = -6, GetFail = -7 };
// const RUNTIME_DIR = "data/";

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
    rt = nana.init(
        d,
        false,
    ) catch |err| {
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
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = gpa.allocator();
    defer {
        const deinit_status = gpa.deinit();
        if (deinit_status == .leak) @panic("TEST FAIL");
    }
    const note = rt.get(@intCast(noteID), alloc) catch |err| {
        std.log.err("Failed to get note with id '{d}': {}\n", .{ noteID, err });
        return @intFromEnum(CError.GetFail);
    };

    return @intCast(note.created);
}
export fn nana_mod_time(noteID: c_int) c_int {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = gpa.allocator();
    defer {
        const deinit_status = gpa.deinit();
        if (deinit_status == .leak) @panic("TEST FAIL");
    }
    const note = rt.get(@intCast(noteID), alloc) catch |err| {
        std.log.err("Failed to get note with id '{d}': {}\n", .{ noteID, err });
        return @intFromEnum(CError.GetFail);
    };

    return @intCast(note.modified);
}

// TODO
//
// Input: 0 terminated query
// Output: -1 if failure, ID if success
// export fn nana_search(query: [*:0]u8) c_int {
//     _ = query;
//     return 0;
// }

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
