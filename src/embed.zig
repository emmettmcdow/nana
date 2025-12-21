pub const EmbeddingModel = enum {
    apple_nlembedding,
    jina_embedding,
};

pub const EmbeddingModelOutput = union(EmbeddingModel) {
    apple_nlembedding: *const @Vector(NLEmbedder.VEC_SZ, NLEmbedder.VEC_TYPE),
    jina_embedding: *const @Vector(JinaEmbedder.VEC_SZ, JinaEmbedder.VEC_TYPE),
};

pub const Embedder = struct {
    ptr: *anyopaque,
    splitFn: *const fn (ptr: *anyopaque, contents: []const u8) EmbedIterator,
    embedFn: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, str: []const u8) anyerror!?EmbeddingModelOutput,
    deinitFn: *const fn (self: *anyopaque) void,

    id: EmbeddingModel,
    threshold: f32,
    path: []const u8,

    pub fn split(self: *Embedder, contents: []const u8) EmbedIterator {
        return self.splitFn(self.ptr, contents);
    }

    pub fn embed(self: *Embedder, allocator: std.mem.Allocator, contents: []const u8) !?EmbeddingModelOutput {
        return self.embedFn(self.ptr, allocator, contents);
    }

    pub fn deinit(self: *Embedder) void {
        self.deinitFn(self.ptr);
    }
};

//**************************************************************************************** Embedder
pub const JinaEmbedder = struct {
    pub const VEC_SZ = 512;
    pub const VEC_TYPE = f16;
    pub const ID = EmbeddingModel.jina_embedding;
    pub const THRESHOLD = 0.35;
    pub const PATH = @tagName(ID) ++ ".db";

    pub fn init() !JinaEmbedder {
        return .{};
    }

    pub fn embedder(self: *JinaEmbedder) Embedder {
        return .{
            .ptr = self,
            .splitFn = split,
            .embedFn = embed,
            .deinitFn = deinit,
            .id = ID,
            .threshold = THRESHOLD,
            .path = PATH,
        };
    }

    pub fn deinit(ptr: *anyopaque) void {
        _ = ptr;
    }

    fn split(self: *anyopaque, note: []const u8) EmbedIterator {
        _ = self;
        return EmbedIterator.init(note);
    }

    fn embed(ptr: *anyopaque, allocator: std.mem.Allocator, str: []const u8) !?EmbeddingModelOutput {
        // const self: *NLEmbedder = @ptrCast(@alignCast(ptr));
        _ = ptr;
        _ = str;
        const VecType = @Vector(VEC_SZ, VEC_TYPE);
        const vec_buf: [*]align(@alignOf(VecType)) VEC_TYPE = @ptrCast((try allocator.alignedAlloc(VEC_TYPE, @alignOf(VecType), VEC_SZ)).ptr);
        return EmbeddingModelOutput{
            .jina_embedding = @ptrCast(vec_buf),
        };
    }
};

pub const NLEmbedder = struct {
    embedder_obj: Object,

    pub const VEC_SZ = 512;
    pub const VEC_TYPE = f32;
    pub const ID = EmbeddingModel.apple_nlembedding;
    pub const THRESHOLD = 0.35;
    pub const PATH = @tagName(ID) ++ ".db";

    pub fn init() !NLEmbedder {
        const init_zone = tracy.beginZone(@src(), .{ .name = "embed.zig:init" });
        defer init_zone.end();

        var NSString = objc.getClass("NSString").?;
        var NLEmbedding = objc.getClass("NLEmbedding").?;
        const fromUTF8 = objc.Sel.registerName("stringWithUTF8String:");

        const sentenceEmbeddingForLang = objc.Sel.registerName("sentenceEmbeddingForLanguage:");
        const language = "en";
        const ns_lang = NSString.msgSend(Object, fromUTF8, .{language});

        const embedder_obj = NLEmbedding.msgSend(Object, sentenceEmbeddingForLang, .{ns_lang});
        assert(embedder_obj.getProperty(c_int, "dimension") == VEC_SZ);

        // Retain the Objective-C object to prevent it from being deallocated
        const retain_sel = objc.Sel.registerName("retain");
        _ = embedder_obj.msgSend(Object, retain_sel, .{});

        return .{
            .embedder_obj = embedder_obj,
        };
    }

    pub fn embedder(self: *NLEmbedder) Embedder {
        return .{
            .ptr = self,
            .splitFn = split,
            .embedFn = embed,
            .deinitFn = deinit,
            .id = ID,
            .threshold = THRESHOLD,
            .path = PATH,
        };
    }

    fn deinit(ptr: *anyopaque) void {
        _ = ptr;
    }

    fn split(self: *anyopaque, note: []const u8) EmbedIterator {
        _ = self;
        return EmbedIterator.init(note);
    }

    fn embed(ptr: *anyopaque, allocator: std.mem.Allocator, str: []const u8) !?EmbeddingModelOutput {
        const self: *NLEmbedder = @ptrCast(@alignCast(ptr));

        const zone = tracy.beginZone(@src(), .{ .name = "embed.zig:embed" });
        defer zone.end();

        var NSString = objc.getClass("NSString").?;
        const fromUTF8 = objc.Sel.registerName("stringWithUTF8String:");
        const getVectorForString = objc.Sel.registerName("getVector:forString:");

        if (str.len == 0) {
            std.log.info("Skipping embed of zero-length string\n", .{});
            return null;
        }
        const c_str = try std.fmt.allocPrintZ(allocator, "{s}", .{str});
        const objc_str = NSString.msgSend(Object, fromUTF8, .{c_str.ptr});

        const VecType = @Vector(VEC_SZ, VEC_TYPE);
        const vec_buf: [*]align(@alignOf(VecType)) VEC_TYPE = @ptrCast((try allocator.alignedAlloc(VEC_TYPE, @alignOf(VecType), VEC_SZ)).ptr);
        if (!self.embedder_obj.msgSend(bool, getVectorForString, .{ vec_buf, objc_str })) {
            std.log.err("Failed to embed {s}\n", .{str[0..@min(str.len, 10)]});
            return null;
        }

        return EmbeddingModelOutput{
            .apple_nlembedding = @ptrCast(vec_buf),
        };
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
    _ = try NLEmbedder.init();
}

test "embed - nlembed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var e = out: {
        var e_temp = try NLEmbedder.init();
        break :out e_temp.embedder();
    };

    var output = try e.embed(allocator, "Hello world");
    // We don't check this too hard because the work to save vectors is not worth the reward.
    // Better to check at the interface level. i.e. we don't care what the specific embedding is
    // as long as the output is what we desire. This test is just to verify that the embedder
    // doesn't do anything FUBAR.
    var vec = output.?.apple_nlembedding.*;
    var sum = @reduce(.Add, vec);
    try expectEqual(1.009312, sum);

    output = try e.embed(allocator, "Hello again world");
    vec = output.?.apple_nlembedding.*;
    sum = @reduce(.Add, vec);
    try expectEqual(7.870239, sum);
}

test "embed - jinaembed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var e = out: {
        var e_temp = try JinaEmbedder.init();
        break :out e_temp.embedder();
    };

    const output = try e.embed(allocator, "Hello world");
    const vec = output.?.jina_embedding.*;
    const sum = @reduce(.Add, vec);
    try expectEqual(-2.588e1, sum);
}

test "embed skip empty" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var e = out: {
        var e_temp = try NLEmbedder.init();
        break :out e_temp.embedder();
    };

    try expectEqual(null, try e.embed(allocator, ""));
}

test "embed skip failures" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var e = out: {
        var e_temp = try NLEmbedder.init();
        break :out e_temp.embedder();
    };

    _ = (try e.embed(allocator, "(*^(*&(# 4327897493287498*&)(FKJDHDHLKDJHL")).?;
}

const std = @import("std");
const assert = std.debug.assert;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
const parseFromSliceLeaky = std.json.parseFromSliceLeaky;

const objc = @import("objc");
const Object = objc.Object;
const tracy = @import("tracy");
