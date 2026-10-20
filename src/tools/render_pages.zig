//! Renders one page template into a complete document at build time, using
//! the layout engine (`zlive.layout`). This is the framework's half of the
//! page pipeline: the app names its templates and page entries, and
//! `zlive.build.addRenderedPages` runs this tool once per entry and assembles
//! the outputs into a module the app embeds. See `zlive/README.md`
//! ("Layouts").
//!
//! Contract:
//!
//!     zlive-render-pages <entry> <output> <name=path>...
//!
//! `<entry>` is the page's template name; every `<name=path>` registers a
//! template file (layout, include or page) under `name`. The rendered
//! document is written to `<output>`. A template mistake fails the build
//! with the template name, line and reason.

const std = @import("std");
const zlive = @import("zlive");
const layout = zlive.layout;

/// One template, under the name `extends`/`include` use.
pub const Source = struct { name: []const u8, source: []const u8 };

/// Renders `entry` against `sources`; allocations are caller-owned (an arena
/// is the natural choice).
pub fn render(
    allocator: std.mem.Allocator,
    sources: []const Source,
    entry: []const u8,
) layout.Error![]const u8 {
    var engine = layout.Engine.init(allocator);
    for (sources) |source| try engine.add(source.name, source.source);
    return engine.render(entry);
}

pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.next(); // executable
    const entry = args.next() orelse return usage();
    const output = args.next() orelse return usage();

    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const allocator = arena.allocator();

    var engine = layout.Engine.init(allocator);
    while (args.next()) |spec| {
        const eq = std.mem.indexOfScalar(u8, spec, '=') orelse return usage();
        const bytes = std.Io.Dir.cwd().readFileAlloc(init.io, spec[eq + 1 ..], allocator, .unlimited) catch |err|
            return reportIo(spec[eq + 1 ..], err);
        engine.add(spec[0..eq], bytes) catch |err| return report(&engine, err);
    }
    const bytes = engine.render(entry) catch |err| return report(&engine, err);

    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = output, .data = bytes });
}

fn report(engine: *const layout.Engine, err: layout.Error) anyerror {
    std.debug.print("zlive-render-pages: {s}:{d}: {s} ({t})\n", .{
        engine.diag.template,
        engine.diag.line,
        engine.diag.message,
        err,
    });
    return err;
}

fn reportIo(path: []const u8, err: anyerror) anyerror {
    std.debug.print("zlive-render-pages: {s}: {t}\n", .{ path, err });
    return err;
}

fn usage() error{Usage} {
    std.debug.print("usage: zlive-render-pages <entry> <output> <name=path>...\n", .{});
    return error.Usage;
}

test "render: a page extending a layout becomes a complete document" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const sources = [_]Source{
        .{ .name = "base.html", .source = "<!DOCTYPE html><html><body>{% block page %}{% endblock %}</body></html>" },
        .{ .name = "index.html", .source = "{% extends \"base.html\" %}{% block page %}<h1>hi</h1>{% endblock %}" },
    };
    const bytes = try render(arena.allocator(), &sources, "index.html");
    try std.testing.expectEqualStrings(
        "<!DOCTYPE html><html><body><h1>hi</h1></body></html>",
        bytes,
    );
}

test "render: an unknown entry and a missing layout are errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const sources = [_]Source{
        .{ .name = "index.html", .source = "{% extends \"base.html\" %}" },
    };
    try std.testing.expectError(error.UnknownTemplate, render(arena.allocator(), &sources, "nope.html"));
    try std.testing.expectError(error.UnknownTemplate, render(arena.allocator(), &sources, "index.html"));
}
