// The transport layer: everything that touches the HTTP/WebSocket
// dependency lives behind this module, so the rest of zlive stays
// std-only and an app can depend on zlive alone.
//
//   const zlive = @import("zlive");
//   var server = try zlive.http.Server(App, Handler).init(config);

pub const server = @import("server.zig");
pub const service = @import("service.zig");
pub const static = @import("static.zig");
pub const notify = @import("notify.zig");
pub const scope = @import("scope.zig");

pub const Server = server.Server;
pub const Service = service.Service;
pub const Slots = service.Slots;
pub const Store = scope.Store;
pub const Queue = notify.Queue;
pub const max_envelope_size = service.max_envelope_size;

pub const Request = server.Request;
pub const Response = server.Response;
pub const Conn = service.Conn;
pub const Address = server.Address;
pub const Static = server.Static;

/// The underlying transport, re-exported for the rare app that needs it.
/// Importing this is a signal that zlive's surface is missing something.
pub const httpz = @import("httpz");
pub const websocket = httpz.websocket;

test {
    _ = server;
    _ = service;
    _ = static;
    _ = notify;
    _ = scope;
}
