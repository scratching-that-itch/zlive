// Small shared helpers: HTML escaping and JSON payload readers.

const std = @import("std");

pub fn escapeHtml(a: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    for (s) |c| {
        switch (c) {
            '&' => try out.appendSlice(a, "&amp;"),
            '<' => try out.appendSlice(a, "&lt;"),
            '>' => try out.appendSlice(a, "&gt;"),
            '"' => try out.appendSlice(a, "&quot;"),
            '\'' => try out.appendSlice(a, "&#39;"),
            else => try out.append(a, c),
        }
    }
    return out.toOwnedSlice(a);
}

pub fn payloadString(payload: ?std.json.Value, key: []const u8) ?[]const u8 {
    const p = payload orelse return null;
    if (p != .object) return null;
    const v = p.object.get(key) orelse return null;
    if (v != .string) return null;
    return v.string;
}

pub fn payloadInt(payload: ?std.json.Value, key: []const u8) ?i64 {
    const p = payload orelse return null;
    if (p != .object) return null;
    const v = p.object.get(key) orelse return null;
    if (v != .integer) return null;
    return v.integer;
}

pub fn payloadIntLenient(payload: ?std.json.Value, key: []const u8) ?i64 {
    const p = payload orelse return null;
    if (p != .object) return null;
    const v = p.object.get(key) orelse return null;
    return switch (v) {
        .integer => |i| i,
        .string => |s| std.fmt.parseInt(i64, s, 10) catch null,
        else => null,
    };
}

pub fn sessionToken(payload: ?std.json.Value) ?[]const u8 {
    const p = payload orelse return null;
    if (p != .object) return null;
    const v = p.object.get("session") orelse return null;
    if (v != .string) return null;
    return v.string;
}
