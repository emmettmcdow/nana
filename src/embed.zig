//**************************************************************************************** Embedder

pub const Embedder = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    embedder: Object,

    pub fn init(allocator: std.mem.Allocator) !Self {
        const init_zone = tracy.beginZone(@src(), .{ .name = "embed.zig:init" });
        defer init_zone.end();

        var NSString = objc.getClass("NSString").?;
        var NLEmbedding = objc.getClass("NLEmbedding").?;
        const fromUTF8 = objc.Sel.registerName("stringWithUTF8String:");

        const sentenceEmbeddingForLanguage = objc.Sel.registerName("sentenceEmbeddingForLanguage:");
        const language = "en";
        const ns_lang = NSString.msgSend(Object, fromUTF8, .{language});

        const embedder = NLEmbedding.msgSend(Object, sentenceEmbeddingForLanguage, .{ns_lang});
        assert(embedder.getProperty(c_int, "dimension") == vec_sz);

        return Embedder{
            .allocator = allocator,
            .embedder = embedder,
        };
    }
    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn split(self: Self, note: []const u8) EmbedIterator {
        _ = self;
        return EmbedIterator.init(note);
    }

    pub fn embed(self: *Self, str: []const u8) !?[]vec_type {
        const zone = tracy.beginZone(@src(), .{ .name = "embed.zig:embed" });
        defer zone.end();

        var NSString = objc.getClass("NSString").?;
        const fromUTF8 = objc.Sel.registerName("stringWithUTF8String:");
        const getVectorForString = objc.Sel.registerName("getVector:forString:");

        if (str.len == 0) {
            std.log.info("Skipping embed of zero-length string\n", .{});
            return null;
        }
        const c_str = try std.fmt.allocPrintZ(self.allocator, "{s}", .{str});
        defer self.allocator.free(c_str);
        const objc_str = NSString.msgSend(Object, fromUTF8, .{c_str.ptr});

        const vector: []vec_type = try self.allocator.alloc(vec_type, vec_sz);
        if (!self.embedder.msgSend(bool, getVectorForString, .{ vector.ptr, objc_str })) {
            std.log.err("Failed to embed {s}\n", .{str[0..@min(str.len, 10)]});
            return null;
        }

        return vector;
    }
};

pub const Sentence = struct {
    contents: []const u8,
    start_i: u32,
    end_i: u32,
};

pub const EmbedIterator = struct {
    const Self = @This();

    splitter: std.mem.SplitIterator(u8, .any),
    curr_i: u32,

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
        if (self.splitter.next()) |sentence| {
            const out = Sentence{
                .contents = sentence,
                .start_i = self.curr_i,
                .end_i = self.curr_i + @as(u32, @intCast(sentence.len)),
            };
            self.curr_i += @intCast(sentence.len + 1);
            return out;
        } else {
            return null;
        }
    }
};

test "embed - init" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    _ = try Embedder.init(allocator);
}

test "embed - embed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var e = try Embedder.init(allocator);

    var output = try e.embed("Hello world");
    defer if (output) |o| allocator.free(o);
    // We don't check this too hard because the work to save vectors is not worth the reward.
    // Better to check at the interface level. i.e. we don't care what the specific embedding is
    // as long as the output is what we desire. This test is just to verify that the embedder
    // doesn't do anything FUBAR.
    var vec: Vector = output.?[0..vec_sz].*;
    var sum = @reduce(.Add, vec);
    try expectEqual(1.009312, sum);

    output = try e.embed("Hello again world");
    defer if (output) |o| allocator.free(o);
    vec = output.?[0..vec_sz].*;
    sum = @reduce(.Add, vec);
    try expectEqual(7.870239, sum);
}

test "embed skip empty" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var e = try Embedder.init(allocator);

    const vec_slice = try e.embed("Hello world") orelse unreachable;
    defer allocator.free(vec_slice);
}

test "embed skip failures" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var e = try Embedder.init(allocator);

    const vec_slice = try e.embed("(*^(*&(# 4327897493287498*&)(FKJDHDHLKDJHLKFHKLFHD") orelse unreachable;
    defer allocator.free(vec_slice);
}

test "split" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var e = try Embedder.init(allocator);

    const input_str = "foo.bar.baz";
    var splitter = e.split(input_str);
    while (splitter.next()) |chunk| {
        try expectEqualStrings(input_str[chunk.start_i..chunk.end_i], chunk.contents);
    }

    const input_str_2 = "foo..bar";
    splitter = e.split(input_str_2);
    while (splitter.next()) |chunk| {
        try expectEqualStrings(input_str_2[chunk.start_i..chunk.end_i], chunk.contents);
    }

    const input_str_3 = "foo.";
    splitter = e.split(input_str_3);
    while (splitter.next()) |chunk| {
        try expectEqualStrings(input_str_3[chunk.start_i..chunk.end_i], chunk.contents);
    }
}

const std = @import("std");
const assert = std.debug.assert;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
const parseFromSliceLeaky = std.json.parseFromSliceLeaky;

const objc = @import("objc");
const Object = objc.Object;
const Class = objc.Class;
const tracy = @import("tracy");

const types = @import("types.zig");
const Vector = types.Vector;
const vec_sz = types.vec_sz;
const vec_type = types.vec_type;
