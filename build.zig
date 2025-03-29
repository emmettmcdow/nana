const std = @import("std");

const Step = std.Build.Step;
const RunStep = std.Build.Step.Run;
const LazyPath = std.Build.LazyPath;

// This file is a crime against zig. But I am deferring making it unfugly until I know more about
// the zig build system.

const targets: []const std.Target.Query = &.{
    .{ .cpu_arch = .aarch64, .os_tag = .macos },
    .{ .cpu_arch = .x86_64, .os_tag = .macos },
};

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});

    ///////////////////
    // Build the Lib //
    ///////////////////
    var ltSteps = [2]*LibtoolStep{ undefined, undefined };
    for (targets, 0..) |t, i| {
        const target = b.resolveTargetQuery(t);
        const lib2 = b.addStaticLibrary(.{
            .name = "nana2",
            .root_source_file = b.path("src/intf.zig"),
            .target = target,
            .optimize = optimize,
        });
        const sqlite = b.dependency("sqlite", .{
            .target = target,
            .optimize = optimize,
        });
        const onnx_dep = b.dependency("zig_onnxruntime", .{
            .optimize = optimize,
            .target = target,
        });
        const sqliteArtifact = sqlite.artifact("sqlite");
        const mod = sqlite.module("sqlite");
        lib2.root_module.addImport("sqlite", mod);
        lib2.root_module.addImport("onnxruntime", onnx_dep.module("zig-onnxruntime"));
        lib2.linkLibrary(sqliteArtifact);
        lib2.bundle_compiler_rt = true;
        lib2.linkLibC();
        b.default_step.dependOn(&lib2.step);

        const install_onnx_libs = b.addInstallDirectory(.{
            .source_dir = onnx_dep.module("onnxruntime_lib").root_source_file.?,
            .install_dir = .bin,
            .install_subdir = ".",
        });
        b.getInstallStep().dependOn(&install_onnx_libs.step);

        var libSources = [_]LazyPath{
            lib2.getEmittedBin(),
            sqliteArtifact.getEmittedBin(),
        };
        const os = target.query.os_tag.?;
        const cpu = target.query.cpu_arch.?;
        const outfile = b.fmt("libnana-{s}-{s}.a", .{ @tagName(os), @tagName(cpu) });
        const libtool = createLibtoolStep(b, .{
            .name = "nana",
            .out_name = outfile,
            .sources = libSources[0..],
        });
        libtool.step.dependOn(&lib2.step);
        ltSteps[i] = libtool;
        b.default_step.dependOn(libtool.step);
        const lib_install = b.addInstallLibFile(libtool.output, outfile);
        b.getInstallStep().dependOn(&lib_install.step);
    }

    const outfile = "libnana.a";
    const static_lib_universal = createLipoStep(b, .{
        .name = "nana",
        .out_name = outfile,
        .input_a = ltSteps[0].output,
        .input_b = ltSteps[1].output,
    });
    static_lib_universal.step.dependOn(ltSteps[0].step);
    static_lib_universal.step.dependOn(ltSteps[1].step);
    const lib_install = b.addInstallLibFile(static_lib_universal.output, outfile);
    b.getInstallStep().dependOn(&lib_install.step);

    const xcframework = createXCFrameworkStep(b, .{
        .name = "NanaKit",
        .out_path = "macos/NanaKit.xcframework",
        .library = static_lib_universal.output,
        .headers = .{ .cwd_relative = "include" },
    });
    xcframework.step.dependOn(static_lib_universal.step);
    b.getInstallStep().dependOn(xcframework.step);

    ////////////////
    // Unit Tests //
    ////////////////
    const target = b.standardTargetOptions(.{});
    const lib_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const sqlite = b.dependency("sqlite", .{
        .target = target,
        .optimize = optimize,
    });
    const onnx_dep = b.dependency("zig_onnxruntime", .{
        .optimize = optimize,
        .target = target,
    });

    lib_unit_tests.root_module.addImport("sqlite", sqlite.module("sqlite"));
    lib_unit_tests.root_module.addImport("onnxruntime", onnx_dep.module("zig-onnxruntime"));
    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);

    const embed_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/embed.zig"),
        .target = target,
        .optimize = optimize,
    });
    embed_unit_tests.root_module.addImport("onnxruntime", onnx_dep.module("zig-onnxruntime"));
    const run_embed_unit_tests = b.addRunArtifact(embed_unit_tests);
    test_step.dependOn(&run_embed_unit_tests.step);

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
