const std = @import("std");
const assert = std.debug.assert;
const parseFromSliceLeaky = std.json.parseFromSliceLeaky;

const onnx = @import("onnxruntime");

const types = @import("types.zig");
const Vector = types.Vector;
const vec_sz = types.vec_sz;
const vec_type = types.vec_type;

//**************************************************************************************** Embedder

// TODO: this is a hack...
pub const MXBAI_QUANTIZED_MODEL: *const [24:0]u8 = "zig-out/share/model.onnx";
pub const Embedder = struct {
    const Self = @This();

    onnx_instance: *onnx.OnnxInstance,
    allocator: std.mem.Allocator,

    // Settings
    const batch = 1;
    const sequence = 64; // TODO: change me
    // The potion model flattens the input. The input is a 1D series of tokens. The offsets
    // indicates the beginning of each batch within the input. For a batch of 1, we can ignore
    // the offsets.
    // Input
    const input_len = batch * sequence;
    const input_dimms: []const i64 = &.{input_len};
    var input_ids: [input_len]i64 = undefined;

    const offset_len = batch;
    const offset_dimms: []const i64 = &.{offset_len};
    var offsets: [offset_len]i64 = undefined;

    // Output
    const output_len = batch * vec_sz;
    const output_dimms: []const i64 = &.{ batch, vec_sz };
    var last: [output_len]f32 = undefined;

    pub fn init(allocator: std.mem.Allocator, model: [:0]const u8) !Self {
        const onnx_opts = onnx.OnnxInstanceOpts{
            .log_id = "ZIG",
            .log_level = .warning,
            .model_path = model,
            .input_names = &.{ "input_ids", "offsets" },
            .output_names = &.{"embeddings"},
        };
        var onnx_instance = try onnx.OnnxInstance.init(allocator, onnx_opts);
        try onnx_instance.initMemoryInfo("Cpu", .arena, 0, .default);

        //////////////
        //  Inputs  //
        //////////////
        @memset(&input_ids, 0);
        const input_id_ort_input = try onnx_instance.createTensorWithDataAsOrtValue(
            i64,
            &input_ids,
            input_dimms,
            .i64,
        );
        @memset(&offsets, 0);
        const offsets_ort_input = try onnx_instance.createTensorWithDataAsOrtValue(
            i64,
            &offsets,
            offset_dimms,
            .i64,
        );
        const ort_inputs = try allocator.dupe(*onnx.c_api.OrtValue, &.{
            input_id_ort_input,
            offsets_ort_input,
        });

        ///////////////
        //  Outputs  //
        ///////////////
        @memset(&last, 0);
        const last_ort_output = try onnx_instance.createTensorWithDataAsOrtValue(
            f32,
            &last,
            output_dimms,
            .f32,
        );
        const ort_outputs = try allocator.dupe(?*onnx.c_api.OrtValue, &.{
            last_ort_output,
        });

        onnx_instance.setManagedInputsOutputs(ort_inputs, ort_outputs);

        return Embedder{
            .onnx_instance = onnx_instance,
            .allocator = allocator,
        };
    }
    pub fn deinit(self: *Self) void {
        // _ = self;
        // Possibly not necessary due to arena usage?
        self.onnx_instance.deinit_arena();
    }

    pub fn embed(self: *Self, tokens: Tokens) !Vector {
        // Clear out the last result
        @memset(&input_ids, 0);
        @memset(&offsets, 0);
        @memset(&last, 0);

        // Copy in the new input
        @memcpy(input_ids[0..tokens.input_ids.len], tokens.input_ids);
        @memcpy(offsets[0..tokens.offsets.len], tokens.offsets);
        try self.onnx_instance.run();

        return last;
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
        .offsets = &.{0},
    };

    var output = try e.embed(input);
    // We don't check this too hard because the work to save vectors is not worth the reward.
    // Better to check at the interface level. i.e. we don't care what the specific embedding is
    // as long as the output is what we desire. This test is just to verify that the embedder
    // doesn't do anything FUBAR.
    var sum = @reduce(.Add, output);
    try expectEqual(-1.1252012, sum);

    input = Tokens{
        .input_ids = &.{ 101, 2748, 2909, 102 },
        .offsets = &.{0},
    };
    output = try e.embed(input);
    sum = @reduce(.Add, output);
    try expectEqual(-1.2431731, sum);
}

//*************************************************************************************** Tokenizer
const Tokens = struct {
    input_ids: []const i64,
    offsets: []const i64,
};

fn toLower(str: []const u8, buf: []u8) []u8 {
    for (str, 0..) |c, i| {
        // TODO: handle non-ascii?
        if (std.ascii.isAscii(c)) {
            buf[i] = std.ascii.toLower(c);
        } else {
            buf[i] = c;
        }
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

        // First token will always be 101
        // TODO: update this to read from the Config
        self._input_buf[0] = 101;

        var it = std.mem.splitSequence(u8, input, " ");
        var tok: u16 = undefined;
        var i: usize = 1;
        while (it.next()) |word| {
            const trimmed_word = std.mem.trim(u8, word, &std.ascii.whitespace);
            if (trimmed_word.len == 0) continue;
            if (trimmed_word.len >= MAX_TOKEN_LENGTH) {
                std.debug.print("skipping too-long token -> '{s}'!\n", .{trimmed_word});
                continue;
            }
            var wordbuf: [MAX_TOKEN_LENGTH]u8 = undefined;
            const lowerWord = toLower(trimmed_word, &wordbuf);
            tok = self.map.get(lowerWord) orelse {
                std.debug.print("dropping token -> '{s}'!\n", .{lowerWord});
                break;
            };
            self._input_buf[i] = tok;
            i += 1;
            if (i >= MAX_SENTENCE_TOKENS) unreachable;
        }

        // Last token will always be 102
        // TODO: update this to read from the Config
        self._input_buf[i] = 102;
        i += 1;

        return Tokens{
            .input_ids = self._input_buf[0..i],
            .offsets = &.{0},
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
        .input_ids = &.{ 101, 6598, 102 },
        .offsets = &.{0},
    };

    const output = try t.tokenize(input);
    try expectEqualSlices(i64, output.input_ids, expected.input_ids);
    try expectEqualSlices(i64, output.offsets, expected.offsets);
}

test "tokenize - yes sir" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var t = try Tokenizer.init(allocator);

    const input: []const u8 = "yes sir";
    const expected = Tokens{
        .input_ids = &.{ 101, 1754, 1915, 102 },
        .offsets = &.{0},
    };

    const output = try t.tokenize(input);
    try expectEqualSlices(i64, output.input_ids, expected.input_ids);
    try expectEqualSlices(i64, output.offsets, expected.offsets);
}

test "tokenize - YES SIR" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var t = try Tokenizer.init(allocator);

    const input: []const u8 = "YES SIR";
    const expected = Tokens{
        .input_ids = &.{ 101, 1754, 1915, 102 },
        .offsets = &.{0},
    };

    const output = try t.tokenize(input);
    try expectEqualSlices(i64, output.input_ids, expected.input_ids);
    try expectEqualSlices(i64, output.offsets, expected.offsets);
}

test "tokenize - strip edge whitespace" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var t = try Tokenizer.init(allocator);

    const input: []const u8 = "  yes sir\t";
    const expected = Tokens{
        .input_ids = &.{ 101, 1754, 1915, 102 },
        .offsets = &.{0},
    };

    const output = try t.tokenize(input);
    try expectEqualSlices(i64, expected.input_ids, output.input_ids);
    try expectEqualSlices(i64, expected.offsets, output.offsets);
}

test "tokenize - skip too-long token" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var t = try Tokenizer.init(allocator);

    const input =
        \\ looooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooong
    ;
    const expected = Tokens{
        .input_ids = &.{ 101, 102 },
        .offsets = &.{0},
    };

    const output = try t.tokenize(input);
    try expectEqualSlices(i64, expected.input_ids, output.input_ids);
    try expectEqualSlices(i64, expected.offsets, output.offsets);
}
