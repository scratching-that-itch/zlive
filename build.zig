const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The transport lives in this package: apps depend on zlive only.
    const httpz_dep = b.dependency("httpz", .{
        .target = target,
        .optimize = optimize,
    });

    const zlive = b.addModule("zlive", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "httpz", .module = httpz_dep.module("httpz") },
        },
    });

    // The template compiler runs on the build machine, so it is always
    // built for the host; debug mode compiles fast and is fast enough.
    const tool_optimize = b.option(
        std.builtin.OptimizeMode,
        "tool_optimize",
        "Optimize mode for zlive-compile (default: debug)",
    ) orelse .debug;
    const compiler_exe = b.addExecutable(.{
        .name = "zlive-compile",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/template/main.zig"),
            .target = b.graph.host,
            .optimize = tool_optimize,
        }),
    });
    b.installArtifact(compiler_exe);

    // Golden fixture: compile fixture_counter.html, then test the
    // generated code's render + diff output.
    const fixture_templates = addTemplatesWithCompiler(b, compiler_exe, "", &.{
        b.path("src/template/fixture_counter.html"),
    });

    const tests = b.addTest(.{
        .root_module = zlive,
    });
    const run_tests = b.addRunArtifact(tests);

    const fixture_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/template/fixture_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    fixture_tests.root_module.addImport("zlive", zlive);
    fixture_tests.step.dependOn(fixture_templates);
    const run_fixture_tests = b.addRunArtifact(fixture_tests);

    // The template compiler's own tests. It is a build-time executable, so
    // nothing else reaches its test declarations.
    const compiler_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/template/compiler.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_compiler_tests = b.addRunArtifact(compiler_tests);

    const test_step = b.step("test", "Run zlive unit tests");
    test_step.dependOn(&run_tests.step);
    test_step.dependOn(&run_fixture_tests.step);
    test_step.dependOn(&run_compiler_tests.step);
}

/// Compiles .html template files to .zig files next to the sources
/// (button.html -> button.zig). `out_prefix` is prepended to the generated
/// path: "" in the owning package's own build, "../zlive-components/" when
/// a sibling package (e.g. the examples app) regenerates them, since
/// UpdateSourceFiles always writes relative to the root build root.
/// Returns a step that must complete before anything importing the
/// generated files compiles:
///
///   const zlive = @import("zlive");
///   const zlive_dep = b.dependency("zlive", .{});
///   const templates = zlive.addTemplates(b, zlive_dep, "", &.{
///       b.path("src/button.html"),
///   });
///   exe.step.dependOn(templates);
pub fn addTemplates(
    b: *std.Build,
    zlive_dep: *std.Build.Dependency,
    out_prefix: []const u8,
    template_paths: []const std.Build.LazyPath,
) *std.Build.Step {
    return addTemplatesWithCompiler(b, zlive_dep.artifact("zlive-compile"), out_prefix, template_paths);
}

fn addTemplatesWithCompiler(
    b: *std.Build,
    compiler: *std.Build.Step.Compile,
    out_prefix: []const u8,
    template_paths: []const std.Build.LazyPath,
) *std.Build.Step {
    const usf = b.addUpdateSourceFiles();
    for (template_paths) |template_path| {
        const sub_path = switch (template_path) {
            .src_path => |p| p.sub_path,
            .dependency => |p| p.sub_path,
            else => @panic("addTemplates: template paths must be b.path(...) or dep.path(...) source paths"),
        };
        const stem = sub_path[0 .. sub_path.len - std.fs.path.extension(sub_path).len];
        const out_sub_path = std.mem.concat(b.allocator, u8, &.{ out_prefix, stem, ".zig" }) catch @panic("OOM");

        const run = b.addRunArtifact(compiler);
        run.addFileArg(template_path);
        const output = run.addOutputFileArg(std.fs.path.basename(out_sub_path));
        usf.addCopyFileToSource(output, out_sub_path);
    }
    return &usf.step;
}

/// Renders layout/page templates at build time with an app-supplied tool.
///
/// `renderer` is a host executable invoked as
/// `renderer <entry> <output>`; `page_files` are the entry names passed to
/// it, and each result is copied to `out_prefix ++ name`, where the app's
/// `@embedFile` can reach it (embedding is bounded by the module root).
/// Returns a step that anything embedding the rendered pages must depend on.
///
/// The app owns its template sources, its page list and its renderer (which
/// embeds those sources so the build tracks them); zlive owns the engine
/// (`zlive.layout`) and this copy step, mirroring `addTemplates` for the
/// component compiler. See `zlive/README.md` ("Layouts").
pub fn addRenderedPages(
    b: *std.Build,
    renderer: *std.Build.Step.Compile,
    page_files: []const []const u8,
    out_prefix: []const u8,
) *std.Build.Step {
    const usf = b.addUpdateSourceFiles();
    for (page_files) |name| {
        const run = b.addRunArtifact(renderer);
        run.addArg(name);
        const output = run.addOutputFileArg(name);
        const sub_path = std.mem.concat(b.allocator, u8, &.{ out_prefix, name }) catch @panic("OOM");
        usf.addCopyFileToSource(output, sub_path);
    }
    return &usf.step;
}
