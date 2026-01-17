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
                buf = allocator.realloc(buf, bufsz) catch |alloc_e| {
                    std.log.err("Failed to resize to {d}: {}\n", .{ bufsz, alloc_e });
                    return OutOfMemory;
                };
                continue;
            },
            else => |leftover_err| return leftover_err,
        };
        return buf[0..sz];
    }
}

pub fn UniqueCircularBuffer(T: type, ID_T: type, GET_ID_FN: fn (T) ID_T) type {
    const HashMap = HashMapUnmanaged(ID_T, usize, AutoContext(ID_T), 99);

    return struct {
        N: u32,
        ring_buf: []T,
        id_to_idx: *HashMap,
        allocator: Allocator,
        read_i: usize = 0,
        write_i: usize = 0,
        mutex: Mutex = Mutex{},

        pub const Error = error{Full};

        pub fn init(allocator: Allocator, sz: u32) !*@This() {
            var map = try allocator.create(HashMap);
            map.* = .empty;
            try map.ensureTotalCapacity(allocator, sz);
            const self = try allocator.create(@This());
            self.* = .{
                .N = sz,
                .ring_buf = try allocator.alloc(T, sz),
                .id_to_idx = map,
                .allocator = allocator,
            };
            return self;
        }

        pub fn deinit(self: *@This()) void {
            self.id_to_idx.deinit(self.allocator);
            self.allocator.destroy(self.id_to_idx);
            self.allocator.free(self.ring_buf);
            self.allocator.destroy(self);
        }

        /// Pop from the front of the queue.
        pub fn pop(self: *@This()) ?T {
            const output = b: {
                self.mutex.lock();
                defer self.mutex.unlock();

                if (self.read_i == self.write_i) {
                    return null;
                }
                defer self.read_i = (self.read_i + 1) % self.N;
                const item = self.ring_buf[self.read_i];
                assert(self.id_to_idx.remove(GET_ID_FN(item)));
                break :b item;
            };
            return output;
        }

        /// Push to the back of the queue.
        pub fn push(self: *@This(), item: T) Error!void {
            self.mutex.lock();
            defer self.mutex.unlock();

            // Check if we can update rather than add.
            if (self.id_to_idx.getEntry(GET_ID_FN(item))) |entry| {
                self.ring_buf[entry.value_ptr.*] = item;
                return;
            }

            if ((self.write_i + 1) % self.N == self.read_i) {
                return error.Full;
            }
            self.ring_buf[self.write_i] = item;
            self.id_to_idx.putAssumeCapacity(GET_ID_FN(item), self.write_i);
            self.write_i = (self.write_i + 1) % self.N;
        }
    };
}

fn usizeID(a: usize) usize {
    return a;
}

test "UniqueCircularBuffer" {
    const capacity = 4;
    const UsizeCircularBuf = UniqueCircularBuffer(usize, usize, usizeID);
    const allocator = std.testing.allocator;

    { // FIFO base
        var buf = try UsizeCircularBuf.init(allocator, capacity);
        defer buf.deinit();
        for (0..capacity - 1) |i| try buf.push(i);
        for (0..capacity - 1) |i| try expectEqual(i, buf.pop());
    }
    { // Error Cases
        var buf = try UsizeCircularBuf.init(allocator, capacity);
        defer buf.deinit();
        try expectEqual(null, buf.pop());
        for (0..capacity - 1) |i| try buf.push(i);
        try expectEqual(UsizeCircularBuf.Error.Full, buf.push(4));
    }
    { // Update unique.
        const TestStruct = struct {
            id: usize,
            val: usize,

            pub fn getID(self: @This()) usize {
                return self.id;
            }
        };
        const StructCircularBuf = UniqueCircularBuffer(TestStruct, usize, TestStruct.getID);
        var buf = try StructCircularBuf.init(allocator, capacity);
        defer buf.deinit();

        // Fill the buf.
        const a = TestStruct{ .id = 1, .val = 1 };
        try buf.push(a);
        const b = TestStruct{ .id = 2, .val = 2 };
        try buf.push(b);
        const c = TestStruct{ .id = 3, .val = 3 };
        try buf.push(c);

        // This should not fail because it is only updating an existing entry.
        const want = 420;
        const b_mod = TestStruct{ .id = b.id, .val = want };
        try buf.push(b_mod);

        try expectEqualDeep(a, buf.pop());
        try expectEqualDeep(b_mod, buf.pop());
        try expectEqualDeep(c, buf.pop());
    }
}

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const AutoContext = std.hash_map.AutoContext;
const expectEqual = std.testing.expectEqual;
const expectEqualDeep = std.testing.expectEqualDeep;
const HashMapUnmanaged = std.hash_map.HashMapUnmanaged;
const Mutex = std.Thread.Mutex;
const OutOfMemory = std.mem.Allocator.Error.OutOfMemory;

const model = @import("model.zig");
const Note = model.Note;
const NoteID = model.NoteID;
const root = @import("root.zig");
