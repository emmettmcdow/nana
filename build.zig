const VEC_SZ = 512;

const xc_fw_path = "macos/NanaKit.xcframework";

pub fn build(b: *std.Build) !void {
    const debug = b.option(bool, "debug-output", "Show debug output") orelse false;
    const embedding_model = b.option(
        EmbeddingModel,
        "embedding-model",
        "Embedding model to use (apple_nlembedding or jina_embedding)",
    ) orelse .apple_nlembedding;
    // Need to find a way to merge this with existing filtering per compilation unit
    // const test_filter = b.option(
    //     []const u8,
    //     "test-filter",
    //     "Skip tests that do not match any filter",
    // ) orelse &[]const u8{};
    const optimize = b.standardOptimizeOption(.{});

    const install_step = b.getInstallStep();

    // Targets
    const arm_target = b.resolveTargetQuery(.{ .cpu_arch = .aarch64, .os_tag = .macos });
    const x86_target = b.resolveTargetQuery(.{ .cpu_arch = .x86_64, .os_tag = .macos });

    const targets: [2]std.Build.ResolvedTarget = .{
        x86_target,
        arm_target,
    };

    const fake_vec_cfg = GlobalOptions{};
    const real_vec_cfg = GlobalOptions{ .vec_sz = VEC_SZ };

    // Sources
    const root_file = b.path("src/root.zig");
    const note_id_map_file = b.path("src/note_id_map.zig");
    const diff_file = b.path("src/dmp.zig");
    const embed_file = b.path("src/embed.zig");
    const vec_storage_file = b.path("src/vec_storage.zig");
    const vector_file = b.path("src/vector.zig");
    const benchmark_file = b.path("src/benchmark.zig");
    const perf_file = b.path("src/perf_benchmark.zig");
    const profile_file = b.path("src/profile.zig");
    const markdown_file = b.path("src/markdown.zig");
    const util_file = b.path("src/util.zig");

    ///////////////////
    // Build the Lib //
    ///////////////////
    // Base Library
    var baselib_platform_list = std.ArrayList(Baselib).init(b.allocator);
    defer baselib_platform_list.deinit();
    for (targets) |target| {
        try baselib_platform_list.append(Baselib.create(.{
            .b = b,
            .target = target,
            .optimize = optimize,
            .debug = debug,
            .embedding_model = embedding_model,
        }));
    }

    const outfile = "libnana.a";
    const static_lib_universal = Lipo.create(b, .{
        .name = "nana",
        .out_name = outfile,
        .inputs = baselib_platform_list.items,
    });

    const xcframework = XCFramework.create(b, .{
        .name = "NanaKit",
        .out_path = xc_fw_path,
        .libraries = &.{static_lib_universal.output},
        .headers = &.{.{ .cwd_relative = "include" }},
    });
    xcframework.step.dependOn(static_lib_universal.step);

    const signedFW = Codesign.create(.{ .b = b, .path = xc_fw_path });
    signedFW.step.dependOn(xcframework.step);
    install_step.dependOn(signedFW.step);

    //////////////////////
    // Jina Model Fetch //
    //////////////////////
    const jina_model = JinaModel.create(b);
    const fetch_jina_step = b.step(
        "fetch-jina-model",
        "Download Jina embeddings model from HuggingFace",
    );
    fetch_jina_step.dependOn(jina_model.step);

    // Copy model to mac app Resources for bundling
    const copy_model_to_mac = RunStep.create(b, "copy jina model to mac app");
    copy_model_to_mac.addArgs(&.{
        "cp",                "-R",
        JinaModel.MODEL_DIR, "mac/nana/Resources/",
    });
    copy_model_to_mac.step.dependOn(jina_model.step);

    const mkdir_mac_resources = RunStep.create(b, "create mac resources dir");
    mkdir_mac_resources.addArgs(&.{ "mkdir", "-p", "mac/nana/Resources" });
    copy_model_to_mac.step.dependOn(&mkdir_mac_resources.step);

    install_step.dependOn(&copy_model_to_mac.step);

    ////////////////////////
    // Standalone Binary  //
    ////////////////////////
    const main_file = b.path("src/main.zig");
    const native_target = b.resolveTargetQuery(.{});
    const exe = b.addExecutable(.{
        .name = "nana",
        .root_source_file = main_file,
        .target = native_target,
        .optimize = optimize,
    });
    exe.root_module.addImport("nana", b.createModule(.{
        .root_source_file = root_file,
    }));
    real_vec_cfg.install(b, exe, debug, embedding_model);
    addAllDeps(.{ .b = b, .dest = exe, .target = native_target, .optimize = optimize });
    b.installArtifact(exe);

    // Install model files to share directory
    const model_dir = "models/jina-embeddings-v2-base-en";
    b.installDirectory(.{
        .source_dir = .{ .cwd_relative = model_dir },
        .install_dir = .{ .custom = "share/nana" },
        .install_subdir = "jina-embeddings-v2-base-en",
    });

    const run_exe = b.addRunArtifact(exe);
    run_exe.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_exe.addArgs(args);
    }
    const run_step = b.step("run", "Run the standalone binary");
    run_step.dependOn(&run_exe.step);

    ////////////////
    // Unit Tests //
    ////////////////
    const x86_deps = DepOptions{
        .b = b,
        .dest = undefined,
        .target = x86_target,
        .optimize = optimize,
    };

    const test_root = b.step("test-root", "run the tests for src/root.zig");
    {
        const t = b.addTest(.{
            .root_source_file = root_file,
            .target = x86_target,
            .optimize = optimize,
            .filters = &.{"root"},
        });
        real_vec_cfg.install(b, t, debug, embedding_model);
        addAllDeps(depOpts(x86_deps, t));
        test_root.dependOn(&b.addRunArtifact(t).step);
    }

    const test_note_id_map = b.step("test-note_id_map", "run the tests for src/note_id_map.zig");
    {
        const t = b.addTest(.{
            .root_source_file = note_id_map_file,
            .target = x86_target,
            .optimize = optimize,
            .filters = &.{"note_id_map"},
        });
        addTracy(depOpts(x86_deps, t));
        test_note_id_map.dependOn(&b.addRunArtifact(t).step);
    }

    const test_embed = b.step("test-embed", "run the tests for src/embed.zig");
    {
        const t = b.addTest(.{
            .root_source_file = embed_file,
            .target = x86_target,
            .optimize = optimize,
            .filters = &.{"embed"},
        });
        real_vec_cfg.install(b, t, debug, embedding_model);
        addObjC(depOpts(x86_deps, t));
        addTracy(depOpts(x86_deps, t));
        const install_models = b.addInstallDirectory(.{
            .source_dir = .{ .cwd_relative = JinaModel.MODEL_DIR },
            .install_dir = .{ .custom = "share/nana" },
            .install_subdir = "jina-embeddings-v2-base-en",
        });
        install_models.step.dependOn(jina_model.step);
        const run = b.addRunArtifact(t);
        run.step.dependOn(&install_models.step);
        test_embed.dependOn(&run.step);
    }

    const test_vec_storage = b.step("test-vec_storage", "run the tests for src/vec_storage.zig");
    {
        const t = b.addTest(.{
            .root_source_file = vec_storage_file,
            .target = x86_target,
            .optimize = optimize,
            .filters = &.{"vec_storage"},
        });
        fake_vec_cfg.install(b, t, debug, embedding_model);
        addTracy(depOpts(x86_deps, t));
        test_vec_storage.dependOn(&b.addRunArtifact(t).step);
    }

    const test_markdown = b.step("test-markdown", "run the tests for src/markdown.zig");
    {
        const t = b.addTest(.{
            .root_source_file = markdown_file,
            .target = x86_target,
            .optimize = optimize,
            .filters = &.{"markdown"},
        });
        fake_vec_cfg.install(b, t, debug, embedding_model);
        addTracy(depOpts(x86_deps, t));
        test_markdown.dependOn(&b.addRunArtifact(t).step);
    }

    const test_vector = b.step("test-vector", "run the tests for src/vector.zig");
    {
        const t = b.addTest(.{
            .root_source_file = vector_file,
            .target = x86_target,
            .optimize = optimize,
            .filters = &.{"vector"},
        });
        real_vec_cfg.install(b, t, debug, embedding_model);
        addAllDeps(depOpts(x86_deps, t));
        test_vector.dependOn(&b.addRunArtifact(t).step);
    }

    const test_diff = b.step("test-diff", "run the tests for src/diff.zig");
    {
        const t = b.addTest(.{
            .root_source_file = diff_file,
            .target = x86_target,
            .optimize = optimize,
            .filters = &.{"diff"},
        });
        fake_vec_cfg.install(b, t, debug, embedding_model);
        test_diff.dependOn(&b.addRunArtifact(t).step);
    }

    const test_util = b.step("test-util", "run the tests for src/util.zig");
    {
        const t = b.addTest(.{
            .root_source_file = util_file,
            .target = x86_target,
            .optimize = optimize,
            .filters = &.{"util"},
        });
        fake_vec_cfg.install(b, t, debug, embedding_model);
        test_util.dependOn(&b.addRunArtifact(t).step);
    }

    const test_benchmark = b.step("test-benchmark", "run the tests for src/benchmark.zig");
    {
        const t = b.addTest(.{
            .root_source_file = benchmark_file,
            .target = x86_target,
            .optimize = optimize,
            .filters = &.{"benchmark"},
        });
        real_vec_cfg.install(b, t, debug, embedding_model);
        addAllDeps(depOpts(x86_deps, t));
        test_benchmark.dependOn(&b.addRunArtifact(t).step);
    }

    const test_perf = b.step("perf", "Run performance benchmark tests");
    {
        const t = b.addTest(.{
            .root_source_file = perf_file,
            .target = x86_target,
            .optimize = optimize,
            .filters = &.{"perf"},
        });
        real_vec_cfg.install(b, t, debug, embedding_model);
        addObjC(depOpts(x86_deps, t));
        addTracy(depOpts(x86_deps, t));
        const run = b.addRunArtifact(t);
        run.step.dependOn(jina_model.step);
        test_perf.dependOn(&run.step);
    }

    const profile_step = b.step("profile", "run the profile executable");
    {
        const p = b.addExecutable(.{
            .name = "profile",
            .root_source_file = profile_file,
            .target = x86_target,
            .optimize = optimize,
        });
        real_vec_cfg.install(b, p, debug, embedding_model);
        addAllDeps(depOpts(x86_deps, p));
        profile_step.dependOn(&b.addRunArtifact(p).step);
    }

    // All tests
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(test_root);
    test_step.dependOn(test_note_id_map);
    test_step.dependOn(test_embed);
    test_step.dependOn(test_vec_storage);
    test_step.dependOn(test_vector);
    test_step.dependOn(test_diff);
    test_step.dependOn(test_markdown);
    test_step.dependOn(test_util);

    const lint_cmd = b.step("lint", "Lint source code.");
    lint_cmd.dependOn(step: {
        var builder = zlinter.builder(b, .{});
        builder.addPaths(.{ .exclude = &.{b.path("testing/")} });
        builder.addRule(.{ .builtin = .max_positional_args }, .{});
        builder.addRule(.{ .builtin = .no_unused }, .{});
        builder.addRule(.{ .builtin = .no_orelse_unreachable }, .{});
        builder.addRule(.{ .builtin = .no_hidden_allocations }, .{});
        builder.addRule(.{ .builtin = .no_swallow_error }, .{});
        builder.addRule(.{ .builtin = .require_errdefer_dealloc }, .{});
        builder.addRule(.{ .builtin = .no_todo }, .{});
        // builder.addRule(.{ .builtin = .declaration_naming }, .{});
        // builder.addRule(.{ .builtin = .field_ordering }, .{});
        // builder.addRule(.{ .builtin = .field_naming }, .{});
        // builder.addRule(.{ .builtin = .file_naming }, .{});
        // builder.addRule(.{ .builtin = .function_naming }, .{});
        // builder.addRule(.{ .builtin = .import_ordering }, .{});
        // builder.addRule(.{ .builtin = .no_comment_out_code }, .{});
        // builder.addRule(.{ .builtin = .no_deprecated }, .{});
        // builder.addRule(.{ .builtin = .no_empty_block }, .{});
        // builder.addRule(.{ .builtin = .no_inferred_error_unions }, .{});
        // builder.addRule(.{ .builtin = .no_literal_args }, .{});
        // builder.addRule(.{ .builtin = .no_literal_only_bool_expression }, .{});
        // builder.addRule(.{ .builtin = .no_panic }, .{});
        // builder.addRule(.{ .builtin = .no_undefined }, .{});
        // builder.addRule(.{ .builtin = .require_braces }, .{});
        // builder.addRule(.{ .builtin = .require_doc_comment }, .{});
        // builder.addRule(.{ .builtin = .switch_case_ordering }, .{});
        break :step builder.build();
    });
}

const EmbeddingModel = enum {
    apple_nlembedding,
    jina_embedding,
};

const GlobalOptions = struct {
    vec_sz: usize = 3,
    vec_type: type = f32,

    const Self = @This();

    pub fn install(
        self: Self,
        b: *std.Build,
        dest: *Step.Compile,
        debug: bool,
        embedding_model: EmbeddingModel,
    ) void {
        const options = b.addOptions();
        options.addOption(usize, "vec_sz", self.vec_sz);
        // options.addOption(type, "vec_type", self.vec_type);
        options.addOption(bool, "debug", debug);
        options.addOption(EmbeddingModel, "embedding_model", embedding_model);
        dest.root_module.addOptions("config", options);
    }
};

const Baselib = struct {
    pub const Options = struct {
        b: *std.Build,
        target: std.Build.ResolvedTarget,
        optimize: std.builtin.OptimizeMode,
        debug: bool,
        embedding_model: EmbeddingModel,
    };

    step: *Step,
    output: LazyPath,

    pub fn create(opts: Baselib.Options) Baselib {
        const interface_file = opts.b.path("src/intf.zig");

        const options = opts.b.addOptions();
        options.addOption(bool, "debug", opts.debug);
        options.addOption(usize, "vec_sz", VEC_SZ);
        options.addOption(EmbeddingModel, "embedding_model", opts.embedding_model);

        const base_nana_lib = opts.b.addStaticLibrary(.{
            .name = "nana",
            .root_source_file = interface_file,
            .target = opts.target,
            .optimize = opts.optimize,
        });
        base_nana_lib.root_module.addOptions("config", options);
        const dep_opts = DepOptions{
            .b = opts.b,
            .dest = base_nana_lib,
            .target = opts.target,
            .optimize = opts.optimize,
        };
        addObjC(dep_opts);
        addTracy(dep_opts);

        return .{
            .step = &base_nana_lib.step,
            .output = base_nana_lib.getEmittedBin(),
        };
    }
};

const DepOptions = struct {
    b: *std.Build,
    dest: *Step.Compile,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
};

fn addObjC(opts: DepOptions) void {
    const objc_dep = opts.b.dependency("zig_objc", .{
        .target = opts.target,
        .optimize = opts.optimize,
    });
    opts.dest.root_module.addImport("objc", objc_dep.module("objc"));
    opts.dest.root_module.linkFramework("NaturalLanguage", .{});
    opts.dest.root_module.linkFramework("CoreML", .{});
    opts.dest.root_module.linkFramework("Foundation", .{});
}

fn addTracy(opts: DepOptions) void {
    const tracy_enable = opts.optimize == .Debug;
    const tracy_dep = opts.b.dependency("tracy", .{
        .target = opts.target,
        .optimize = opts.optimize,
        .tracy_enable = tracy_enable,
        .tracy_callstack = 62,
    });
    opts.dest.root_module.addImport("tracy", tracy_dep.module("tracy"));
    if (!tracy_enable) return;

    opts.dest.root_module.linkLibrary(tracy_dep.artifact("tracy"));
    opts.dest.root_module.link_libcpp = true;
    opts.b.getInstallStep().dependOn(&opts.b.addInstallArtifact(tracy_dep.artifact("tracy"), .{
        .dest_dir = .{ .override = .{ .bin = {} } },
    }).step);
}

fn addAllDeps(opts: DepOptions) void {
    addObjC(opts);
    addTracy(opts);
}

fn depOpts(base: DepOptions, dest: *Step.Compile) DepOptions {
    return .{ .b = base.b, .dest = dest, .target = base.target, .optimize = base.optimize };
}

// TY mitchellh
// https://gist.github.com/mitchellh/0ee168fb34915e96159b558b89c9a74b#file-libtoolstep-zig
const Libtool = struct {
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

    /// Run libtool against a list of library files to combine into a single
    /// static library.
    pub fn create(b: *std.Build, opts: Libtool.Options) *Libtool {
        const self = b.allocator.create(Libtool) catch @panic("OOM");

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
};

const Lipo = struct {
    pub const Options = struct {
        /// The name of the xcframework to create.
        name: []const u8,

        /// The filename (not the path) of the file to create.
        out_name: []const u8,

        /// Library file (dylib, a) to package.
        inputs: []Baselib,
    };

    step: *Step,

    /// Resulting binary
    output: LazyPath,

    pub fn create(b: *std.Build, opts: Lipo.Options) *Lipo {
        const self = b.allocator.create(Lipo) catch @panic("OOM");

        const run_step = RunStep.create(b, b.fmt("lipo {s}", .{opts.name}));
        run_step.addArgs(&.{ "lipo", "-create", "-output" });
        const output = run_step.addOutputFileArg(opts.out_name);
        for (opts.inputs) |lib| {
            run_step.addFileArg(lib.output);
            run_step.step.dependOn(lib.step);
        }

        self.* = .{
            .step = &run_step.step,
            .output = output,
        };

        return self;
    }
};

const XCFramework = struct {
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

    pub fn create(b: *std.Build, opts: XCFramework.Options) *XCFramework {
        const self = b.allocator.create(XCFramework) catch @panic("OOM");

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
};

const Codesign = struct {
    pub const Options = struct {
        b: *std.Build,
        /// The path of the xcframework to sign.
        path: []const u8,
    };

    step: *Step,

    pub fn create(opts: Codesign.Options) Codesign {
        const run_step = RunStep.create(opts.b, opts.b.fmt("CodeSign {s}", .{opts.path}));
        run_step.addArgs(&.{
            "codesign",
            "--timestamp",
            "-s",
            "5AE3B7EECB504FB7ED5B00BB70576647A21ADB15", // Apple Development: email@email.com
            opts.path,
        });

        const self: Codesign = .{
            .step = &run_step.step,
        };

        return self;
    }
};

const JinaModel = struct {
    const HF_BASE = "https://huggingface.co/jinaai/jina-embeddings-v2-base-en/resolve/main";
    const MODEL_DIR = "models/jina-embeddings-v2-base-en";

    step: *Step,
    tokenizer_path: LazyPath,
    model_path: LazyPath,

    pub fn create(b: *std.Build) JinaModel {
        const mkdir_step = RunStep.create(b, "jina: create directories");
        if (hasDir(MODEL_DIR)) {
            const noop_step = b.allocator.create(Step) catch @panic("OOM");
            noop_step.* = Step.init(.{
                .id = .custom,
                .name = "jina: directories already exist",
                .owner = b,
            });
            return .{
                .step = noop_step,
                .tokenizer_path = .{ .cwd_relative = MODEL_DIR ++ "/tokenizer.json" },
                .model_path = .{ .cwd_relative = MODEL_DIR ++ "/float32_model.mlpackage" },
            };
        }
        mkdir_step.addArgs(&.{
            "mkdir",                                                               "-p",
            MODEL_DIR ++ "/float32_model.mlpackage/Data/com.apple.CoreML/weights",
        });

        const dl_tokenizer = RunStep.create(b, "jina: download tokenizer.json");
        dl_tokenizer.addArgs(&.{
            "curl",                       "-fsSL", "-o", MODEL_DIR ++ "/tokenizer.json",
            HF_BASE ++ "/tokenizer.json",
        });
        dl_tokenizer.step.dependOn(&mkdir_step.step);

        const dl_manifest = RunStep.create(b, "jina: download Manifest.json");
        dl_manifest.addArgs(&.{
            "curl",                                                     "-fsSL", "-o", MODEL_DIR ++ "/float32_model.mlpackage/Manifest.json",
            HF_BASE ++ "/coreml/float32_model.mlpackage/Manifest.json",
        });
        dl_manifest.step.dependOn(&mkdir_step.step);

        const dl_mlmodel = RunStep.create(b, "jina: download model.mlmodel");
        dl_mlmodel.addArgs(&.{
            "curl",                                                                      "-fsSL",                                                                          "-o",
            MODEL_DIR ++ "/float32_model.mlpackage/Data/com.apple.CoreML/model.mlmodel", HF_BASE ++ "/coreml/float32_model.mlpackage/Data/com.apple.CoreML/model.mlmodel",
        });
        dl_mlmodel.step.dependOn(&mkdir_step.step);

        const dl_weights = RunStep.create(b, "jina: download weight.bin");
        dl_weights.addArgs(&.{
            "curl",                                                                                "-fsSL",
            "-o",                                                                                  MODEL_DIR ++ "/float32_model.mlpackage/Data/com.apple.CoreML/weights/weight.bin",
            HF_BASE ++ "/coreml/float32_model.mlpackage/Data/com.apple.CoreML/weights/weight.bin",
        });
        dl_weights.step.dependOn(&mkdir_step.step);

        const final_step = b.allocator.create(Step) catch @panic("OOM");
        final_step.* = Step.init(.{
            .id = .custom,
            .name = "jina: download complete",
            .owner = b,
        });
        final_step.dependOn(&dl_tokenizer.step);
        final_step.dependOn(&dl_manifest.step);
        final_step.dependOn(&dl_mlmodel.step);
        final_step.dependOn(&dl_weights.step);

        return .{
            .step = final_step,
            .tokenizer_path = .{ .cwd_relative = MODEL_DIR ++ "/tokenizer.json" },
            .model_path = .{ .cwd_relative = MODEL_DIR ++ "/float32_model.mlpackage" },
        };
    }
};

fn hasDir(dir_path: []const u8) bool {
    _ = std.fs.cwd().openDir(dir_path, .{}) catch |err| switch (err) {
        FileNotFound => {
            // Handle the case where the directory does not exist
            std.debug.print("Directory '{s}' not found. Creating it now...\n", .{dir_path});
            return false; // Or handle the error as appropriate for your build logic
        },
        NotDir => {
            std.debug.print("Error: '{s}' is a file, not a directory.\n", .{dir_path});
            return false;
        },
        else => |e| {
            std.debug.print("An error occurred accessing '{s}': {any}\n", .{ dir_path, e });
            return false;
        },
    };
    return true;
}

const std = @import("std");
const assert = std.debug.assert;
const Step = std.Build.Step;
const FileNotFound = std.fs.Dir.OpenError.FileNotFound;
const NotDir = std.fs.Dir.OpenError.NotDir;
const RunStep = Step.Run;
const LazyPath = std.Build.LazyPath;

const zlinter = @import("zlinter");
