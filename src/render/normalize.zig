const std = @import("std");
const Allocator = std.mem.Allocator;
const entities = @import("entities");

const TokenKind = enum { text, tag };
const Token = struct {
    kind: TokenKind,
    slice: []const u8,
};

const Attr = struct {
    name: []const u8,
    value: ?[]const u8,
};

/// Elements whose textual content must preserve whitespace exactly.
const pre_elements = std.StaticStringMap(void).initComptime(.{
    .{ "pre", {} },
    .{ "code", {} },
    .{ "script", {} },
    .{ "style", {} },
});

/// Normalize an HTML fragment so that semantically-equivalent inputs compare
/// equal. Mirrors the behavior of commonmark-spec's `normalize.py`.
pub fn normalize(gpa: Allocator, html: []const u8) Allocator.Error![]u8 {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var tokens: std.ArrayList(Token) = .empty;
    try tokenize(a, html, &tokens);

    var out: std.ArrayList(u8) = .empty;
    var pre_depth: usize = 0;

    for (tokens.items) |tok| {
        if (tok.kind == .text) {
            if (pre_depth > 0) {
                try out.appendSlice(a, tok.slice);
            } else {
                try processText(a, &out, tok.slice);
            }
        } else {
            try processTag(a, &out, tok.slice, &pre_depth);
        }
    }

    // Strip leading/trailing whitespace — the CommonMark normalize.py does
    // the same so that a renderer's trailing newline doesn't cause a mismatch
    // against fixture HTML that omits it.
    const trimmed = std.mem.trim(u8, out.items, " \t\r\n\x0c");
    return try gpa.dupe(u8, trimmed);
}

fn tokenize(a: Allocator, html: []const u8, tokens: *std.ArrayList(Token)) Allocator.Error!void {
    const n = html.len;
    var i: usize = 0;
    var text_start: usize = 0;
    while (i < n) {
        if (html[i] == '<') {
            if (i > text_start) {
                try tokens.append(a, .{ .kind = .text, .slice = html[text_start..i] });
            }
            const end_opt = findTagEnd(html, i);
            const tag_end = if (end_opt) |e| e + 1 else n;
            try tokens.append(a, .{ .kind = .tag, .slice = html[i..tag_end] });
            i = tag_end;
            text_start = i;
        } else {
            i += 1;
        }
    }
    if (text_start < n) {
        try tokens.append(a, .{ .kind = .text, .slice = html[text_start..n] });
    }
}

/// Given the index of a `<`, return the index of the matching `>` for the
/// construct that begins there, respecting quoted attribute values. Returns
/// null when no terminator is present.
fn findTagEnd(html: []const u8, lt: usize) ?usize {
    const n = html.len;
    if (std.mem.startsWith(u8, html[lt..], "<!--")) {
        if (std.mem.indexOfPos(u8, html, lt + 4, "-->")) |p| return p + 2;
        return null;
    }
    if (std.mem.startsWith(u8, html[lt..], "<![CDATA[")) {
        if (std.mem.indexOfPos(u8, html, lt + 9, "]]>")) |p| return p + 2;
        return null;
    }
    if (std.mem.startsWith(u8, html[lt..], "<!") or std.mem.startsWith(u8, html[lt..], "<?")) {
        if (std.mem.indexOfScalarPos(u8, html, lt + 2, '>')) |p| return p;
        return null;
    }
    var i: usize = lt + 1;
    while (i < n) {
        const c = html[i];
        if (c == '"' or c == '\'') {
            if (std.mem.indexOfScalarPos(u8, html, i + 1, c)) |p| {
                i = p + 1;
            } else {
                return null;
            }
        } else if (c == '>') {
            return i;
        } else {
            i += 1;
        }
    }
    return null;
}

fn processTag(a: Allocator, out: *std.ArrayList(u8), raw: []const u8, pre_depth: *usize) Allocator.Error!void {
    // Comments, declarations, CDATA and processing instructions pass through.
    if (std.mem.startsWith(u8, raw, "<!--") or
        std.mem.startsWith(u8, raw, "<![CDATA[") or
        std.mem.startsWith(u8, raw, "<!") or
        std.mem.startsWith(u8, raw, "<?"))
    {
        try out.appendSlice(a, raw);
        return;
    }

    if (raw.len < 2) {
        try out.appendSlice(a, raw);
        return;
    }

    const inner = raw[1 .. raw.len - 1];
    const trimmed = std.mem.trim(u8, inner, " \t\r\n\x0c");
    if (trimmed.len == 0) {
        try out.appendSlice(a, raw);
        return;
    }

    if (trimmed[0] == '/') {
        const name = std.mem.trim(u8, trimmed[1..], " \t\r\n\x0c");
        const lname = try toLower(a, name);
        if (pre_elements.has(lname)) {
            if (pre_depth.* > 0) pre_depth.* -= 1;
        }
        try out.append(a, '<');
        try out.append(a, '/');
        try out.appendSlice(a, lname);
        try out.append(a, '>');
        return;
    }

    const self_closing = trimmed[trimmed.len - 1] == '/';
    const body = if (self_closing)
        std.mem.trim(u8, trimmed[0 .. trimmed.len - 1], " \t\r\n\x0c")
    else
        trimmed;

    try serializeOpenTag(a, out, body, self_closing, pre_depth);
}

fn serializeOpenTag(
    a: Allocator,
    out: *std.ArrayList(u8),
    body: []const u8,
    self_closing: bool,
    pre_depth: *usize,
) Allocator.Error!void {
    var i: usize = 0;
    while (i < body.len and !isWs(body[i]) and body[i] != '/') : (i += 1) {}
    const lname = try toLower(a, body[0..i]);

    var attrs: std.ArrayList(Attr) = .empty;
    while (true) {
        while (i < body.len and isWs(body[i])) : (i += 1) {}
        if (i >= body.len or body[i] == '/') break;

        const an_start = i;
        while (i < body.len and !isWs(body[i]) and body[i] != '=' and body[i] != '/') : (i += 1) {}
        if (i == an_start) {
            i += 1;
            continue;
        }
        const aname = try toLower(a, body[an_start..i]);

        while (i < body.len and isWs(body[i])) : (i += 1) {}
        var value: ?[]const u8 = null;
        if (i < body.len and body[i] == '=') {
            i += 1;
            while (i < body.len and isWs(body[i])) : (i += 1) {}
            if (i < body.len and (body[i] == '"' or body[i] == '\'')) {
                const q = body[i];
                i += 1;
                const v_start = i;
                while (i < body.len and body[i] != q) : (i += 1) {}
                value = body[v_start..i];
                if (i < body.len) i += 1;
            } else {
                const v_start = i;
                while (i < body.len and !isWs(body[i]) and body[i] != '/') : (i += 1) {}
                value = body[v_start..i];
            }
        }
        try attrs.append(a, .{ .name = aname, .value = value });
    }

    std.sort.block(Attr, attrs.items, {}, attrLess);

    try out.append(a, '<');
    try out.appendSlice(a, lname);
    for (attrs.items) |at| {
        try out.append(a, ' ');
        try out.appendSlice(a, at.name);
        if (at.value) |v| {
            try out.append(a, '=');
            try out.append(a, '"');
            try out.appendSlice(a, v);
            try out.append(a, '"');
        }
    }
    if (self_closing) {
        try out.append(a, ' ');
        try out.append(a, '/');
    }
    try out.append(a, '>');

    if (!self_closing and pre_elements.has(lname)) {
        pre_depth.* += 1;
    }
}

fn processText(a: Allocator, out: *std.ArrayList(u8), text: []const u8) Allocator.Error!void {
    const n = text.len;
    var i: usize = 0;
    while (i < n) {
        const c = text[i];
        if (c == '&') {
            if (try decodeEntityAt(a, out, text, i)) |newi| {
                i = newi;
                continue;
            }
            try out.appendSlice(a, "&amp;");
            i += 1;
            continue;
        }
        if (isWs(c)) {
            try out.append(a, ' ');
            while (i < n and isWs(text[i])) : (i += 1) {}
            continue;
        }
        if (c == '<') {
            try out.appendSlice(a, "&lt;");
        } else if (c == '>') {
            try out.appendSlice(a, "&gt;");
        } else {
            try out.append(a, c);
        }
        i += 1;
    }
}

/// Attempt to decode a character reference beginning at `text[start]` (which is
/// `&`). On success the decoded codepoint is written (re-encoded) to `out` and
/// the index past the terminating `;` is returned. Returns null when the text
/// at this position is not a recognized reference.
fn decodeEntityAt(a: Allocator, out: *std.ArrayList(u8), text: []const u8, start: usize) Allocator.Error!?usize {
    const n = text.len;
    var scan: usize = start + 1;
    if (scan >= n) return null;

    var semi: ?usize = null;
    var steps: usize = 0;
    while (scan < n and steps < 32) : (steps += 1) {
        const c = text[scan];
        if (c == ';') {
            semi = scan;
            break;
        }
        if (isWs(c)) break;
        scan += 1;
    }
    const s = semi orelse return null;
    if (s == start + 1) return null;

    const name = text[start + 1 .. s];
    if (name[0] != '#') {
        const decoded = entities.named_entities.get(name) orelse return null;
        try writeReencoded(a, out, decoded);
        return s + 1;
    }

    if (name.len == 1) return null;
    const cp: u21 = if (name.len >= 2 and (name[1] == 'x' or name[1] == 'X'))
        std.fmt.parseInt(u21, name[2..], 16) catch return null
    else
        std.fmt.parseInt(u21, name[1..], 10) catch return null;
    if (cp > 0x10FFFF or (cp >= 0xD800 and cp <= 0xDFFF)) return null;

    var buf: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(cp, &buf) catch return null;
    try writeReencoded(a, out, buf[0..len]);
    return s + 1;
}

/// Writes decoded entity text back out, re-escaping the three characters that
/// must stay as references in HTML text.
fn writeReencoded(a: Allocator, out: *std.ArrayList(u8), decoded: []const u8) Allocator.Error!void {
    for (decoded) |c| switch (c) {
        '&' => try out.appendSlice(a, "&amp;"),
        '<' => try out.appendSlice(a, "&lt;"),
        '>' => try out.appendSlice(a, "&gt;"),
        else => try out.append(a, c),
    };
}

fn toLower(a: Allocator, src: []const u8) Allocator.Error![]u8 {
    const dst = try a.alloc(u8, src.len);
    for (src, 0..) |c, j| dst[j] = std.ascii.toLower(c);
    return dst;
}

fn isWs(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0c;
}

fn attrLess(_: void, x: Attr, y: Attr) bool {
    return std.mem.lessThan(u8, x.name, y.name);
}
