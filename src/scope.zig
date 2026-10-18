// Scoped server-side state.
//
// zlive's state model has three lifetimes, and this module owns two of them:
//
//   session  one connection          — the handler's own `Slots(capacity)`,
//                                      created on mount, freed on close.
//                                      Layout/render state lives here.
//   group    a set of connections    — keyed by an app-chosen id ("room:42",
//                                      a tenant, a dashboard). Created on the
//                                      first join, parked for `ttl_sec` once
//                                      the last member leaves, freed by the
//                                      sweep. Shared truth for that set.
//   global   the whole process       — one cell set for every session, freed
//                                      at shutdown.
//
// What makes "shared between a set of sessions" work is the notification
// half: a group or global value changing is only useful if the *other*
// members are re-rendered and patched. The store therefore tracks live
// sessions and their group membership, and `notifyGroup` / `notifyAll`
// flush them — which is why a Handler must declare:
//
//     pub fn flush(self: *Handler) void
//
// "re-render whatever this session is showing and write the patch". For a
// view, `flush` is its `pushUpdate` minus the event plumbing (see
// zlive-examples' `handler.zig` and `views/room.zig`).
//
// Locking: every notify call takes the app lock (when the app declares
// `lock`/`unlock`, as `notify.Queue` does) and holds it for the whole loop,
// so a member cannot close and have its state freed mid-flush. `flush`
// therefore runs *with the app lock already held* — either make the lock
// recursive (the demo does; see `App.lock` in zlive-examples) or give the
// handler a separate `flushLocked` that assumes it.
//
// The store itself is not internally locked for the simple state calls:
// `attach`/`join`/`leave`/`groupCells`/`globalCells` are meant to be called
// from a session's own handler (held under the app lock, as the demo does)
// or from a single-threaded app.

const std = @import("std");
const service = @import("service.zig");

/// `Slots` is the same type-erased cell set that holds one connection's view
/// state; a group is just another cell set, so the store reuses it verbatim.
pub const Clock = *const fn () i64;

pub fn Store(comptime App: type, comptime cells_per_group: usize) type {
    if (!@hasDecl(App, "WebsocketHandler"))
        @compileError(@typeName(App) ++ " must declare `pub const WebsocketHandler` to use Store");
    const Handler = App.WebsocketHandler;
    if (!@hasDecl(Handler, "flush"))
        @compileError(@typeName(Handler) ++ " must declare `pub fn flush(self: *Handler) void` to use Store");

    return struct {
        const Self = @This();

        pub const Cells = service.Slots(cells_per_group);
        pub const Handler_ = Handler;

        const Group = struct {
            cells: Cells,
            members: std.ArrayListUnmanaged(*Handler) = .empty,
            /// Non-null once the last member left: when the sweep may free
            /// this group. Cleared when someone joins again.
            parked_at: ?i64 = null,
        };

        allocator: std.mem.Allocator,
        /// The app this store belongs to, for its lock. Borrowed: the app is
        /// built in place and must not move (the framework's lifetime rule).
        app: *App,
        clock: Clock,
        ttl_sec: i64,
        /// The process-wide scope.
        global_cells: Cells,
        groups: std.StringHashMapUnmanaged(Group) = .empty,
        /// Every attached session, for `notifyAll`. Membership in a group is
        /// tracked on the group, not here.
        sessions: std.ArrayListUnmanaged(*Handler) = .empty,

        /// `app` is the address the app will live at (build it in place).
        pub fn init(app: *App, allocator: std.mem.Allocator, clock: Clock, ttl_sec: i64) Self {
            return .{
                .allocator = allocator,
                .app = app,
                .clock = clock,
                .ttl_sec = ttl_sec,
                .global_cells = Cells.init(allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            var it = self.groups.iterator();
            while (it.next()) |entry| {
                entry.value_ptr.cells.deinit();
                entry.value_ptr.members.deinit(self.allocator);
                self.allocator.free(entry.key_ptr.*);
            }
            self.groups.deinit(self.allocator);
            self.sessions.deinit(self.allocator);
            self.global_cells.deinit();
        }

        // -------------------------------------------------------------
        // The process-wide scope
        // -------------------------------------------------------------

        /// The global cell set: `getOrCreate` named values on it. Every
        /// session sees the same cells.
        pub fn global(self: *Self) *Cells {
            return &self.global_cells;
        }

        // -------------------------------------------------------------
        // Sessions
        // -------------------------------------------------------------

        /// Registers a session so `notifyAll` can reach it. Call once, when
        /// the view mounts; `join` does it too.
        pub fn attach(self: *Self, h: *Handler) !void {
            if (self.indexOfSession(h) != null) return;
            try self.sessions.append(self.allocator, h);
        }

        /// The session's group, or null when it is not in one.
        pub fn groupOf(self: *Self, h: *Handler) ?[]const u8 {
            var it = self.groups.iterator();
            while (it.next()) |entry| {
                for (entry.value_ptr.members.items) |member| {
                    if (member == h) return entry.key_ptr.*;
                }
            }
            return null;
        }

        /// Joins `group`, leaving any previous one. Creates the group (or
        /// un-parks it) and returns its cells.
        ///
        /// Pure: it notifies nobody. Membership changes that other members
        /// can see (a mount, a close) notify explicitly — `detach` does it
        /// for a close, a mounting view calls `notifyGroup` itself — because
        /// `join` is also reached lazily from inside a render, and
        /// notification must not run there.
        pub fn join(self: *Self, h: *Handler, group: []const u8) !*Cells {
            try self.attach(h);
            if (self.groupOf(h)) |current| {
                if (std.mem.eql(u8, current, group)) return self.groupCells(group).?;
                self.leave(h);
            }
            self.sweep();

            const entry = try self.groups.getOrPut(self.allocator, group);
            if (!entry.found_existing) {
                entry.key_ptr.* = try self.allocator.dupe(u8, group);
                entry.value_ptr.* = .{ .cells = Cells.init(self.allocator) };
            }
            const g = entry.value_ptr;
            g.parked_at = null;
            try g.members.append(self.allocator, h);
            return &g.cells;
        }

        /// Drops the session's group membership. When it was the last
        /// member the group is parked (its state survives until the sweep),
        /// so a reconnect can rejoin and find it intact. Safe on a session
        /// that never joined.
        pub fn leave(self: *Self, h: *Handler) void {
            const group = self.groupOf(h) orelse return;
            const g = self.groups.getPtr(group) orelse return;
            for (g.members.items, 0..) |member, i| {
                if (member != h) continue;
                _ = g.members.swapRemove(i);
                break;
            }
            if (g.members.items.len == 0) g.parked_at = self.clock();
        }

        /// Detaches a closing session: leaves its group and stops being a
        /// notification target. Call from the handler's `close`.
        ///
        /// The remaining members render a member count, so they are notified
        /// — this is why `detach` must be called while the app lock is held
        /// (the notify loop runs under it).
        pub fn detach(self: *Self, h: *Handler) void {
            const group = self.groupOf(h);
            self.leave(h);
            if (self.indexOfSession(h)) |i| _ = self.sessions.swapRemove(i);
            if (group) |g| {
                if (self.members(g).len > 0) self.notifyGroup(g, null);
            }
        }

        /// Frees groups whose last member left more than `ttl_sec` ago.
        /// Called on every join; expose it for an app ticker if you want
        /// parked state to disappear on time rather than on next join.
        pub fn sweep(self: *Self) void {
            const now = self.clock();
            var doomed: [16][]const u8 = undefined;
            var n: usize = 0;
            var it = self.groups.iterator();
            while (it.next()) |entry| {
                const parked_at = entry.value_ptr.parked_at orelse continue;
                if (now - parked_at < self.ttl_sec) continue;
                if (n == doomed.len) break;
                doomed[n] = entry.key_ptr.*;
                n += 1;
            }
            for (doomed[0..n]) |key| {
                if (self.groups.fetchRemove(key)) |kv| {
                    var group = kv.value;
                    group.cells.deinit();
                    group.members.deinit(self.allocator);
                    self.allocator.free(kv.key);
                }
            }
        }

        // -------------------------------------------------------------
        // Group state and membership
        // -------------------------------------------------------------

        /// The group's cells, or null when no such group exists (never
        /// joined, or swept).
        pub fn groupCells(self: *Self, group: []const u8) ?*Cells {
            const g = self.groups.getPtr(group) orelse return null;
            return &g.cells;
        }

        /// The live members of `group`. The slice is valid until the next
        /// join/leave; read it under the app lock.
        pub fn members(self: *Self, group: []const u8) []const *Handler {
            const g = self.groups.getPtr(group) orelse return &.{};
            return g.members.items;
        }

        pub fn sessionCount(self: *Self) usize {
            return self.sessions.items.len;
        }

        pub fn groupCount(self: *Self) usize {
            return self.groups.count();
        }

        // -------------------------------------------------------------
        // Notification
        // -------------------------------------------------------------

        /// Re-renders and patches every member of `group` except `except`
        /// (normally the session that made the change, which pushes its own
        /// patch in its event handler).
        ///
        /// Holds the app lock across the whole loop, so a member cannot
        /// close and have its state freed mid-flush.
        pub fn notifyGroup(self: *Self, group: []const u8, except: ?*Handler) void {
            self.lock();
            defer self.unlock();
            for (self.members(group)) |member| {
                if (except != null and member == except.?) continue;
                member.flush();
            }
        }

        /// The same for a global value: every attached session.
        pub fn notifyAll(self: *Self, except: ?*Handler) void {
            self.lock();
            defer self.unlock();
            for (self.sessions.items) |member| {
                if (except != null and member == except.?) continue;
                member.flush();
            }
        }

        fn lock(self: *Self) void {
            if (comptime std.meta.hasFn(App, "lock")) self.app.lock();
        }

        fn unlock(self: *Self) void {
            if (comptime std.meta.hasFn(App, "unlock")) self.app.unlock();
        }

        fn indexOfSession(self: *Self, h: *Handler) ?usize {
            for (self.sessions.items, 0..) |member, i| {
                if (member == h) return i;
            }
            return null;
        }
    };
}

// ---------------------------------------------------------------------
// Tests: a fake app and handler, so the scoping rules are verified
// without a socket. `flush` counts calls, which is how notification is
// asserted.
// ---------------------------------------------------------------------

const testing = std.testing;

var test_now: i64 = 1000;
fn testClock() i64 {
    return test_now;
}

const FakeHandler = struct {
    flushes: usize = 0,

    pub fn flush(self: *FakeHandler) void {
        self.flushes += 1;
    }
};

const FakeApp = struct {
    pub const WebsocketHandler = FakeHandler;
};

const TestStore = Store(FakeApp, 4);

/// Cell types must declare `deinit` (the Slots contract): a replaced or
/// freed cell is deinited first.
const Count = struct {
    n: i64 = 0,

    pub fn deinit(_: *Count) void {}
};

fn testCreate(_: std.mem.Allocator) Count {
    return .{};
}

test "global cells are shared by every session" {
    var store = TestStore.init(undefined, testing.allocator, testClock, 60);
    defer store.deinit();

    const a = try store.global().getOrCreate("total", Count, testCreate);
    const b = try store.global().getOrCreate("total", Count, testCreate);
    try testing.expectEqual(a, b);
    a.n = 7;
    try testing.expectEqual(@as(i64, 7), b.n);
}

test "a group's cells are per group, and members are tracked" {
    var store = TestStore.init(undefined, testing.allocator, testClock, 60);
    defer store.deinit();

    var h1 = FakeHandler{};
    var h2 = FakeHandler{};
    var h3 = FakeHandler{};

    const room = try store.join(&h1, "room:1");
    const same = try store.join(&h2, "room:1");
    const other = try store.join(&h3, "room:2");
    try testing.expectEqual(room, same);
    try testing.expect(room != other);
    try testing.expectEqual(@as(usize, 2), store.members("room:1").len);
    try testing.expectEqualStrings("room:1", store.groupOf(&h1).?);

    // state written through one member's handle is what the other sees
    const count = try room.getOrCreate("count", Count, testCreate);
    count.n += 1;
    try testing.expectEqual(@as(i64, 1), (try same.getOrCreate("count", Count, testCreate)).n);
    try testing.expectEqual(@as(i64, 0), (try other.getOrCreate("count", Count, testCreate)).n);
    try testing.expectEqual(@as(usize, 2), store.groupCount());
    try testing.expectEqual(@as(usize, 3), store.sessionCount());
}

test "notifyGroup flushes the other members, not the originator" {
    var store = TestStore.init(undefined, testing.allocator, testClock, 60);
    defer store.deinit();

    var h1 = FakeHandler{};
    var h2 = FakeHandler{};
    var outsider = FakeHandler{};
    _ = try store.join(&h1, "room:1");
    _ = try store.join(&h2, "room:1");
    _ = try store.join(&outsider, "room:2");

    store.notifyGroup("room:1", &h1);
    try testing.expectEqual(@as(usize, 0), h1.flushes); // originator pushes its own
    try testing.expectEqual(@as(usize, 1), h2.flushes);
    try testing.expectEqual(@as(usize, 0), outsider.flushes);

    store.notifyAll(null);
    try testing.expectEqual(@as(usize, 1), h1.flushes);
    try testing.expectEqual(@as(usize, 2), h2.flushes);
    try testing.expectEqual(@as(usize, 1), outsider.flushes);
}

test "leaving the last member parks the group, and a rejoin finds it intact" {
    var store = TestStore.init(undefined, testing.allocator, testClock, 60);
    defer store.deinit();

    var h1 = FakeHandler{};
    const room = try store.join(&h1, "room:1");
    (try room.getOrCreate("count", Count, testCreate)).n = 42;

    store.leave(&h1);
    try testing.expectEqual(@as(usize, 1), store.groupCount()); // parked, not freed
    try testing.expectEqual(@as(usize, 0), store.members("room:1").len);
    try testing.expect((try store.groupCells("room:1").?.getOrCreate("count", Count, testCreate)).n == 42);

    // inside the TTL: same state, same membership list
    var h2 = FakeHandler{};
    const rejoined = try store.join(&h2, "room:1");
    try testing.expectEqual(@as(i64, 42), (try rejoined.getOrCreate("count", Count, testCreate)).n);
    try testing.expectEqual(@as(usize, 1), store.members("room:1").len);
    try testing.expectEqualStrings("room:1", store.groupOf(&h2).?);
}

test "sweep frees a parked group once the TTL passes" {
    var store = TestStore.init(undefined, testing.allocator, testClock, 10);
    defer store.deinit();

    var h1 = FakeHandler{};
    const room = try store.join(&h1, "room:1");
    (try room.getOrCreate("count", Count, testCreate)).n = 42;
    store.leave(&h1);

    test_now += 9;
    store.sweep();
    try testing.expectEqual(@as(usize, 1), store.groupCount()); // still inside the TTL

    test_now += 2;
    store.sweep();
    try testing.expectEqual(@as(usize, 0), store.groupCount());

    // a fresh join starts from defaults
    var h2 = FakeHandler{};
    const fresh = try store.join(&h2, "room:1");
    try testing.expectEqual(@as(i64, 0), (try fresh.getOrCreate("count", Count, testCreate)).n);
}

test "joining another group leaves the first, parking it if it empties" {
    var store = TestStore.init(undefined, testing.allocator, testClock, 60);
    defer store.deinit();

    var h1 = FakeHandler{};
    var h2 = FakeHandler{};
    _ = try store.join(&h1, "room:1");
    _ = try store.join(&h2, "room:1");
    _ = try store.join(&h1, "room:2"); // h1 moves
    try testing.expectEqual(@as(usize, 1), store.members("room:1").len);
    try testing.expectEqualStrings("room:2", store.groupOf(&h1).?);

    _ = try store.join(&h2, "room:2"); // and now room:1 has no members
    try testing.expectEqual(@as(usize, 0), store.members("room:1").len);
    try testing.expectEqual(@as(usize, 2), store.members("room:2").len);
    // room:1 is empty but parked, not gone: it survives until the sweep
    try testing.expectEqual(@as(usize, 2), store.groupCount());
}

test "detach unsubscribes a closing session from notifications" {
    var store = TestStore.init(undefined, testing.allocator, testClock, 60);
    defer store.deinit();

    var h1 = FakeHandler{};
    var h2 = FakeHandler{};
    _ = try store.join(&h1, "room:1");
    _ = try store.join(&h2, "room:1");

    store.detach(&h1);
    try testing.expectEqual(@as(usize, 1), store.sessionCount());
    try testing.expectEqual(@as(usize, 1), store.members("room:1").len);
    try testing.expect(store.groupOf(&h1) == null);
    // the member that stayed is told, because it renders a member count
    try testing.expectEqual(@as(usize, 1), h2.flushes);

    store.notifyAll(null);
    try testing.expectEqual(@as(usize, 0), h1.flushes); // no longer a target
    try testing.expectEqual(@as(usize, 2), h2.flushes);
}

test "detach on a session that stayed alone in its group notifies nobody" {
    var store = TestStore.init(undefined, testing.allocator, testClock, 60);
    defer store.deinit();

    var h1 = FakeHandler{};
    _ = try store.join(&h1, "room:1");
    store.detach(&h1);
    try testing.expectEqual(@as(usize, 0), h1.flushes);
    try testing.expectEqual(@as(usize, 0), store.sessionCount());
    try testing.expectEqual(@as(usize, 1), store.groupCount()); // parked
}

test "a full cell set reports the capacity error instead of corrupting" {
    var store = TestStore.init(undefined, testing.allocator, testClock, 60);
    defer store.deinit();

    var h1 = FakeHandler{};
    const room = try store.join(&h1, "room:1");
    _ = try room.getOrCreate("a", Count, testCreate);
    _ = try room.getOrCreate("b", Count, testCreate);
    _ = try room.getOrCreate("c", Count, testCreate);
    _ = try room.getOrCreate("d", Count, testCreate);
    try testing.expectError(error.SlotCapacityExceeded, room.getOrCreate("e", Count, testCreate));
}
