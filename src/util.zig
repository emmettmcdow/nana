pub fn readAllZ(basedir: std.fs.Dir, path: []const u8, buf: []u8) !usize {
    const f = basedir.openFile(path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            return 0; // Lazy creation
        },
        else => {
            return err;
        },
    };
    defer f.close();

    const n = try f.readAll(buf);

    // Save space for the null-terminator
    if (n >= buf.len - 1) {
        return root.Error.BufferTooSmall;
    }
    buf[n] = 0;

    return n;
}

pub fn readAllZ2(basedir: std.fs.Dir, path: []const u8, allocator: std.mem.Allocator) ![]u8 {
    var bufsz: usize = 16;
    var buf = try allocator.alloc(u8, bufsz);

    while (true) {
        const sz = readAllZ(basedir, path, buf[0..bufsz]) catch |e| switch (e) {
            root.Error.BufferTooSmall => {
                bufsz = try std.math.mul(usize, bufsz, 2);
                if (!allocator.resize(buf, bufsz)) return OutOfMemory;
                continue;
            },
            else => |leftover_err| return leftover_err,
        };
        return buf[0..sz];
    }
}

const std = @import("std");
const Allocator = std.mem.allocator;
const OutOfMemory = std.mem.Allocator.Error.OutOfMemory;

const root = @import("root.zig");
const model = @import("model.zig");
const Note = model.Note;
const NoteID = model.NoteID;
