const std = @import("std");

// Input: 0 terminated query
// Output: -1 if failure, ID if success
export fn nana_init() c_int {
    return 0;
}

// Input: 0 terminated query
// Output: -1 if failure, ID if success
export fn nana_search(query: [*:0]u8) c_int {
    _ = query;
    return 0;
}

// Input: Search ID from nana_search, buffer, buffer size
// Output: -1 if no more results, otherwise NoteID
export fn nana_next_result(searchID: c_int) c_int {
    _ = searchID;
    return 0;
}

// Input: NoteID
// Output: Create/Mod Time
export fn nana_create_time(noteID: c_int) c_int {
    _ = noteID;
    return 0;
}
export fn nana_mod_time(noteID: c_int) c_int {
    _ = noteID;
    return 0;
}

// Input: NoteID, buffer, buffer size
// Output: -1 if failure, otherwise written bytes
export fn nana_contents(noteID: c_int, buffer: [*]u8, bufSize: c_int) c_int {
    _ = noteID;
    _ = buffer;
    _ = bufSize;
    return 0;
}

// Input: NoteID, buffer, buffer size
// Output: -1 if failure, 0 if success
export fn nana_update(noteID: c_int, buffer: [*]u8, bufSize: c_int) c_int {
    _ = noteID;
    _ = buffer;
    _ = bufSize;
    return 0;
}

// Output: -1 if failure, NoteID if success
export fn nana_create() void {
    return;
}
