pub fn diffN(old: []const u8, new: []const u8) !usize {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    var allocator = gpa.allocator();
    const max_depth = old.len + new.len;
    if (max_depth >= U_TO_I_MAX) {
        return Error.TooBig;
    }

    const n: usize = max_depth + 1;
    const m: usize = 2 * max_depth + 1;
    var t: Trace = Trace.init(n, m, try allocator.alloc(usize, n * m));
    defer allocator.free(t.entries);

    return diffFwd(old, new, &t);
}

pub fn diff(old: []const u8, new: []const u8, allocator: std.mem.Allocator) ![]Change {
    if (old.len == 0 and new.len != 0) {
        const changes = try allocator.alloc(Change, 1);
        changes[0] = .{ .i = 0, .mod = .add };
        return changes;
    }

    const max_depth = old.len + new.len;
    if (max_depth >= U_TO_I_MAX) {
        return Error.TooBig;
    }
    const n: usize = max_depth + 1;
    const m: usize = 2 * max_depth + 1;
    var t: Trace = Trace.init(n, m, try allocator.alloc(usize, n * m));
    defer allocator.free(t.entries);

    const n_changes = try diffFwd(old, new, &t);
    const changes: []Change = try allocator.alloc(Change, n_changes);

    return diffBwd(old, new, &t, changes);
}

fn diffFwd(old: []const u8, new: []const u8, trace: *Trace) !usize {
    for (0..trace.n) |d| {
        var k: isize = -@as(isize, @intCast(d));
        while (k <= d) : (k += 2) {
            const bot_edge = k == -@as(isize, @intCast(d));
            const top_edge = k == d;
            var x: usize = 0;
            if (bot_edge or (!top_edge and trace.get(k + 1) > trace.get(k - 1))) {
                x = trace.get(k + 1);
            } else {
                x = trace.get(k - 1) + 1;
            }

            if (k > x) continue;
            var y: usize = @intCast(@as(isize, @intCast(x)) - k);

            while (x < old.len and y < new.len and old[x] == new[y]) {
                x += 1;
                y += 1;
            }
            trace.set(k, x);
            if (x == old.len and y == new.len) {
                return d;
            }
        }
        trace.push();
    }
    unreachable;
}

fn diffBwd(old: []const u8, new: []const u8, trace: *Trace, changes: []Change) ![]Change {
    if (changes.len == 0) return changes;

    var x: usize = old.len;
    var y: usize = new.len;
    var d: usize = undefined;
    var prev_x: usize = undefined;
    var prev_y: usize = undefined;
    var prev_k: isize = undefined;
    var change_idx: usize = changes.len;

    while (trace.reverseIter()) |_| {
        d = trace.curr_d;
        const k: isize = @as(isize, @intCast(x)) - @as(isize, @intCast(y));
        const bot_edge = k == -@as(isize, @intCast(d));
        const top_edge = k == d;

        if (bot_edge or (!top_edge and trace.get(k + 1) > trace.get(k - 1))) {
            prev_k = k + 1;
        } else {
            prev_k = k - 1;
        }

        prev_x = trace.get(prev_k);
        if (prev_k > prev_x) continue;
        prev_y = @intCast(@as(isize, @intCast(prev_x)) - prev_k);

        const before_diag_x = x;
        const before_diag_y = y;
        while (x > 0 and y > 0 and old[x - 1] == new[y - 1]) {
            x -= 1;
            y -= 1;
        }

        if (before_diag_x != prev_x or before_diag_y != prev_y) {
            change_idx -= 1;
            if (prev_k == k + 1) {
                changes[change_idx] = Change{ .i = prev_y, .mod = .add };
            } else {
                changes[change_idx] = Change{ .i = prev_x, .mod = .del };
            }
        }
        x = prev_x;
        y = prev_y;
    }
    std.mem.sort(Change, changes, {}, Change.sort);
    return changes;
}

const U_TO_I_MAX: usize = std.math.maxInt(isize);

pub const Error = error{TooBig};

const Trace = struct {
    n: usize,
    m: usize,
    entries: []usize,
    curr_d: usize,
    negative_shift: isize,

    pub fn init(n: usize, m: usize, buffer: []usize) Trace {
        @memset(buffer, 0);
        return Trace{
            .n = n,
            .m = m,
            .entries = buffer,
            .curr_d = 0,
            .negative_shift = @intCast(@divFloor(m, 2)),
        };
    }

    pub fn get(self: Trace, i: isize) usize {
        assert(self.curr_d < self.n);
        assert(i < self.m);
        const offset: isize = @intCast(self.curr_d * self.m);
        return self.entries[@intCast(offset + self.negative_shift + i)];
    }

    pub fn set(self: Trace, i: isize, val: usize) void {
        assert(self.curr_d < self.n);
        assert(i < self.m);
        const offset: isize = @intCast(self.curr_d * self.m);
        self.entries[@intCast(offset + self.negative_shift + i)] = val;
    }

    pub fn push(self: *Trace) void {
        assert(self.curr_d + 1 < self.n);
        const dest_offset = (self.curr_d + 1) * self.m;
        const src_offset = self.curr_d * self.m;
        self.debug_print_v();
        @memcpy(
            self.entries[dest_offset .. dest_offset + self.m],
            self.entries[src_offset .. src_offset + self.m],
        );
        self.curr_d += 1;
        return;
    }

    pub fn reverseIter(self: *Trace) ?[]usize {
        if (self.curr_d == 0) return null;
        defer self.curr_d -= 1;
        const offset = self.curr_d * self.m;
        return self.entries[offset .. offset + self.m];
    }

    fn debug_print_v(self: Trace) void {
        if (true) return;
        const start = self.curr_d * self.m;
        const writable_start = start + @as(usize, @intCast(self.negative_shift)) - self.curr_d;
        const writable_end = start + @as(usize, @intCast(self.negative_shift)) + self.curr_d + 1;
        std.debug.print("Pushing: {any}\n", .{
            self.entries[writable_start..writable_end],
        });
    }
};

pub const Change = struct {
    i: usize,
    mod: enum { add, del },

    const Self = @This();

    pub fn sort(ctx: void, this: Self, that: Self) bool {
        _ = ctx;
        return this.i < that.i;
    }
};

test "all diffN" {
    const cases = [_]struct { []const u8, []const u8, u32 }{
        .{ "a", "a", 0 },
        .{ "a", "", 1 },
        .{ "a", "b", 2 },
        .{ "abcabba", "cbabac", 5 },
        .{ "xr", "xrxx", 2 },
        .{ "artwork", "driftwood", 8 },
    };

    for (cases, 0..) |case, i| {
        const old = case[0];
        const new = case[1];
        const want = case[2];

        const got = try diffN(old, new);
        expectEqual(want, got) catch |e| {
            std.debug.print("Case {d}. Got {d}, want {d}\n", .{ i, got, want });
            std.debug.print("Old:\n", .{});
            std.debug.print("\t{s}\n", .{old});
            std.debug.print("New:\n", .{});
            std.debug.print("\t{s}\n", .{new});
            return e;
        };
    }
}

test "all diff" {
    const cases = [_]struct { []const u8, []const u8, []const Change }{
        .{ "a", "a", &.{} },
        .{ "a", "", &[_]Change{.{ .i = 0, .mod = .del }} },
        .{ "", "a", &[_]Change{.{ .i = 0, .mod = .add }} },
        .{ "a", "b", &[_]Change{ .{ .i = 0, .mod = .del }, .{ .i = 0, .mod = .add } } },
        .{ "abcabba", "cbabac", &[_]Change{
            .{ .i = 0, .mod = .del },
            .{ .i = 1, .mod = .del },
            .{ .i = 1, .mod = .add },
            .{ .i = 5, .mod = .del },
            .{ .i = 5, .mod = .add },
        } },
        .{ "driftwood", "artwork", &[_]Change{
            .{ .i = 0, .mod = .del },
            .{ .i = 0, .mod = .add },
            .{ .i = 2, .mod = .del },
            .{ .i = 3, .mod = .del },
            .{ .i = 5, .mod = .add },
            .{ .i = 6, .mod = .add },
            .{ .i = 7, .mod = .del },
            .{ .i = 8, .mod = .del },
        } },
    };

    for (cases, 0..) |case, i| {
        const old = case[0];
        const new = case[1];
        const want = case[2];

        var allocator = std.testing.allocator;
        const got = try diff(old, new, allocator);
        defer allocator.free(got);
        expectEqualDeep(want, got) catch |e| {
            std.debug.print("Case {d}\n", .{i});
            std.debug.print("Old:\n", .{});
            std.debug.print("\t{s}\n", .{old});
            std.debug.print("New:\n", .{});
            std.debug.print("\t{s}\n", .{new});
            std.debug.print("All: [[ {any} ]]\n", .{got});
            return e;
        };
    }
}

pub const Sentence = struct {
    contents: []const u8,
    off: usize,
    new: bool = false,

    const Self = @This();

    pub fn inRange(self: Self, i: usize) bool {
        return self.off <= i and i < self.off + self.contents.len;
    }
};

pub const Spliterator = struct {
    const Self = @This();

    splitter: std.mem.SplitIterator(u8, .any),
    curr_i: usize,

    pub fn init(buffer: []const u8) Self {
        return .{
            .splitter = std.mem.SplitIterator(u8, .any){
                .index = 0,
                .buffer = buffer,
                .delimiter = ".!?\n",
            },
            .curr_i = 0,
        };
    }

    pub fn next(self: *Self) ?Sentence {
        while (self.splitter.next()) |sentence| {
            if (sentence.len < 1) {
                self.curr_i += 1;
                continue;
            }
            const out = Sentence{
                .contents = sentence,
                .off = self.curr_i,
            };
            self.curr_i += sentence.len + 1;
            return out;
        }
        return null;
    }
};

test "split" {
    {
        const input_str = "foo.bar.baz";
        var splitter = Spliterator.init(input_str);
        var i: usize = 0;
        const expected = [_]Sentence{
            .{ .contents = "foo", .off = 0, .new = false },
            .{ .contents = "bar", .off = 4, .new = false },
            .{ .contents = "baz", .off = 8, .new = false },
        };
        while (splitter.next()) |s| {
            try expectEqual(expected[i].off, s.off);
            try expectEqualStrings(expected[i].contents, s.contents);
            i += 1;
        }
    }

    {
        const input_str = "foo.\nbar";
        var splitter = Spliterator.init(input_str);
        var i: usize = 0;
        const expected = [_]Sentence{
            .{ .contents = "foo", .off = 0, .new = false },
            .{ .contents = "bar", .off = 5, .new = false },
        };
        while (splitter.next()) |s| {
            try expectEqual(expected[i].off, s.off);
            try expectEqualStrings(expected[i].contents, s.contents);
            i += 1;
        }
    }

    {
        const input_str = "foo.";
        var splitter = Spliterator.init(input_str);
        const expected = [_]Sentence{.{ .contents = "foo", .off = 0, .new = false }};
        var i: usize = 0;
        while (splitter.next()) |s| {
            try expectEqual(expected[i].off, s.off);
            try expectEqualStrings(expected[i].contents, s.contents);
            i += 1;
        }
    }
}

pub fn diffSplit(
    old: []const u8,
    new: []const u8,
    allocator: std.mem.Allocator,
) !std.ArrayList(Sentence) {
    var output = std.ArrayList(Sentence).init(allocator);
    var split_new = Spliterator.init(new);

    new: while (split_new.next()) |new_s| {
        var split_old = Spliterator.init(old);
        while (split_old.next()) |old_s| {
            if (std.mem.eql(u8, old_s.contents, new_s.contents)) {
                try output.append(Sentence{
                    .contents = new_s.contents,
                    .new = false,
                    .off = new_s.off,
                });
                continue :new;
            }
        }
        try output.append(Sentence{
            .contents = new_s.contents,
            .new = true,
            .off = new_s.off,
        });
    }

    return output;
}

test "diffSplit" {
    {
        const old = "foo.bar";
        const new = "foo.baz";
        const result = try diffSplit(old, new, std.testing.allocator);
        defer result.deinit();

        try expectEqual(2, result.items.len);

        try expectEqualStrings("foo", result.items[0].contents);
        try expectEqual(false, result.items[0].new);
        try expectEqualStrings("baz", result.items[1].contents);
        try expectEqual(true, result.items[1].new);
    }

    {
        const old = "foo.bar";
        const new = "bar.foo";
        const result = try diffSplit(old, new, std.testing.allocator);
        defer result.deinit();

        try expectEqual(2, result.items.len);

        try expectEqualStrings("bar", result.items[0].contents);
        try expectEqual(false, result.items[0].new);
        try expectEqualStrings("foo", result.items[1].contents);
        try expectEqual(false, result.items[1].new);
    }

    {
        const old = "foo";
        const new = "baz!bar?foo";
        const result = try diffSplit(old, new, std.testing.allocator);
        defer result.deinit();

        try expectEqual(3, result.items.len);

        try expectEqualStrings("baz", result.items[0].contents);
        try expectEqual(true, result.items[0].new);
        try expectEqualStrings("bar", result.items[1].contents);
        try expectEqual(true, result.items[1].new);
        try expectEqualStrings("foo", result.items[2].contents);
        try expectEqual(false, result.items[2].new);
    }

    {
        const old = "";
        const new = "foo.\n!?bar";
        const result = try diffSplit(old, new, std.testing.allocator);
        defer result.deinit();

        try expectEqual(2, result.items.len);

        try expectEqualStrings("foo", result.items[0].contents);
        try expectEqual(true, result.items[0].new);
        try expectEqual(0, result.items[0].off);
        try expectEqualStrings("bar", result.items[1].contents);
        try expectEqual(true, result.items[1].new);
        try expectEqual(7, result.items[1].off);
    }

    {
        const old = "foobar";
        const new = "foo.bar";
        const result = try diffSplit(old, new, std.testing.allocator);
        defer result.deinit();

        try expectEqual(2, result.items.len);

        try expectEqualStrings("foo", result.items[0].contents);
        try expectEqual(true, result.items[0].new);
        try expectEqualStrings("bar", result.items[1].contents);
        try expectEqual(true, result.items[1].new);
    }
}

const std = @import("std");
const assert = std.debug.assert;
const expectEqual = std.testing.expectEqual;
const expectEqualDeep = std.testing.expectEqualDeep;
const expectEqualStrings = std.testing.expectEqualStrings;
