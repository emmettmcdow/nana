const std = @import("std");
const parseFromSliceLeaky = std.json.parseFromSliceLeaky;

const onnx = @import("onnxruntime");

//**************************************************************************************** Embedder

pub const Embedder = struct {
    const Self = @This();

    onnx_instance: *onnx.OnnxInstance,
    allocator: std.mem.Allocator,
    // Input
    input_ids: []i64,
    attention_masks: []i64,
    token_type_ids: []i64,
    // Output
    last: []f32,

    pub fn init(allocator: std.mem.Allocator, model: [:0]const u8) !Self {
        const onnx_opts = onnx.OnnxInstanceOpts{
            .log_id = "ZIG",
            .log_level = .warning,
            .model_path = model,
            .input_names = &.{ "input_ids", "attention_mask", "token_type_ids" },
            .output_names = &.{"last_hidden_state"},
        };
        // const one = std.time.microTimestamp();
        var onnx_instance = try onnx.OnnxInstance.init(allocator, onnx_opts);
        // const two = std.time.microTimestamp();
        // std.debug.print("Onnx took {d} ms to init\n", .{two - one});
        try onnx_instance.initMemoryInfo("Cpu", .arena, 0, .default);

        const batch = 8; // TODO: change me
        //////////////
        //  Inputs  //
        //////////////
        const size_input_id: usize = 1 * batch;
        const input_id_node_dimms: []const i64 = &.{ 1, batch };
        var input_ids: [size_input_id]i64 = undefined;
        @memset(&input_ids, 0);
        const input_id_ort_input = try onnx_instance.createTensorWithDataAsOrtValue(
            i64,
            &input_ids,
            input_id_node_dimms,
            .i64,
        );

        const size_attention_mask: usize = 1 * batch;
        const attention_mask_node_dimms: []const i64 = &.{ 1, batch };
        var attention_masks: [size_attention_mask]i64 = undefined;
        @memset(&attention_masks, 0);
        const attention_mask_ort_input = try onnx_instance.createTensorWithDataAsOrtValue(
            i64,
            &attention_masks,
            attention_mask_node_dimms,
            .i64,
        );

        const size_token_type_id: usize = 1 * batch;
        const token_type_id_node_dimms: []const i64 = &.{ 1, batch };
        var token_type_ids: [size_token_type_id]i64 = undefined;
        @memset(&token_type_ids, 0);
        const token_type_id_ort_input = try onnx_instance.createTensorWithDataAsOrtValue(
            i64,
            &token_type_ids,
            token_type_id_node_dimms,
            .i64,
        );

        const ort_inputs = try allocator.dupe(*onnx.c_api.OrtValue, &.{
            input_id_ort_input,
            attention_mask_ort_input,
            token_type_id_ort_input,
        });

        ///////////////
        //  Outputs  //
        ///////////////
        const vector_ln: usize = 1024;
        const size_last: usize = 1 * batch * vector_ln;
        const last_node_dimms: []const i64 = &.{
            1,
            batch,
            vector_ln,
        };
        var last: [size_last]f32 = undefined;
        @memset(&last, 0);
        const last_ort_output = try onnx_instance.createTensorWithDataAsOrtValue(
            f32,
            &last,
            last_node_dimms,
            .f32,
        );

        const ort_outputs = try allocator.dupe(?*onnx.c_api.OrtValue, &.{
            last_ort_output,
        });

        onnx_instance.setManagedInputsOutputs(ort_inputs, ort_outputs);

        return Embedder{
            .onnx_instance = onnx_instance,
            .allocator = allocator,
            .input_ids = &input_ids,
            .attention_masks = &attention_masks,
            .token_type_ids = &token_type_ids,
            .last = &last,
        };
    }
    pub fn deinit(self: *Self) void {
        // _ = self;
        // Possibly not necessary due to arena usage?
        self.onnx_instance.deinit_arena();
    }

    pub fn embed(self: *Self, tokens: Tokens) ![]f32 {
        // Clear out the last result
        @memset(&self.input_ids, 0);
        @memset(&self.attention_masks, 0);
        @memset(&self.token_type_ids, 0);
        @memset(&self.last, 0);

        // Copy in the new input
        @memcpy(self.input_ids, tokens.input_ids);
        @memcpy(self.attention_mask, tokens.attention_mask);
        @memcpy(self.token_type_ids, tokens.token_type_ids);
        try self.onnx_instance.run();
        return self.last;
    }
};

//*************************************************************************************** Tokenizer
const Tokens = struct {
    input_ids: []const u16,
    attention_mask: []const u8,
    token_type_ids: []const u8,
};

fn toLower(str: []const u8, buf: []u8) []u8 {
    if (str.len >= MAX_TOKEN_LENGTH) unreachable;
    for (str, 0..) |c, i| {
        // TODO: handle non-ascii?
        if (!std.ascii.isAscii(c)) unreachable;
        buf[i] = std.ascii.toLower(c);
    }
    return buf[0..str.len];
}

// TODO: max token length can likely be shorter
const MAX_TOKEN_LENGTH = 64;
const MAX_SENTENCE_TOKENS = 64;
const MEGABYTE = 1000000;

const TokenConfig = struct {
    model: TokenConfigModel,
};
const TokenConfigModel = struct {
    vocab: std.json.ArrayHashMap(u16),
};

pub const Tokenizer = struct {
    map: std.StringArrayHashMapUnmanaged(u16),
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) !Self {
        const wholeFile = comptime @embedFile("tokenizer.json")[0..];
        // const wholeFile: [1000]u8 = undefined;
        // Leaky is needed because we will be using arena
        const parsed = try parseFromSliceLeaky(
            TokenConfig,
            allocator,
            wholeFile,
            .{ .ignore_unknown_fields = true },
        );

        return Tokenizer{
            .map = parsed.model.vocab.map,
            .allocator = allocator,
        };
    }

    pub fn tokenize(self: *Self, input: []const u8) !Tokens {
        var input_buf = try self.allocator.alloc(u16, MAX_SENTENCE_TOKENS);
        @memset(input_buf, 0);
        var attention_buf = try self.allocator.alloc(u8, MAX_SENTENCE_TOKENS);
        @memset(attention_buf, 0);
        // This will not change. Zeros only for now
        var type_buf = try self.allocator.alloc(u8, MAX_SENTENCE_TOKENS);
        @memset(type_buf, 0);

        // First token will always be 101
        // TODO: update this to read from the Config
        input_buf[0] = 101;
        attention_buf[0] = 1;

        var it = std.mem.splitSequence(u8, input, " ");
        var tok: u16 = undefined;
        var i: usize = 1;
        while (it.next()) |word| {
            var wordbuf: [MAX_TOKEN_LENGTH]u8 = undefined;
            const lowerWord = toLower(word, &wordbuf);
            tok = self.map.get(lowerWord) orelse {
                std.debug.print("we are bailing here!\n", .{});
                unreachable;
            };
            input_buf[i] = tok;
            attention_buf[i] = 1;
            i += 1;
            if (i >= MAX_SENTENCE_TOKENS) unreachable;
        }

        // Last token will always be 102
        // TODO: update this to read from the Config
        input_buf[i] = 102;
        attention_buf[i] = 1;
        i += 1;

        return Tokens{
            .input_ids = input_buf[0..i],
            .attention_mask = attention_buf[0..i],
            .token_type_ids = type_buf[0..i],
        };
    }
};

const expect = std.testing.expect;
const expectEqualSlices = std.testing.expectEqualSlices;
// FYI for tests - cwd() is relative to the dir that the `zig build test` command was called
// from. NOT the source file directory OR the binary directory
test "hello" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var t = try Tokenizer.init(allocator);

    const input: []const u8 = "hello";
    const expected = Tokens{
        .input_ids = &.{ 101, 7592, 102 },
        .attention_mask = &.{ 1, 1, 1 },
        .token_type_ids = &.{ 0, 0, 0 },
    };

    const output = try t.tokenize(input);
    try expectEqualSlices(u16, output.input_ids, expected.input_ids);
    try expectEqualSlices(u8, output.attention_mask, expected.attention_mask);
    try expectEqualSlices(u8, output.token_type_ids, expected.token_type_ids);
}

test "YES SIR" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var t = try Tokenizer.init(allocator);

    const input: []const u8 = "YES SIR";
    const expected = Tokens{
        .input_ids = &.{ 101, 2748, 2909, 102 },
        .attention_mask = &.{ 1, 1, 1, 1 },
        .token_type_ids = &.{ 0, 0, 0, 0 },
    };

    const output = try t.tokenize(input);
    try expectEqualSlices(u16, output.input_ids, expected.input_ids);
    try expectEqualSlices(u8, output.attention_mask, expected.attention_mask);
    try expectEqualSlices(u8, output.token_type_ids, expected.token_type_ids);
}

test "yes sir" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var t = try Tokenizer.init(allocator);

    const input: []const u8 = "yes sir";
    const expected = Tokens{
        .input_ids = &.{ 101, 2748, 2909, 102 },
        .attention_mask = &.{ 1, 1, 1, 1 },
        .token_type_ids = &.{ 0, 0, 0, 0 },
    };

    const output = try t.tokenize(input);
    try expectEqualSlices(u16, output.input_ids, expected.input_ids);
    try expectEqualSlices(u8, output.attention_mask, expected.attention_mask);
    try expectEqualSlices(u8, output.token_type_ids, expected.token_type_ids);
}
