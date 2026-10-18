// zlive-compile: compiles one .html template to a .zig source file.
//
//   zlive-compile <input.html> <output.zig>

const std = @import("std");
const compiler = @import("compiler.zig");

pub fn main(init: std.process.Init) !void {
    var args = init.minimal.args.iterate();
    _ = args.next(); // executable name
    const input = args.next() orelse return usage();
    const output = args.next() orelse return usage();

    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const cwd = std.Io.Dir.cwd();
    const source = cwd.readFileAlloc(init.io, input, a, .limited(4 * 1024 * 1024)) catch |err| {
        std.debug.print("zlive-compile: cannot read {s}: {t}\n", .{ input, err });
        return err;
    };
    const zig = compiler.compileSource(a, source, std.fs.path.basename(input)) catch |err| {
        std.debug.print("zlive-compile: {s}: {t}\n", .{ input, err });
        return err;
    };
    try cwd.writeFile(init.io, .{ .sub_path = output, .data = zig });
}

fn usage() error{Usage} {
    std.debug.print("usage: zlive-compile <input.html> <output.zig>\n", .{});
    return error.Usage;
}
