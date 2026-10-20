//! Layouts: the Jinja-style template inheritance engine for page layouts.
//!
//! A page is a static document, but a document is mostly shell: the
//! doctype, the head, the script tags, `#lv` and `#log`. Instead of copying
//! that into every file, pages inherit it. This engine implements the part
//! of Jinja's template inheritance that layouts need, and nothing else:
//!
//!   {% extends "base.html" %}          first tag in a child template
//!   {% block name %}...{% endblock %}  a named override point
//!   {{ super() }}                      the parent's body for this block
//!   {% include "partial.html" %}       splice another template
//!   {%- ... -%}  /  {{- ... -}}        trim whitespace around a tag
//!
//! There are deliberately no expressions, loops, or variables: a page is
//! the same bytes for every visitor, and per-session content is a view's
//! job (the page only calls `Live.start`, which hands over to the view).
//! Text outside blocks in a child template is ignored, as in Jinja;
//! nested blocks work, so a layout can add override points of its own.
//!
//! Layout sources and the page list belong to the app; this module is the
//! mechanism, and `zlive.build.addRenderedPages` owns the pipeline: it runs
//! the framework's `zlive-render-pages` tool at build time and assembles the
//! output into a generated module in the build cache, so the server's
//! `comptime` page table can embed the rendered bytes. A failure carries
//! the template name, line and reason in `Engine.diag`, so a bad layout
//! points at the file and line in `zig build`.
//!
//! See `zlive/README.md` ("Layouts") for the app-side pattern.

const std = @import("std");

pub const Error = error{
    OutOfMemory,
    DuplicateTemplate,
    UnknownTemplate,
    ExtendsNotFirst,
    DuplicateExtends,
    ExtendsCycle,
    DuplicateBlock,
    UnclosedBlock,
    UnexpectedEndblock,
    MismatchedEndblock,
    UnknownTag,
    InvalidTag,
    UnclosedTag,
    UnknownBlock,
    NoSuper,
    IncludeCycle,
    IncludeExtends,
    TooDeep,
    Internal,
};

/// Where and why rendering failed: the template's name, the 1-based line,
/// and a message. `render` clears it on entry.
pub const Diagnostic = struct {
    template: []const u8 = "",
    line: usize = 0,
    message: []const u8 = "",
};

const max_chain = 32;
const max_include_depth = 32;

const Kind = enum { tag, expr };

const Tag = struct {
    kind: Kind,
    content: []const u8,
    start: usize,
    end: usize,
    trim_before: bool,
    trim_after: bool,
};

const Directive = struct { word: []const u8, arg: []const u8 };

const Block = struct {
    name: []const u8,
    line: usize,
    /// Nesting depth inside this template (0 = top level). Only top-level
    /// blocks are checked against the parents when they override, because
    /// a layout is allowed to introduce new nested override points.
    depth: usize,
    tag_start: usize,
    body_start: usize,
    body_end: usize,
    /// Offset just past the matching `{% endblock %}` (after its trim).
    after: usize,
};

const Open = struct { name: []const u8, rec: usize };

const Parsed = struct {
    name: []const u8,
    source: []const u8,
    parent: ?[]const u8,
    blocks: []const Block,
};

const BodyRef = struct { parsed: *const Parsed, base: usize, body: []const u8 };
const SuperRef = struct { name: []const u8, level: usize };

pub const Engine = struct {
    allocator: std.mem.Allocator,
    sources: std.StringHashMapUnmanaged([]const u8) = .empty,
    parsed: std.StringHashMapUnmanaged(*const Parsed) = .empty,
    rendered: std.StringHashMapUnmanaged([]const u8) = .empty,
    include_stack: std.ArrayListUnmanaged([]const u8) = .empty,
    diag: Diagnostic = .{},

    /// The engine borrows `name` and `source` (embedded files live for the
    /// process); everything it derives is allocated from `allocator` and
    /// lives until the caller frees it — an arena, in the app and in the
    /// tests.
    pub fn init(allocator: std.mem.Allocator) Engine {
        return .{ .allocator = allocator };
    }

    /// Registers a template by name. Names are the strings used by
    /// `{% extends %}`/`{% include %}` and by `render`.
    pub fn add(self: *Engine, name: []const u8, source: []const u8) Error!void {
        if (self.sources.get(name) != null) {
            self.diagAt(name, 0, "template '{s}' was added twice", .{name});
            return error.DuplicateTemplate;
        }
        try self.sources.put(self.allocator, name, source);
    }

    /// Renders `entry` and its inheritance chain. The result is owned by
    /// the engine's allocator and cached: rendering the same entry twice
    /// returns the same bytes.
    pub fn render(self: *Engine, entry: []const u8) Error![]const u8 {
        self.diag = .{};
        if (self.rendered.get(entry)) |bytes| return bytes;

        const chain = try self.chainFor(entry);
        try self.validateOverrides(chain);

        const root = chain[0];
        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(self.allocator);
        try self.renderBody(root, 0, root.source, chain, null, 0, &out);

        const bytes = try out.toOwnedSlice(self.allocator);
        try self.rendered.put(self.allocator, entry, bytes);
        return bytes;
    }

    /// The entry's chain, root layout first, entry last.
    fn chainFor(self: *Engine, entry: []const u8) Error![]const *const Parsed {
        var chain: std.ArrayListUnmanaged(*const Parsed) = .empty;
        defer chain.deinit(self.allocator);

        var name = entry;
        while (true) {
            if (chain.items.len >= max_chain) {
                self.diagAt(entry, 0, "extend chain is deeper than {d}", .{max_chain});
                return error.TooDeep;
            }
            const parsed = try self.parse(name);
            try chain.append(self.allocator, parsed);

            const parent = parsed.parent orelse break;
            for (chain.items) |seen| {
                if (std.mem.eql(u8, seen.name, parent)) {
                    self.diagAt(parsed.name, 0, "extends cycle through '{s}'", .{parent});
                    return error.ExtendsCycle;
                }
            }
            name = parent;
        }

        std.mem.reverse(*const Parsed, chain.items);
        return chain.toOwnedSlice(self.allocator);
    }

    /// A top-level block in a non-root template must override a block that
    /// some ancestor defines; a typo would otherwise silently render
    /// nothing. New nested blocks are allowed (that is how a layout adds
    /// override points of its own).
    fn validateOverrides(self: *Engine, chain: []const *const Parsed) Error!void {
        for (chain, 0..) |parsed, i| {
            if (i == 0) continue;
            for (parsed.blocks) |block| {
                if (block.depth != 0) continue;
                var defined = false;
                for (chain[0..i]) |ancestor| {
                    for (ancestor.blocks) |candidate| {
                        if (std.mem.eql(u8, candidate.name, block.name)) {
                            defined = true;
                            break;
                        }
                    }
                    if (defined) break;
                }
                if (!defined) {
                    self.diagAt(parsed.name, block.line, "block '{s}' is not defined by any parent layout", .{block.name});
                    return error.UnknownBlock;
                }
            }
        }
    }

    fn parse(self: *Engine, name: []const u8) Error!*const Parsed {
        if (self.parsed.get(name)) |parsed| return parsed;
        const source = self.sources.get(name) orelse {
            self.diagAt(name, 0, "template '{s}' was not added", .{name});
            return error.UnknownTemplate;
        };
        const parsed = try self.parseSource(name, source);
        try self.parsed.put(self.allocator, name, parsed);
        return parsed;
    }

    fn parseSource(self: *Engine, name: []const u8, source: []const u8) Error!*const Parsed {
        const a = self.allocator;
        var blocks: std.ArrayListUnmanaged(Block) = .empty;
        var open: std.ArrayListUnmanaged(Open) = .empty;
        var parent: ?[]const u8 = null;
        var seen_tag = false;

        var pos: usize = 0;
        while (try self.nextTag(name, source, pos)) |tag| {
            if (tag.kind == .tag) {
                const d = directive(tag.content);
                const line = lineOf(source, tag.start);

                if (std.mem.eql(u8, d.word, "extends")) {
                    if (parent != null) {
                        self.diagAt(name, line, "only one extends is allowed", .{});
                        return error.DuplicateExtends;
                    }
                    if (seen_tag) {
                        self.diagAt(name, line, "extends must be the first tag in the template", .{});
                        return error.ExtendsNotFirst;
                    }
                    parent = try self.stringArg(name, line, d.arg);
                } else if (std.mem.eql(u8, d.word, "block")) {
                    if (!isIdent(d.arg)) {
                        self.diagAt(name, line, "block needs a name, found '{s}'", .{d.arg});
                        return error.InvalidTag;
                    }
                    for (blocks.items) |existing| {
                        if (std.mem.eql(u8, existing.name, d.arg)) {
                            self.diagAt(name, line, "block '{s}' is defined twice in one template", .{d.arg});
                            return error.DuplicateBlock;
                        }
                    }
                    try blocks.append(a, .{
                        .name = d.arg,
                        .line = line,
                        .depth = open.items.len,
                        .tag_start = tag.start,
                        .body_start = if (tag.trim_after) skipWs(source, tag.end) else tag.end,
                        .body_end = 0,
                        .after = 0,
                    });
                    try open.append(a, .{ .name = d.arg, .rec = blocks.items.len - 1 });
                } else if (std.mem.eql(u8, d.word, "endblock")) {
                    if (open.items.len == 0) {
                        self.diagAt(name, line, "endblock without a block", .{});
                        return error.UnexpectedEndblock;
                    }
                    const top = open.items[open.items.len - 1];
                    open.items.len -= 1;
                    if (d.arg.len > 0 and !std.mem.eql(u8, d.arg, top.name)) {
                        self.diagAt(name, line, "endblock '{s}' closes block '{s}'", .{ d.arg, top.name });
                        return error.MismatchedEndblock;
                    }
                    const rec = &blocks.items[top.rec];
                    rec.body_end = if (tag.trim_before) trimEndWs(source[0..tag.start]).len else tag.start;
                    if (rec.body_end < rec.body_start) rec.body_end = rec.body_start;
                    rec.after = if (tag.trim_after) skipWs(source, tag.end) else tag.end;
                } else if (std.mem.eql(u8, d.word, "include")) {
                    // Validated here so a malformed name fails even when the
                    // include sits in text the entry never renders.
                    _ = try self.stringArg(name, line, d.arg);
                } else {
                    self.diagAt(name, line, "unknown tag '{s}'", .{d.word});
                    return error.UnknownTag;
                }
            }
            seen_tag = true;
            pos = tag.end;
        }

        if (open.items.len > 0) {
            const top = open.items[open.items.len - 1];
            const rec = blocks.items[top.rec];
            self.diagAt(name, rec.line, "block '{s}' is never closed", .{rec.name});
            return error.UnclosedBlock;
        }

        const parsed = try a.create(Parsed);
        parsed.* = .{
            .name = name,
            .source = source,
            .parent = parent,
            .blocks = try blocks.toOwnedSlice(a),
        };
        return parsed;
    }

    fn renderBody(
        self: *Engine,
        parsed: *const Parsed,
        base: usize,
        body: []const u8,
        chain: []const *const Parsed,
        super_ref: ?SuperRef,
        include_depth: usize,
        out: *std.ArrayListUnmanaged(u8),
    ) Error!void {
        const a = self.allocator;
        var pos: usize = 0;

        while (try self.nextTag(parsed.name, body, pos)) |tag| {
            var text = body[pos..tag.start];
            if (tag.trim_before) text = trimEndWs(text);
            try out.appendSlice(a, text);
            pos = tag.end;

            // A block tag's trim-after is about the start of its default
            // body (already applied by the parser); after substituting an
            // override we continue at the endblock, not after the tag.
            var apply_trim_after = true;

            switch (tag.kind) {
                .expr => {
                    const line = lineOf(parsed.source, base + tag.start);
                    const expr = std.mem.trim(u8, tag.content, " \t\r\n");
                    if (!std.mem.eql(u8, expr, "super()")) {
                        self.diagAt(parsed.name, line, "only super() is allowed in an expression tag, found '{s}'", .{expr});
                        return error.InvalidTag;
                    }
                    const sr = super_ref orelse {
                        self.diagAt(parsed.name, line, "super() outside a block", .{});
                        return error.NoSuper;
                    };
                    if (sr.level == 0) {
                        self.diagAt(parsed.name, line, "block '{s}' has no parent body for super()", .{sr.name});
                        return error.NoSuper;
                    }
                    var buf: [max_chain]BodyRef = undefined;
                    const bodies = try self.bodiesFor(chain, sr.name, &buf);
                    const idx = sr.level - 1;
                    if (idx >= bodies.len) {
                        self.diagAt(parsed.name, line, "internal: super() level out of range", .{});
                        return error.Internal;
                    }
                    try self.renderBody(
                        bodies[idx].parsed,
                        bodies[idx].base,
                        bodies[idx].body,
                        chain,
                        .{ .name = sr.name, .level = idx },
                        include_depth,
                        out,
                    );
                },
                .tag => {
                    const d = directive(tag.content);
                    const line = lineOf(parsed.source, base + tag.start);

                    if (std.mem.eql(u8, d.word, "include")) {
                        const include_name = try self.stringArg(parsed.name, line, d.arg);
                        if (include_depth >= max_include_depth) {
                            self.diagAt(parsed.name, line, "include nesting is deeper than {d}", .{max_include_depth});
                            return error.IncludeCycle;
                        }
                        const included = try self.parse(include_name);
                        if (included.parent != null) {
                            self.diagAt(parsed.name, line, "included template '{s}' itself extends a layout", .{include_name});
                            return error.IncludeExtends;
                        }
                        for (self.include_stack.items) |open_name| {
                            if (std.mem.eql(u8, open_name, include_name)) {
                                self.diagAt(parsed.name, line, "include cycle through '{s}'", .{include_name});
                                return error.IncludeCycle;
                            }
                        }
                        try self.include_stack.append(a, include_name);
                        defer _ = self.include_stack.pop();
                        const one = [_]*const Parsed{included};
                        try self.renderBody(included, 0, included.source, &one, null, include_depth + 1, out);
                    } else if (std.mem.eql(u8, d.word, "block")) {
                        if (!isIdent(d.arg)) {
                            self.diagAt(parsed.name, line, "block needs a name, found '{s}'", .{d.arg});
                            return error.InvalidTag;
                        }
                        const rec = findBlock(parsed, base + tag.start) orelse {
                            self.diagAt(parsed.name, line, "internal: block was not indexed", .{});
                            return error.Internal;
                        };
                        var buf: [max_chain]BodyRef = undefined;
                        const bodies = try self.bodiesFor(chain, d.arg, &buf);
                        if (bodies.len == 0) {
                            self.diagAt(parsed.name, line, "no definition for block '{s}'", .{d.arg});
                            return error.UnknownBlock;
                        }
                        const last = bodies[bodies.len - 1];
                        try self.renderBody(
                            last.parsed,
                            last.base,
                            last.body,
                            chain,
                            .{ .name = d.arg, .level = bodies.len - 1 },
                            include_depth,
                            out,
                        );
                        pos = rec.after - base;
                        apply_trim_after = false;
                    } else if (std.mem.eql(u8, d.word, "endblock")) {
                        self.diagAt(parsed.name, line, "unexpected endblock", .{});
                        return error.UnexpectedEndblock;
                    } else if (std.mem.eql(u8, d.word, "extends")) {
                        // Extends is stripped from rendered layouts; only a
                        // root (which has no parent) is rendered, so this is
                        // a template that was included or mis-nested.
                        self.diagAt(parsed.name, line, "unexpected extends", .{});
                        return error.InvalidTag;
                    } else {
                        self.diagAt(parsed.name, line, "unknown tag '{s}'", .{d.word});
                        return error.UnknownTag;
                    }
                },
            }

            if (apply_trim_after and tag.trim_after) pos = skipWs(body, pos);
        }

        try out.appendSlice(a, body[pos..]);
    }

    /// All definitions of `block_name`, root first, most-derived last.
    fn bodiesFor(self: *Engine, chain: []const *const Parsed, block_name: []const u8, out: []BodyRef) Error![]const BodyRef {
        var n: usize = 0;
        for (chain) |parsed| {
            for (parsed.blocks) |block| {
                if (!std.mem.eql(u8, block.name, block_name)) continue;
                if (n == out.len) {
                    self.diagAt(parsed.name, block.line, "too many definitions for block '{s}'", .{block_name});
                    return error.TooDeep;
                }
                const start = @min(block.body_start, block.body_end);
                out[n] = .{ .parsed = parsed, .base = start, .body = parsed.source[start..block.body_end] };
                n += 1;
            }
        }
        return out[0..n];
    }

    fn nextTag(self: *Engine, name: []const u8, source: []const u8, from: usize) Error!?Tag {
        if (from >= source.len) return null;

        const tag_at = std.mem.indexOfPos(u8, source, from, "{%");
        const expr_at = std.mem.indexOfPos(u8, source, from, "{{");

        var start: usize = undefined;
        var kind: Kind = undefined;
        if (tag_at) |t| {
            if (expr_at) |e| {
                if (e < t) {
                    start = e;
                    kind = .expr;
                } else {
                    start = t;
                    kind = .tag;
                }
            } else {
                start = t;
                kind = .tag;
            }
        } else if (expr_at) |e| {
            start = e;
            kind = .expr;
        } else {
            return null;
        }

        var content_start = start + 2;
        var trim_before = false;
        if (content_start < source.len and source[content_start] == '-') {
            trim_before = true;
            content_start += 1;
        }

        const closer = if (kind == .tag) "%}" else "}}";
        const close_at = std.mem.indexOfPos(u8, source, content_start, closer) orelse {
            self.diagAt(name, lineOf(source, start), "unclosed '{s}'", .{closer});
            return error.UnclosedTag;
        };

        var content_end = close_at;
        var trim_after = false;
        if (content_end > content_start and source[content_end - 1] == '-') {
            trim_after = true;
            content_end -= 1;
        }

        return Tag{
            .kind = kind,
            .content = source[content_start..content_end],
            .start = start,
            .end = close_at + 2,
            .trim_before = trim_before,
            .trim_after = trim_after,
        };
    }

    fn stringArg(self: *Engine, name: []const u8, line: usize, arg: []const u8) Error![]const u8 {
        const trimmed = std.mem.trim(u8, arg, " \t\r\n");
        if (trimmed.len < 2) {
            self.diagAt(name, line, "expected a quoted template name", .{});
            return error.InvalidTag;
        }
        const quote = trimmed[0];
        if ((quote != '"' and quote != '\'') or trimmed[trimmed.len - 1] != quote) {
            self.diagAt(name, line, "expected a quoted template name", .{});
            return error.InvalidTag;
        }
        const inner = trimmed[1 .. trimmed.len - 1];
        if (std.mem.indexOfScalar(u8, inner, quote) != null) {
            self.diagAt(name, line, "template name contains its own quote", .{});
            return error.InvalidTag;
        }
        return inner;
    }

    fn diagAt(self: *Engine, name: []const u8, line: usize, comptime fmt: []const u8, args: anytype) void {
        self.diag = .{
            .template = name,
            .line = line,
            .message = std.fmt.allocPrint(self.allocator, fmt, args) catch "",
        };
    }
};

fn directive(content: []const u8) Directive {
    const trimmed = std.mem.trim(u8, content, " \t\r\n");
    if (trimmed.len == 0) return .{ .word = "", .arg = "" };
    var i: usize = 0;
    while (i < trimmed.len and !std.ascii.isWhitespace(trimmed[i])) i += 1;
    return .{
        .word = trimmed[0..i],
        .arg = std.mem.trim(u8, trimmed[i..], " \t\r\n"),
    };
}

fn isIdent(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '-') return false;
    }
    return true;
}

fn findBlock(parsed: *const Parsed, tag_start: usize) ?Block {
    for (parsed.blocks) |block| {
        if (block.tag_start == tag_start) return block;
    }
    return null;
}

fn lineOf(source: []const u8, offset: usize) usize {
    var line: usize = 1;
    for (source[0..@min(offset, source.len)]) |c| {
        if (c == '\n') line += 1;
    }
    return line;
}

fn trimEndWs(text: []const u8) []const u8 {
    var end = text.len;
    while (end > 0 and std.ascii.isWhitespace(text[end - 1])) end -= 1;
    return text[0..end];
}

fn skipWs(source: []const u8, from: usize) usize {
    var i = from;
    while (i < source.len and std.ascii.isWhitespace(source[i])) i += 1;
    return i;
}

// --- tests ---------------------------------------------------------------
//
// The engine is pure (no I/O, no clock), so the tests render in-memory
// templates. Each test names the behaviour a page layout relies on.

const testing = std.testing;

const Source = struct { name: []const u8, source: []const u8 };

fn expectRender(expected: []const u8, sources: []const Source, entry: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var engine = Engine.init(arena.allocator());
    for (sources) |source| try engine.add(source.name, source.source);
    const out = try engine.render(entry);
    try testing.expectEqualStrings(expected, out);
}

fn expectError(expected: Error, sources: []const Source, entry: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var engine = Engine.init(arena.allocator());
    for (sources) |source| try engine.add(source.name, source.source);
    try testing.expectError(expected, engine.render(entry));
}

test "layout: a child overrides the shell's blocks" {
    try expectRender(
        "<title>child</title>\n<p>hi</p>",
        &.{
            .{ .name = "base.html", .source = "<title>{% block title %}base{% endblock %}</title>\n{% block body %}{% endblock %}" },
            .{ .name = "child.html", .source = "{% extends \"base.html\" %}\n{% block title %}child{% endblock %}\n{% block body %}<p>hi</p>{% endblock %}" },
        },
        "child.html",
    );
}

test "layout: three levels and super()" {
    try expectRender(
        "leaf(mid(base))",
        &.{
            .{ .name = "base.html", .source = "{% block body %}base{% endblock %}" },
            .{ .name = "mid.html", .source = "{% extends \"base.html\" %}{% block body %}mid({{ super() }}){% endblock %}" },
            .{ .name = "leaf.html", .source = "{% extends \"mid.html\" %}{% block body %}leaf({{ super() }}){% endblock %}" },
        },
        "leaf.html",
    );
}

test "layout: a child can override a nested block" {
    try expectRender(
        "[child-inner]-tail",
        &.{
            .{ .name = "base.html", .source = "{% block outer %}[{% block inner %}base-inner{% endblock %}]{% endblock %}-{% block tail %}tail{% endblock %}" },
            .{ .name = "child.html", .source = "{% extends \"base.html\" %}{% block inner %}child-inner{% endblock %}" },
        },
        "child.html",
    );
}

test "layout: include splices a partial" {
    try expectRender(
        "<main><em>p</em></main>",
        &.{
            .{ .name = "base.html", .source = "<main>{% include \"partial.html\" %}</main>" },
            .{ .name = "partial.html", .source = "<em>{% block x %}p{% endblock %}</em>" },
        },
        "base.html",
    );
}

test "layout: trim markers control the whitespace" {
    try expectRender(
        "aXb",
        &.{.{ .name = "t.html", .source = "a \n{%- block x -%}\nX\n{%- endblock -%}\n b" }},
        "t.html",
    );
}

test "layout: an include cycle is an error" {
    try expectError(error.IncludeCycle, &.{
        .{ .name = "a.html", .source = "{% include \"b.html\" %}" },
        .{ .name = "b.html", .source = "{% include \"a.html\" %}" },
    }, "a.html");
}

test "layout: an included template cannot extend a layout" {
    try expectError(error.IncludeExtends, &.{
        .{ .name = "a.html", .source = "{% include \"b.html\" %}" },
        .{ .name = "b.html", .source = "{% extends \"a.html\" %}" },
    }, "a.html");
}

test "layout: extends must be the first tag" {
    try expectError(error.ExtendsNotFirst, &.{
        .{ .name = "base.html", .source = "{% block b %}{% endblock %}" },
        .{ .name = "child.html", .source = "{% block b %}{% endblock %}{% extends \"base.html\" %}" },
    }, "child.html");
}

test "layout: unknown parent names the template" {
    try expectError(error.UnknownTemplate, &.{
        .{ .name = "child.html", .source = "{% extends \"missing.html\" %}" },
    }, "child.html");
}

test "layout: an unclosed block reports its line" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var engine = Engine.init(arena.allocator());
    try engine.add("t.html", "line one\n{% block body %}\nnever closed");
    try testing.expectError(error.UnclosedBlock, engine.render("t.html"));
    try testing.expectEqual(@as(usize, 2), engine.diag.line);
    try testing.expectEqualStrings("body", engine.diag.message[7 .. 7 + 4]);
}

test "layout: overriding an undefined block is an error" {
    try expectError(error.UnknownBlock, &.{
        .{ .name = "base.html", .source = "{% block body %}{% endblock %}" },
        .{ .name = "child.html", .source = "{% extends \"base.html\" %}{% block typo %}{% endblock %}" },
    }, "child.html");
}

test "layout: super() outside a block is an error" {
    try expectError(error.NoSuper, &.{
        .{ .name = "t.html", .source = "{{ super() }}" },
    }, "t.html");
}

test "layout: duplicate blocks and mismatched endblock are errors" {
    try expectError(error.DuplicateBlock, &.{
        .{ .name = "t.html", .source = "{% block x %}{% endblock %}{% block x %}{% endblock %}" },
    }, "t.html");
    try expectError(error.MismatchedEndblock, &.{
        .{ .name = "t.html", .source = "{% block x %}{% endblock y %}" },
    }, "t.html");
}

test "layout: unknown and malformed tags are errors" {
    try expectError(error.UnknownTag, &.{
        .{ .name = "t.html", .source = "{% frobnicate %}" },
    }, "t.html");
    try expectError(error.UnclosedTag, &.{
        .{ .name = "t.html", .source = "{% block body" },
    }, "t.html");
    try expectError(error.InvalidTag, &.{
        .{ .name = "t.html", .source = "{{ 1 + 1 }}" },
    }, "t.html");
}

test "layout: an extends cycle is caught" {
    try expectError(error.ExtendsCycle, &.{
        .{ .name = "a.html", .source = "{% extends \"b.html\" %}" },
        .{ .name = "b.html", .source = "{% extends \"a.html\" %}" },
    }, "a.html");
}

test "layout: renders are cached" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var engine = Engine.init(arena.allocator());
    try engine.add("t.html", "<p>{% block x %}one{% endblock %}</p>");
    const first = try engine.render("t.html");
    const second = try engine.render("t.html");
    try testing.expectEqualStrings("<p>one</p>", first);
    try testing.expectEqual(first.ptr, second.ptr);
}
