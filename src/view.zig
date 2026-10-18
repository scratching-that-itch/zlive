const std = @import("std");

/// A dynamic scalar value — the only part of a render tree that can
/// change between renders. Static text and structure are fixed per tree.
pub const Scalar = union(enum) {
    string: []const u8,
    int: i64,
    bool: bool,

    pub fn eql(a: Scalar, b: Scalar) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .string => |s| std.mem.eql(u8, s, b.string),
            .int => |v| v == b.int,
            .bool => |v| v == b.bool,
        };
    }
};

/// One node of a rendered view.
///
/// A render produces a tree: a list of segments where each node is either
/// constant text, a dynamic scalar, or a nested list of segments (produced
/// by loops or component composition).
pub const Segment = union(enum) {
    /// constant text — never produces a value patch
    static: []const u8,
    /// a value that may change between renders
    dynamic: Scalar,
    /// nested segment list (loop iteration or composed component)
    children: []const Segment,

    pub fn text(s: []const u8) Segment {
        return .{ .static = s };
    }

    /// Convenience constructor for a dynamic scalar segment. Accepts
    /// strings, integers (cast to i64), bools, and Scalars (passed through,
    /// for components that produce Scalar values directly, e.g. table
    /// cells).
    pub fn of(v: anytype) Segment {
        const T = @TypeOf(v);
        return switch (@typeInfo(T)) {
            .bool => .{ .dynamic = .{ .bool = v } },
            .int, .comptime_int => .{ .dynamic = .{ .int = @intCast(v) } },
            .pointer => .{ .dynamic = .{ .string = v } },
            .@"struct" => if (T == Scalar)
                .{ .dynamic = v }
            else
                @compileError("unsupported scalar type: " ++ @typeName(T)),
            else => @compileError("unsupported scalar type: " ++ @typeName(T)),
        };
    }
};

/// One path-addressed change. `path` is dot-separated child indices from
/// the root of the tree ("3.2.1" = root[3][2][1]); `node` is the replacement:
/// a `.dynamic` for a value change, a `.children` for structural change
/// (e.g. an appended item). Patch nodes borrow from the `new` tree passed
/// to `diff`, which must outlive the PatchSet.
pub const Patch = struct {
    path: []const u8,
    node: Segment,
};

pub const PatchSet = struct {
    allocator: std.mem.Allocator,
    patches: std.ArrayListUnmanaged(Patch) = .empty,

    pub fn deinit(self: *PatchSet) void {
        for (self.patches.items) |p| self.allocator.free(p.path);
        self.patches.deinit(self.allocator);
    }

    pub fn count(self: *const PatchSet) usize {
        return self.patches.items.len;
    }

    pub fn at(self: *const PatchSet, i: usize) Patch {
        return self.patches.items[i];
    }

    /// Builds the JSON object form of the patch set, keyed by path:
    /// {"3.2.1":"new value","4":["- ","d"]}
    /// Ownership of the returned containers transfers to the caller.
    pub fn toValue(self: *const PatchSet, allocator: std.mem.Allocator) !std.json.Value {
        var obj: std.json.ObjectMap = .empty;
        for (self.patches.items) |p| {
            try obj.put(allocator, p.path, try nodeToValue(allocator, p.node));
        }
        return .{ .object = obj };
    }

    /// Serializes the patch set as a JSON object keyed by path.
    /// Caller owns the returned memory.
    pub fn toJson(self: *const PatchSet, allocator: std.mem.Allocator) ![]u8 {
        const value = try self.toValue(allocator);
        defer freeValue(allocator, value);
        return std.json.Stringify.valueAlloc(allocator, value, .{});
    }
};

/// Converts a render tree to its JSON form: an array whose elements are
/// strings (statics), scalars (dynamics), or nested arrays (children).
/// Ownership of the returned containers transfers to the caller.
pub fn treeToValue(allocator: std.mem.Allocator, tree: []const Segment) !std.json.Value {
    var arr: std.json.Array = .init(allocator);
    for (tree) |seg| try arr.append(try nodeToValue(allocator, seg));
    return .{ .array = arr };
}

/// Frees containers built by nodeToValue/treeToValue. Strings are borrowed
/// (patch paths and statics are owned elsewhere), so only arrays/objects
/// release memory.
pub fn freeValue(allocator: std.mem.Allocator, v: std.json.Value) void {
    switch (v) {
        .array => |arr| {
            for (arr.items) |item| freeValue(allocator, item);
            arr.deinit();
        },
        .object => |obj| {
            var o = obj;
            var it = o.iterator();
            while (it.next()) |e| freeValue(allocator, e.value_ptr.*);
            o.deinit(allocator);
        },
        else => {},
    }
}

pub const DiffError = error{OutOfMemory};

/// Diffs two render trees, emitting one patch per changed slot.
/// Indices present only in `old` (removed tail items) are replaced with
/// an empty subtree, so a removal shows up as e.g. {"3": []}.
pub fn diff(allocator: std.mem.Allocator, old: []const Segment, new: []const Segment) DiffError!PatchSet {
    var set = PatchSet{ .allocator = allocator };
    var path: std.ArrayListUnmanaged(u8) = .empty;
    defer path.deinit(allocator);
    try diffList(allocator, &set, &path, old, new);
    return set;
}

fn diffList(allocator: std.mem.Allocator, set: *PatchSet, path: *std.ArrayListUnmanaged(u8), old: []const Segment, new: []const Segment) DiffError!void {
    const common = @min(old.len, new.len);
    for (old[0..common], new[0..common], 0..) |o, n, i| {
        try diffNode(allocator, set, path, i, o, n);
    }
    for (new[common..], common..) |n, i| {
        const start_len = path.items.len;
        defer path.shrinkRetainingCapacity(start_len);
        try appendIndex(allocator, path, i);
        try addPatch(allocator, set, path, n);
    }
    // removed tail: clear each removed slot (the client replaces the node
    // with an empty subtree)
    for (old[common..], common..) |_, i| {
        const start_len = path.items.len;
        defer path.shrinkRetainingCapacity(start_len);
        try appendIndex(allocator, path, i);
        try addPatch(allocator, set, path, .{ .children = &.{} });
    }
}

fn diffNode(allocator: std.mem.Allocator, set: *PatchSet, path: *std.ArrayListUnmanaged(u8), i: usize, old: Segment, new: Segment) DiffError!void {
    const start_len = path.items.len;
    defer path.shrinkRetainingCapacity(start_len);
    try appendIndex(allocator, path, i);

    switch (old) {
        .static => |os| switch (new) {
            .static => |ns| if (!std.mem.eql(u8, os, ns)) try addPatch(allocator, set, path, new),
            else => try addPatch(allocator, set, path, new),
        },
        .dynamic => |od| switch (new) {
            .dynamic => |nd| if (!Scalar.eql(od, nd)) try addPatch(allocator, set, path, new),
            else => try addPatch(allocator, set, path, new),
        },
        .children => |oc| switch (new) {
            .children => |nc| {
                if (oc.len == 0 and nc.len == 0) {
                    // both empty: nothing to do
                } else if (oc.len == 0 or nc.len == 0) {
                    // one side empty: every child differs, replace the
                    // whole slot with the new subtree (e.g. {"3": [...]})
                    try addPatch(allocator, set, path, new);
                } else {
                    try diffList(allocator, set, path, oc, nc);
                }
            },
            else => try addPatch(allocator, set, path, new),
        },
    }
}

fn appendIndex(allocator: std.mem.Allocator, path: *std.ArrayListUnmanaged(u8), i: usize) DiffError!void {
    var buf: [32]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{i}) catch unreachable;
    if (path.items.len > 0) try path.append(allocator, '.');
    try path.appendSlice(allocator, s);
}

fn addPatch(allocator: std.mem.Allocator, set: *PatchSet, path: *const std.ArrayListUnmanaged(u8), node: Segment) DiffError!void {
    try set.patches.append(allocator, .{
        .path = try allocator.dupe(u8, path.items),
        .node = node,
    });
}

fn nodeToValue(allocator: std.mem.Allocator, seg: Segment) !std.json.Value {
    return switch (seg) {
        .static => |s| .{ .string = s },
        .dynamic => |sc| switch (sc) {
            .string => |s| .{ .string = s },
            .int => |v| .{ .integer = v },
            .bool => |v| .{ .bool = v },
        },
        .children => |kids| blk: {
            var arr: std.json.Array = .init(allocator);
            for (kids) |k| try arr.append(try nodeToValue(allocator, k));
            break :blk .{ .array = arr };
        },
    };
}

// A counter render: one static label, one dynamic count.
fn counterTree(count: i64) [2]Segment {
    return .{ .text("count: "), .of(count) };
}

test "counter diff touches one slot" {
    const allocator = std.testing.allocator;

    const old = counterTree(41);
    const new = counterTree(42);

    var patches = try diff(allocator, &old, &new);
    defer patches.deinit();

    try std.testing.expectEqual(@as(usize, 1), patches.count());
    try std.testing.expectEqualStrings("1", patches.at(0).path);
    try std.testing.expect(patches.at(0).node.dynamic.int == 42);

    const json = try patches.toJson(allocator);
    defer allocator.free(json);
    try std.testing.expectEqualStrings("{\"1\":42}", json);
}

// A list of items where each item is itself a nested segment list
// (static bullet + dynamic label) — the loop/composition case.
fn itemTree(label: []const u8) [2]Segment {
    return .{ .text("- "), .of(label) };
}

test "list middle item change produces exactly one nested patch" {
    const allocator = std.testing.allocator;

    const old = [_]Segment{
        .{ .children = &itemTree("a") },
        .{ .children = &itemTree("b") },
        .{ .children = &itemTree("c") },
    };
    const new = [_]Segment{
        .{ .children = &itemTree("a") },
        .{ .children = &itemTree("B") },
        .{ .children = &itemTree("c") },
    };

    var patches = try diff(allocator, &old, &new);
    defer patches.deinit();

    try std.testing.expectEqual(@as(usize, 1), patches.count());
    try std.testing.expectEqualStrings("1.1", patches.at(0).path);
    try std.testing.expectEqualStrings("B", patches.at(0).node.dynamic.string);

    const json = try patches.toJson(allocator);
    defer allocator.free(json);
    try std.testing.expectEqualStrings("{\"1.1\":\"B\"}", json);
}

test "appending an item patches only the added index" {
    const allocator = std.testing.allocator;

    const old = [_]Segment{
        .{ .children = &itemTree("a") },
        .{ .children = &itemTree("b") },
        .{ .children = &itemTree("c") },
    };
    const new = [_]Segment{
        .{ .children = &itemTree("a") },
        .{ .children = &itemTree("b") },
        .{ .children = &itemTree("c") },
        .{ .children = &itemTree("d") },
    };

    var patches = try diff(allocator, &old, &new);
    defer patches.deinit();

    try std.testing.expectEqual(@as(usize, 1), patches.count());
    try std.testing.expectEqualStrings("3", patches.at(0).path);
    try std.testing.expect(patches.at(0).node == .children);

    // the patch carries the appended item's whole subtree
    const json = try patches.toJson(allocator);
    defer allocator.free(json);
    try std.testing.expectEqualStrings("{\"3\":[\"- \",\"d\"]}", json);
}

// Three levels of nesting: page -> rows -> cells, mirroring the
// "3.2.1"-style path from the wire format documentation.
// Storage lives in the test scope; trees borrow from it.
test "deep nesting addresses cells by full path" {
    const allocator = std.testing.allocator;

    const old_c0 = [2]Segment{ .text("cell "), .of(1) };
    const old_c1 = [2]Segment{ .text("cell "), .of(2) };
    const old_c2 = [2]Segment{ .text("cell "), .of(3) };
    const old_c3 = [2]Segment{ .text("cell "), .of(4) };
    const old_r0 = [2]Segment{ .{ .children = &old_c0 }, .{ .children = &old_c1 } };
    const old_r1 = [2]Segment{ .{ .children = &old_c2 }, .{ .children = &old_c3 } };
    const old = [_]Segment{ .{ .children = &old_r0 }, .{ .children = &old_r1 } };

    const new_c0 = [2]Segment{ .text("cell "), .of(1) };
    const new_c1 = [2]Segment{ .text("cell "), .of(2) };
    const new_c2 = [2]Segment{ .text("cell "), .of(3) };
    const new_c3 = [2]Segment{ .text("cell "), .of(99) };
    const new_r0 = [2]Segment{ .{ .children = &new_c0 }, .{ .children = &new_c1 } };
    const new_r1 = [2]Segment{ .{ .children = &new_c2 }, .{ .children = &new_c3 } };
    const new = [_]Segment{ .{ .children = &new_r0 }, .{ .children = &new_r1 } };

    var patches = try diff(allocator, &old, &new);
    defer patches.deinit();

    try std.testing.expectEqual(@as(usize, 1), patches.count());
    try std.testing.expectEqualStrings("1.1.1", patches.at(0).path);

    const json = try patches.toJson(allocator);
    defer allocator.free(json);
    try std.testing.expectEqualStrings("{\"1.1.1\":99}", json);
}

test "identical trees produce no patches" {
    const allocator = std.testing.allocator;

    const a = [_]Segment{
        .text("count: "),
        .of(42),
        .{ .children = &itemTree("x") },
    };
    const b = [_]Segment{
        .text("count: "),
        .of(42),
        .{ .children = &itemTree("x") },
    };

    var patches = try diff(allocator, &a, &b);
    defer patches.deinit();

    try std.testing.expectEqual(@as(usize, 0), patches.count());
    const json = try patches.toJson(allocator);
    defer allocator.free(json);
    try std.testing.expectEqualStrings("{}", json);
}

// ---------------------------------------------------------------------
// Component layer
// ---------------------------------------------------------------------

/// Validates (at comptime) and returns a component type. A component is a
/// struct that declares a typed `Props` and a `render` returning the
/// recursive segment tree, assembled from comptime statics with only prop
/// values as dynamic segments — so diffs touch exactly the slots whose
/// props changed.
///
/// Two render shapes are supported:
///   * static components:  render(props: Props) [N]Segment
///   * loop components:    render(allocator, props: Props) ![]Segment
///     (build a variable-length tree; the tree and all nested row arrays
///     are allocated from `allocator` — use an arena and free wholesale)
pub fn Component(comptime Impl: type) type {
    if (@typeInfo(Impl) != .@"struct")
        @compileError("component must be a struct, got " ++ @typeName(Impl));
    if (!@hasDecl(Impl, "Props"))
        @compileError(@typeName(Impl) ++ " must declare a Props struct");
    if (!@hasDecl(Impl, "render"))
        @compileError(@typeName(Impl) ++ " must declare render(props: Props)");
    const param_types = @typeInfo(@TypeOf(Impl.render)).@"fn".param_types;
    const static_shape = param_types.len == 1 and param_types[0].? == Impl.Props;
    const loop_shape = param_types.len == 2 and
        param_types[0].? == std.mem.Allocator and param_types[1].? == Impl.Props;
    if (!static_shape and !loop_shape)
        @compileError(@typeName(Impl) ++ ".render must be render(props: Props) or render(allocator, props: Props)");
    return Impl;
}

/// Flattens a render tree to the contiguous HTML string a browser would
/// receive — dynamics are stringified, children spliced in order. Intended
/// for tests and snapshot assertions. Caller owns the returned memory.
pub fn flattenHtml(allocator: std.mem.Allocator, tree: []const Segment) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try flattenInto(tree, &out, allocator);
    return out.toOwnedSlice(allocator);
}

fn flattenInto(tree: []const Segment, out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator) !void {
    for (tree) |seg| switch (seg) {
        .static => |s| try out.appendSlice(allocator, s),
        .dynamic => |d| switch (d) {
            .string => |s| try out.appendSlice(allocator, s),
            .int => |v| {
                var buf: [24]u8 = undefined;
                const s = std.fmt.bufPrint(&buf, "{d}", .{v}) catch unreachable;
                try out.appendSlice(allocator, s);
            },
            .bool => |v| try out.appendSlice(allocator, if (v) "true" else "false"),
        },
        .children => |kids| try flattenInto(kids, out, allocator),
    };
}

/// Empties the children node at a dotted path, e.g. "0.3" or "0.154.3".
///
/// For a view that patches a slot *outside* its own render loop: whatever
/// cleared that slot on the client has to be mirrored into the tree the view
/// keeps for diffing, or the next diff repeats a clear the client already
/// applied (harmless, but not minimal).
///
/// The framework's own notification queues do **not** need this: an expiring
/// message is a state change re-rendered through the view's ordinary diff
/// (see `notify.zig`), so the view never patches around itself. This is for
/// an app that writes a patch of its own from a timer or an external event.
///
/// The tree must be mutable memory (an arena allocation, not a comptime
/// static); the `[]const Segment` type is what render trees normally are, so
/// the cast is confined here. A malformed path or an out-of-range index is
/// ignored rather than fatal: this is cache bookkeeping, not rendering.
pub fn clearSlot(tree: []const Segment, path: []const u8) void {
    var indices: [16]usize = undefined;
    var len: usize = 0;
    var parts = std.mem.splitScalar(u8, path, '.');
    while (parts.next()) |part| {
        if (len == indices.len) return;
        indices[len] = std.fmt.parseInt(usize, part, 10) catch return;
        len += 1;
    }
    clearAt(@constCast(tree), indices[0..len]);
}

fn clearAt(nodes: []Segment, path: []const usize) void {
    if (path.len == 0) return;
    const i = path[0];
    if (i >= nodes.len) return;
    if (path.len == 1) {
        nodes[i] = .{ .children = &.{} };
        return;
    }
    switch (nodes[i]) {
        .children => |kids| clearAt(@constCast(kids), path[1..]),
        else => {},
    }
}

test "clearSlot empties the node at a dotted path, in place" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const leaf = try a.alloc(Segment, 2);
    leaf[0] = .text("<p>");
    leaf[1] = .{ .dynamic = .{ .string = "x" } };
    const region = try a.alloc(Segment, 3);
    region[0] = .text("<div>");
    region[1] = .{ .children = leaf };
    region[2] = .text("</div>");
    var root = [_]Segment{.{ .children = region }};

    clearSlot(&root, "0.1");
    try std.testing.expectEqualStrings(
        "<div></div>",
        try flattenHtml(a, &root),
    );

    // a second clear is a no-op, and so is junk: no crash, no change
    clearSlot(&root, "0.1");
    clearSlot(&root, "not-a-path");
    clearSlot(&root, "9.9.9");
    clearSlot(&root, "");
    try std.testing.expectEqualStrings("<div></div>", try flattenHtml(a, &root));
}
