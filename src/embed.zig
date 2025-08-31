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

    pub fn split(self: Self, note: []const u8) std.mem.SplitIterator(u8, .any) {
        _ = self;
        return .{
            .index = 0,
            .buffer = note,
            .delimiter = ".!?\n",
        };
    }

    pub fn embed(self: *Self, str: []const u8) !?Vector {
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

        var vector: []vec_type = try self.allocator.alloc(vec_type, vec_sz);
        if (!self.embedder.msgSend(bool, getVectorForString, .{ vector.ptr, objc_str })) {
            std.log.err("Failed to embed {s}\n", .{str[0..@min(str.len, 10)]});
            return null;
        }

        return vector[0..vec_sz].*;
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
    // We don't check this too hard because the work to save vectors is not worth the reward.
    // Better to check at the interface level. i.e. we don't care what the specific embedding is
    // as long as the output is what we desire. This test is just to verify that the embedder
    // doesn't do anything FUBAR.
    var sum = @reduce(.Add, output.?);
    try expectEqual(1.009312, sum);

    output = try e.embed("Hello again world");
    sum = @reduce(.Add, output.?);
    try expectEqual(7.870239, sum);
}

test "embed skip empty" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var e = try Embedder.init(allocator);

    _ = try e.embed("Hello world") orelse assert(false);
}

test "embed skip failures" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var e = try Embedder.init(allocator);

    _ = try e.embed("(*^(*&(# 4327897493287498*&)(FKJDHDHLKDJHLKFHKLFHD") orelse assert(false);
}

const std = @import("std");
const assert = std.debug.assert;
const expectEqual = std.testing.expectEqual;
const parseFromSliceLeaky = std.json.parseFromSliceLeaky;

const objc = @import("objc");
const Object = objc.Object;
const Class = objc.Class;
const tracy = @import("tracy");

const types = @import("types.zig");
const Vector = types.Vector;
const vec_sz = types.vec_sz;
const vec_type = types.vec_type;
