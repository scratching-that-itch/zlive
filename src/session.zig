// Session state registry: parks a disconnected view's state under the
// client's session token for a TTL, so a reconnect (or a reload) restores
// the view instead of remounting it fresh.
//
// Generic machinery, not demo policy: the framework owns the storage and
// the expiry sweep, the app owns the payload type it stores per session.

const std = @import("std");

/// Reads wall-clock seconds. Injected so tests are deterministic and the
/// registry itself needs no I/O context.
pub const Clock = *const fn () i64;

/// A stored payload plus the time it went dormant. `T` is app-defined.
pub fn Entry(comptime T: type) type {
    return struct {
        value: T,
        disconnected_at: i64,
    };
}

/// Thread-safe token -> payload registry with TTL expiry.
///
/// `stash` parks state (replacing any existing entry for the token);
/// `restore` claims it and removes it either way, so a session is consumed
/// exactly once. Expired entries are swept on every operation.
pub fn Registry(comptime T: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        clock: Clock,
        /// How long a disconnected view's state is kept, in seconds.
        ttl_sec: i64,
        mutex: std.atomic.Mutex = .unlocked,
        map: std.StringHashMapUnmanaged(Entry(T)) = .empty,

        pub const Payload = T;
        pub const Stored = Entry(T);

        pub fn init(allocator: std.mem.Allocator, clock: Clock, ttl_sec: i64) Self {
            return .{ .allocator = allocator, .clock = clock, .ttl_sec = ttl_sec };
        }

        pub fn deinit(self: *Self) void {
            var it = self.map.keyIterator();
            while (it.next()) |key| self.allocator.free(key.*);
            self.map.deinit(self.allocator);
        }

        pub fn lock(self: *Self) void {
            while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
        }

        pub fn unlock(self: *Self) void {
            self.mutex.unlock();
        }

        /// Takes ownership of a disconnected view's state. The token is
        /// copied; an existing entry for the token is replaced.
        pub fn stash(self: *Self, token: []const u8, value: T) !void {
            self.lock();
            defer self.unlock();
            self.sweepLocked();
            const gop = try self.map.getOrPut(self.allocator, token);
            if (!gop.found_existing) {
                gop.key_ptr.* = try self.allocator.dupe(u8, token);
            }
            gop.value_ptr.* = .{ .value = value, .disconnected_at = self.clock() };
        }

        /// Claims the state stored for `token`, if it is still within the
        /// TTL. The entry is removed either way.
        pub fn restore(self: *Self, token: []const u8) ?T {
            self.lock();
            defer self.unlock();
            self.sweepLocked();
            const kv = self.map.fetchRemove(token) orelse return null;
            self.allocator.free(kv.key);
            return kv.value.value;
        }

        /// Drops every entry older than the TTL. Caller must hold the lock
        /// (public so apps can sweep from their own housekeeping path).
        pub fn sweepLocked(self: *Self) void {
            const ts = self.clock();
            var expired: std.ArrayListUnmanaged([]const u8) = .empty;
            defer expired.deinit(self.allocator);
            var it = self.map.iterator();
            while (it.next()) |e| {
                if (ts - e.value_ptr.disconnected_at > self.ttl_sec) {
                    expired.append(self.allocator, e.key_ptr.*) catch break;
                }
            }
            for (expired.items) |key| {
                _ = self.map.remove(key);
                self.allocator.free(key);
            }
        }

        /// Number of live entries (test/diagnostic helper).
        pub fn count(self: *Self) usize {
            self.lock();
            defer self.unlock();
            return self.map.count();
        }
    };
}

const testing = std.testing;

var fake_now: i64 = 0;

fn testClock() i64 {
    return fake_now;
}

fn TestRegistry() type {
    return Registry(i64);
}

test "registry round trip consumes the entry" {
    fake_now = 100;
    var reg = TestRegistry().init(testing.allocator, testClock, 300);
    defer reg.deinit();

    try reg.stash("tok", 7);
    try testing.expectEqual(@as(i64, 7), reg.restore("tok").?);
    try testing.expect(reg.restore("tok") == null);
}

test "registry entry expires after the ttl" {
    fake_now = 100;
    var reg = TestRegistry().init(testing.allocator, testClock, 10);
    defer reg.deinit();

    try reg.stash("tok", 1);
    fake_now = 111; // 11s later, past the 10s ttl
    try testing.expect(reg.restore("tok") == null);
    try testing.expectEqual(@as(usize, 0), reg.count());
}

test "restashing the same token replaces the entry" {
    fake_now = 100;
    var reg = TestRegistry().init(testing.allocator, testClock, 300);
    defer reg.deinit();

    try reg.stash("tok", 1);
    try reg.stash("tok", 2);
    try testing.expectEqual(@as(i64, 2), reg.restore("tok").?);
    try testing.expectEqual(@as(usize, 0), reg.count());
}

test "polling an unrelated token expires stale entries" {
    fake_now = 100;
    var reg = TestRegistry().init(testing.allocator, testClock, 10);
    defer reg.deinit();

    try reg.stash("old", 1);
    fake_now = 200;
    try testing.expect(reg.restore("other") == null);
    try testing.expectEqual(@as(usize, 0), reg.count());
}
