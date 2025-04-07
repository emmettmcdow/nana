const std = @import("std");
const parseFromSliceLeaky = std.json.parseFromSliceLeaky;

const onnx = @import("onnxruntime");

//**************************************************************************************** Embedder

// TODO: this is a hack...
pub const MXBAI_QUANTIZED_MODEL: *const [29:0]u8 = "zig-out/share/onnx/model.onnx";
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

        const batch = 1;
        const sequence = 8; // TODO: change me
        //////////////
        //  Inputs  //
        //////////////
        const size_input_id: usize = batch * sequence;
        const input_id_node_dimms: []const i64 = &.{ batch, sequence };
        const input_ids = try allocator.alloc(i64, size_input_id);
        @memset(input_ids, 0);
        const input_id_ort_input = try onnx_instance.createTensorWithDataAsOrtValue(
            i64,
            input_ids,
            input_id_node_dimms,
            .i64,
        );

        const size_attention_mask: usize = batch * sequence;
        const attention_mask_node_dimms: []const i64 = &.{ batch, sequence };
        const attention_masks = try allocator.alloc(i64, size_attention_mask);
        @memset(attention_masks, 0);
        const attention_mask_ort_input = try onnx_instance.createTensorWithDataAsOrtValue(
            i64,
            attention_masks,
            attention_mask_node_dimms,
            .i64,
        );

        const size_token_type_id: usize = batch * sequence;
        const token_type_id_node_dimms: []const i64 = &.{ batch, sequence };
        const token_type_ids = try allocator.alloc(i64, size_token_type_id);
        @memset(token_type_ids, 0);
        const token_type_id_ort_input = try onnx_instance.createTensorWithDataAsOrtValue(
            i64,
            token_type_ids,
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
        const size_last: usize = batch * sequence * vector_ln;
        const last_node_dimms: []const i64 = &.{
            batch,
            sequence,
            vector_ln,
        };
        const last = try allocator.alloc(f32, size_last);
        @memset(last, 0);
        const last_ort_output = try onnx_instance.createTensorWithDataAsOrtValue(
            f32,
            last,
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
            .input_ids = input_ids,
            .attention_masks = attention_masks,
            .token_type_ids = token_type_ids,
            .last = last,
        };
    }
    pub fn deinit(self: *Self) void {
        // _ = self;
        // Possibly not necessary due to arena usage?
        self.onnx_instance.deinit_arena();
    }

    pub fn embed(self: *Self, tokens: Tokens) ![]f32 {
        // Clear out the last result
        @memset(self.input_ids, 0);
        @memset(self.attention_masks, 0);
        @memset(self.token_type_ids, 0);
        @memset(self.last, 0);

        // Copy in the new input
        @memcpy(self.input_ids[0..tokens.input_ids.len], tokens.input_ids);
        @memcpy(self.attention_masks[0..tokens.attention_mask.len], tokens.attention_mask);
        @memcpy(self.token_type_ids[0..tokens.token_type_ids.len], tokens.token_type_ids);
        try self.onnx_instance.run();
        return self.last;
    }
};

test "embed - init" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    _ = try Embedder.init(
        allocator,
        MXBAI_QUANTIZED_MODEL,
    );
}

const expectEqual = std.testing.expectEqual;
test "embed - embed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var e = try Embedder.init(
        allocator,
        MXBAI_QUANTIZED_MODEL,
    );

    var input = Tokens{
        .input_ids = &.{ 101, 7592, 102 },
        .attention_mask = &.{ 1, 1, 1 },
        .token_type_ids = &.{ 0, 0, 0 },
    };

    var output = try e.embed(input);
    // We don't check this too hard because the work to save vectors is not worth the reward.
    // Better to check at the interface level. i.e. we don't care what the specific embedding is
    // as long as the output is what we desire. This test is just to verify that the embedder
    // doesn't do anything FUBAR.
    try expectEqual(output[0], 0.6923382);

    input = Tokens{
        .input_ids = &.{ 101, 2748, 2909, 102 },
        .attention_mask = &.{ 1, 1, 1, 1 },
        .token_type_ids = &.{ 0, 0, 0, 0 },
    };
    output = try e.embed(input);
    try expectEqual(output[0], 1.1471152);
}

//*************************************************************************************** Tokenizer
const Tokens = struct {
    input_ids: []const i64,
    attention_mask: []const i64,
    token_type_ids: []const i64,
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
    // Right now we only have one set of tokens at a time. So instead of allocating, we will just
    // ref this heap memory.
    _input_buf: [MAX_SENTENCE_TOKENS]i64 = undefined,
    _attention_buf: [MAX_SENTENCE_TOKENS]i64 = undefined,
    _token_type_id_buf: [MAX_SENTENCE_TOKENS]i64 = undefined,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) !Self {
        // TODO: move this out of the source and into the buildsystem
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
        @memset(&self._input_buf, 0);
        @memset(&self._attention_buf, 0);
        @memset(&self._token_type_id_buf, 0); // This will not change. Zeros only for now

        // First token will always be 101
        // TODO: update this to read from the Config
        self._input_buf[0] = 101;
        self._attention_buf[0] = 1;

        var it = std.mem.splitSequence(u8, input, " ");
        var tok: u16 = undefined;
        var i: usize = 1;
        while (it.next()) |word| {
            var wordbuf: [MAX_TOKEN_LENGTH]u8 = undefined;
            const lowerWord = toLower(word, &wordbuf);
            tok = self.map.get(lowerWord) orelse {
                break;
                // std.debug.print("we are bailing on token -> '{s}'!\n", .{lowerWord});
                // unreachable;
            };
            self._input_buf[i] = tok;
            self._attention_buf[i] = 1;
            i += 1;
            if (i >= MAX_SENTENCE_TOKENS) unreachable;
        }

        // Last token will always be 102
        // TODO: update this to read from the Config
        self._input_buf[i] = 102;
        self._attention_buf[i] = 1;
        i += 1;

        return Tokens{
            .input_ids = self._input_buf[0..i],
            .attention_mask = self._attention_buf[0..i],
            .token_type_ids = self._token_type_id_buf[0..i],
        };
    }
};

const expect = std.testing.expect;
const expectEqualSlices = std.testing.expectEqualSlices;
// FYI for tests - cwd() is relative to the dir that the `zig build test` command was called
// from. NOT the source file directory OR the binary directory
test "tokenize - hello" {
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
    try expectEqualSlices(i64, output.input_ids, expected.input_ids);
    try expectEqualSlices(i64, output.attention_mask, expected.attention_mask);
    try expectEqualSlices(i64, output.token_type_ids, expected.token_type_ids);
}

test "tokenize - yes sir" {
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
    try expectEqualSlices(i64, output.input_ids, expected.input_ids);
    try expectEqualSlices(i64, output.attention_mask, expected.attention_mask);
    try expectEqualSlices(i64, output.token_type_ids, expected.token_type_ids);
}

test "tokenize - YES SIR" {
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
    try expectEqualSlices(i64, output.input_ids, expected.input_ids);
    try expectEqualSlices(i64, output.attention_mask, expected.attention_mask);
    try expectEqualSlices(i64, output.token_type_ids, expected.token_type_ids);
}

test "tokenize nonsense - 'norecycle'" {
    // TODO
    // 101,4496,8586,2100,14321,102,0,0,0,0,0,0,0,0,0,0
    // 1,1,1,1,1,1,0,0,0,0,0,0,0,0,0,0
    // 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
}
