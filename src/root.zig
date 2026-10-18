// zlive: server-rendered, patch-delivered UI framework for Zig.
//
// The render model: a view renders to a recursive segment tree (statics,
// dynamic scalars, nested child lists); `diff` walks two trees and emits
// path-addressed patches ({"3.2.1": "new value"}); `protocol` carries
// renders and patches as JSON envelopes over the wire; `client.js` is the
// browser runtime that applies them.
//
// `http` is the transport half: the server an app is built on, the
// per-connection service and its view-state slot registry, static and
// embedded-asset serving, the notification queue, and scoped state. It is
// the only part of zlive that depends on anything outside std, which is why
// an app can depend on this one package and never import httpz itself.

const std = @import("std");

const view = @import("view.zig");

pub const Scalar = view.Scalar;
pub const Segment = view.Segment;
pub const Patch = view.Patch;
pub const PatchSet = view.PatchSet;
pub const DiffError = view.DiffError;
pub const Component = view.Component;
pub const diff = view.diff;
pub const treeToValue = view.treeToValue;
pub const flattenHtml = view.flattenHtml;
pub const clearSlot = view.clearSlot;
pub const freeValue = view.freeValue;

pub const protocol = @import("protocol.zig");
pub const util = @import("util.zig");

/// Session-state registry for parked views (generic; no transport).
pub const session = @import("session.zig");
pub const Registry = session.Registry;

/// The HTTP/WebSocket transport layer (server, service, slots, static).
pub const http = @import("http.zig");

/// Layouts: Jinja-style template inheritance (`extends`/`block`/`super()`/
/// `include`) for the app's page documents. Rendering is a build-time step
/// (`zlive.build.addRenderedPages`), so pages stay static bytes.
pub const layout = @import("layout.zig");

/// The browser runtime (LiveHooks registry + socket client), embedded so
/// consumers can serve it without depending on their working directory.
pub const client_js: []const u8 = @embedFile("client.js");

/// Renders a child component for template composition, dispatching at
/// comptime on the component's render shape (static `[N]Segment` or
/// loop `![]Segment`), so template-generated and hand-written components
/// mix freely. The returned tree is allocated from `allocator`.
pub fn renderChild(allocator: std.mem.Allocator, comptime C: type, args: anytype) ![]const Segment {
    const param_types = @typeInfo(@TypeOf(C.render)).@"fn".param_types;
    const props: C.Props = args;
    if (param_types.len == 1) {
        const tree = C.render(props);
        const copy = try allocator.alloc(Segment, tree.len);
        @memcpy(copy, &tree);
        return copy;
    }
    return C.render(allocator, props);
}

test {
    std.testing.refAllDecls(@This());
    _ = session;
    _ = http;
}
