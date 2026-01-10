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

pub fn UniqueCircularBuffer(T: type, N: usize, ID_T: type, GET_ID_FN: fn (T) ID_T) type {
    const HashMap = HashMapUnmanaged(ID_T, usize, AutoContext(ID_T), 99);

    return struct {
        N: u32,
        ring_buf: []T,
        id_to_idx: *HashMap,
        allocator: Allocator,
        read_i: usize = 0,
        write_i: usize = 0,
        mutex: Mutex = Mutex{},
        condition: Condition = Condition{},

        pub const Error = error{Full};

        pub fn init(allocator: Allocator, sz: u32) !@This() {
            var map = try allocator.create(HashMap);
            map.* = .empty;
            try map.ensureTotalCapacity(allocator, sz);
            return .{
                .N = sz,
                .ring_buf = try allocator.alloc(T, sz),
                .id_to_idx = map,
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *@This()) void {
            self.id_to_idx.deinit(self.allocator);
            self.allocator.destroy(self.id_to_idx);
            self.allocator.free(self.ring_buf);
        }

        /// Pop from the front of the queue. Block until an item is available.
        pub fn popBlock(self: *@This(), output: *T) void {
            {
                self.mutex.lock();
                defer self.mutex.unlock();
                while (self.read_i == self.write_i) {
                    self.condition.wait(&self.mutex);
                }
                output.* = self.ring_buf[self.read_i];
                assert(self.id_to_idx.remove(GET_ID_FN(output.*)));
                self.read_i = (self.read_i + 1) % N;
            }
            self.condition.signal();
        }

        /// Push to the back of the queue. Block until space is available.
        pub fn pushBlock(self: *@This(), item: T) void {
            {
                self.mutex.lock();
                defer self.mutex.unlock();

                // Check if we can update rather than add.
                if (self.id_to_idx.getEntry(GET_ID_FN(item))) |entry| {
                    self.ring_buf[entry.value_ptr.*] = item;
                    return;
                }

                while ((self.write_i + 1) % N == self.read_i) {
                    self.condition.wait(&self.mutex);
                }
                self.ring_buf[self.write_i] = item;
                self.id_to_idx.putAssumeCapacity(GET_ID_FN(item), self.write_i);
                self.write_i = (self.write_i + 1) % N;
            }
            self.condition.signal();
        }

        /// Pop from the front of the queue.
        pub fn pop(self: *@This()) ?T {
            const output = b: {
                self.mutex.lock();
                defer self.mutex.unlock();

                if (self.read_i == self.write_i) {
                    return null;
                }
                defer self.read_i = (self.read_i + 1) % N;
                const item = self.ring_buf[self.read_i];
                assert(self.id_to_idx.remove(GET_ID_FN(item)));
                break :b item;
            };
            self.condition.signal();
            return output;
        }

        /// Push to the back of the queue.
        pub fn push(self: *@This(), item: T) Error!void {
            {
                self.mutex.lock();
                defer self.mutex.unlock();

                // Check if we can update rather than add.
                if (self.id_to_idx.getEntry(GET_ID_FN(item))) |entry| {
                    self.ring_buf[entry.value_ptr.*] = item;
                    return;
                }

                if ((self.write_i + 1) % N == self.read_i) {
                    return error.Full;
                }
                self.ring_buf[self.write_i] = item;
                self.id_to_idx.putAssumeCapacity(GET_ID_FN(item), self.write_i);
                self.write_i = (self.write_i + 1) % N;
            }
            self.condition.signal();
        }
    };
}

fn usizeID(a: usize) usize {
    return a;
}

test "UniqueCircularBuffer" {
    const capacity = 4;
    const UsizeCircularBuf = UniqueCircularBuffer(usize, capacity, usize, usizeID);
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
    { // Block until space available.
        var buf = try UsizeCircularBuf.init(allocator, capacity);
        defer buf.deinit();
        const want = 420;

        // Fill the buf
        for (0..capacity - 1) |i| try buf.push(i);
        try expectEqual(UsizeCircularBuf.Error.Full, buf.push(want));

        // Start a thread which will push once space is available
        var t1 = try Thread.spawn(.{}, UsizeCircularBuf.pushBlock, .{ &buf, want });
        // Give t1 an opportunity to fail.
        try yield();
        _ = buf.pop();
        t1.join();
        for (0..capacity - 2) |_| _ = buf.pop();
        try expectEqual(want, buf.pop());
    }
    { // Block until item available.
        var buf = try UsizeCircularBuf.init(allocator, capacity);
        defer buf.deinit();
        const want = 420;
        var output: usize = undefined;

        // Start a thread which will wait for an item to be available.
        var t1 = try Thread.spawn(.{}, UsizeCircularBuf.popBlock, .{ &buf, &output });

        // Give t1 an opportunity to fail.
        try yield();

        // Make something available to the thread.
        try buf.push(want);
        t1.join();
        try expectEqual(want, output);
    }
    { // pushBlock sends signals.
        var buf = try UsizeCircularBuf.init(allocator, capacity);
        defer buf.deinit();
        const want = 420;
        var output: usize = undefined;

        // Start a thread which will wait for an item to be available.
        var t1 = try Thread.spawn(.{}, UsizeCircularBuf.popBlock, .{ &buf, &output });
        // Give t1 an opportunity to fail.
        try yield();

        // Make something available to the thread.
        buf.pushBlock(want);
        t1.join();
        try expectEqual(want, output);
    }
    { // popBlock sends signals.
        var buf = try UsizeCircularBuf.init(allocator, capacity);
        defer buf.deinit();
        const want = 420;
        var output: usize = undefined;

        // Fill the buf
        for (0..capacity - 1) |i| try buf.push(i);
        try expectEqual(UsizeCircularBuf.Error.Full, buf.push(want));

        // Start a thread which will push once space is available
        var t1 = try Thread.spawn(.{}, UsizeCircularBuf.pushBlock, .{ &buf, want });

        // Give t1 an opportunity to fail.
        try yield();

        // Make space for t1.
        buf.popBlock(&output);
        t1.join();
    }
    { // Update unique.
        const TestStruct = struct {
            id: usize,
            val: usize,

            pub fn getID(self: @This()) usize {
                return self.id;
            }
        };
        const StructCircularBuf = UniqueCircularBuffer(TestStruct, capacity, usize, TestStruct.getID);
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

        // Now lets do it with the blocking fns.
        buf.pushBlock(a);
        buf.pushBlock(b);
        buf.pushBlock(c);
        buf.pushBlock(b_mod);

        var output: TestStruct = undefined;
        buf.popBlock(&output);
        try expectEqualDeep(a, output);
        buf.popBlock(&output);
        try expectEqualDeep(b_mod, output);
        buf.popBlock(&output);
        try expectEqualDeep(c, output);
    }
}

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const AutoContext = std.hash_map.AutoContext;
const Condition = Thread.Condition;
const expectEqual = std.testing.expectEqual;
const expectEqualDeep = std.testing.expectEqualDeep;
const HashMapUnmanaged = std.hash_map.HashMapUnmanaged;
const Mutex = Thread.Mutex;
const OutOfMemory = std.mem.Allocator.Error.OutOfMemory;
const Thread = std.Thread;
const yield = Thread.yield;

const model = @import("model.zig");
const Note = model.Note;
const NoteID = model.NoteID;
const root = @import("root.zig");
