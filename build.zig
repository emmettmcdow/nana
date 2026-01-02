const VEC_SZ = 512;

const xc_fw_path = "macos/NanaKit.xcframework";

pub fn build(b: *std.Build) !void {
    const debug = b.option(bool, "debug-output", "Show debug output") orelse false;
    // Need to find a way to merge this with existing filtering per compilation unit
    // const test_filter = b.option([]const u8, "test-filter", "Skip tests that do not match any filter") orelse &[]const u8{};
    const optimize = b.standardOptimizeOption(.{});

    const install_step = b.getInstallStep();

    // Targets
    const arm_target = b.resolveTargetQuery(.{ .cpu_arch = .aarch64, .os_tag = .macos });
    const x86_target = b.resolveTargetQuery(.{ .cpu_arch = .x86_64, .os_tag = .macos });
    // const ios_target = b.resolveTargetQuery(.{
    //     .cpu_arch = .x86_64,
    //     .os_tag = .ios,
    //     .abi = .simulator,
    //     .os_version_min = .{ .semver = .{ .major = 18, .minor = 2, .patch = 0 } },
    // });

    const targets: [2]std.Build.ResolvedTarget = .{
        x86_target,
        arm_target,
        // This one has proven much harder than expected to build for. Get back to it later.
        // ios_target,
    };

    const fake_vec_cfg = GlobalOptions{};
    const real_vec_cfg = GlobalOptions{ .vec_sz = VEC_SZ };

    // Sources
    const root_file = b.path("src/root.zig");
    const model_file = b.path("src/model.zig");
    const diff_file = b.path("src/dmp.zig");
    const embed_file = b.path("src/embed.zig");
    const vec_storage_file = b.path("src/vec_storage.zig");
    const vector_file = b.path("src/vector.zig");
    const benchmark_file = b.path("src/benchmark.zig");
    const perf_file = b.path("src/perf_benchmark.zig");
    const profile_file = b.path("src/profile.zig");
    const markdown_file = b.path("src/markdown.zig");

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
    const fetch_jina_step = b.step("fetch-jina-model", "Download Jina embeddings model from HuggingFace");
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
    real_vec_cfg.install(b, exe, debug);
    _ = SQLite.create(.{
        .b = b,
        .dest = exe,
        .target = native_target,
        .optimize = optimize,
    });
    _ = ObjC.create(.{
        .b = b,
        .dest = exe,
        .target = native_target,
        .optimize = optimize,
    });
    _ = Tracy.create(.{
        .b = b,
        .dest = exe,
        .target = native_target,
        .optimize = optimize,
    });
    b.installArtifact(exe);

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
    // Root
    const root_unit_tests = b.addTest(.{
        .root_source_file = root_file,
        .target = x86_target,
        .optimize = optimize,
        .filters = &.{"root"},
    });
    real_vec_cfg.install(b, root_unit_tests, debug);
    _ = SQLite.create(.{
        .b = b,
        .dest = root_unit_tests,
        .target = x86_target,
        .optimize = optimize,
    });
    _ = ObjC.create(.{
        .b = b,
        .dest = root_unit_tests,
        .target = x86_target,
        .optimize = optimize,
    });
    _ = Tracy.create(.{
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
    _ = SQLite.create(.{
        .b = b,
        .dest = model_unit_tests,
        .target = x86_target,
        .optimize = optimize,
    });
    _ = Tracy.create(.{
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
    _ = ObjC.create(.{
        .b = b,
        .dest = embed_unit_tests,
        .target = x86_target,
        .optimize = optimize,
    });
    _ = Tracy.create(.{
        .b = b,
        .dest = embed_unit_tests,
        .target = x86_target,
        .optimize = optimize,
    });
    (real_vec_cfg).install(b, embed_unit_tests, debug);
    const run_embed_unit_tests = b.addRunArtifact(embed_unit_tests);
    run_embed_unit_tests.step.dependOn(jina_model.step);
    const test_embed = b.step("test-embed", "run the tests for src/embed.zig");
    test_embed.dependOn(&run_embed_unit_tests.step);

    // Vector Storage
    const vec_storage_unit_tests = b.addTest(.{
        .root_source_file = vec_storage_file,
        .target = x86_target,
        .optimize = optimize,
        .filters = &.{"vec_storage"},
    });
    _ = Tracy.create(.{
        .b = b,
        .dest = vec_storage_unit_tests,
        .target = x86_target,
        .optimize = optimize,
    });
    fake_vec_cfg.install(b, vec_storage_unit_tests, debug);
    const run_vec_storage_unit_tests = b.addRunArtifact(vec_storage_unit_tests);
    const test_vec_storage = b.step("test-vec_storage", "run the tests for src/vec_storage.zig");
    test_vec_storage.dependOn(&run_vec_storage_unit_tests.step);

    // Vector Storage
    const markdown_unit_tests = b.addTest(.{
        .root_source_file = markdown_file,
        .target = x86_target,
        .optimize = optimize,
        .filters = &.{"markdown"},
    });
    _ = Tracy.create(.{
        .b = b,
        .dest = markdown_unit_tests,
        .target = x86_target,
        .optimize = optimize,
    });
    fake_vec_cfg.install(b, markdown_unit_tests, debug);
    const run_markdown_unit_tests = b.addRunArtifact(markdown_unit_tests);
    const test_markdown = b.step("test-markdown", "run the tests for src/markdown.zig");
    test_markdown.dependOn(&run_markdown_unit_tests.step);

    // Vector DB
    const vec_unit_tests = b.addTest(.{
        .root_source_file = vector_file,
        .target = x86_target,
        .optimize = optimize,
        .filters = &.{"vector"},
    });
    _ = SQLite.create(.{
        .b = b,
        .dest = vec_unit_tests,
        .target = x86_target,
        .optimize = optimize,
    });
    _ = ObjC.create(.{
        .b = b,
        .dest = vec_unit_tests,
        .target = x86_target,
        .optimize = optimize,
    });
    _ = Tracy.create(.{
        .b = b,
        .dest = vec_unit_tests,
        .target = x86_target,
        .optimize = optimize,
    });
    real_vec_cfg.install(b, vec_unit_tests, debug);
    const run_vec_unit_tests = b.addRunArtifact(vec_unit_tests);
    const test_vec = b.step("test-vector", "run the tests for src/vector.zig");
    test_vec.dependOn(&run_vec_unit_tests.step);

    // Diff
    const diff_unit_tests = b.addTest(.{
        .root_source_file = diff_file,
        .target = x86_target,
        .optimize = optimize,
        .filters = &.{"diff"},
    });
    fake_vec_cfg.install(b, diff_unit_tests, debug);
    const run_diff_unit_tests = b.addRunArtifact(diff_unit_tests);
    const test_diff = b.step("test-diff", "run the tests for src/diff.zig");
    test_diff.dependOn(&run_diff_unit_tests.step);

    // Benchmark
    const benchmark_unit_tests = b.addTest(.{
        .root_source_file = benchmark_file,
        .target = x86_target,
        .optimize = optimize,
        .filters = &.{"benchmark"},
    });
    _ = SQLite.create(.{
        .b = b,
        .dest = benchmark_unit_tests,
        .target = x86_target,
        .optimize = optimize,
    });
    _ = ObjC.create(.{
        .b = b,
        .dest = benchmark_unit_tests,
        .target = x86_target,
        .optimize = optimize,
    });
    _ = Tracy.create(.{
        .b = b,
        .dest = benchmark_unit_tests,
        .target = x86_target,
        .optimize = optimize,
    });
    real_vec_cfg.install(b, benchmark_unit_tests, debug);
    const run_benchmark_unit_tests = b.addRunArtifact(benchmark_unit_tests);
    const test_benchmark = b.step("test-benchmark", "run the tests for src/benchmark.zig");
    test_benchmark.dependOn(&run_benchmark_unit_tests.step);

    // Benchmark
    const perf_tests = b.addTest(.{
        .root_source_file = perf_file,
        .target = x86_target,
        .optimize = optimize,
        .filters = &.{"perf"},
    });
    _ = ObjC.create(.{
        .b = b,
        .dest = perf_tests,
        .target = x86_target,
        .optimize = optimize,
    });
    _ = Tracy.create(.{
        .b = b,
        .dest = perf_tests,
        .target = x86_target,
        .optimize = optimize,
    });
    real_vec_cfg.install(b, perf_tests, debug);
    const run_perf_tests = b.addRunArtifact(perf_tests);
    const test_perf = b.step("perf", "Run performance benchmark tests");
    run_perf_tests.step.dependOn(jina_model.step);
    test_perf.dependOn(&run_perf_tests.step);

    const profile_exe = b.addExecutable(.{
        .name = "profile",
        .root_source_file = profile_file,
        .target = x86_target,
        .optimize = optimize,
    });
    _ = SQLite.create(.{
        .b = b,
        .dest = profile_exe,
        .target = x86_target,
        .optimize = optimize,
    });
    _ = ObjC.create(.{
        .b = b,
        .dest = profile_exe,
        .target = x86_target,
        .optimize = optimize,
    });
    _ = Tracy.create(.{
        .b = b,
        .dest = profile_exe,
        .target = x86_target,
        .optimize = optimize,
    });
    real_vec_cfg.install(b, profile_exe, debug);
    const run_profile = b.addRunArtifact(profile_exe);
    const profile_step = b.step("profile", "run the profile executable");
    profile_step.dependOn(&run_profile.step);

    // All
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(test_root);
    test_step.dependOn(test_model);
    test_step.dependOn(test_embed);
    test_step.dependOn(test_vec_storage);
    test_step.dependOn(test_vec);
    test_step.dependOn(test_diff);
    test_step.dependOn(test_markdown);
    // Enable this to see benchmark output
    // test_step.dependOn(test_benchmark);

    ////////////////////
    // Test Debugging //
    ////////////////////
    const lldb = b.addSystemCommand(&.{
        "lldb",
        // add lldb flags before --
        // Uncomment this if lib_unit_tests needs lldb args or test args
        // "--",
    });
    lldb.addArtifactArg(vec_unit_tests);
    const lldb_step = b.step("debug", "run the tests under lldb");
    lldb_step.dependOn(&lldb.step);

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

const GlobalOptions = struct {
    vec_sz: usize = 3,
    vec_type: type = f32,

    const Self = @This();

    pub fn install(self: Self, b: *std.Build, dest: *Step.Compile, debug: bool) void {
        const options = b.addOptions();
        options.addOption(usize, "vec_sz", self.vec_sz);
        // options.addOption(type, "vec_type", self.vec_type);
        options.addOption(bool, "debug", debug);
        dest.root_module.addOptions("config", options);
    }
};

const Baselib = struct {
    pub const Options = struct {
        b: *std.Build,
        target: std.Build.ResolvedTarget,
        optimize: std.builtin.OptimizeMode,
        debug: bool,
    };

    step: *Step,
    output: LazyPath,

    pub fn create(opts: Baselib.Options) Baselib {
        const interface_file = opts.b.path("src/intf.zig");

        const options = opts.b.addOptions();
        options.addOption(bool, "debug", opts.debug);
        options.addOption(usize, "vec_sz", VEC_SZ);

        const base_nana_lib = opts.b.addStaticLibrary(.{
            .name = "nana",
            .root_source_file = interface_file,
            .target = opts.target,
            .optimize = opts.optimize,
        });
        base_nana_lib.root_module.addOptions("config", options);
        const sqlite_step = SQLite.create(.{
            .b = opts.b,
            .dest = base_nana_lib,
            .target = opts.target,
            .optimize = opts.optimize,
        });
        _ = ObjC.create(.{
            .b = opts.b,
            .dest = base_nana_lib,
            .target = opts.target,
            .optimize = opts.optimize,
        });
        _ = Tracy.create(.{
            .b = opts.b,
            .dest = base_nana_lib,
            .target = opts.target,
            .optimize = opts.optimize,
        });

        // Combine Libs
        var lib_sources = [_]LazyPath{
            base_nana_lib.getEmittedBin(),
            sqlite_step.output,
        };
        const outname = opts.b.fmt("libnana-{s}-{s}.a", .{
            @tagName(opts.target.query.os_tag.?),
            @tagName(opts.target.query.cpu_arch.?),
        });
        const combine_lib = Libtool.create(opts.b, .{
            .name = "nana",
            .out_name = outname,
            .sources = &lib_sources,
        });
        combine_lib.step.dependOn(&base_nana_lib.step);

        return .{
            .step = combine_lib.step,
            .output = combine_lib.output,
        };
    }
};

const SQLite = struct {
    // step: *Step,
    output: LazyPath,

    const SQLiteOptions = struct {
        b: *std.Build,
        dest: *Step.Compile,
        target: std.Build.ResolvedTarget,
        optimize: std.builtin.OptimizeMode,
    };

    pub fn create(opts: SQLiteOptions) SQLite {
        const sqlite_dep = opts.b.dependency("sqlite", .{
            .target = opts.target,
            .optimize = opts.optimize,
        });
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

const ObjC = struct {
    const ObjCOptions = struct {
        b: *std.Build,
        dest: *Step.Compile,
        target: std.Build.ResolvedTarget,
        optimize: std.builtin.OptimizeMode,
    };

    pub fn create(opts: ObjCOptions) ObjC {
        var objc_dep = opts.b.dependency("zig_objc", .{
            .target = opts.target,
            .optimize = opts.optimize,
        });
        opts.dest.root_module.addImport("objc", objc_dep.module("objc"));
        opts.dest.root_module.linkFramework("NaturalLanguage", .{});
        opts.dest.root_module.linkFramework("CoreML", .{});
        opts.dest.root_module.linkFramework("Foundation", .{});

        return ObjC{};
    }
};

const Tracy = struct {
    const TracyOptions = struct {
        b: *std.Build,
        dest: *Step.Compile,
        target: std.Build.ResolvedTarget,
        optimize: std.builtin.OptimizeMode,
    };

    pub fn create(opts: TracyOptions) Tracy {
        const tracy_enable = if (opts.optimize == .Debug) true else false;
        var tracy_dep = opts.b.dependency("tracy", .{
            .target = opts.target,
            .optimize = opts.optimize,
            .tracy_enable = tracy_enable,
            .tracy_callstack = 62,
        });
        opts.dest.root_module.addImport("tracy", tracy_dep.module("tracy"));
        if (!tracy_enable) {
            return Tracy{};
        }

        opts.dest.root_module.linkLibrary(tracy_dep.artifact("tracy"));
        opts.dest.root_module.link_libcpp = true;
        const install_dir = std.Build.Step.InstallArtifact.Options.Dir{ .override = .{ .bin = {} } };
        const install_tracy = opts.b.addInstallArtifact(tracy_dep.artifact("tracy"), .{
            .dest_dir = install_dir,
        });
        opts.b.getInstallStep().dependOn(&install_tracy.step);

        return Tracy{};
    }
};

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
            "curl",                                                                           "-fsSL", "-o", MODEL_DIR ++ "/float32_model.mlpackage/Data/com.apple.CoreML/model.mlmodel",
            HF_BASE ++ "/coreml/float32_model.mlpackage/Data/com.apple.CoreML/model.mlmodel",
        });
        dl_mlmodel.step.dependOn(&mkdir_step.step);

        const dl_weights = RunStep.create(b, "jina: download weight.bin");
        dl_weights.addArgs(&.{
            "curl",                                                                                "-fsSL", "-o", MODEL_DIR ++ "/float32_model.mlpackage/Data/com.apple.CoreML/weights/weight.bin",
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
