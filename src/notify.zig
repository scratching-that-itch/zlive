// Server-side auto-dismiss for a *queue* of notifications.
//
// The inline banner and the corner toast stack are the same thing at
// different capacities: a list of messages, each with its own deadline.
// `Queue(App, Props, 1)` is the banner, `Queue(App, Props, 3)` is the
// stack. What the framework owns is the timing and the lifetime of the
// messages; what the app owns is what they look like and where they sit.
//
// The important difference from a timer that patches the socket itself:
// **expiry is a state change, not a patch**. The reaper removes the item
// and then calls
//
//     pub fn flush(self: *Handler) void
//
// ("re-render whatever this session is showing and write the patch"), so
// the patch for an expiring toast is computed by the ordinary render +
// `view.diff` path. Nothing in the app needs to know which slot a message
// lives in, how many siblings it has, or which generation it belongs to —
// and a cached tree cannot go stale behind the view's back, because the
// reaper goes through the same render the view does. That is the contract
// `zlive.http.Store` already uses for group and global changes.
//
// Lifetime. The reaper never touches the connection's slot storage: the
// queue's state lives in a separate reference-counted `Inner`, the cell in
// the slot registry holds one reference, the reaper holds another, and
// teardown only *disarms*. A sleeping reaper therefore wakes to
// `alive == false`, drops its reference and frees the state it was holding
// — it cannot read memory the connection already released.
//
// Locking. Every public entry point takes the app lock (which is why `App`
// must declare `lock`/`unlock`), and the reaper holds it across `flush`, so
// `flush` must tolerate being called with the lock held: make the lock
// recursive (the demo does) or give the handler a `flushLocked`. Same rule
// as `zlive.http.Store`.
//
// Live only when an app uses it; no other path spawns threads.

const std = @import("std");

/// Milliseconds. The queue only ever subtracts two readings, so any fixed
/// origin works.
pub const Clock = *const fn () i64;

/// How often the reaper wakes to look for due items, in milliseconds.
/// Expiry is therefore accurate to this, which is far below what a toast
/// needs; the point of a fixed tick is that a `show` from any thread is
/// picked up without a cross-thread wakeup protocol.
pub const tick_ms: u64 = 100;

/// Live reaper threads, process-wide. A reaper is *detached* on purpose — a
/// connection must never block on one, and a reaper blocked writing to a
/// dead socket must not hold up a close — so it cannot be joined. This
/// counter is the join-in-spirit: the framework knows how many are running,
/// and an app waits for them at shutdown (`waitIdle`) instead of exiting
/// with a queue's state still allocated.
var reapers: std.atomic.Value(usize) = .init(0);

/// Are all reapers stopped?
pub fn idle() bool {
    return reapers.load(.acquire) == 0;
}

/// Waits (up to `timeout_ms`) for every reaper to exit, and returns whether
/// they all did.
///
/// Call this from the app's shutdown: a reaper holds its queue's state until
/// its next tick (at most `tick_ms`), and a process that exits first reports
/// that state — and the messages still queued in it — as leaked. It returns
/// immediately when no queue is being served, which is the common case.
pub fn waitIdle(timeout_ms: u64) bool {
    var waited: u64 = 0;
    while (!idle()) {
        if (waited >= timeout_ms) return false;
        sleepMs(2);
        waited += 2;
    }
    return true;
}

/// A per-connection queue of notifiable messages, at most `cap` at once.
///
///     const Queue = zlive.http.Queue;
///     pub const Banners = Queue(App, view.Flash.Props, 1);
///     pub const Toasts  = Queue(App, view.Toast.Props, 3);
///
///     const q = try h.toasts();            // slot-registry lookup
///     const id = try q.show(.{ .message = "Saved" }, 3000);
///     _ = q.dismiss(id);                   // the close button
///
/// `Props` may carry any fields; its string fields (`[]const u8` and
/// `?[]const u8`) are what the queue *owns*: `show` copies them and the
/// queue frees them when the item goes away, so callers pass borrowed
/// slices (a request arena, a literal) and never free anything.
pub fn Queue(comptime App: type, comptime Props: type, comptime cap: usize) type {
    if (cap == 0)
        @compileError("Queue capacity must be at least 1");
    if (!@hasDecl(App, "WebsocketHandler"))
        @compileError(@typeName(App) ++ " must declare `pub const WebsocketHandler` to use Queue");
    const Handler = App.WebsocketHandler;
    if (!@hasDecl(Handler, "flush"))
        @compileError(@typeName(Handler) ++ " must declare `pub fn flush(self: *Handler) void` to use Queue: " ++
            "the reaper re-renders the connection's view through it");
    if (!std.meta.hasFn(App, "lock") or !std.meta.hasFn(App, "unlock"))
        @compileError(@typeName(App) ++ " must declare `lock`/`unlock` to use Queue: the reaper, " ++
            "`flush` and teardown are serialized by the app lock");

    return struct {
        const Self = @This();

        /// One queued message. `props` is owned by the queue; `deadline_ms`
        /// is on the queue's clock.
        pub const Item = struct {
            id: u64,
            props: Props,
            deadline_ms: i64,
        };

        /// The refcounted half of the queue. Deliberately a separate
        /// allocation from the cell: the slot registry frees the *cell* on
        /// close, and a reaper may still be sleeping, so the reaper's
        /// pointer must not be the cell.
        const Inner = struct {
            refs: std.atomic.Value(u32),
            /// Disarmed by `deinit`. Read (under the app lock) before the
            /// reaper touches anything else.
            alive: std.atomic.Value(bool),
            /// Whether a reaper thread is serving this queue. Set under the
            /// app lock; read by `isRunning`.
            running: std.atomic.Value(bool) = .init(false),
            app: *App,
            /// Only ever used *after* the alive check, under the app lock.
            handler: *Handler,
            clock: Clock,
            items: [cap]Item = undefined,
            len: usize = 0,
            next_id: u64 = 1,

            fn drop(self: *Inner) void {
                if (self.refs.fetchSub(1, .acq_rel) == 1) self.app.allocator.destroy(self);
            }

            /// Frees every queued message. The messages are the only thing
            /// the queue owns; the `Inner` itself is refcounted.
            fn clear(self: *Inner) void {
                for (self.items[0..self.len]) |item| freeProps(self.app.allocator, item.props);
                self.len = 0;
            }

            /// Drops the item at `i`, keeping the rest in age order.
            fn removeAt(self: *Inner, i: usize) void {
                freeProps(self.app.allocator, self.items[i].props);
                var j = i;
                while (j + 1 < self.len) : (j += 1) self.items[j] = self.items[j + 1];
                self.len -= 1;
            }

            /// Removes every item whose deadline has passed. Returns how
            /// many went, which is what tells the reaper whether the host
            /// view needs re-rendering.
            fn sweepLocked(self: *Inner) usize {
                const now = self.clock();
                var removed: usize = 0;
                var i: usize = 0;
                while (i < self.len) {
                    if (self.items[i].deadline_ms > now) {
                        i += 1;
                        continue;
                    }
                    self.removeAt(i);
                    removed += 1;
                }
                return removed;
            }
        };

        app: *App,
        handler: *Handler,
        clock: Clock,
        /// Spawn a reaper on the first `show`? `initManual` turns it off for
        /// an app that runs its own ticker (or a test with a fake clock).
        auto_reaper: bool = true,
        inner: ?*Inner = null,

        /// `app` and `handler` are borrowed: they own this queue, not the
        /// other way round.
        pub fn init(app: *App, handler: *Handler, clock: Clock) Self {
            return .{ .app = app, .handler = handler, .clock = clock };
        }

        /// A queue with no background thread: the app calls `sweep` itself
        /// (a ticker, an event-loop turn) and re-renders its view when
        /// `sweep` reports work.
        pub fn initManual(app: *App, handler: *Handler, clock: Clock) Self {
            return .{ .app = app, .handler = handler, .clock = clock, .auto_reaper = false };
        }

        /// Slot-registry teardown. Disarms the reaper and frees the queued
        /// messages; the `Inner` lives until its last holder drops it.
        pub fn deinit(self: *Self) void {
            self.app.lock();
            defer self.app.unlock();
            const in = self.inner orelse return;
            in.alive.store(false, .release);
            in.clear();
            self.inner = null;
            in.drop();
        }

        /// Queues `props` for `ttl_ms` and returns its id. The oldest item is
        /// dropped when the queue is full, so the newest message is never
        /// the one lost.
        ///
        /// The caller need not hold the app lock (this takes it) and need
        /// not free anything it passed in.
        pub fn show(self: *Self, props: Props, ttl_ms: u64) !u64 {
            self.app.lock();
            defer self.app.unlock();

            const in = try self.ensure();
            const owned = try dupeProps(self.app.allocator, props);
            const ttl: i64 = @intCast(@min(ttl_ms, 24 * 60 * 60 * 1000));

            // Full: evict the oldest first, which frees its message.
            if (in.len == cap) in.removeAt(0);

            const id = in.next_id;
            in.next_id += 1;
            in.items[in.len] = .{
                .id = id,
                .props = owned,
                .deadline_ms = self.clock() + ttl,
            };
            in.len += 1;

            if (self.auto_reaper and !in.running.load(.acquire)) spawnReaper(in);
            return id;
        }

        /// Removes the item with `id` now — the close button, or an app
        /// cancelling its own notice. Returns whether anything went.
        ///
        /// Writes nothing: the caller re-renders through its ordinary event
        /// path, so the patch is the diff's business as usual.
        pub fn dismiss(self: *Self, id: u64) bool {
            self.app.lock();
            defer self.app.unlock();
            const in = self.inner orelse return false;
            for (in.items[0..in.len], 0..) |item, i| {
                if (item.id != id) continue;
                in.removeAt(i);
                return true;
            }
            return false;
        }

        /// Removes every due item and returns how many. The reaper calls
        /// this; an app with its own ticker calls it and then `flush`es.
        pub fn sweep(self: *Self) usize {
            self.app.lock();
            defer self.app.unlock();
            const in = self.inner orelse return 0;
            return in.sweepLocked();
        }

        /// The live items, oldest first. **Borrowed**: the slice and the
        /// messages in it stay valid until the next `show`/`dismiss`/`sweep`,
        /// so read them under the app lock (the render path already holds
        /// it) and do not keep them past it.
        pub fn items(self: *Self) []const Item {
            const in = self.inner orelse return &.{};
            return in.items[0..in.len];
        }

        pub fn count(self: *Self) usize {
            return self.items().len;
        }

        /// Is a reaper thread serving this queue right now? Diagnostics and
        /// tests: the reaper starts on the first `show` and exits once the
        /// queue is empty or has been deinited.
        pub fn isRunning(self: *Self) bool {
            const in = self.inner orelse return false;
            return in.running.load(.acquire);
        }

        fn ensure(self: *Self) !*Inner {
            if (self.inner) |in| return in;
            const in = try self.app.allocator.create(Inner);
            in.* = .{
                .refs = std.atomic.Value(u32).init(1),
                .alive = std.atomic.Value(bool).init(true),
                .app = self.app,
                .handler = self.handler,
                .clock = self.clock,
            };
            self.inner = in;
            return in;
        }

        fn spawnReaper(in: *Inner) void {
            in.running.store(true, .release);
            _ = in.refs.fetchAdd(1, .monotonic); // the reaper's reference
            // Counted before the spawn so a concurrent `waitIdle` cannot see
            // a quiet process between the thread starting and being counted.
            _ = reapers.fetchAdd(1, .release);
            const thread = std.Thread.spawn(.{}, reaperMain, .{in}) catch {
                // Without a reaper nothing auto-dismisses; the messages
                // stay queued until something sweeps. Not fatal, not silent.
                _ = reapers.fetchSub(1, .release);
                in.running.store(false, .release);
                in.drop();
                std.log.scoped(.zlive).warn("failed to spawn notification reaper; no auto-dismiss", .{});
                return;
            };
            thread.detach();
        }

        /// The reaper's whole loop: under the app lock, drop what is due and
        /// ask the handler to re-render; between wakeups, hold nothing.
        ///
        /// It borrows the `Inner` (reference-counted) and the app (outlives
        /// the connection), and touches `in.handler` only while holding the
        /// lock, after checking `alive` — that ordering is what makes
        /// teardown safe without joining the thread.
        fn reaperMain(in: *Inner) void {
            // The reference is dropped (and the state freed) before the
            // thread is counted as gone, so a waiter that sees `idle` can
            // trust that everything a reaper allocated is released.
            defer {
                in.drop();
                _ = reapers.fetchSub(1, .release);
            }
            const app = in.app;
            while (true) {
                app.lock();
                if (!in.alive.load(.acquire)) {
                    in.running.store(false, .release);
                    app.unlock();
                    return;
                }
                const expired = in.sweepLocked();
                // Still holding the lock: `flush` is expected to re-enter it
                // (recursive app lock) or to assume it (`flushLocked`). The
                // flush comes *before* the empty check — the item that
                // empties the queue is exactly the one that has to be
                // patched away.
                if (expired > 0) in.handler.flush();
                if (in.len == 0) {
                    // Nothing left to time: stop rather than idle forever.
                    // The next `show` starts a new reaper.
                    in.running.store(false, .release);
                    app.unlock();
                    return;
                }
                app.unlock();
                sleepMs(tick_ms);
            }
        }

        /// The string-valued fields of `Props` are the queue's to own: one
        /// dupe/free pair, no per-component knowledge. A failed copy unwinds
        /// the copies already made, so a caller that reports OutOfMemory
        /// does not also leak.
        fn dupeProps(allocator: std.mem.Allocator, props: Props) !Props {
            var out = props;
            const S = @typeInfo(Props).@"struct";
            inline for (S.field_names, S.field_types) |name, T| {
                if (T == ?[]const u8) {
                    if (@field(props, name)) |s| {
                        const copy = try allocator.dupe(u8, s);
                        errdefer allocator.free(copy);
                        @field(out, name) = copy;
                    }
                } else if (T == []const u8) {
                    const copy = try allocator.dupe(u8, @field(props, name));
                    errdefer allocator.free(copy);
                    @field(out, name) = copy;
                }
            }
            return out;
        }

        fn freeProps(allocator: std.mem.Allocator, props: Props) void {
            const S = @typeInfo(Props).@"struct";
            inline for (S.field_names, S.field_types) |name, T| {
                if (T == ?[]const u8) {
                    if (@field(props, name)) |s| allocator.free(s);
                } else if (T == []const u8) {
                    allocator.free(@field(props, name));
                }
            }
        }
    };
}

/// Sleep for `ms`, uninterruptibly: std.Io.sleep returns immediately outside
/// a task context, so raw nanosleep from this thread is the right call (same
/// as the transport's own workers).
fn sleepMs(ms: u64) void {
    var req: std.posix.timespec = .{
        .sec = @intCast(ms / 1000),
        .nsec = @intCast((ms % 1000) * std.time.ns_per_ms),
    };
    while (std.posix.errno(std.posix.system.nanosleep(&req, &req)) == .INTR) {}
}

// ---------------------------------------------------------------------
// Tests: a fake app/handler and a clock the test controls, so the queue's
// rules (ownership, capacity, order, dismissal, expiry) are verified
// without a socket. The one test that exercises the real reaper uses the
// wall clock.
// ---------------------------------------------------------------------

const testing = std.testing;

var test_now: i64 = 1_000;

fn testClock() i64 {
    return test_now;
}

fn wallClock() i64 {
    return std.Io.Clock.now(.real, std.Io.Threaded.global_single_threaded.io()).toMilliseconds();
}

const FakeHandler = struct {
    /// Atomic because the reaper test polls it from another thread.
    flushes: std.atomic.Value(usize) = .init(0),

    pub fn flush(self: *FakeHandler) void {
        _ = self.flushes.fetchAdd(1, .monotonic);
    }
};

const FakeApp = struct {
    pub const WebsocketHandler = FakeHandler;

    allocator: std.mem.Allocator,
    mutex: std.atomic.Mutex = .unlocked,

    pub fn lock(self: *FakeApp) void {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
    }

    pub fn unlock(self: *FakeApp) void {
        self.mutex.unlock();
    }
};

/// Props shaped like a real notification component's: two owned strings, one
/// optional, plus non-string fields the queue must leave alone.
const Msg = struct {
    message: []const u8,
    title: ?[]const u8 = null,
    level: u8 = 0,
};

const TestQueue = Queue(FakeApp, Msg, 3);

fn testQueue(app: *FakeApp, h: *FakeHandler) TestQueue {
    return TestQueue.initManual(app, h, testClock);
}

test "show owns the message: the caller's slice is copied and freed once" {
    var app = FakeApp{ .allocator = testing.allocator };
    var h = FakeHandler{};
    var q = testQueue(&app, &h);
    defer q.deinit();

    // Borrowed input: a stack buffer would be freed by the queue if it did
    // not copy, which testing.allocator would report as a bad free.
    var buf: [8]u8 = undefined;
    @memcpy(buf[0..7], "hello!!");
    const id = try q.show(.{ .message = buf[0..7], .title = "hi" }, 1000);
    try testing.expectEqual(@as(u64, 1), id); // ids are 1-based and monotonic

    try testing.expectEqual(@as(usize, 1), q.count());
    const item = q.items()[0];
    try testing.expectEqualStrings("hello!!", item.props.message);
    try testing.expectEqualStrings("hi", item.props.title.?);
    // a copy, not the caller's buffer (which is stack storage here)
    try testing.expect(@intFromPtr(item.props.message.ptr) != @intFromPtr(&buf));
    try testing.expectEqual(testClock() + 1000, item.deadline_ms);
}

test "an optional string field stays null instead of becoming empty" {
    var app = FakeApp{ .allocator = testing.allocator };
    var h = FakeHandler{};
    var q = testQueue(&app, &h);
    defer q.deinit();

    _ = try q.show(.{ .message = "no title" }, 10);
    try testing.expect(q.items()[0].props.title == null);
}

test "items come out oldest first, each with its own id and deadline" {
    var app = FakeApp{ .allocator = testing.allocator };
    var h = FakeHandler{};
    var q = testQueue(&app, &h);
    defer q.deinit();

    const a = try q.show(.{ .message = "first" }, 100);
    const b = try q.show(.{ .message = "second" }, 900);
    try testing.expect(a != b);
    const items = q.items();
    try testing.expectEqual(@as(usize, 2), items.len);
    try testing.expectEqualStrings("first", items[0].props.message);
    try testing.expectEqualStrings("second", items[1].props.message);
    try testing.expect(items[0].deadline_ms < items[1].deadline_ms);
}

test "a full queue drops the oldest, so the newest always fits" {
    var app = FakeApp{ .allocator = testing.allocator };
    var h = FakeHandler{};
    var q = testQueue(&app, &h);
    defer q.deinit();

    _ = try q.show(.{ .message = "one" }, 100);
    _ = try q.show(.{ .message = "two" }, 100);
    _ = try q.show(.{ .message = "three" }, 100);
    _ = try q.show(.{ .message = "four" }, 100); // evicts "one"

    try testing.expectEqual(@as(usize, 3), q.count());
    const items = q.items();
    try testing.expectEqualStrings("two", items[0].props.message);
    try testing.expectEqualStrings("four", items[2].props.message);
    // ids keep counting: they identify an item, they are not an index
    try testing.expectEqual(@as(u64, 4), items[2].id);
}

test "dismiss removes exactly the addressed item" {
    var app = FakeApp{ .allocator = testing.allocator };
    var h = FakeHandler{};
    var q = testQueue(&app, &h);
    defer q.deinit();

    _ = try q.show(.{ .message = "a" }, 100);
    const middle = try q.show(.{ .message = "b" }, 100);
    _ = try q.show(.{ .message = "c" }, 100);

    try testing.expect(q.dismiss(middle));
    // the neighbours keep their identity and their order
    const items = q.items();
    try testing.expectEqual(@as(usize, 2), items.len);
    try testing.expectEqualStrings("a", items[0].props.message);
    try testing.expectEqualStrings("c", items[1].props.message);
    try testing.expect(!q.dismiss(middle)); // gone: a no-op, not an error
    try testing.expect(!q.dismiss(9999));
    try testing.expectEqual(@as(usize, 2), q.count());
}

test "sweep expires only what is due, and reports the count" {
    var app = FakeApp{ .allocator = testing.allocator };
    var h = FakeHandler{};
    var q = testQueue(&app, &h);
    defer q.deinit();

    test_now = 5_000;
    _ = try q.show(.{ .message = "short" }, 50);
    _ = try q.show(.{ .message = "long" }, 500);

    test_now += 40; // nothing due yet
    try testing.expectEqual(@as(usize, 0), q.sweep());
    try testing.expectEqual(@as(usize, 2), q.count());

    test_now += 20; // the first deadline has passed, the second has not
    try testing.expectEqual(@as(usize, 1), q.sweep());
    const items = q.items();
    try testing.expectEqual(@as(usize, 1), items.len);
    try testing.expectEqualStrings("long", items[0].props.message);

    test_now += 1000; // now both are past
    try testing.expectEqual(@as(usize, 1), q.sweep());
    try testing.expectEqual(@as(usize, 0), q.count());
}

test "deinit frees what is still queued and disarms the state" {
    var app = FakeApp{ .allocator = testing.allocator };
    var h = FakeHandler{};
    var q = testQueue(&app, &h);

    _ = try q.show(.{ .message = "left over", .title = "t" }, 10_000);
    q.deinit(); // testing.allocator fails the test if the messages leak
    try testing.expectEqual(@as(usize, 0), q.count());
    try testing.expect(!q.isRunning());

    // a second deinit (idempotent, like every other slot teardown) is quiet
    q.deinit();
}

test "show and dismiss after deinit are harmless no-ops" {
    var app = FakeApp{ .allocator = testing.allocator };
    var h = FakeHandler{};
    var q = testQueue(&app, &h);
    q.deinit();

    // The cell is gone but not destroyed: reaching a deinited queue must
    // not resurrect it (the registry may still hand out the cell).
    try testing.expect(!q.dismiss(1));
    try testing.expectEqual(@as(usize, 0), q.sweep());
    try testing.expectEqual(@as(usize, 0), q.count());
    try testing.expect(!q.isRunning());
}

test "the real reaper expires its item and re-renders the host view" {
    var app = FakeApp{ .allocator = testing.allocator };
    var h = FakeHandler{};
    var q = TestQueue.init(&app, &h, wallClock);
    defer q.deinit();

    try testing.expect(!q.isRunning());
    _ = try q.show(.{ .message = "tick" }, 20);
    try testing.expect(q.isRunning());
    try testing.expectEqual(@as(usize, 1), q.count());

    // The reaper wakes on its tick, so this is bounded by tick_ms plus
    // scheduling; poll rather than sleep a fixed amount.
    var spins: usize = 0;
    while (h.flushes.load(.acquire) == 0 and spins < 400) : (spins += 1) sleepMs(5);
    try testing.expect(h.flushes.load(.acquire) >= 1);
    try testing.expectEqual(@as(usize, 0), q.count());

    // An empty queue stops the thread (and its reference) on its own, so
    // this test needs no join to leave the allocator clean.
    spins = 0;
    while (q.isRunning() and spins < 400) : (spins += 1) sleepMs(5);
    try testing.expect(!q.isRunning());
}

test "waitIdle reports when every reaper has stopped" {
    // Nothing running: it must be free and immediate, because this is on an
    // app's shutdown path and the common case is no queue at all.
    try testing.expect(idle());
    try testing.expect(waitIdle(0));

    var app = FakeApp{ .allocator = testing.allocator };
    var h = FakeHandler{};
    var q = TestQueue.init(&app, &h, wallClock);
    defer q.deinit();

    _ = try q.show(.{ .message = "counted" }, 10);
    try testing.expect(!idle());
    try testing.expect(waitIdle(2000)); // it empties and stops on its own
    try testing.expect(idle());
    try testing.expect(!q.isRunning());
}

test "a dismissed item is never flushed by the reaper" {
    var app = FakeApp{ .allocator = testing.allocator };
    var h = FakeHandler{};
    var q = TestQueue.init(&app, &h, wallClock);
    defer q.deinit();

    const id = try q.show(.{ .message = "never mind" }, 20);
    try testing.expect(q.dismiss(id));
    // Long enough that the item's deadline is well past: if the reaper were
    // timing it rather than the queue, this would have flushed by now.
    sleepMs(3 * tick_ms);
    try testing.expectEqual(@as(usize, 0), h.flushes.load(.acquire));
    try testing.expectEqual(@as(usize, 0), q.count());

    var spins: usize = 0;
    while (q.isRunning() and spins < 400) : (spins += 1) sleepMs(5);
    try testing.expect(!q.isRunning());
}
