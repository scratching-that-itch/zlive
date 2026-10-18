// The HTTP/WebSocket server an app is built on.
//
// zlive owns the transport (the httpz dependency), the listener, route
// registration, graceful shutdown, and the WebSocket upgrade path. An app
// supplies a context value (`App`) and a connection handler type, then
// registers routes that read as ordinary handler functions — it never
// imports httpz and never sees a socket handshake.

const std = @import("std");
const builtin = @import("builtin");
const httpz = @import("httpz");

const static = @import("static.zig");

pub const Request = httpz.Request;
pub const Response = httpz.Response;

/// The default listen address: loopback only. Apps that need to bind
/// elsewhere pass `address`.
pub const default_port = 9224;

/// The transport's listen address (ip+port, or a unix socket).
pub const Address = httpz.Config.Address;

/// Transport-level cap for one websocket message. The service layer
/// enforces its own smaller envelope cap on top of this.
pub const default_max_message_size = 1 << 20;

/// Serves `index` for "/" and every other path under the prefix from disk
/// (`static/a/b.css` for "/a/b.css"), falling back to `index` when the
/// file is missing. Pass `.none` to handle every route explicitly.
pub const Static = union(enum) {
    none,
    /// `dir` is a directory relative to the working directory, `index` the
    /// file served for "/" and for unknown paths (usually "index.html").
    dir: struct { dir: []const u8, index: []const u8 = "index.html" },
};

/// The HTTP/WebSocket server for an app context `App`.
///
/// `App` is the value the transport owns and passes to every action
/// handler (`*App`), so it must declare the connection handler:
///
///   pub const WebsocketHandler = my_handler.Handler;
///
/// and expose `allocator: std.mem.Allocator` and `io: std.Io`. Two
/// optional declarations shape behaviour:
///
///   pub fn authorizeSocket(self: *App, req: *zlive.http.Request) bool
///   pub fn shutdown(self: *App) void
///   pub fn deinit(self: *App) void
///
/// `authorizeSocket` runs before the upgrade (a false result is a 401 and
/// the connection is never upgraded). `shutdown` runs from `Server.deinit`
/// after the listener stops but *before* the transport frees its handler
/// storage, so it is where an app releases things the transport does not
/// know about (a session registry, a cache). `deinit` runs last, after the
/// handler's own `close` has already run.
pub fn Server(comptime App: type) type {
    return struct {
        const Self = @This();
        const Handler = App.WebsocketHandler;

        /// What the transport actually owns: a pointer to the app value.
        /// httpz passes its handler by value to every action, so carrying
        /// the pointer here means route handlers and the websocket handler
        /// all see the *same* app state — and the app can be a stack local
        /// in `main`.
        pub const Ctx = struct {
            app: *App,

            pub const WebsocketHandler = Handler;
        };

        /// The router type httpz derives: action parameter is
        /// `Action(Ctx)`, which every route handler here coerces to.
        const Action = httpz.Action(Ctx);
        const Router = httpz.Router(Ctx, Action);

        /// Handlers registered with httpz carry compile-time config (their
        /// `ctx`), so each configuration gets a generated namespace with
        /// its own copies of the static-file handlers. That keeps the whole
        /// wiring comptime — no mutable global state, no double init.
        fn Namespace(comptime config: Config) type {
            return struct {
                fn serveIndex(ctx: Ctx, req: *Request, res: *Response) !void {
                    _ = ctx;
                    switch (config.static) {
                        .none => notFound(res),
                        .dir => |d| try static.serveFile(req, res, try join(res, d.dir, d.index)),
                    }
                }

                /// Every path not registered as a page or asset is served
                /// from the static directory; a miss is a 404 (the index is
                /// only served for "/"), so typos are visible instead of
                /// silently rendering the landing page.
                fn servePath(ctx: Ctx, req: *Request, res: *Response) !void {
                    _ = ctx;
                    switch (config.static) {
                        .none => notFound(res),
                        .dir => |d| {
                            const rel = if (req.url.path.len > 0 and req.url.path[0] == '/')
                                req.url.path[1..]
                            else
                                req.url.path;
                            const full = try join(res, d.dir, rel);
                            if (!try exists(full)) return notFound(res);
                            try static.serveFile(req, res, full);
                        },
                    }
                }

                fn exists(path: []const u8) !bool {
                    std.Io.Dir.cwd().access(std.Io.Threaded.global_single_threaded.io(), path, .{}) catch return false;
                    return true;
                }

                /// A page route. `page.bytes` (when given) is embedded in
                /// the handler, so the binary carries the page; otherwise
                /// the file is read from the working directory per request.
                fn servePage(comptime page: Page) fn (Ctx, *Request, *Response) anyerror!void {
                    return struct {
                        fn handle(ctx: Ctx, req: *Request, res: *Response) anyerror!void {
                            _ = ctx;
                            if (comptime page.bytes) |bytes| {
                                // Owned by the binary; `page.file` only
                                // supplies the content type.
                                return static.serveAsset(res, bytes, static.contentTypeFor(page.file));
                            }
                            try static.serveFileAs(req, res, page.file, static.contentTypeFor(page.file));
                        }
                    }.handle;
                }

                fn join(res: *Response, dir: []const u8, rel: []const u8) ![]const u8 {
                    return std.fs.path.join(res.arena, &.{ dir, rel });
                }

                fn notFound(res: *Response) void {
                    res.status = 404;
                    res.body = "not found";
                }
            };
        }

        server: httpz.Server(Ctx),
        /// Routes are registered on first access — after the server has
        /// come to rest, so httpz's router pointer can never dangle.
        routed: ?*Router = null,
        /// The single live instance, used by the signal handler.
        live: ?*Self = null,

        pub const Config = struct {
            address: Address = .localhost(default_port),
            max_message_size: usize = default_max_message_size,
            static: Static = .none,
            /// Page routes, registered before the static fallback so they
            /// win over it. Embed the bytes for a self-contained binary, or
            /// leave them null to read from disk while developing.
            pages: []const Page = &.{},
        };

        /// One page route.
        ///
        ///   .{ .path = "/tabs", .file = "tabs.html", .bytes = @embedFile("pages/tabs.html") }
        ///
        /// `bytes` is the production path: the page travels inside the
        /// binary, `file` is then only the name its content type is derived
        /// from, and nothing is read from disk. With `bytes = null` the
        /// file is read from the working directory on every request, which
        /// is what you want while iterating on markup: edit, refresh,
        /// rebuild nothing.
        pub const Page = struct {
            path: []const u8,
            file: []const u8,
            bytes: ?[]const u8 = null,
        };

        /// Builds the server, moving `app` into the transport (action
        /// handlers receive a pointer to it). Routing is registered lazily
        /// by `router()`, because httpz's router lives inside the server and
        /// capturing it here would dangle the moment this value is returned.
        pub fn init(comptime config: Config, app_ptr: *App) !Self {
            const allocator = app_ptr.allocator;
            const ctx = Ctx{ .app = app_ptr };
            var server = try httpz.Server(Ctx).init(app_ptr.io, allocator, .{
                .address = config.address,
                .websocket = .{ .max_message_size = config.max_message_size },
            }, ctx);
            errdefer server.deinit();
            return .{ .server = server };
        }

        /// The transport's router, created once and populated from
        /// `comptime config` — the same config `init` was given. Passed
        /// back in rather than stored, because a config can hold comptime
        /// data (page paths baked into handlers) that a struct field
        /// cannot.
        pub fn router(self: *Self, comptime config: Config) !*Router {
            if (self.routed) |r| return r;
            const Names = Namespace(config);
            // Two pages on the same path would overwrite each other in the
            // router at runtime; catch it while compiling instead.
            inline for (config.pages, 0..) |page, i| {
                inline for (config.pages[i + 1 ..]) |other| {
                    if (comptime std.mem.eql(u8, page.path, other.path)) {
                        @compileError("duplicate page path: " ++ page.path);
                    }
                }
            }
            const r = try self.server.router(.{});
            // Comptime: each page's bytes are baked into its handler.
            inline for (config.pages) |page| {
                r.get(page.path, Names.servePage(page), .{});
            }
            switch (config.static) {
                .none => {},
                .dir => {
                    r.get("/", Names.serveIndex, .{});
                    r.get("/*path", Names.servePath, .{});
                },
            }
            self.routed = r;
            return r;
        }

        pub fn deinit(self: *Self) void {
            self.live = null;
            if (self_ptr == self) self_ptr = null;
            // Order matters: the app lives inside the transport's handler
            // value, so give the app a chance to release its own resources
            // while that storage is still valid, then let the transport
            // free the storage, and only then run the app's final deinit.
            if (comptime std.meta.hasFn(App, "shutdown")) self.server.handler.app.shutdown();
            self.server.deinit();
            if (comptime std.meta.hasFn(App, "deinit")) self.server.handler.app.deinit();
        }

        // ---------------------------------------------------------------
        // Route registration
        // ---------------------------------------------------------------

        /// GET route. The handler has httpz's action shape:
        /// `fn (app: *App, req: *Request, res: *Response) !void`.
        pub fn get(self: *Self, comptime config: Config, path: []const u8, handler: Action) !void {
            (try self.router(config)).get(path, handler, .{});
        }

        /// POST route, same handler shape as `get`.
        pub fn post(self: *Self, comptime config: Config, path: []const u8, handler: Action) !void {
            (try self.router(config)).post(path, handler, .{});
        }

        /// Registers `/ws`: validates with `App.authorizeSocket` when
        /// present, then upgrades to `Handler`. A missing handshake is a
        /// 400; a rejected session is a 401 and never upgrades.
        pub fn socket(self: *Self, comptime config: Config, path: []const u8) !void {
            (try self.router(config)).get(path, struct {
                fn upgrade(ctx: Ctx, req: *Request, res: *Response) !void {
                    const app = ctx.app;
                    if (comptime std.meta.hasFn(App, "authorizeSocket")) {
                        if (!app.authorizeSocket(req)) {
                            res.status = 401;
                            res.body = "unauthorized";
                            return;
                        }
                    }
                    std.log.scoped(.zlive).info("websocket upgrade request", .{});
                    if (try httpz.upgradeWebsocket(Handler, req, res, app) == false) {
                        res.status = 400;
                        res.body = "invalid websocket handshake";
                    }
                }
            }.upgrade, .{});
        }

        /// Serves an embedded asset at `path` (framework or component
        /// library bytes), e.g. zlive's own client runtime.
        pub fn asset(
            self: *Self,
            comptime config: Config,
            path: []const u8,
            comptime bytes: []const u8,
            comptime content_type: []const u8,
        ) !void {
            (try self.router(config)).get(path, struct {
                fn serve(_: Ctx, _: *Request, res: *Response) !void {
                    try static.serveAsset(res, bytes, content_type);
                }
            }.serve, .{});
        }

        // ---------------------------------------------------------------
        // Serving
        // ---------------------------------------------------------------

        /// Runs until stopped, handling SIGINT/SIGTERM as a graceful
        /// shutdown. Blocks; call from `main`.
        pub fn run(self: *Self) !void {
            self_ptr = self;
            defer self_ptr = null;

            if (comptime builtin.os.tag == .windows) {
                // std.posix.sigaction is unavailable; run without signals.
                try self.server.listen();
                return;
            }
            try self.installSignals();
            std.log.scoped(.zlive).info("listening on http://127.0.0.1:{d}", .{default_port});
            try self.server.listen();
            std.log.scoped(.zlive).info("shut down", .{});
        }

        /// Asks the listener to stop; safe to call from a signal handler.
        pub fn stop(self: *Self) void {
            self.server.stop();
        }

        fn installSignals(self: *Self) !void {
            _ = self;
            const act = std.posix.Sigaction{
                .handler = .{ .handler = handleSignal },
                .mask = std.posix.sigemptyset(),
                .flags = 0,
            };
            std.posix.sigaction(std.posix.SIG.INT, &act, null);
            std.posix.sigaction(std.posix.SIG.TERM, &act, null);
        }

        fn handleSignal(_: std.posix.SIG) callconv(.c) void {
            // Set for the duration of `run`; outside that a signal is a
            // no-op rather than a use-after-free.
            if (self_ptr) |server| server.stop();
        }

        /// Set from `run`, read by the signal handler. One live instance
        /// per process, which is all a listener can be anyway.
        var self_ptr: ?*Self = null;
    };
}

const testing = std.testing;

test "static content type routing" {
    try testing.expectEqualStrings(
        static.ContentType.html,
        static.contentTypeFor("static/index.html"),
    );
}
