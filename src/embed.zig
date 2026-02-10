// Note on Objective-C runtime
// Because we are calling into a garbage-collected language (Objective-C), we need to manage our
// memory accordingly. When a new Object is created (typically through `msgSend(Object...`), the
// runtime needs to know whether it can GC that instance. This is done through
// - Object.retain() - indicates we need this instance, incrementing the refence counter.
// - Object.release() - indicates we are finished with this object, decrementing the ref counter.
// - objc.AutoreleasePool.init() and .deinit() - works like an arena.
// Most allocated objects start with a reference counter of 1, so there is no need to `retain` an
// object most of the time. The only time we need to explicitly retain is when we get an object
// from some parent object which we release. The release cascades down to children.
// AutoreleasePools don't work for explicit allocations.
pub const EmbeddingModel = enum {
    apple_nlembedding,
    mpnet_embedding,
};

pub const EmbeddingModelOutput = union(EmbeddingModel) {
    apple_nlembedding: *const @Vector(NLEmbedder.VEC_SZ, NLEmbedder.VEC_TYPE),
    mpnet_embedding: *const @Vector(MpnetEmbedder.VEC_SZ, MpnetEmbedder.VEC_TYPE),
};

pub const Embedder = struct {
    ptr: *anyopaque,
    splitFn: *const fn (ptr: *anyopaque, contents: []const u8) SentenceSpliterator,
    embedFn: *const fn (
        ptr: *anyopaque,
        allocator: Allocator,
        str: []const u8,
    ) anyerror!?EmbeddingModelOutput,
    deinitFn: *const fn (self: *anyopaque) void,

    id: EmbeddingModel,
    threshold: f32,
    strict_threshold: f32,
    path: []const u8,

    pub fn split(self: *Embedder, contents: []const u8) SentenceSpliterator {
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
pub const MpnetEmbedder = struct {
    model: Object,
    tokenizer: tokenizer_mod.WordPieceTokenizer,
    tokenizer_alloc: std.heap.ArenaAllocator,

    pub const VEC_SZ = 768;
    pub const VEC_TYPE = f32;
    pub const ID = EmbeddingModel.mpnet_embedding;
    pub const THRESHOLD = 0.36;
    pub const STRICT_THRESHOLD = THRESHOLD + 0.1;
    pub const PATH = @tagName(ID) ++ ".db";
    pub const MODEL_PATH = "share/nana/all_mpnet_base_v2.mlpackage";
    pub const TOKENIZER_PATH = "share/nana/tokenizer.json";
    pub const BUNDLE_MODEL_PATH = "all_mpnet_base_v2.mlmodelc";
    pub const BUNDLE_TOKENIZER_PATH = "tokenizer.json";
    const MAX_SEQ_LEN = 512;

    // The calling Swift thread wraps this in an AutoreleasePool, so we do not need to release
    // anything here. We only need to retain the model and the rest will be cleaned up.
    pub fn init() !MpnetEmbedder {
        const init_zone = tracy.beginZone(@src(), .{ .name = "embed.zig:MpnetEmbedder.init" });
        defer init_zone.end();
        const pool = objc.AutoreleasePool.init();
        defer pool.deinit();
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

        var tok: WordPieceTokenizer = undefined;
        tok.init(
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

        const is_precompiled = std.mem.endsWith(u8, std.mem.sliceTo(full_path, 0), ".mlmodelc");

        const load_url = if (is_precompiled) model_url else compiled: {
            var compile_error: ?*anyopaque = null;
            const compiled_url = MLModel.msgSend(Object, compileModelAtURL, .{
                model_url,
                &compile_error,
            });
            if (compile_error) |err_ptr| {
                const err = Object{ .value = @intFromPtr(err_ptr) };
                const desc_sel = objc.Sel.registerName("localizedDescription");
                const desc = err.msgSend([*:0]const u8, desc_sel, .{});
                std.log.err("Failed to compile CoreML model: {s}\n", .{desc});
                return error.ModelCompileFailed;
            }
            if (compiled_url.value == 0) {
                std.log.err("Compiled URL is null\n", .{});
                return error.ModelCompileFailed;
            }
            break :compiled compiled_url;
        };

        var load_error: ?*anyopaque = null;
        const model = MLModel.msgSend(Object, modelWithContentsOfURL, .{
            load_url,
            &load_error,
        });
        errdefer model.release();
        if (load_error) |err_ptr| {
            const err = Object{ .value = @intFromPtr(err_ptr) };
            const desc_sel = objc.Sel.registerName("localizedDescription");
            const desc = err.msgSend([*:0]const u8, desc_sel, .{});
            std.log.err("Failed to load CoreML model: {s}\n", .{desc});
            return error.ModelLoadFailed;
        }
        if (model.value == 0) {
            std.log.err("Model is null\n", .{});
            return error.ModelLoadFailed;
        }

        return .{
            .model = model.retain(),
            .tokenizer = tok,
            .tokenizer_alloc = tokenizer_alloc,
        };
    }

    pub fn embedder(self: *MpnetEmbedder) Embedder {
        return .{
            .ptr = self,
            .splitFn = split,
            .embedFn = embed,
            .deinitFn = deinitFn,
            .id = ID,
            .threshold = THRESHOLD,
            .strict_threshold = STRICT_THRESHOLD,
            .path = PATH,
        };
    }

    pub fn deinit(self: *MpnetEmbedder) void {
        self.model.release();
        self.tokenizer_alloc.deinit();
    }

    fn deinitFn(ptr: *anyopaque) void {
        const self: *MpnetEmbedder = @ptrCast(@alignCast(ptr));
        self.deinit();
    }

    fn split(self_ptr: *anyopaque, note: []const u8) SentenceSpliterator {
        _ = self_ptr;
        return SentenceSpliterator.init(note);
    }

    fn embed(
        ptr: *anyopaque,
        allocator: Allocator,
        str: []const u8,
    ) !?EmbeddingModelOutput {
        const self: *MpnetEmbedder = @ptrCast(@alignCast(ptr));
        const zone = tracy.beginZone(@src(), .{ .name = "embed.zig:MpnetEmbedder.embed" });
        defer zone.end();
        const pool = objc.AutoreleasePool.init();
        defer pool.deinit();

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
        defer input_ids_array.release();
        if (input_err != null) return error.MLMultiArrayInitFailed;
        if (input_ids_array.value == 0) return error.MLMultiArrayInitFailed;

        const attention_mask_array = MLMultiArray.msgSend(Object, alloc_sel, .{}).msgSend(
            Object,
            initWithShape,
            .{ shape, MLMultiArrayDataTypeInt32, &input_err },
        );
        defer attention_mask_array.release();
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

        const input_ids_fv = MLFeatureValue.msgSend(
            Object,
            featureValueWithMultiArray,
            .{input_ids_array},
        );
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

        var provider_err: ?*anyopaque = null;
        const feature_provider = MLDictionaryFeatureProvider.msgSend(
            Object,
            alloc_sel,
            .{},
        ).msgSend(
            Object,
            initWithDictionary,
            .{ features_dict, &provider_err },
        );
        defer feature_provider.release();
        if (provider_err != null) return error.FeatureProviderInitFailed;
        if (feature_provider.value == 0) return error.FeatureProviderInitFailed;

        // Note to future me: This prediction section is by far the slowest section. Should you
        // choose to optimize it, look here first.
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
        // End of the prediction block

        const output_key = NSString.msgSend(Object, fromUTF8, .{"embeddings"});
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

        const output_slice = try allocator.alignedAlloc(
            VEC_TYPE,
            @alignOf(@Vector(VEC_SZ, VEC_TYPE)),
            VEC_SZ,
        );
        @memcpy(output_slice[0..VEC_SZ], data_ptr[0..VEC_SZ]);

        return EmbeddingModelOutput{
            .mpnet_embedding = @as(*const @Vector(VEC_SZ, VEC_TYPE), @ptrCast(output_slice)),
        };
    }
};

fn getModelPath(
    allocator: Allocator,
    exe_relative_path: []const u8,
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
                return try getExeRelativePath(allocator, exe_relative_path);
            }
        }
    }

    return try getExeRelativePath(allocator, exe_relative_path);
}

fn getExeRelativePath(allocator: Allocator, relative_path: []const u8) ![:0]const u8 {
    var exe_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe_path = std.fs.selfExeDirPath(&exe_path_buf) catch |err| {
        std.log.err("Failed to get executable path: {}\n", .{err});
        return error.ExePathFailed;
    };

    // Try exe-relative path first
    const exe_relative = try std.fmt.allocPrintZ(
        allocator,
        "{s}/../{s}",
        .{ exe_path, relative_path },
    );
    std.fs.accessAbsolute(exe_relative, .{}) catch {
        // This is the case where we are testing, files are in a different place.
        allocator.free(exe_relative);
        const cwd = try std.fs.cwd().realpathAlloc(allocator, ".");
        defer allocator.free(cwd);
        return try std.fmt.allocPrintZ(allocator, "{s}/zig-out/{s}", .{ cwd, relative_path });
    };
    return exe_relative;
}

pub const NLEmbedder = struct {
    embedder_obj: Object,
    mutex: Mutex,

    pub const VEC_SZ = 512;
    pub const VEC_TYPE = f32;
    pub const ID = EmbeddingModel.apple_nlembedding;
    pub const THRESHOLD = 0.40;
    pub const STRICT_THRESHOLD = THRESHOLD * 2;
    pub const PATH = @tagName(ID) ++ ".db";

    pub fn init() !NLEmbedder {
        const init_zone = tracy.beginZone(@src(), .{ .name = "embed.zig:init" });
        defer init_zone.end();
        const pool = objc.AutoreleasePool.init();
        defer pool.deinit();

        var NSString = objc.getClass("NSString").?;
        var NLEmbedding = objc.getClass("NLEmbedding").?;
        const fromUTF8 = objc.Sel.registerName("stringWithUTF8String:");

        const sentenceEmbeddingForLang = objc.Sel.registerName("sentenceEmbeddingForLanguage:");
        const language = "en";
        const ns_lang = NSString.msgSend(Object, fromUTF8, .{language});

        const embedder_obj = NLEmbedding.msgSend(Object, sentenceEmbeddingForLang, .{ns_lang});
        if (embedder_obj.value == 0) {
            std.log.err("NLEmbedding.sentenceEmbeddingForLanguage returned nil - ensure this is called from main thread", .{});
            return error.EmbedderInitFailed;
        }
        assert(embedder_obj.getProperty(c_int, "dimension") == VEC_SZ);

        return .{
            .embedder_obj = embedder_obj.retain(),
            .mutex = Mutex{},
        };
    }

    pub fn embedder(self: *NLEmbedder) Embedder {
        return .{
            .ptr = self,
            .splitFn = split,
            .embedFn = embed,
            .deinitFn = deinitFn,
            .id = ID,
            .threshold = THRESHOLD,
            .strict_threshold = STRICT_THRESHOLD,
            .path = PATH,
        };
    }

    pub fn deinit(self: *NLEmbedder) void {
        self.embedder_obj.release();
    }

    fn deinitFn(ptr: *anyopaque) void {
        const self: *NLEmbedder = @ptrCast(@alignCast(ptr));
        self.deinit();
    }

    fn split(self: *anyopaque, note: []const u8) SentenceSpliterator {
        _ = self;
        return SentenceSpliterator.init(note);
    }

    fn embed(
        ptr: *anyopaque,
        allocator: Allocator,
        str: []const u8,
    ) !?EmbeddingModelOutput {
        const self: *NLEmbedder = @ptrCast(@alignCast(ptr));
        const zone = tracy.beginZone(@src(), .{ .name = "embed.zig:embed" });
        defer zone.end();
        const pool = objc.AutoreleasePool.init();
        defer pool.deinit();

        var NSString = objc.getClass("NSString").?;
        const fromUTF8 = objc.Sel.registerName("stringWithUTF8String:");
        const getVectorForString = objc.Sel.registerName("getVector:forString:");

        if (str.len == 0 or str[0] == 0) {
            std.log.info("Skipping embed of zero-length string\n", .{});
            return null;
        }
        const c_str = try std.fmt.allocPrintZ(allocator, "{s}", .{str});
        defer allocator.free(c_str);
        const objc_str = NSString.msgSend(Object, fromUTF8, .{c_str.ptr});
        // defer objc_str.release();

        const VecType = @Vector(VEC_SZ, VEC_TYPE);
        const vec_buf: [*]align(@alignOf(VecType)) VEC_TYPE = @ptrCast((try allocator.alignedAlloc(
            VEC_TYPE,
            @alignOf(VecType),
            VEC_SZ,
        )).ptr);
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!self.embedder_obj.msgSend(bool, getVectorForString, .{ vec_buf, objc_str })) {
            std.log.warn("Failed to embed '{s}'\n", .{str[0..@min(str.len, 10)]});
            return null;
        }

        return EmbeddingModelOutput{
            .apple_nlembedding = @ptrCast(vec_buf),
        };
    }
};

pub const Chunk = struct {
    contents: []const u8,
    start_i: u32,
    end_i: u32,
    type: Type,

    pub const Type = enum { string, url };
};

pub fn Spliterator(comptime delimiters: []const u8) type {
    return struct {
        buffer: []const u8,
        index: usize,
        curr_i: u32,

        const Self = @This();
        const url_prefixes = [_][]const u8{ "https://", "http://" };

        fn isDelimiter(c: u8) bool {
            for (delimiters) |d| {
                if (c == d) return true;
            }
            return false;
        }

        fn isUrlEnd(c: u8) bool {
            return c == ' ' or c == '\n' or c == '\t';
        }

        fn findUrlPrefix(buf: []const u8) ?usize {
            for (url_prefixes) |prefix| {
                if (std.mem.startsWith(u8, buf, prefix)) return prefix.len;
            }
            return null;
        }

        pub fn init(buffer: []const u8) Self {
            return .{
                .buffer = buffer,
                .index = 0,
                .curr_i = 0,
            };
        }

        pub fn next(self: *Self) ?Chunk {
            if (self.index >= self.buffer.len) return null;

            while (self.index < self.buffer.len and isDelimiter(self.buffer[self.index])) {
                self.index += 1;
                self.curr_i += 1;
            }

            if (self.index >= self.buffer.len) return null;

            if (findUrlPrefix(self.buffer[self.index..])) |_| {
                const start = self.index;
                while (self.index < self.buffer.len and !isUrlEnd(self.buffer[self.index])) {
                    self.index += 1;
                }
                const contents = self.buffer[start..self.index];
                const out = Chunk{
                    .contents = contents,
                    .start_i = self.curr_i,
                    .end_i = self.curr_i + @as(u32, @intCast(contents.len)),
                    .type = .url,
                };
                self.curr_i += @intCast(contents.len);
                return out;
            }

            const start = self.index;
            while (self.index < self.buffer.len and !isDelimiter(self.buffer[self.index])) {
                if (findUrlPrefix(self.buffer[self.index..])) |_| break;
                self.index += 1;
            }

            var end = self.index;
            while (end > start and self.buffer[end - 1] == ' ') {
                end -= 1;
            }

            if (end == start) return self.next();

            const contents = self.buffer[start..end];
            const out = Chunk{
                .contents = contents,
                .start_i = self.curr_i,
                .end_i = self.curr_i + @as(u32, @intCast(contents.len)),
                .type = .string,
            };
            self.curr_i += @intCast(self.index - start);
            return out;
        }

        pub fn collectAll(self: *Self, allocator: Allocator) ![]Chunk {
            var list = std.ArrayList(Chunk).init(allocator);
            errdefer list.deinit();
            while (self.next()) |chunk| {
                try list.append(chunk);
            }
            return list.toOwnedSlice();
        }
    };
}

const WORD_SPLIT_DELIMITERS = ".!?\n, ();\":";
pub const WordSpliterator = Spliterator(WORD_SPLIT_DELIMITERS);
const SENTENCE_SPLIT_DELIMITERS = ".!?\n";
pub const SentenceSpliterator = Spliterator(SENTENCE_SPLIT_DELIMITERS);

test "spliterator - does not split on delimiters inside URLs" {
    const ResultType = struct { contents: []const u8, type: Chunk.Type };
    const cases = [_]struct {
        input: []const u8,
        expected: []const ResultType,
    }{
        .{
            .input = "foo https://google.com",
            .expected = &[_]ResultType{
                .{ .contents = "foo", .type = .string },
                .{ .contents = "https://google.com", .type = .url },
            },
        },
        .{
            .input = "foo http://foobar.net",
            .expected = &[_]ResultType{
                .{ .contents = "foo", .type = .string },
                .{ .contents = "http://foobar.net", .type = .url },
            },
        },
        .{
            .input = "foo https://en.wikipedia.org/wiki/Dog",
            .expected = &[_]ResultType{
                .{ .contents = "foo", .type = .string },
                .{ .contents = "https://en.wikipedia.org/wiki/Dog", .type = .url },
            },
        },
        .{
            .input = "one https://en.wikipedia.org/wiki/Dog\n2 https://en.wikipedia.org/wiki/Cat",
            .expected = &[_]ResultType{
                .{ .contents = "one", .type = .string },
                .{ .contents = "https://en.wikipedia.org/wiki/Dog", .type = .url },
                .{ .contents = "2", .type = .string },
                .{ .contents = "https://en.wikipedia.org/wiki/Cat", .type = .url },
            },
        },
    };

    for (cases) |case| {
        var splitter = SentenceSpliterator.init(case.input);
        const chunks = try splitter.collectAll(std.testing.allocator);
        defer std.testing.allocator.free(chunks);

        for (case.expected, chunks) |expected, chunk| {
            try expectEqualStrings(expected.contents, chunk.contents);
            try expectEqual(expected.type, chunk.type);
        }
    }
}

test "embed - nlembed solo" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var nl = try NLEmbedder.init();
    defer nl.deinit();

    var e = nl.embedder();

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

test "embed - mpnetembed init with autorelease pool (simulates Swift caller)" {
    // Swift has an autorelease pool on the calling thread. If init() over-releases
    // autoreleased objects, the pool drain will crash with EXC_BAD_ACCESS.
    const pool = objc.AutoreleasePool.init();
    var mpnet = try MpnetEmbedder.init();
    pool.deinit(); // drains the pool — crashes here if double-release
    defer mpnet.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var e = mpnet.embedder();
    const output = try e.embed(arena.allocator(), "Hello world");
    try std.testing.expect(output != null);
}

test "embed - nlembedder init with autorelease pool (simulates Swift caller)" {
    // Swift has an autorelease pool on the calling thread. If init() over-releases
    // autoreleased objects, the pool drain will crash with EXC_BAD_ACCESS.
    const pool = objc.AutoreleasePool.init();
    var nlembed = try NLEmbedder.init();
    pool.deinit(); // drains the pool — crashes here if double-release
    defer nlembed.deinit();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var e = nlembed.embedder();
    const output = try e.embed(arena.allocator(), "Hello world");
    try std.testing.expect(output != null);
}

test "embed - mpnetembed solo" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var mpnet = try MpnetEmbedder.init();
    defer mpnet.deinit();

    var e = mpnet.embedder();

    const output = try e.embed(allocator, "Hello world");
    try std.testing.expect(output != null);

    const vec = output.?.mpnet_embedding.*;
    const vec_array: [768]f32 = vec;
    try expectEqualSlices(
        f32,
        &.{ -1.0877479e-2, 5.3974453e-2, -3.3752674e-3 },
        vec_array[0..3],
    );

    // From the Python reference implementation
    const sum = @reduce(.Add, vec);
    try expectEqual(-1.0041979e-1, sum);
}

test "embed skip empty" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var nl = try NLEmbedder.init();
    defer nl.deinit();

    var e = nl.embedder();

    try expectEqual(null, try e.embed(allocator, ""));
}

test "embed skip failures" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var nl = try NLEmbedder.init();
    defer nl.deinit();

    var e = nl.embedder();

    _ = (try e.embed(allocator, "(*^(*&(# 4327897493287498*&)(FKJDHDHLKDJHL")).?;
}

test "embed - nlembed thread safety" {
    var nl = try NLEmbedder.init();
    defer nl.deinit();
    var e = nl.embedder();
    try threadSafetyTest(&e);
}

test "embed - mpnetembed thread safety" {
    var mpnet = try MpnetEmbedder.init();
    defer mpnet.deinit();
    var e = mpnet.embedder();
    try threadSafetyTest(&e);
}

fn threadSafetyTest(e: *Embedder) !void {
    const n_threads = 4;
    const n_iters = 50;
    const inputs = [_][]const u8{
        "Hello world",
        "The quick brown fox jumps over the lazy dog",
        "Machine learning is fascinating",
        "Zig is a systems programming language",
    };

    var barrier = std.Thread.ResetEvent{};
    var threads: [n_threads]std.Thread = undefined;
    for (&threads, 0..) |*t, i| {
        t.* = try std.Thread.spawn(.{}, struct {
            fn run(embedder: *Embedder, input: []const u8, b: *std.Thread.ResetEvent) void {
                b.wait();
                for (0..n_iters) |_| {
                    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
                    defer arena.deinit();
                    const result = embedder.embed(arena.allocator(), input) catch |err| {
                        std.debug.panic("embed failed: {}", .{err});
                    };
                    std.debug.assert(result != null);
                }
            }
        }.run, .{ e, inputs[i], &barrier });
    }
    barrier.set();
    for (&threads) |*t| t.join();
}

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
const expectEqualSlices = std.testing.expectEqualSlices;
const parseFromSliceLeaky = std.json.parseFromSliceLeaky;
const tokenizer_mod = @import("tokenizer.zig");
const WordPieceTokenizer = tokenizer_mod.WordPieceTokenizer;
const Mutex = std.Thread.Mutex;

const objc = @import("objc");
const Object = objc.Object;
const tracy = @import("tracy");
