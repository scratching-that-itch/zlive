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

    // The page renderer runs on the build machine, same as the compiler.
    // Apps never build it themselves; addRenderedPages fetches the artifact.
    const pages_renderer_exe = b.addExecutable(.{
        .name = "zlive-render-pages",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tools/render_pages.zig"),
            .target = b.graph.host,
            .optimize = tool_optimize,
            .imports = &.{
                .{ .name = "zlive", .module = zlive },
            },
        }),
    });
    b.installArtifact(pages_renderer_exe);

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

    // The page renderer's tests, likewise a build-time executable.
    const pages_renderer_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tools/render_pages.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zlive", .module = zlive },
            },
        }),
    });
    const run_pages_renderer_tests = b.addRunArtifact(pages_renderer_tests);

    const test_step = b.step("test", "Run zlive unit tests");
    test_step.dependOn(&run_tests.step);
    test_step.dependOn(&run_fixture_tests.step);
    test_step.dependOn(&run_compiler_tests.step);
    test_step.dependOn(&run_pages_renderer_tests.step);
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

/// The output of `addRenderedPages`: the step that renders the pages, and
/// a module that embeds them.
pub const RenderedPages = struct {
    step: *std.Build.Step,
    module: *std.Build.Module,
};

/// The templates and page entries `addRenderedPages` renders.
pub const RenderedPagesOptions = struct {
    /// Layout and include templates the pages may reference, as build paths
    /// (`b.path("src/templates/base.html")`). The template name pages use in
    /// `{% extends %}`/`{% include %}` is the file's basename.
    templates: []const std.Build.LazyPath,
    /// The directory the page entries live in.
    pages_dir: std.Build.LazyPath,
    /// The page entry names within `pages_dir` (`index.html`, ...); each one
    /// is rendered and embedded.
    entries: []const []const u8,
};

/// Renders the app's page templates at build time and returns a module that
/// embeds them.
///
/// The framework owns the whole pipeline: the renderer executable
/// (`zlive-render-pages`, fetched from `zlive_dep`), the per-entry runs, and
/// the assembly of the outputs into a generated directory in the build
/// cache. That directory also gets a generated `pages_rendered.zig` that
/// embeds every page with `@embedFile` — one `pub const` per page, named
/// after the file minus its extension with non-alphanumeric characters
/// mapped to `_` (so `test-morph.html` becomes `test_morph`). The returned
/// module roots at that file; because a generated directory is its own
/// module root, the embeds work without any generated files in the app's
/// source tree.
///
/// The app only declares its data — `options.templates`, `options.pages_dir`
/// and `options.entries` — and imports the returned module. Template sources
/// are passed to the renderer as file inputs, so the build tracks them and
/// re-renders on change. See `zlive/README.md` ("Layouts").
pub fn addRenderedPages(
    b: *std.Build,
    zlive_dep: *std.Build.Dependency,
    options: RenderedPagesOptions,
) RenderedPages {
    const renderer = zlive_dep.artifact("zlive-render-pages");

    const wf = b.addWriteFiles();
    for (options.entries) |entry| {
        const run = b.addRunArtifact(renderer);
        run.addArg(entry);
        const output = run.addOutputFileArg(entry);
        for (options.templates) |template| {
            const sub_path = switch (template) {
                .src_path => |p| p.sub_path,
                .dependency => |p| p.sub_path,
                else => @panic("addRenderedPages: templates must be b.path(...) or dep.path(...) source paths"),
            };
            run.addPrefixedFileArg(
                std.fmt.allocPrint(b.allocator, "{s}=", .{std.fs.path.basename(sub_path)}) catch @panic("OOM"),
                template,
            );
        }
        for (options.entries) |page| {
            run.addPrefixedFileArg(
                std.fmt.allocPrint(b.allocator, "{s}=", .{page}) catch @panic("OOM"),
                options.pages_dir.path(b, page),
            );
        }
        _ = wf.addCopyFile(output, entry);
    }

    var zig_source: std.ArrayList(u8) = .empty;
    for (options.entries) |name| {
        const stem = std.fs.path.stem(name);
        const ident = b.allocator.alloc(u8, stem.len) catch @panic("OOM");
        for (stem, 0..) |c, i| ident[i] = if (std.ascii.isAlphanumeric(c)) c else '_';
        zig_source.print(b.allocator, "pub const {s} = @embedFile(\"{s}\");\n", .{ ident, name }) catch @panic("OOM");
    }
    const zig_file = wf.add("pages_rendered.zig", zig_source.items);

    return .{
        .step = &wf.step,
        .module = b.createModule(.{ .root_source_file = zig_file }),
    };
}
