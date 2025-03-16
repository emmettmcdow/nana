const std = @import("std");

const Step = std.Build.Step;
const RunStep = std.Build.Step.Run;
const LazyPath = std.Build.LazyPath;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

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
    const sqliteArtifact = sqlite.artifact("sqlite");
    lib2.root_module.addImport("sqlite", sqlite.module("sqlite"));
    lib2.linkLibrary(sqliteArtifact);
    lib2.bundle_compiler_rt = true;
    lib2.linkLibC();
    b.default_step.dependOn(&lib2.step);

    var libSources = [_]LazyPath{
        lib2.getEmittedBin(),
        sqliteArtifact.getEmittedBin(),
    };
    const libtool = createLibtoolStep(b, .{
        .name = "nana",
        .out_name = "libnana-amd64-bundle.a",
        .sources = libSources[0..],
    });
    libtool.step.dependOn(&lib2.step);
    b.default_step.dependOn(libtool.step);
    const lib_install = b.addInstallLibFile(libtool.output, "libnana-amd64-bundle.a");
    b.getInstallStep().dependOn(&lib_install.step);

    ////////////////
    // Unit Tests //
    ////////////////
    const lib_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    lib_unit_tests.root_module.addImport("sqlite", sqlite.module("sqlite"));
    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);

    ////////////////////
    // Test Debugging //
    ////////////////////
    const lldb = b.addSystemCommand(&.{
        "lldb",
        // add lldb flags before --
        // Uncomment this if lib_unit_tests needs lldb args or test args
        // "--",
    });
    // appends the unit_tests executable path to the lldb command line
    lldb.addArtifactArg(lib_unit_tests);

    // lldb.addArg can add arguments after the executable path
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

// TODO: set it up so that we can make a universal binary
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
