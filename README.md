# zlive

Server-rendered, patch-delivered UI framework for Zig — the render engine,
the wire protocol, the browser runtime, **and the HTTP/WebSocket server an
app is built on**.

- Requires **Zig 0.17.0**.
- `zig build test` runs the engine, protocol, component-template compiler,
  layout engine, transport, service and session tests.
- An app depends on **zlive only**: the HTTP/WebSocket dependency
  (`http.zig`) is declared and imported here, not by apps. The render core
  (`view`, `protocol`, `util`) stays std-only; only `zlive.http` touches the
  transport.

## Model

A view renders to a recursive **segment tree**: each node is a static
string, a dynamic scalar, or a nested list of child trees (loops and
component composition). `zlive.diff(old, new)` walks two trees and emits
path-addressed patches — `{"3.2.1": "new value"}` — so a re-render only
touches the slots that changed.

## Wire protocol

Every message is a JSON envelope:

```json
{ "version": 1, "type": "message", "topic": "view:counter",
  "event": "patch", "payload": {"1": 42}, "ref": 12 }
```

`version` is checked on decode; mismatches are rejected. `ref` pairs a
reply with the request that caused it. See `src/protocol.zig`.

## Client runtime

`zlive.client_js` is the embedded browser runtime (`src/client.js`):
a `window.LiveHooks` registry (`register(name, {mounted, updated,
destroyed})`, elements opt in via `data-lv-hook`) plus the socket client —
connect/join, full render on mount, morphdom patches, delegated
`[data-lv-click]` events with incrementing refs, reconnect with backoff.
`Live.start({ join: {...} })` merges page-supplied fields into the join
payload, which is how a page tells the server which group it belongs to.

## Layouts (`zlive.layout`)

Pages are static documents, and a document is mostly shell: doctype, head,
`#lv`/`#log`, script tags. `zlive.layout` is the framework's Jinja-style
inheritance engine for that shell, so an app writes each page as a layout
plus blocks instead of copying it:

```html
{% extends "app.html" %}
{% block title %}view:counter{% endblock %}
{% block page %}<h1>view:counter</h1>{% endblock %}
{% block page_script %}
<script>Live.start({ container: 'lv', log: 'log' });</script>
{% endblock %}
```

The subset is deliberate — `extends` (first tag), `block`/`endblock`,
`{{ super() }}`, `include`, and `{%- … -%}` trimming; no expressions, loops
or variables. A page is the same bytes for every visitor, and per-session
content is a view's job. Text outside blocks in a child is ignored (Jinja's
rule); nested blocks work, so a layout can add override points; a top-level
block that no parent defines is an error rather than dead markup.

API: `layout.Engine.init(allocator)` (allocations are caller-owned, so an
arena is the natural choice), `add(name, source)` for every layout, include
and page, then `render(entry)`. Renders are cached, and a failure fills
`engine.diag` with the template name, line and reason before returning the
error (`layout.Error`).

The server's page table is `comptime` and embeds each page's bytes, so
rendering happens at **build time**. `zlive.build.addRenderedPages(b,
renderer, page_files, out_prefix)` invokes the app's renderer as
`renderer <entry> <output>` for each entry and copies the output where
`@embedFile` can see it. The app owns the template sources and the tiny
renderer (embedding them is what makes the build track them); zlive owns the
engine and the copy step, mirroring `addTemplates` for the component
compiler. See `../zlive-examples/src/render_pages.zig` and
`../zlive-examples/build.zig` for the complete usage.

## The transport (`zlive.http`)

Everything an app needs to be a server, so the app itself is plumbing and
never imports http.zig:

| Piece | What it does |
| --- | --- |
| `zlive.http.Server(App)` | listener, routing, graceful shutdown (SIGINT/SIGTERM), embedded-asset serving, an optional disk-backed static fallback, and the `/ws` upgrade path |
| `zlive.http.Service(App)` | per-connection transport: envelope decode/encode, the 4 KiB app-level cap, the error taxonomy, reply helpers, the session token |
| `zlive.http.Slots(n)` | the **slot registry**: typed per-connection view state addressed by key, created on first use, torn down once on close |
| `zlive.Registry(T)` | session-state registry: parks a disconnected view's state under the client's token for a TTL |
| `zlive.http.Queue(App, Props, cap)` | the notification queue behind the inline Flash banner and the corner Toast stack: `show` appends a message and arms its deadline, `dismiss(id)` removes one now, and a reaper thread re-renders the connection's view through `Handler.flush` when one expires |
| `zlive.http.static` | disk and embedded-asset responses with content-type mapping |

Routes are registered four ways: `pages` (an array of `{ path, file, bytes }`
— embed `bytes` for a self-contained binary, or leave it null to read the
file from the working directory), `asset(path, bytes, content_type)` for
embedded bytes, `get`/`post` for ordinary handlers, and `socket` for the
upgrade. Duplicate page paths are rejected at compile time.

An app supplies a context and a connection handler:

```zig
const App = struct {
    allocator: std.mem.Allocator,
    io: std.Io,

    pub const WebsocketHandler = Handler; // the app's connection handler

    pub fn authorizeSocket(self: *App, req: *zlive.http.Request) bool { ... }
    pub fn shutdown(self: *App) void { ... } // release app resources
};

var app: App = ...;
const config: zlive.http.Server(App).Config = .{
    // Embedded: the page travels inside the binary.
    .pages = &.{.{
        .path = "/table",
        .file = "table.html",
        .bytes = @embedFile("pages/table.html"),
    }},
};
var server = try zlive.http.Server(App).init(config, &app);
defer server.deinit();
try server.asset(config, "/client.js", zlive.client_js, zlive.http.static.ContentType.js);
try server.socket(config, "/ws");
try server.run();
```

Two lifetime rules the framework enforces, because getting them wrong is
what bites: the app must be built **in place** (it owns a registry) and the
server must not be moved after route registration (`App` storage lives
inside the transport). `Server.deinit` calls `App.shutdown` while that
storage is still valid, then the transport teardown, then `App.deinit`.

## Notifications (`zlive.http.Queue`)

A notification is a message with a deadline. The framework owns the timing
and the message's lifetime; the app owns what it looks like and where it
sits — an inline banner is a queue of capacity 1, a corner stack is a queue
of capacity 3:

```zig
pub const Banner = zlive.http.Queue(App, view.Flash.Props, 1);
pub const Toast  = zlive.http.Queue(App, view.Toast.Props, 3);

const id = try h.toasts().show(.{ .message = "Saved", .level = .success }, 3000);
_ = try h.toasts().dismiss(id);        // the close button, addressed by id
```

- **`show(props, ttl_ms) !u64`** copies the props' string fields (the queue
  owns those copies, so callers pass borrowed slices and free nothing),
  appends the item and returns its id. When the queue is full the **oldest
  item is dropped**, so the newest message is never the one lost.
- **`dismiss(id)`** removes one item now and writes nothing: the caller
  re-renders through its ordinary event path, so the patch is the diff's
  business as usual.
- **`items()`** is the queue in age order (oldest first) — what a view
  renders. It is borrowed: read it under the app lock, which the render path
  already holds.
- **Expiry is a state change, not a patch.** A reaper thread (`tick_ms`,
  100 ms) removes what is due and calls

  ```zig
  pub fn flush(self: *Handler) void   // re-render what this session shows
  ```

  so an expiring toast goes through the same render + `view.diff` path as an
  event. Nothing in the app needs to know which slot a message lives in, how
  many siblings it has, or which generation it belongs to — and a cached
  tree cannot go stale behind the view's back. This is the contract
  `zlive.http.Store` uses for group and global changes, and it is why a
  view needs no `clearSlot` bookkeeping for its notifications.
- The reaper holds the app lock across `flush`, so `flush` must tolerate
  being called with the lock held: **make the app lock recursive** (the
  demo does) or give the handler a `flushLocked`. `App` must also declare
  `lock`/`unlock` and a `WebsocketHandler` with `flush` — `Queue` is a
  compile error without them.
- Lifetime: the queue's state is reference-counted and separate from the
  slot-registry cell that holds it, so teardown only *disarms* it. A reaper
  sleeping when the connection closes wakes to `alive == false` and frees
  what it was holding, instead of reading released memory.
- `initManual(app, handler, clock)` is the same queue with no thread, for an
  app that runs its own ticker (or a test with a fake clock).

## Scoped state (`zlive.http.Store`)

State has three lifetimes, and the framework gives each one a home:

| Scope | Who sees it | Stored in | Freed |
| --- | --- | --- | --- |
| **session** | one connection | the handler's own `Slots(n)` | on close |
| **group** | every session that joined the same id | `Store`, keyed by an app-chosen id | after the last member leaves, once the TTL passes |
| **global** | every session in the process | `Store`, one cell set | at shutdown |

```zig
pub const App = struct {
    pub const WebsocketHandler = Handler;
    store: Store,                       // Store(App, cells_per_group)
    // ... allocator, lock/unlock (see below)
};

// a view, at mount and on an event:
const cells = try h.app().store.join(h, "room:42");   // group scope
const room = try cells.getOrCreate("state", RoomState, RoomState.init);
const total = try h.app().store.global().getOrCreate("total", Total, Total.init);
room.clicks += 1;
total.clicks += 1;
h.app().store.notifyGroup("room:42", h);              // everyone else re-renders
h.app().store.notifyAll(h);                           // ...or every session
```

- `join(h, id)` attaches the session, creates the group on first use, and
  un-parks it if it was parked. `leave(h)` drops membership; `detach(h)`
  (from the handler's `close`) also stops it being a notification target.
- A group's cells are the same type-erased cell set as a session's slots, so
  cell types declare `deinit(self: *T) void` and `getOrCreate` /
  `getOrCreateWith` / `put` behave identically.
- Parking: an emptied group keeps its state for `ttl_sec` (pass a clock and a
  TTL to `Store.init`) so a reconnecting session rejoins a room that still
  knows its counters. `sweep()` frees expired groups; `join` calls it too.
- **Notification needs one thing from the handler:**

  ```zig
  pub fn flush(self: *Handler) void   // re-render what this session shows
  ```

  `notifyGroup` / `notifyAll` hold the app lock for the whole loop, so a
  member cannot close and have its state freed mid-flush. `flush` therefore
  runs *with the lock already held*, and the two supported ways to keep that
  from deadlocking are a **recursive app lock** (what the demo does) or a
  separate `flushLocked` that assumes the lock. A `flush` must also be cheap:
  it writes to one socket while every other member waits.

## Components


The component contract (`zlive.Component`) lives here; the component
library itself is the sibling package `../zlive-components` (module
`zlive_components`). A runnable demo app lives in `../zlive-examples`.

## License

BSD 3-Clause License — see [LICENSE](LICENSE).
