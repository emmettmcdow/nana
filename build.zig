const std = @import("std");

const Step = std.Build.Step;
const RunStep = Step.Run;
const LazyPath = std.Build.LazyPath;

const PATH_MAX = 4096;

fn toSentinel(allocator: std.mem.Allocator, str: []const u8) ![:0]const u8 {
    var output = try allocator.allocSentinel(u8, str.len, 0);
    @memcpy(output[0..], str);
    return output;
}

pub fn build(b: *std.Build) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();

    const optimize = b.standardOptimizeOption(.{});

    const install_step = b.getInstallStep();

    // Targets
    const arm_target = b.resolveTargetQuery(.{ .cpu_arch = .aarch64, .os_tag = .macos });
    const x86_target = b.resolveTargetQuery(.{ .cpu_arch = .x86_64, .os_tag = .macos });

    // Sources
    const root_file = b.path("src/root.zig");
    const model_file = b.path("src/model.zig");
    const embed_file = b.path("src/embed.zig");
    const vector_file = b.path("src/vector.zig");
    const benchmark_file = b.path("src/benchmark.zig");
    const interface_file = b.path("src/intf.zig");

    // TODO: make these lazy
    // Dependencies
    const mnist_dep = b.dependency("mnist_testing", .{});
    const mxbai_embed_dep = b.dependency("mxbai_embed", .{});

    // Options
    const options = b.addOptions();
    options.addOption(usize, "vec_sz", 8192);

    // Static files
    const install_mnist = b.addInstallDirectory(.{
        .source_dir = mnist_dep.path(""),
        .install_dir = .{ .custom = "share" },
        .install_subdir = ".",
    });
    const install_mxbai_embed = b.addInstallDirectory(.{
        .source_dir = mxbai_embed_dep.path(""),
        .install_dir = .{ .custom = "share" },
        .install_subdir = ".",
    });
    install_step.dependOn(&install_mnist.step);
    install_step.dependOn(&install_mxbai_embed.step);

    ///////////////////
    // Build the Lib //
    ///////////////////
    // Base Library
    const base_nana_x86_lib = b.addStaticLibrary(.{
        .name = "nana",
        .root_source_file = interface_file,
        .target = x86_target,
        .optimize = optimize,
    });
    base_nana_x86_lib.root_module.addOptions("config", options);
    const sqlite_x86_step = SQLiteStep.create(.{
        .b = b,
        .dest = base_nana_x86_lib,
        .target = x86_target,
        .optimize = optimize,
    });
    // const onnx_x86_lib = ORTStep.create(.{
    _ = ORTStep.create(.{
        .b = b,
        .dest = base_nana_x86_lib,
        .target = x86_target,
        .optimize = optimize,
    });

    const base_nana_arm_lib = b.addStaticLibrary(.{
        .name = "nana",
        .root_source_file = interface_file,
        .target = arm_target,
        .optimize = optimize,
    });
    base_nana_arm_lib.root_module.addOptions("config", options);
    const sqlite_arm_step = SQLiteStep.create(.{
        .b = b,
        .dest = base_nana_arm_lib,
        .target = arm_target,
        .optimize = optimize,
    });
    // const onnx_arm_lib = ORTStep.create(.{
    _ = ORTStep.create(.{
        .b = b,
        .dest = base_nana_arm_lib,
        .target = arm_target,
        .optimize = optimize,
    });

    // Combine Libs
    var x86_lib_sources = [_]LazyPath{
        base_nana_x86_lib.getEmittedBin(),
        sqlite_x86_step.output,
            // onnx_x86_lib.output,
    };
    const combine_x86_lib = createLibtoolStep(b, .{
        .name = "nana",
        .out_name = b.fmt("libnana-{s}-{s}.a", .{
            @tagName(x86_target.query.os_tag.?),
            @tagName(x86_target.query.cpu_arch.?),
        }),
        .sources = &x86_lib_sources,
    });
    combine_x86_lib.step.dependOn(&base_nana_x86_lib.step);

    var arm_lib_sources = [_]LazyPath{
        base_nana_arm_lib.getEmittedBin(),
        sqlite_arm_step.output,
            // onnx_arm_lib.output,
    };
    const combine_arm_lib = createLibtoolStep(b, .{
        .name = "nana",
        .out_name = b.fmt("libnana-{s}-{s}.a", .{
            @tagName(arm_target.query.os_tag.?),
            @tagName(arm_target.query.cpu_arch.?),
        }),
        .sources = &arm_lib_sources,
    });
    combine_arm_lib.step.dependOn(&base_nana_arm_lib.step);

    const outfile = "libnana.a";
    const static_lib_universal = createLipoStep(b, .{
        .name = "nana",
        .out_name = outfile,
        .inputs = &.{
            combine_x86_lib.output,
            combine_arm_lib.output,
        },
    });
    static_lib_universal.step.dependOn(combine_x86_lib.step);
    static_lib_universal.step.dependOn(combine_arm_lib.step);

    const xcframework = createXCFrameworkStep(b, .{
        .name = "NanaKit",
        .out_path = "macos/NanaKit.xcframework",
        .libraries = &.{
            static_lib_universal.output,
                // ort_mac_prebuilt_universal_step.output,
        },
        .headers = &.{
            .{ .cwd_relative = "include" },
            // ort_mac_prebuilt_universal_step.headers,
        },
    });
    xcframework.step.dependOn(static_lib_universal.step);
    install_step.dependOn(xcframework.step);

    ////////////////
    // Unit Tests //
    ////////////////
    // Root
    const root_unit_tests = b.addTest(.{
        .root_source_file = root_file,
        .target = x86_target,
        .optimize = optimize,
        .filters = &.{"root"},
    });
    const root_options = b.addOptions();
    root_options.addOption(usize, "vec_sz", 3);
    root_unit_tests.root_module.addOptions("config", root_options);
    _ = SQLiteStep.create(.{
        .b = b,
        .dest = root_unit_tests,
        .target = x86_target,
        .optimize = optimize,
    });
    _ = ORTStep.create(.{
        .b = b,
        .dest = root_unit_tests,
        .target = x86_target,
        .optimize = optimize,
    });
    const run_root_unit_tests = b.addRunArtifact(root_unit_tests);
    const test_root = b.step("test-root", "run the tests for src/root.zig");
    test_root.dependOn(&run_root_unit_tests.step);

    // Model
    const model_unit_tests = b.addTest(.{
        .root_source_file = model_file,
        .target = x86_target,
        .optimize = optimize,
        .filters = &.{"model"},
    });
    _ = SQLiteStep.create(.{
        .b = b,
        .dest = model_unit_tests,
        .target = x86_target,
        .optimize = optimize,
    });
    const run_model_unit_tests = b.addRunArtifact(model_unit_tests);
    const test_model = b.step("test-model", "run the tests for src/model.zig");
    test_model.dependOn(&run_model_unit_tests.step);

    // Embed
    const embed_unit_tests = b.addTest(.{
        .root_source_file = embed_file,
        .target = x86_target,
        .optimize = optimize,
        .filters = &.{"embed"},
    });
    _ = ORTStep.create(.{
        .b = b,
        .dest = embed_unit_tests,
        .target = x86_target,
        .optimize = optimize,
    });
    const run_embed_unit_tests = b.addRunArtifact(embed_unit_tests);
    const test_embed = b.step("test-embed", "run the tests for src/embed.zig");
    test_embed.dependOn(&run_embed_unit_tests.step);

    // Vector
    const vector_options = b.addOptions();
    // vector_options.addOption(type, "vec_type", f32);
    vector_options.addOption(usize, "vec_sz", 3);
    const vector_unit_tests = b.addTest(.{
        .root_source_file = vector_file,
        .target = x86_target,
        .optimize = optimize,
        .filters = &.{"vector"},
    });
    vector_unit_tests.root_module.addOptions("config", vector_options);
    const run_vector_unit_tests = b.addRunArtifact(vector_unit_tests);
    const test_vector = b.step("test-vector", "run the tests for src/vector.zig");
    test_vector.dependOn(&run_vector_unit_tests.step);

    // Benchmark
    const benchmark_options = b.addOptions();
    // benchmark_options.addOption(type, "vec_type", f32);
    benchmark_options.addOption(usize, "vec_sz", 8192);
    const benchmark_unit_tests = b.addTest(.{
        .root_source_file = benchmark_file,
        .target = x86_target,
        .optimize = optimize,
        .filters = &.{"benchmark"},
    });
    _ = SQLiteStep.create(.{
        .b = b,
        .dest = benchmark_unit_tests,
        .target = x86_target,
        .optimize = optimize,
    });
    _ = ORTStep.create(.{
        .b = b,
        .dest = benchmark_unit_tests,
        .target = x86_target,
        .optimize = optimize,
    });
    benchmark_unit_tests.root_module.addOptions("config", benchmark_options);
    const run_benchmark_unit_tests = b.addRunArtifact(benchmark_unit_tests);
    const test_benchmark = b.step("test-benchmark", "run the tests for src/benchmark.zig");
    test_benchmark.dependOn(&run_benchmark_unit_tests.step);

    // All
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(test_root);
    test_step.dependOn(test_model);
    test_step.dependOn(test_embed);
    test_step.dependOn(test_vector);
    test_step.dependOn(test_benchmark);

    ////////////////////
    // Test Debugging //
    ////////////////////
    const lldb = b.addSystemCommand(&.{
        "lldb",
        // add lldb flags before --
        // Uncomment this if lib_unit_tests needs lldb args or test args
        // "--",
    });
    lldb.addArtifactArg(benchmark_unit_tests);
    const lldb_step = b.step("debug", "run the tests under lldb");
    lldb_step.dependOn(&lldb.step);
}

const SQLiteStep = struct {
    // step: *Step,
    output: LazyPath,

    const SQLiteOptions = struct {
        // The build
        b: *std.Build,
        // That which we want to link with
        dest: *Step.Compile,
        // Platform options
        target: std.Build.ResolvedTarget,
        optimize: std.builtin.OptimizeMode,
    };

    pub fn create(opts: SQLiteOptions) SQLiteStep {
        const sqlite_dep = opts.b.dependency("sqlite", .{ .target = opts.target, .optimize = opts.optimize });
        const sqlite_art = sqlite_dep.artifact("sqlite");
        const sqlite_mod = sqlite_dep.module("sqlite");

        opts.dest.root_module.addImport("sqlite", sqlite_mod);
        opts.dest.linkLibrary(sqlite_art);
        opts.dest.bundle_compiler_rt = true;
        opts.dest.linkLibC();

        return .{
            // .step = null,
            .output = sqlite_art.getEmittedBin(),
        };
    }
};
const ORTStep = struct {
    // step: *Step,
    // output: LazyPath,

    const ORTOptions = struct {
        // The build
        b: *std.Build,
        // That which we want to link with
        dest: *Step.Compile,
        // Platform options
        target: std.Build.ResolvedTarget,
        optimize: std.builtin.OptimizeMode,
    };

    pub fn create(opts: ORTOptions) ORTStep {
        const onnx_dep = opts.b.dependency("zig_onnxruntime", .{ .target = opts.target, .optimize = opts.optimize });
        // const onnx_art = onnx_dep.artifact("zig-onnxruntime");
        const onnx_mod = onnx_dep.module("zig-onnxruntime");

        opts.dest.root_module.addImport("onnxruntime", onnx_mod);
        opts.dest.linkLibCpp();
        // opts.dest.linkLibrary(onnx_art);

        return .{
            // .step = &install_onnx_libs.step,
            // .output = onnx_art.getEmittedBin(),
        };
    }
};

// TY mitchellh
// https://gist.github.com/mitchellh/0ee168fb34915e96159b558b89c9a74b#file-libtoolstep-zig
const LibtoolStep = struct {
    pub const Options = struct {
        /// The name of this step.
        name: []const u8,

        /// The filename (not the path) of the file to create. This will
        /// be placed in a unique hashed directory. Use out_path to access.
        out_name: []const u8,

        /// Library files (.a) to combine.
        sources: []LazyPath,
    };

    /// The step to depend on.
    step: *Step,

    /// The output file from the libtool run.
    output: LazyPath,
};

/// Run libtool against a list of library files to combine into a single
/// static library.
pub fn createLibtoolStep(b: *std.Build, opts: LibtoolStep.Options) *LibtoolStep {
    const self = b.allocator.create(LibtoolStep) catch @panic("OOM");

    const run_step = RunStep.create(b, b.fmt("libtool {s}", .{opts.name}));
    run_step.addArgs(&.{ "libtool", "-static", "-o" });
    const output = run_step.addOutputFileArg(opts.out_name);
    for (opts.sources) |source| run_step.addFileArg(source);

    self.* = .{
        .step = &run_step.step,
        .output = output,
    };

    return self;
}

const LipoStep = struct {
    pub const Options = struct {
        /// The name of the xcframework to create.
        name: []const u8,

        /// The filename (not the path) of the file to create.
        out_name: []const u8,

        /// Library file (dylib, a) to package.
        inputs: []const LazyPath,
    };

    step: *Step,

    /// Resulting binary
    output: LazyPath,
};

pub fn createLipoStep(b: *std.Build, opts: LipoStep.Options) *LipoStep {
    const self = b.allocator.create(LipoStep) catch @panic("OOM");

    const run_step = RunStep.create(b, b.fmt("lipo {s}", .{opts.name}));
    run_step.addArgs(&.{ "lipo", "-create", "-output" });
    const output = run_step.addOutputFileArg(opts.out_name);
    for (opts.inputs) |input| {
        run_step.addFileArg(input);
    }

    self.* = .{
        .step = &run_step.step,
        .output = output,
    };

    return self;
}

const XCFrameworkStep = struct {
    pub const Options = struct {
        /// The name of the xcframework to create.
        name: []const u8,

        /// The path to write the framework
        out_path: []const u8,

        /// Library file (dylib, a) to package.
        libraries: []const LazyPath,

        /// Path to a directory with the headers.
        headers: []const LazyPath,
    };

    step: *Step,
};

pub fn createXCFrameworkStep(b: *std.Build, opts: XCFrameworkStep.Options) *XCFrameworkStep {
    const self = b.allocator.create(XCFrameworkStep) catch @panic("OOM");

    // We have to delete the old xcframework first since we're writing
    // to a static path.
    const run_delete = run: {
        const run = RunStep.create(b, b.fmt("xcframework delete {s}", .{opts.name}));
        run.has_side_effects = true;
        run.addArgs(&.{ "rm", "-rf", opts.out_path });
        break :run run;
    };

    // Then we run xcodebuild to create the framework.
    const run_create = run: {
        const run = RunStep.create(b, b.fmt("xcframework {s}", .{opts.name}));
        run.has_side_effects = true;
        run.addArgs(&.{ "xcodebuild", "-create-xcframework" });
        for (opts.libraries, 0..) |library, i| {
            run.addArg("-library");
            run.addFileArg(library);
            run.addArg("-headers");
            run.addFileArg(opts.headers[i]);
        }
        run.addArg("-output");
        run.addArg(opts.out_path);
        break :run run;
    };
    run_create.step.dependOn(&run_delete.step);

    self.* = .{
        .step = &run_create.step,
    };

    return self;
}
