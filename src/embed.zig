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
    embedFn: *const fn (
        ptr: *anyopaque,
        allocator: Allocator,
        str: []const u8,
    ) anyerror!?EmbeddingModelOutput,
    deinitFn: *const fn (self: *anyopaque) void,

    id: EmbeddingModel,
    threshold: f32,
    path: []const u8,

    pub fn split(self: *Embedder, contents: []const u8) EmbedIterator {
        return self.splitFn(self.ptr, contents);
    }

    pub fn embed(
        self: *Embedder,
        allocator: Allocator,
        contents: []const u8,
    ) !?EmbeddingModelOutput {
        return self.embedFn(self.ptr, allocator, contents);
    }

    pub fn deinit(self: *Embedder) void {
        self.deinitFn(self.ptr);
    }
};

//**************************************************************************************** Embedder
pub const JinaEmbedder = struct {
    model: Object,
    tokenizer: tokenizer_mod.WordPieceTokenizer,
    tokenizer_alloc: std.heap.ArenaAllocator,

    pub const VEC_SZ = 768;
    pub const VEC_TYPE = f32;
    pub const ID = EmbeddingModel.jina_embedding;
    pub const THRESHOLD = 0.35;
    pub const PATH = @tagName(ID) ++ ".db";
    pub const MODEL_PATH = "models/jina-embeddings-v2-base-en/float32_model.mlpackage";
    pub const TOKENIZER_PATH = "models/jina-embeddings-v2-base-en/tokenizer.json";
    pub const BUNDLE_MODEL_PATH = "jina-embeddings-v2-base-en/float32_model.mlpackage";
    pub const BUNDLE_TOKENIZER_PATH = "jina-embeddings-v2-base-en/tokenizer.json";
    const MAX_SEQ_LEN = 512;

    pub fn init() !JinaEmbedder {
        const init_zone = tracy.beginZone(@src(), .{ .name = "jina_embed.zig:init" });
        defer init_zone.end();

        var tokenizer_alloc = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        errdefer tokenizer_alloc.deinit();

        const tokenizer_path = getModelPath(
            tokenizer_alloc.allocator(),
            TOKENIZER_PATH,
            BUNDLE_TOKENIZER_PATH,
        ) catch {
            return error.TokenizerLoadFailed;
        };

        const tokenizer_file = std.fs.openFileAbsolute(tokenizer_path, .{}) catch |err| {
            std.log.err("Failed to open tokenizer.json: {}\n", .{err});
            return error.TokenizerLoadFailed;
        };
        defer tokenizer_file.close();

        const tokenizer_json = tokenizer_file.readToEndAlloc(
            tokenizer_alloc.allocator(),
            10 * 1024 * 1024,
        ) catch |err| {
            std.log.err("Failed to read tokenizer.json: {}\n", .{err});
            return error.TokenizerLoadFailed;
        };

        const tok = tokenizer_mod.WordPieceTokenizer.init(
            tokenizer_alloc.allocator(),
            tokenizer_json,
        ) catch |err| {
            std.log.err("Failed to parse tokenizer.json: {}\n", .{err});
            return error.TokenizerParseFailed;
        };

        const NSString = objc.getClass("NSString") orelse {
            std.log.err("Failed to get NSString class\n", .{});
            return error.ObjCClassNotFound;
        };
        const NSURL = objc.getClass("NSURL") orelse {
            std.log.err("Failed to get NSURL class\n", .{});
            return error.ObjCClassNotFound;
        };
        const MLModel = objc.getClass("MLModel") orelse {
            std.log.err("Failed to get MLModel class\n", .{});
            return error.ObjCClassNotFound;
        };

        const fromUTF8 = objc.Sel.registerName("stringWithUTF8String:");
        const fileURLWithPath = objc.Sel.registerName("fileURLWithPath:");
        const compileModelAtURL = objc.Sel.registerName("compileModelAtURL:error:");
        const modelWithContentsOfURL = objc.Sel.registerName("modelWithContentsOfURL:error:");

        const full_path = getModelPath(
            tokenizer_alloc.allocator(),
            MODEL_PATH,
            BUNDLE_MODEL_PATH,
        ) catch {
            return error.PathAllocFailed;
        };

        const path_ns = NSString.msgSend(Object, fromUTF8, .{full_path.ptr});
        if (path_ns.value == 0) {
            std.log.err("Failed to create NSString from path\n", .{});
            return error.NSStringCreateFailed;
        }

        const model_url = NSURL.msgSend(Object, fileURLWithPath, .{path_ns});
        if (model_url.value == 0) {
            std.log.err("Failed to create NSURL from path\n", .{});
            return error.NSURLCreateFailed;
        }

        var compile_error: ?Object = null;
        const compiled_url = MLModel.msgSend(Object, compileModelAtURL, .{
            model_url,
            &compile_error,
        });

        if (compile_error) |err| {
            const desc_sel = objc.Sel.registerName("localizedDescription");
            const desc = err.msgSend([*:0]const u8, desc_sel, .{});
            std.log.err("Failed to compile CoreML model: {s}\n", .{desc});
            return error.ModelCompileFailed;
        }

        if (compiled_url.value == 0) {
            std.log.err("Compiled URL is null\n", .{});
            return error.ModelCompileFailed;
        }

        var load_error: ?Object = null;
        const model = MLModel.msgSend(Object, modelWithContentsOfURL, .{
            compiled_url,
            &load_error,
        });

        if (load_error) |err| {
            const desc_sel = objc.Sel.registerName("localizedDescription");
            const desc = err.msgSend([*:0]const u8, desc_sel, .{});
            std.log.err("Failed to load CoreML model: {s}\n", .{desc});
            return error.ModelLoadFailed;
        }

        if (model.value == 0) {
            std.log.err("Model is null\n", .{});
            return error.ModelLoadFailed;
        }

        const retain_sel = objc.Sel.registerName("retain");
        _ = model.msgSend(Object, retain_sel, .{});

        return .{
            .model = model,
            .tokenizer = tok,
            .tokenizer_alloc = tokenizer_alloc,
        };
    }

    pub fn embedder(self: *JinaEmbedder) Embedder {
        return .{
            .ptr = self,
            .splitFn = split,
            .embedFn = embed,
            .deinitFn = deinitFn,
            .id = ID,
            .threshold = THRESHOLD,
            .path = PATH,
        };
    }

    fn deinitFn(ptr: *anyopaque) void {
        const self: *JinaEmbedder = @ptrCast(@alignCast(ptr));
        self.tokenizer_alloc.deinit();
    }

    fn split(self_ptr: *anyopaque, note: []const u8) EmbedIterator {
        _ = self_ptr;
        return EmbedIterator.init(note);
    }

    fn embed(
        ptr: *anyopaque,
        allocator: Allocator,
        str: []const u8,
    ) !?EmbeddingModelOutput {
        const self: *JinaEmbedder = @ptrCast(@alignCast(ptr));

        const zone = tracy.beginZone(@src(), .{ .name = "jina_embed.zig:embed" });
        defer zone.end();

        if (str.len == 0) {
            std.log.info("Skipping embed of zero-length string\n", .{});
            return null;
        }

        const token_ids = try self.tokenizer.tokenize(allocator, str);
        defer allocator.free(token_ids);

        const MODEL_SEQ_LEN: usize = 128;
        const seq_len: usize = @min(token_ids.len, MODEL_SEQ_LEN);

        const MLMultiArray = objc.getClass("MLMultiArray") orelse return error.ObjCClassNotFound;
        const NSNumber = objc.getClass("NSNumber") orelse return error.ObjCClassNotFound;
        const NSArray = objc.getClass("NSArray") orelse return error.ObjCClassNotFound;
        const MLDictionaryFeatureProvider = objc.getClass("MLDictionaryFeatureProvider") orelse return error.ObjCClassNotFound;
        const NSDictionary = objc.getClass("NSDictionary") orelse return error.ObjCClassNotFound;
        const MLFeatureValue = objc.getClass("MLFeatureValue") orelse return error.ObjCClassNotFound;

        const numberWithInt = objc.Sel.registerName("numberWithInt:");
        const arrayWithObjects = objc.Sel.registerName("arrayWithObjects:count:");
        const initWithShape = objc.Sel.registerName("initWithShape:dataType:error:");
        const alloc_sel = objc.Sel.registerName("alloc");
        const setObject = objc.Sel.registerName("setObject:atIndexedSubscript:");
        const initWithDictionary = objc.Sel.registerName("initWithDictionary:error:");
        const predictionFromFeatures = objc.Sel.registerName("predictionFromFeatures:error:");
        const featureValueForName = objc.Sel.registerName("featureValueForName:");
        const multiArrayValue_sel = objc.Sel.registerName("multiArrayValue");
        const dataPointer_sel = objc.Sel.registerName("dataPointer");
        const featureValueWithMultiArray = objc.Sel.registerName("featureValueWithMultiArray:");
        const fromUTF8 = objc.Sel.registerName("stringWithUTF8String:");
        const dictionaryWithObjects = objc.Sel.registerName("dictionaryWithObjects:forKeys:count:");

        const NSString = objc.getClass("NSString").?;

        const batch_size: i32 = 1;
        const model_seq_len_i32: i32 = @intCast(MODEL_SEQ_LEN);
        const batch_num = NSNumber.msgSend(Object, numberWithInt, .{batch_size});
        const seq_num = NSNumber.msgSend(Object, numberWithInt, .{model_seq_len_i32});
        var shape_arr = [_]Object{ batch_num, seq_num };
        const shape = NSArray.msgSend(
            Object,
            arrayWithObjects,
            .{ @as([*]Object, &shape_arr), @as(usize, 2) },
        );

        const MLMultiArrayDataTypeInt32: i32 = 0x20000 | 32; // 131104

        var input_err: ?*anyopaque = null;
        const input_ids_array = MLMultiArray.msgSend(Object, alloc_sel, .{}).msgSend(
            Object,
            initWithShape,
            .{ shape, MLMultiArrayDataTypeInt32, &input_err },
        );
        if (input_err != null) return error.MLMultiArrayInitFailed;
        if (input_ids_array.value == 0) return error.MLMultiArrayInitFailed;

        const attention_mask_array = MLMultiArray.msgSend(Object, alloc_sel, .{}).msgSend(
            Object,
            initWithShape,
            .{ shape, MLMultiArrayDataTypeInt32, &input_err },
        );
        if (input_err != null) return error.MLMultiArrayInitFailed;
        if (attention_mask_array.value == 0) return error.MLMultiArrayInitFailed;

        const zero_val = NSNumber.msgSend(Object, numberWithInt, .{@as(i32, 0)});
        const one_val = NSNumber.msgSend(Object, numberWithInt, .{@as(i32, 1)});

        for (0..MODEL_SEQ_LEN) |i| {
            if (i < seq_len) {
                const token_val = NSNumber.msgSend(
                    Object,
                    numberWithInt,
                    .{@as(i32, @intCast(token_ids[i]))},
                );
                input_ids_array.msgSend(void, setObject, .{ token_val, i });
                attention_mask_array.msgSend(void, setObject, .{ one_val, i });
            } else {
                input_ids_array.msgSend(void, setObject, .{ zero_val, i });
                attention_mask_array.msgSend(void, setObject, .{ zero_val, i });
            }
        }

        const input_ids_fv = MLFeatureValue.msgSend(Object, featureValueWithMultiArray, .{input_ids_array});
        const attention_mask_fv = MLFeatureValue.msgSend(
            Object,
            featureValueWithMultiArray,
            .{attention_mask_array},
        );

        const input_ids_key = NSString.msgSend(Object, fromUTF8, .{"input_ids"});
        const attention_mask_key = NSString.msgSend(Object, fromUTF8, .{"attention_mask"});

        var keys = [_]Object{ input_ids_key, attention_mask_key };
        var values = [_]Object{ input_ids_fv, attention_mask_fv };

        const features_dict = NSDictionary.msgSend(Object, dictionaryWithObjects, .{
            @as([*]Object, &values),
            @as([*]Object, &keys),
            @as(usize, 2),
        });

        var provider_err: ?Object = null;
        const feature_provider = MLDictionaryFeatureProvider.msgSend(
            Object,
            alloc_sel,
            .{},
        ).msgSend(
            Object,
            initWithDictionary,
            .{ features_dict, &provider_err },
        );
        if (provider_err != null) return error.FeatureProviderInitFailed;
        if (feature_provider.value == 0) return error.FeatureProviderInitFailed;

        var pred_err: ?*anyopaque = null;
        const prediction = self.model.msgSend(
            Object,
            predictionFromFeatures,
            .{ feature_provider, &pred_err },
        );

        if (pred_err) |err_ptr| {
            const err_obj = Object{ .value = @intFromPtr(err_ptr) };
            const desc_sel = objc.Sel.registerName("localizedDescription");
            const desc_ns = err_obj.msgSend(Object, desc_sel, .{});
            const utf8_sel = objc.Sel.registerName("UTF8String");
            const desc = desc_ns.msgSend([*:0]const u8, utf8_sel, .{});
            std.log.err("Prediction failed: {s}\n", .{desc});
            return error.PredictionFailed;
        }

        if (prediction.value == 0) {
            std.log.err("Prediction returned null (no error reported)\n", .{});
            return error.PredictionFailed;
        }

        const output_key = NSString.msgSend(Object, fromUTF8, .{"pooler_output"});
        const output_fv = prediction.msgSend(Object, featureValueForName, .{output_key});
        if (output_fv.value == 0) {
            std.log.err("Output feature value is null\n", .{});
            return error.OutputNotFound;
        }

        const output_array = output_fv.msgSend(Object, multiArrayValue_sel, .{});
        if (output_array.value == 0) {
            std.log.err("Output multi array is null\n", .{});
            return error.OutputNotFound;
        }

        const data_ptr = output_array.msgSend([*]VEC_TYPE, dataPointer_sel, .{});

        const VecType = @Vector(VEC_SZ, VEC_TYPE);
        const vec_buf: [*]align(@alignOf(VecType)) VEC_TYPE = @ptrCast((try allocator.alignedAlloc(
            VEC_TYPE,
            @alignOf(VecType),
            VEC_SZ,
        )).ptr);
        @memcpy(vec_buf[0..VEC_SZ], data_ptr[0..VEC_SZ]);

        return EmbeddingModelOutput{
            .jina_embedding = @ptrCast(vec_buf),
        };
    }
};

const tokenizer_mod = @import("tokenizer.zig");

fn getModelPath(
    allocator: Allocator,
    cwd_relative_path: []const u8,
    bundle_relative_path: []const u8,
) ![:0]const u8 {
    const NSBundle = objc.getClass("NSBundle") orelse return error.ObjCClassNotFound;
    const mainBundle_sel = objc.Sel.registerName("mainBundle");
    const resourcePath_sel = objc.Sel.registerName("resourcePath");
    const utf8_sel = objc.Sel.registerName("UTF8String");

    const bundle = NSBundle.msgSend(Object, mainBundle_sel, .{});
    if (bundle.value != 0) {
        const resource_path_ns = bundle.msgSend(Object, resourcePath_sel, .{});
        if (resource_path_ns.value != 0) {
            const resource_path = resource_path_ns.msgSend([*:0]const u8, utf8_sel, .{});
            const bundle_path = try std.fmt.allocPrintZ(
                allocator,
                "{s}/{s}",
                .{ resource_path, bundle_relative_path },
            );

            if (std.fs.accessAbsolute(bundle_path, .{})) |_| {
                return bundle_path;
            } else |_| {
                const cwd = try std.fs.cwd().realpathAlloc(allocator, ".");
                return try std.fmt.allocPrintZ(allocator, "{s}/{s}", .{ cwd, cwd_relative_path });
            }
        }
    }

    const cwd = try std.fs.cwd().realpathAlloc(allocator, ".");
    return try std.fmt.allocPrintZ(allocator, "{s}/{s}", .{ cwd, cwd_relative_path });
}

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

    fn embed(
        ptr: *anyopaque,
        allocator: Allocator,
        str: []const u8,
    ) !?EmbeddingModelOutput {
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
        const vec_buf: [*]align(@alignOf(VecType)) VEC_TYPE = @ptrCast((try allocator.alignedAlloc(
            VEC_TYPE,
            @alignOf(VecType),
            VEC_SZ,
        )).ptr);
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
    defer e.deinit();

    const output = try e.embed(allocator, "Hello world");
    try std.testing.expect(output != null);

    const vec = output.?.jina_embedding.*;
    const sum = @reduce(.Add, vec);
    try expectEqual(-13.268887, sum);
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
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
const parseFromSliceLeaky = std.json.parseFromSliceLeaky;

const objc = @import("objc");
const Object = objc.Object;
const tracy = @import("tracy");
