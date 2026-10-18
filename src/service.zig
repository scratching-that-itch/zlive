// Per-connection service: the transport half of a WebSocket session.
//
// It owns envelope decode/encode, the app-level message-size cap, the
// session token, and the reply helpers — everything that is the same for
// every app. An app's handler embeds one (as `service`) and adds its own
// view-state slots; the framework's socket route drives it through
// `clientMessage`/`close`, so those stay thin forwarders in the app.

const std = @import("std");
const httpz = @import("httpz");
const protocol = @import("protocol.zig");
const session = @import("session.zig");
const util = @import("util.zig");

pub const Conn = httpz.websocket.Conn;

/// Application-level cap for a single message; the websocket transport
/// enforces its own (larger) cap before a handler ever sees a message.
pub const max_envelope_size = 4 * 1024;

/// Typed, per-connection state slots — the "slot registry".
///
/// The framework never knows what an app stores per view: a slot is a
/// comptime-typed cell addressed by a string key, holding exactly one
/// value, created on first use and `deinit`ed once when the connection
/// closes. Lookups are linear, which is right for the handful of views a
/// connection mounts.
///
///     var slots = zlive.Service.Slots(8){ .allocator = allocator };
///     defer slots.deinit();
///     const s = try slots.getOrCreate("counter", CounterState, CounterState.init);
pub fn Slots(comptime capacity: usize) type {
    return struct {
        const Self = @This();

        /// One type-erased cell. `state` points at a `Key`-typed value;
        /// `destroy` is monomorphized per key type and frees it.
        const Slot = struct {
            key: []const u8,
            state: *anyopaque,
            destroy: *const fn (allocator: std.mem.Allocator, ptr: *anyopaque) void,

            fn deinit(self: *const Slot, allocator: std.mem.Allocator) void {
                self.destroy(allocator, self.state);
            }
        };

        allocator: std.mem.Allocator,
        entries: [capacity]?Slot = @splat(null),
        len: usize = 0,

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .allocator = allocator };
        }

        pub fn deinit(self: *Self) void {
            for (self.entries[0..self.len]) |*maybe| {
                if (maybe.*) |*slot| slot.deinit(self.allocator);
                maybe.* = null;
            }
            self.len = 0;
        }

        /// The state stored for `key`, or null when the view is not mounted.
        /// The key type is a comptime argument, so this is fully typed at
        /// the call site despite the erased storage.
        pub fn get(self: *Self, key: []const u8, comptime Key: type) ?*Key {
            for (self.entries[0..self.len]) |maybe| {
                const slot = maybe orelse continue;
                if (std.mem.eql(u8, slot.key, key)) return @ptrCast(@alignCast(slot.state));
            }
            return null;
        }

        /// Stores `value` for `key`, replacing and deiniting any previous
        /// value. The key string is borrowed and must outlive the slot
        /// (call sites pass literals).
        pub fn put(self: *Self, comptime Key: type, key: []const u8, value: Key) !*Key {
            if (self.get(key, Key)) |existing| {
                existing.deinit();
                existing.* = value;
                return existing;
            }
            const ptr = try self.allocator.create(Key);
            errdefer self.allocator.destroy(ptr);
            ptr.* = value;
            if (self.len == capacity) return error.SlotCapacityExceeded;
            self.entries[self.len] = .{
                .key = key,
                .state = ptr,
                .destroy = struct {
                    fn destroy(allocator: std.mem.Allocator, erased: *anyopaque) void {
                        const typed: *Key = @ptrCast(@alignCast(erased));
                        typed.deinit();
                        allocator.destroy(typed);
                    }
                }.destroy,
            };
            self.len += 1;
            return ptr;
        }

        /// Returns the existing slot for `key`, or creates one from
        /// `create` (called with the slot allocator) on first use.
        ///
        /// `create` must build a *complete* value: whatever the app needs
        /// (a connection, a back-pointer to its context) has to arrive
        /// through `ctx`, because a half-initialized state stored here is
        /// exactly the kind of value that corrupts on teardown.
        pub fn getOrCreate(
            self: *Self,
            key: []const u8,
            comptime Key: type,
            comptime create: *const fn (std.mem.Allocator) Key,
        ) !*Key {
            if (self.get(key, Key)) |existing| return existing;
            return self.put(Key, key, create(self.allocator));
        }

        /// `getOrCreate` with a runtime factory: `create(ctx, allocator)`
        /// so the caller can pass per-connection data (a connection, an app
        /// pointer) that is not comptime-known. `ctx` need only outlive the
        /// call.
        pub fn getOrCreateWith(
            self: *Self,
            key: []const u8,
            comptime Key: type,
            ctx: *anyopaque,
            create: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator) Key,
        ) !*Key {
            if (self.get(key, Key)) |existing| return existing;
            return self.put(Key, key, create(ctx, self.allocator));
        }

        /// Removes `key`'s slot, deiniting its state immediately. Used by
        /// flows that park state in a session registry and drop the
        /// in-connection copy (view remount).
        pub fn remove(self: *Self, key: []const u8) void {
            var i: usize = 0;
            while (i < self.len) : (i += 1) {
                const slot = self.entries[i] orelse continue;
                if (!std.mem.eql(u8, slot.key, key)) continue;
                slot.deinit(self.allocator);
                self.entries[i] = self.entries[self.len - 1];
                self.entries[self.len - 1] = null;
                self.len -= 1;
                return;
            }
        }
    };
}

/// The transport half of one WebSocket connection, generic over the app
/// type (the `ctx` passed to `httpz.upgradeWebsocket`).
pub fn Service(comptime App: type) type {
    return struct {
        const Self = @This();

        conn: *Conn,
        app: *App,
        /// Long-lived copy of the session token from the connection's join;
        /// the per-message arena the payload lived in is gone after
        /// `dispatch` returns.
        token: ?[]const u8 = null,

        pub fn init(conn: *Conn, app: *App) Self {
            return .{ .conn = conn, .app = app };
        }

        /// Decodes one wire message, enforces the size cap, and hands the
        /// envelope to the app's dispatcher. Protocol-level failures are
        /// answered here so every app gets the same error taxonomy.
        ///
        /// The app's dispatcher is any value with a method
        /// `dispatch(aa, env) !void` — in practice the app's handler.
        pub fn clientMessage(self: *Self, dispatcher: anytype, aa: std.mem.Allocator, data: []const u8) !void {
            if (data.len > max_envelope_size) {
                return self.sendParseError(aa, data, "message_too_large", "message_too_large");
            }

            var parsed = protocol.Envelope.decode(aa, data) catch |err| switch (err) {
                error.UnsupportedVersion => return self.sendParseError(aa, data, "version_mismatch", "version_mismatch"),
                error.Malformed => return self.sendParseError(aa, data, "malformed", "malformed"),
                error.OutOfMemory => return error.OutOfMemory,
            };
            defer parsed.deinit();

            try dispatcher.dispatch(aa, &parsed.value);
        }

        pub fn send(self: *Self, aa: std.mem.Allocator, env: protocol.Envelope) !void {
            const json = try env.encode(aa);
            try self.conn.write(json);
        }

        pub fn sendErr(self: *Self, aa: std.mem.Allocator, env: *const protocol.Envelope, reason: []const u8) !void {
            var obj: std.json.ObjectMap = .empty;
            try obj.put(aa, "reason", .{ .string = reason });
            try self.send(aa, .{
                .type = .err,
                .topic = env.topic,
                .event = env.event,
                .payload = .{ .object = obj },
                .ref = env.ref,
            });
        }

        /// Adopts the session token carried by a join, replacing any
        /// previous one (which is freed).
        pub fn adoptToken(self: *Self, token: []const u8) !void {
            if (self.token) |current| {
                if (std.mem.eql(u8, current, token)) return;
                self.app.allocator.free(current);
            }
            self.token = try self.app.allocator.dupe(u8, token);
        }

        pub fn deinit(self: *Self) void {
            if (self.token) |t| {
                self.app.allocator.free(t);
                self.token = null;
            }
        }

        /// Replies to a message we could not decode (malformed, oversized,
        /// or a foreign protocol version). The failed message cannot be
        /// trusted, so topic/event/ref are best-effort extractions; for
        /// version mismatches the claimed version is included.
        pub fn sendParseError(
            self: *Self,
            aa: std.mem.Allocator,
            data: []const u8,
            event: []const u8,
            reason: []const u8,
        ) !void {
            std.log.scoped(.zlive).warn("{s}: {s}", .{ reason, data[0..@min(data.len, 64)] });
            var obj: std.json.ObjectMap = .empty;
            try obj.put(aa, "reason", .{ .string = reason });

            var topic: []const u8 = "system";
            var ref: ?u64 = null;
            if (std.json.parseFromSliceLeaky(std.json.Value, aa, data, .{})) |value| {
                if (value == .object) {
                    const o = value.object;
                    if (o.get("version")) |v| {
                        if (v == .integer) try obj.put(aa, "version", v);
                    }
                    if (o.get("topic")) |t| {
                        if (t == .string) topic = t.string;
                    }
                    if (o.get("ref")) |r| {
                        if (r == .integer and r.integer >= 0) ref = @intCast(r.integer);
                    }
                }
            } else |_| {}

            try self.send(aa, .{
                .type = .err,
                .topic = topic,
                .event = event,
                .payload = .{ .object = obj },
                .ref = ref,
            });
        }

        /// The session token carried by a join payload: `{"session": "..."}`.
        pub fn sessionToken(payload: ?std.json.Value) ?[]const u8 {
            return util.sessionToken(payload);
        }

        /// Convenience: is `token` the session this connection adopted?
        pub fn hasToken(self: *const Self, token: []const u8) bool {
            const current = self.token orelse return false;
            return std.mem.eql(u8, current, token);
        }
    };
}

/// App-side registry types are re-exported here so apps can name them
/// through the service module if they prefer.
pub const Registry = session.Registry;

const testing = std.testing;

const DummyApp = struct {
    allocator: std.mem.Allocator,
};

const CounterState = struct {
    count: i64 = 0,
    inited: bool = false,

    pub fn init(_: std.mem.Allocator) CounterState {
        return .{ .inited = true };
    }

    pub fn deinit(self: *CounterState) void {
        self.inited = false;
    }
};

const OtherState = struct {
    label: []const u8,

    pub fn init(_: std.mem.Allocator) OtherState {
        return .{ .label = "" };
    }

    pub fn deinit(_: *OtherState) void {}
};

test "slots create, fetch and replace typed state" {
    var slots = Slots(4).init(testing.allocator);
    defer slots.deinit();

    const counter = try slots.getOrCreate("counter", CounterState, CounterState.init);
    try testing.expect(counter.inited);
    counter.count = 41;
    try testing.expectEqual(@as(i64, 41), slots.get("counter", CounterState).?.count);
    try testing.expect(slots.get("other", CounterState) == null);

    // getOrCreate returns the same instance rather than re-creating
    const again = try slots.getOrCreate("counter", CounterState, CounterState.init);
    try testing.expectEqual(@as(i64, 41), again.count);

    // a different key type coexists in the same registry
    _ = try slots.getOrCreate("other", OtherState, OtherState.init);
    try testing.expect(slots.get("other", OtherState) != null);
}

test "slots put replaces in place and remove drops the slot" {
    var slots = Slots(4).init(testing.allocator);
    defer slots.deinit();

    _ = try slots.put(CounterState, "s", .{ .count = 1, .inited = true });
    _ = try slots.put(CounterState, "s", .{ .count = 2, .inited = true });
    try testing.expectEqual(@as(i64, 2), slots.get("s", CounterState).?.count);

    slots.remove("s");
    try testing.expect(slots.get("s", CounterState) == null);
}

test "slots reject overflow past capacity" {
    var slots = Slots(1).init(testing.allocator);
    defer slots.deinit();

    _ = try slots.put(CounterState, "a", .{ .inited = true });
    try testing.expectError(
        error.SlotCapacityExceeded,
        slots.put(CounterState, "b", .{ .inited = true }),
    );
}
