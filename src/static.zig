// Static and embedded-asset responses.
//
// Everything an app serves on a plain GET goes through here: files read
// from disk (HTML pages, theme.js) and bytes already embedded in the
// framework or a component library (client.js, hooks.js, zc.css), so the
// same binary works from any working directory.

const std = @import("std");
const httpz = @import("httpz");

pub const Request = httpz.Request;
pub const Response = httpz.Response;

/// Cap for a single static file; pages and scripts are small, and a
/// runaway read should fail rather than allocate without bound.
pub const max_file_size = 64 * 1024;

pub const ContentType = struct {
    pub const html = "text/html; charset=utf-8";
    pub const js = "text/javascript; charset=utf-8";
    pub const css = "text/css; charset=utf-8";
    pub const json = "application/json; charset=utf-8";
    pub const text = "text/plain; charset=utf-8";
    pub const svg = "image/svg+xml";
    pub const png = "image/png";
    pub const ico = "image/x-icon";
};

/// Content type for a path, by extension. Unknown extensions are served as
/// text/plain rather than guessed.
pub fn contentTypeFor(path: []const u8) []const u8 {
    const ext = std.fs.path.extension(path);
    const map = .{
        .{ ".html", ContentType.html },
        .{ ".htm", ContentType.html },
        .{ ".js", ContentType.js },
        .{ ".mjs", ContentType.js },
        .{ ".css", ContentType.css },
        .{ ".json", ContentType.json },
        .{ ".txt", ContentType.text },
        .{ ".svg", ContentType.svg },
        .{ ".png", ContentType.png },
        .{ ".ico", ContentType.ico },
    };
    inline for (map) |entry| {
        if (std.mem.eql(u8, ext, entry[0])) return entry[1];
    }
    return ContentType.text;
}

/// Serves a file from the current working directory. The read is bounded
/// by `max_file_size` and allocated from the request arena (freed when the
/// response completes).
pub fn serveFile(req: *Request, res: *Response, path: []const u8) !void {
    try serveFileAs(req, res, path, contentTypeFor(path));
}

/// Serves a file with an explicit content type.
pub fn serveFileAs(req: *Request, res: *Response, path: []const u8, content_type: []const u8) !void {
    res.header("content-type", content_type);
    res.body = std.Io.Dir.cwd().readFileAlloc(
        req.conn.io,
        path,
        res.arena,
        .limited(max_file_size),
    ) catch {
        res.status = 500;
        res.body = "failed to load the file (run from the directory the app serves)";
        return;
    };
}

/// Serves an in-memory asset (`@embedFile` bytes from the framework or a
/// component library). Nothing is copied: `bytes` must outlive the write.
pub fn serveAsset(res: *Response, bytes: []const u8, content_type: []const u8) !void {
    res.header("content-type", content_type);
    res.body = bytes;
}

const testing = std.testing;

test "content types resolve by extension" {
    try testing.expectEqualStrings(ContentType.html, contentTypeFor("static/index.html"));
    try testing.expectEqualStrings(ContentType.js, contentTypeFor("client.js"));
    try testing.expectEqualStrings(ContentType.css, contentTypeFor("/x/zc.css"));
    try testing.expectEqualStrings(ContentType.text, contentTypeFor("LICENSE"));
    try testing.expectEqualStrings(ContentType.text, contentTypeFor("data.bin"));
}
