const std = @import("std");

const Step = std.Build.Step;
const RunStep = std.Build.Step.Run;
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
    const embed_file = b.path("src/embed.zig");
    const interface_file = b.path("src/intf.zig");

    // TODO: make these lazy
    // Dependencies
    const mnist_dep = b.dependency("mnist_testing", .{});

    // Options
    const options = b.addOptions();

    // Static files
    const install_mnist = b.addInstallDirectory(.{
        .source_dir = mnist_dep.path(""),
        .install_dir = .{ .custom = "share" },
        .install_subdir = ".",
    });
    install_step.dependOn(&install_mnist.step);

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
    const sqlite_x86_art = addSQLite(b, optimize, base_nana_x86_lib, x86_target);
    const ort_install_x86_step = addORT(b, optimize, base_nana_x86_lib, x86_target);
    install_step.dependOn(ort_install_x86_step);

    const base_nana_arm_lib = b.addStaticLibrary(.{
        .name = "nana",
        .root_source_file = interface_file,
        .target = arm_target,
        .optimize = optimize,
    });
    base_nana_arm_lib.root_module.addOptions("config", options);
    const sqlite_arm_art = addSQLite(b, optimize, base_nana_arm_lib, arm_target);
    const ort_install_arm_step = addORT(b, optimize, base_nana_arm_lib, arm_target);
    install_step.dependOn(ort_install_arm_step);

    // Combine Libs
    var x86_lib_sources = [_]LazyPath{
        base_nana_x86_lib.getEmittedBin(),
        sqlite_x86_art.getEmittedBin(),
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
        sqlite_arm_art.getEmittedBin(),
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
        .input_a = combine_x86_lib.output,
        .input_b = combine_arm_lib.output,
    });
    static_lib_universal.step.dependOn(combine_x86_lib.step);
    static_lib_universal.step.dependOn(combine_arm_lib.step);

    const xcframework = createXCFrameworkStep(b, .{
        .name = "NanaKit",
        .out_path = "macos/NanaKit.xcframework",
        .library = static_lib_universal.output,
        .headers = .{ .cwd_relative = "include" },
    });
    xcframework.step.dependOn(static_lib_universal.step);
    install_step.dependOn(xcframework.step);

    ////////////////
    // Unit Tests //
    ////////////////
    // Root
    const lib_unit_tests = b.addTest(.{
        .root_source_file = root_file,
        .target = x86_target,
        .optimize = optimize,
    });
    _ = addSQLite(b, optimize, lib_unit_tests, x86_target);
    // const ort_install_root_test_step = addORT(b, optimize, lib_unit_tests, x86_target);
    const run_root_unit_tests = b.addRunArtifact(lib_unit_tests);
    const test_root = b.step("test-root", "run the tests for src/root.zig");
    // test_root.dependOn(ort_install_root_test_step);
    test_root.dependOn(&run_root_unit_tests.step);

    // Embed
    const embed_unit_tests = b.addTest(.{
        .root_source_file = embed_file,
        .target = x86_target,
        .optimize = optimize,
    });
    // const ort_install_embed_test_step = addORT(b, optimize, embed_unit_tests, x86_target);
    const run_embed_unit_tests = b.addRunArtifact(embed_unit_tests);
    const test_embed = b.step("test-embed", "run the tests for src/embed.zig");
    // test_embed.dependOn(ort_install_embed_test_step);
    test_embed.dependOn(&run_embed_unit_tests.step);

    // All
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(test_root);
    test_step.dependOn(test_embed);

    ////////////////////
    // Test Debugging //
    ////////////////////
    const lldb = b.addSystemCommand(&.{
        "lldb",
        // add lldb flags before --
        // Uncomment this if lib_unit_tests needs lldb args or test args
        // "--",
    });
    lldb.addArtifactArg(lib_unit_tests);
    const lldb_step = b.step("debug", "run the tests under lldb");
    lldb_step.dependOn(&lldb.step);
}

fn addSQLite(b: *std.Build, optimize: std.builtin.OptimizeMode, dest: *Step.Compile, target: std.Build.ResolvedTarget) *Step.Compile {
    const sqlite_dep = b.dependency("sqlite", .{ .target = target, .optimize = optimize });
    const sqlite_art = sqlite_dep.artifact("sqlite");
    const sqlite_mod = sqlite_dep.module("sqlite");

    dest.root_module.addImport("sqlite", sqlite_mod);
    dest.linkLibrary(sqlite_art);
    dest.bundle_compiler_rt = true;
    dest.linkLibC();

    return sqlite_art;
}

fn addORT(b: *std.Build, optimize: std.builtin.OptimizeMode, dest: *Step.Compile, target: std.Build.ResolvedTarget) *Step {
    const onnx_dep = b.dependency("zig_onnxruntime", .{ .target = target, .optimize = optimize });
    const onnx_mod = onnx_dep.module("zig-onnxruntime");

    dest.root_module.addImport("onnxruntime", onnx_mod);
    // dest.each_lib_rpath = false;

    const install_onnx_libs = b.addInstallDirectory(.{
        .source_dir = onnx_dep.module("onnxruntime_lib").root_source_file.?,
        .install_dir = .bin,
        .install_subdir = ".",
    });

    return &install_onnx_libs.step;
}

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
        input_a: LazyPath,
        input_b: LazyPath,
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
    run_step.addFileArg(opts.input_a);
    run_step.addFileArg(opts.input_b);

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
        library: LazyPath,

        /// Path to a directory with the headers.
        headers: LazyPath,
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
        run.addArg("-library");
        run.addFileArg(opts.library);
        run.addArg("-headers");
        run.addFileArg(opts.headers);
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
