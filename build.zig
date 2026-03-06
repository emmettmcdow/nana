const xc_fw_path = "macos/NanaKit.xcframework";

pub fn build(b: *std.Build) !void {
    const debug = b.option(bool, "debug-output", "Show debug output") orelse false;
    const embedding_model = b.option(
        EmbeddingModel,
        "embedding-model",
        "Embedding model to use (apple_nlembedding or mpnet_embedding)",
    ) orelse .apple_nlembedding;
    const test_filter: ?[]const u8 = b.option(
        []const u8,
        "test-filter",
        "Filter to select specific tests (e.g., -Dtest-filter='my test name')",
    );
    const test_file: ?[]const u8 = b.option(
        []const u8,
        "test-file",
        "Run tests only from this file (e.g., -Dtest-file=root)",
    );
    const use_objc_leakcheck: bool = b.option(
        bool,
        "objc-leakcheck",
        "(MacOS only) Run the test with `leaks`",
    ) orelse false;
    const use_lldb = b.option(bool, "lldb", "Run tests under lldb debugger") orelse false;
    if (use_lldb and use_objc_leakcheck) {
        std.debug.print("Cannot use `lldb` and `leaks` at the same time. Exiting.\n", .{});
        return Error.ConflictingOptions;
    }
    const optimize = b.standardOptimizeOption(.{});

    const install_step = b.getInstallStep();

    // Targets
    const arm_target = b.resolveTargetQuery(.{ .cpu_arch = .aarch64, .os_tag = .macos });
    const x86_target = b.resolveTargetQuery(.{ .cpu_arch = .x86_64, .os_tag = .macos });

    const targets: [2]std.Build.ResolvedTarget = .{
        x86_target,
        arm_target,
    };

    // Sources
    const root_file = b.path("src/root.zig");
    const diff_file = b.path("src/dmp.zig");
    const perf_file = b.path("src/perf_benchmark.zig");
    const profile_file = b.path("src/profile.zig");
    const markdown_file = b.path("src/markdown.zig");
    const util_file = b.path("src/util.zig");

    ///////////////////////////
    // dve dependency module //
    ///////////////////////////
    const dve_dep = b.dependency("dve", .{
        .target = x86_target,
        .optimize = optimize,
        .@"debug-output" = debug,
        .@"embedding-model" = embedding_model,
    });
    const dve_module = dve_dep.module("dve");

    // Copy model and tokenizer to mac app Resources for bundling
    const mkdir_mac_resources = RunStep.create(b, "create mac resources dir");
    mkdir_mac_resources.addArgs(&.{ "mkdir", "-p", "mac/nana/Resources" });

    const copy_model_to_mac = RunStep.create(b, "copy mpnet model to mac app");
    copy_model_to_mac.addArgs(&.{ "cp", "-R" });
    copy_model_to_mac.addFileArg(dve_dep.path("models/all_mpnet_base_v2/all_mpnet_base_v2.mlpackage"));
    copy_model_to_mac.addArgs(&.{"mac/nana/Resources/"});
    copy_model_to_mac.step.dependOn(&mkdir_mac_resources.step);

    const copy_tokenizer_to_mac = RunStep.create(b, "copy tokenizer to mac app");
    copy_tokenizer_to_mac.addArgs(&.{"cp"});
    copy_tokenizer_to_mac.addFileArg(dve_dep.path("models/all_mpnet_base_v2/tokenizer.json"));
    copy_tokenizer_to_mac.addArgs(&.{"mac/nana/Resources/"});
    copy_tokenizer_to_mac.step.dependOn(&mkdir_mac_resources.step);

    install_step.dependOn(&copy_model_to_mac.step);
    install_step.dependOn(&copy_tokenizer_to_mac.step);

    ///////////////////
    // Build the Lib //
    ///////////////////
    var baselib_platform_list: [targets.len]Baselib = undefined;
    for (targets, 0..) |target, i| {
        const dve_dep_arch = b.dependency("dve", .{
            .target = target,
            .optimize = optimize,
            .@"debug-output" = debug,
            .@"embedding-model" = embedding_model,
        });
        baselib_platform_list[i] = Baselib.create(.{
            .b = b,
            .target = target,
            .optimize = optimize,
            .debug = debug,
            .dve_module = dve_dep_arch.module("dve"),
        });
    }

    const outfile = "libnana.a";
    const static_lib_universal = Lipo.create(b, .{
        .name = "nana",
        .out_name = outfile,
        .inputs = &baselib_platform_list,
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

    ////////////////////////
    // Standalone Binary  //
    ////////////////////////
    const main_file = b.path("src/main.zig");
    const native_target = b.resolveTargetQuery(.{});
    const exe = b.addExecutable(.{
        .name = "nana",
        .root_module = b.createModule(.{
            .root_source_file = main_file,
            .target = native_target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addImport("nana", b.createModule(.{
        .root_source_file = root_file,
        .imports = &.{.{ .name = "dve", .module = dve_module }},
    }));
    addNanaDeps(.{ .b = b, .dest = exe, .target = native_target, .optimize = optimize }, dve_module);
    b.installArtifact(exe);

    // Install model files to share directory
    b.installDirectory(.{
        .source_dir = dve_dep.path("models/all_mpnet_base_v2/all_mpnet_base_v2.mlpackage"),
        .install_dir = .{ .custom = "share" },
        .install_subdir = "all_mpnet_base_v2.mlpackage",
    });
    install_step.dependOn(&b.addInstallFile(
        dve_dep.path("models/all_mpnet_base_v2/tokenizer.json"),
        "share/tokenizer.json",
    ).step);

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

    const filters: []const []const u8 = if (test_filter) |f| &.{f} else &.{};

    const runTest = struct {
        fn run(builder: *std.Build, test_artifact: *std.Build.Step.Compile, lldb: bool, leaks: bool) *RunStep {
            if (lldb) {
                const lldb_run = RunStep.create(builder, "lldb test");
                lldb_run.addArgs(&.{ "lldb", "--" });
                lldb_run.addArtifactArg(test_artifact);
                return lldb_run;
            } else if (leaks) {
                const leaks_run = RunStep.create(builder, "leaks test");
                leaks_run.setEnvironmentVariable("MallocStackLogging", "1");
                leaks_run.addArgs(&.{ "leaks", "--atExit", "-quiet", "--" });
                leaks_run.addArtifactArg(test_artifact);
                return leaks_run;
            } else {
                return builder.addRunArtifact(test_artifact);
            }
        }
    }.run;

    const test_root = b.step("test-root", "run the tests for src/root.zig");
    {
        const t = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = root_file,
                .target = x86_target,
                .optimize = optimize,
            }),
            .filters = if (test_filter != null) filters else &.{},
        });
        t.root_module.addImport("dve", dve_module);
        addNanaDeps(depOpts(x86_deps, t), dve_module);
        const install_models = b.addInstallDirectory(.{
            .source_dir = dve_dep.path("models/all_mpnet_base_v2/all_mpnet_base_v2.mlpackage"),
            .install_dir = .{ .custom = "share" },
            .install_subdir = "all_mpnet_base_v2.mlpackage",
        });
        const install_tokenizer = b.addInstallFile(
            dve_dep.path("models/all_mpnet_base_v2/tokenizer.json"),
            "share/tokenizer.json",
        );
        const run = runTest(b, t, use_lldb, use_objc_leakcheck);
        run.step.dependOn(&install_models.step);
        run.step.dependOn(&install_tokenizer.step);
        test_root.dependOn(&run.step);
    }

    const test_markdown = b.step("test-markdown", "run the tests for src/markdown.zig");
    {
        const t = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = markdown_file,
                .target = x86_target,
                .optimize = optimize,
            }),
            .filters = if (test_filter != null) filters else &.{},
        });
        t.root_module.addImport("dve", dve_module);
        addTracy(depOpts(x86_deps, t));
        test_markdown.dependOn(&runTest(b, t, use_lldb, use_objc_leakcheck).step);
    }

    const test_diff = b.step("test-diff", "run the tests for src/diff.zig");
    {
        const t = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = diff_file,
                .target = x86_target,
                .optimize = optimize,
            }),
            .filters = if (test_filter != null) filters else &.{},
        });
        test_diff.dependOn(&runTest(b, t, use_lldb, use_objc_leakcheck).step);
    }

    const test_util = b.step("test-util", "run the tests for src/util.zig");
    {
        const t = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = util_file,
                .target = x86_target,
                .optimize = optimize,
            }),
            .filters = if (test_filter != null) filters else &.{},
        });
        test_util.dependOn(&runTest(b, t, use_lldb, use_objc_leakcheck).step);
    }

    const test_perf = b.step("perf", "Run performance benchmark tests");
    {
        const t = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = perf_file,
                .target = x86_target,
                .optimize = optimize,
            }),
            .filters = if (test_filter != null) filters else &.{},
        });
        t.root_module.addImport("dve", dve_module);
        addNanaDeps(depOpts(x86_deps, t), dve_module);
        test_perf.dependOn(&runTest(b, t, use_lldb, use_objc_leakcheck).step);
    }

    const profile_step = b.step("profile", "run the profile executable");
    {
        const p = b.addExecutable(.{
            .name = "profile",
            .root_module = b.createModule(.{
                .root_source_file = profile_file,
                .target = x86_target,
                .optimize = optimize,
            }),
        });
        p.root_module.addImport("dve", dve_module);
        addNanaDeps(depOpts(x86_deps, p), dve_module);
        const profile_run = if (use_lldb) blk: {
            const lldb_run = RunStep.create(b, "lldb profile");
            lldb_run.addArgs(&.{ "lldb", "--" });
            lldb_run.addArtifactArg(p);
            break :blk lldb_run;
        } else b.addRunArtifact(p);
        profile_step.dependOn(&profile_run.step);
    }

    // All tests
    const test_step = b.step("test", "Run unit tests (-Dtest-file=X to run one file, -Dtest-filter=Y to filter tests)");
    const file_tests = .{
        .{ "root.zig", test_root },
        .{ "diff.zig", test_diff },
        .{ "markdown.zig", test_markdown },
        .{ "util.zig", test_util },
    };
    inline for (file_tests) |entry| {
        const name = entry[0];
        const step = entry[1];
        if (test_file) |tf| {
            if (std.mem.eql(u8, tf, name)) {
                test_step.dependOn(step);
            }
        } else {
            test_step.dependOn(step);
        }
    }

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
        break :step builder.build();
    });
}

const EmbeddingModel = enum {
    apple_nlembedding,
    mpnet_embedding,
};

const Baselib = struct {
    pub const Options = struct {
        b: *std.Build,
        target: std.Build.ResolvedTarget,
        optimize: std.builtin.OptimizeMode,
        debug: bool,
        dve_module: *std.Build.Module,
    };

    step: *Step,
    output: LazyPath,

    pub fn create(opts: Baselib.Options) Baselib {
        const interface_file = opts.b.path("src/intf.zig");

        const base_nana_lib = opts.b.addLibrary(.{
            .linkage = .static,
            .name = "nana",
            .root_module = opts.b.createModule(.{
                .root_source_file = interface_file,
                .target = opts.target,
                .optimize = opts.optimize,
            }),
        });
        base_nana_lib.bundle_compiler_rt = true;
        base_nana_lib.root_module.addImport("dve", opts.dve_module);
        const dep_opts = DepOptions{
            .b = opts.b,
            .dest = base_nana_lib,
            .target = opts.target,
            .optimize = opts.optimize,
        };
        addObjCFrameworks(dep_opts);
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

/// Link ObjC frameworks needed by dve's embed code.
fn addObjCFrameworks(opts: DepOptions) void {
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

/// Add all deps a nana compile target needs: ObjC framework links + tracy.
fn addNanaDeps(opts: DepOptions, dve_module: *std.Build.Module) void {
    _ = dve_module;
    addObjCFrameworks(opts);
    addTracy(opts);
}

fn depOpts(base: DepOptions, dest: *Step.Compile) DepOptions {
    return .{ .b = base.b, .dest = dest, .target = base.target, .optimize = base.optimize };
}

// TY mitchellh
// https://gist.github.com/mitchellh/0ee168fb34915e96159b558b89c9a74b#file-libtoolstep-zig
const Libtool = struct {
    pub const Options = struct {
        name: []const u8,
        out_name: []const u8,
        sources: []LazyPath,
    };

    step: *Step,
    output: LazyPath,

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
        name: []const u8,
        out_name: []const u8,
        inputs: []Baselib,
    };

    step: *Step,
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
        name: []const u8,
        out_path: []const u8,
        libraries: []const LazyPath,
        headers: []const LazyPath,
    };

    step: *Step,

    pub fn create(b: *std.Build, opts: XCFramework.Options) *XCFramework {
        const self = b.allocator.create(XCFramework) catch @panic("OOM");

        const run_delete = run: {
            const run = RunStep.create(b, b.fmt("xcframework delete {s}", .{opts.name}));
            run.has_side_effects = true;
            run.addArgs(&.{ "rm", "-rf", opts.out_path });
            break :run run;
        };

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
        path: []const u8,
    };

    step: *Step,

    pub fn create(opts: Codesign.Options) Codesign {
        const run_step = RunStep.create(opts.b, opts.b.fmt("CodeSign {s}", .{opts.path}));
        run_step.addArgs(&.{
            "codesign",
            "--timestamp",
            "-s",
            "5AE3B7EECB504FB7ED5B00BB70576647A21ADB15",
            opts.path,
        });

        return .{ .step = &run_step.step };
    }
};

pub const Error = error{ConflictingOptions};

const std = @import("std");
const assert = std.debug.assert;
const Step = std.Build.Step;
const RunStep = Step.Run;
const LazyPath = std.Build.LazyPath;

const zlinter = @import("zlinter");
