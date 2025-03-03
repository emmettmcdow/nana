const std = @import("std");

pub fn main() !void {
    // Prints to stderr (it's a shortcut based on `std.io.getStdErr()`)
    std.debug.print("All your {s} are belong to us.\n", .{"codebase"});

    // stdout is for the actual output of your application, for example if you
    // are implementing gzip, then only the compressed bytes should be sent to
    // stdout, not any debugging messages.
    const stdout_file = std.io.getStdOut().writer();
    var bw = std.io.bufferedWriter(stdout_file);
    const stdout = bw.writer();

    try stdout.print("Run `zig build test` to run the tests.\n", .{});

    try bw.flush(); // don't forget to flush!
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

test "simple test" {
    var list = std.ArrayList(i32).init(std.testing.allocator);
    defer list.deinit(); // try commenting this out and see if zig detects the memory leak!
    try list.append(42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}
