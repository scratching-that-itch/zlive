// Golden test for the template compiler: renders the generated code from
// fixture_counter.html and checks the tree, the flattened HTML, and the
// diff output.

const std = @import("std");
const zlive = @import("zlive");
const fixture = @import("fixture_counter.zig");

fn renderFixture(a: std.mem.Allocator, count: i64, items: []const []const u8, show: bool) ![]zlive.Segment {
    return fixture.render(a, .{ .count = count, .items = items, .show = show });
}

test "fixture: flattened html" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const tree = try renderFixture(a, 3, &.{ "a", "b" }, true);
    const html = try zlive.flattenHtml(a, tree);
    try std.testing.expectEqualStrings(
        "<p>count: 3</p><span>visible</span><ul><li>a</li><li>b</li></ul>",
        html,
    );
}

test "fixture: counter diff touches one slot" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const old = try renderFixture(a, 3, &.{"a"}, false);
    const new = try renderFixture(a, 4, &.{"a"}, false);

    var patches = try zlive.diff(a, old, new);
    defer patches.deinit();
    try std.testing.expectEqual(@as(usize, 1), patches.count());
    try std.testing.expectEqualStrings("1", patches.at(0).path);
}

test "fixture: if-block toggle replaces the slot" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const shown = try renderFixture(a, 1, &.{"a"}, true);
    const hidden = try renderFixture(a, 1, &.{"a"}, false);

    var patches = try zlive.diff(a, shown, hidden);
    defer patches.deinit();
    try std.testing.expectEqual(@as(usize, 1), patches.count());
    try std.testing.expectEqualStrings("3", patches.at(0).path);
    try std.testing.expectEqual(@as(usize, 0), patches.at(0).node.children.len);
}

test "fixture: appending a loop item patches only the added index" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const before = try renderFixture(a, 1, &.{ "a", "b" }, false);
    const after = try renderFixture(a, 1, &.{ "a", "b", "c" }, false);

    var patches = try zlive.diff(a, before, after);
    defer patches.deinit();
    try std.testing.expectEqual(@as(usize, 1), patches.count());
    try std.testing.expectEqualStrings("5.2", patches.at(0).path);

    const json = try patches.toJson(a);
    try std.testing.expectEqualStrings("{\"5.2\":[\"<li>\",\"c\",\"</li>\"]}", json);
}

test "fixture: generated component satisfies the Component contract" {
    _ = zlive.Component(fixture);
}
