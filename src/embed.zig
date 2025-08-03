//**************************************************************************************** Embedder

pub const Embedder = struct {
    const Self = @This();

    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !Self {
        return Embedder{
            .allocator = allocator,
        };
    }
    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn embed(self: *Self, sentence: []const u8) !?Vector {
        const language = "en";
        // Types
        var NSString = objc.getClass("NSString").?;
        var NLEmbedding = objc.getClass("NLEmbedding").?;
        // Functions
        const fromUTF8 = objc.Sel.registerName("stringWithUTF8String:");
        const sentenceEmbeddingForLanguage = objc.Sel.registerName("sentenceEmbeddingForLanguage:");
        const getVectorForString = objc.Sel.registerName("getVector:forString:");

        if (sentence.len == 0) return null;

        // Ensure sentence is null-terminated for stringWithUTF8String:
        const null_terminated_sentence = if (sentence.len > 0 and sentence[sentence.len - 1] == 0)
            sentence.ptr
        else
            (try std.fmt.allocPrintZ(self.allocator, "{s}", .{sentence})).ptr;

        // Do the work
        const ns_lang = NSString.msgSend(Object, fromUTF8, .{language});
        const ns_input = NSString.msgSend(Object, fromUTF8, .{null_terminated_sentence});
        // std.debug.print("String: {s}, ns_input: {}\n", .{ sentence, ns_input });
        const embedding = NLEmbedding.msgSend(Object, sentenceEmbeddingForLanguage, .{ns_lang});
        assert(embedding.getProperty(c_int, "dimension") == vec_sz);
        var vector: []vec_type = try self.allocator.alloc(vec_type, vec_sz);
        if (!embedding.msgSend(bool, getVectorForString, .{ vector[0..vec_sz], ns_input })) {
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

const types = @import("types.zig");
const Vector = types.Vector;
const vec_sz = types.vec_sz;
const vec_type = types.vec_type;
