const std = @import("std");

/// Protocol version baked into every envelope. Bump when the envelope
/// shape changes incompatibly; decoders reject mismatched versions.
///
/// v2: dynamic strings in render trees and patches are tagged objects
/// (`{"s": ...}` / `{"html": ...}`) instead of plain strings, so the
/// client can tell them apart from statics (see view.nodeToValue).
pub const version: u32 = 2;

/// Discriminator for the kind of message an envelope carries.
/// Serialized as its name in JSON ("publish", "message", ...).
pub const Type = enum {
    /// client -> server: trigger an event on a topic
    publish,
    /// server -> client: an event fired on a topic
    message,
    /// keepalive; payload and ref are typically null
    heartbeat,
    /// response acknowledging a previously ref'd message
    ack,
    /// an error occurred processing a message
    err,
};

/// Every wire message is a JSON envelope with these fields:
///
///   { "version": 1, "type": "message", "topic": "chat",
///     "event": "said", "payload": {...}, "ref": 12 }
///
/// `payload` is an arbitrary JSON value (null when unused);
/// `ref` correlates request/response pairs (null when unused).
pub const Envelope = struct {
    version: u32 = version,
    type: Type,
    topic: []const u8,
    event: []const u8,
    payload: ?std.json.Value = null,
    ref: ?u64 = null,

    /// Serializes the envelope to a minified JSON string.
    /// Caller owns the returned memory.
    pub fn encode(self: Envelope, allocator: std.mem.Allocator) ![]u8 {
        return std.json.Stringify.valueAlloc(allocator, self, .{});
    }

    /// Parses an envelope. The returned value borrows from the input, so
    /// the caller must keep `data` alive and call `deinit()` on the result
    /// (typically via an arena allocator). JSON parse failures surface as
    /// `error.Malformed`; a foreign `version` as `error.UnsupportedVersion`.
    pub fn decode(
        allocator: std.mem.Allocator,
        data: []const u8,
    ) error{ UnsupportedVersion, Malformed, OutOfMemory }!std.json.Parsed(Envelope) {
        const parsed = std.json.parseFromSlice(Envelope, allocator, data, .{
            .ignore_unknown_fields = true,
        }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.Malformed,
        };
        if (parsed.value.version != version) {
            parsed.deinit();
            return error.UnsupportedVersion;
        }
        return parsed;
    }

    pub fn isHeartbeat(self: Envelope) bool {
        return self.type == .heartbeat;
    }
};

/// Builds a heartbeat envelope: `{"version":1,"type":"heartbeat",...,"event":"ping",...}`.
pub fn heartbeat(ref: ?u64) Envelope {
    return .{
        .type = .heartbeat,
        .topic = "system",
        .event = "ping",
        .ref = ref,
    };
}

test "heartbeat round trip" {
    const allocator = std.testing.allocator;

    const original = heartbeat(7);
    const json = try original.encode(allocator);
    defer allocator.free(json);

    try std.testing.expectEqualStrings(
        "{\"version\":2,\"type\":\"heartbeat\",\"topic\":\"system\",\"event\":\"ping\",\"payload\":null,\"ref\":7}",
        json,
    );

    var parsed = try Envelope.decode(allocator, json);
    defer parsed.deinit();

    try std.testing.expectEqual(version, parsed.value.version);
    try std.testing.expectEqual(Type.heartbeat, parsed.value.type);
    try std.testing.expectEqualStrings("system", parsed.value.topic);
    try std.testing.expectEqualStrings("ping", parsed.value.event);
    try std.testing.expect(parsed.value.payload == null);
    try std.testing.expectEqual(@as(?u64, 7), parsed.value.ref);
    try std.testing.expect(parsed.value.isHeartbeat());
}

test "message with object payload round trip" {
    const allocator = std.testing.allocator;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const original = Envelope{
        .type = .message,
        .topic = "chat",
        .event = "said",
        .payload = try std.json.parseFromSliceLeaky(
            std.json.Value,
            arena.allocator(),
            "{\"user\":\"kim\",\"lines\":[1,2,3]}",
            .{},
        ),
        .ref = null,
    };

    const json = try original.encode(allocator);
    defer allocator.free(json);

    var parsed = try Envelope.decode(allocator, json);
    defer parsed.deinit();

    // expectEqualDeep can't compare std.json.Value maps (it diffs internal
    // allocation pointers), so verify by stable re-encoding + field checks
    const reencoded = try parsed.value.encode(allocator);
    defer allocator.free(reencoded);
    try std.testing.expectEqualStrings(json, reencoded);

    const payload = parsed.value.payload.?.object;
    try std.testing.expectEqualStrings("kim", payload.get("user").?.string);
    try std.testing.expectEqual(@as(usize, 3), payload.get("lines").?.array.items.len);
}

test "publish with scalar payload and ref round trip" {
    const allocator = std.testing.allocator;

    const original = Envelope{
        .type = .publish,
        .topic = "game",
        .event = "move",
        .payload = .{ .integer = 42 },
        .ref = 900,
    };

    const json = try original.encode(allocator);
    defer allocator.free(json);

    var parsed = try Envelope.decode(allocator, json);
    defer parsed.deinit();

    try std.testing.expectEqualDeep(original, parsed.value);
}

test "ack round trip" {
    const allocator = std.testing.allocator;

    const original = Envelope{
        .type = .ack,
        .topic = "chat",
        .event = "said",
        .ref = 900,
    };

    const json = try original.encode(allocator);
    defer allocator.free(json);

    var parsed = try Envelope.decode(allocator, json);
    defer parsed.deinit();

    try std.testing.expectEqual(@as(?u64, 900), parsed.value.ref);
    try std.testing.expect(parsed.value.payload == null);
}

test "decode rejects unsupported version" {
    const allocator = std.testing.allocator;

    try std.testing.expectError(
        error.UnsupportedVersion,
        Envelope.decode(allocator, "{\"version\":99,\"type\":\"heartbeat\",\"topic\":\"\",\"event\":\"\"}"),
    );
}

test "decode rejects malformed json" {
    const allocator = std.testing.allocator;

    try std.testing.expectError(error.Malformed, Envelope.decode(allocator, "not json"));
    try std.testing.expectError(error.Malformed, Envelope.decode(allocator, "{\"version\":2}"));
}
