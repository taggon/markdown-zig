const std = @import("std");
const Allocator = std.mem.Allocator;
const chars = @import("../chars.zig");
const ParseError = @import("../root.zig").ParseError;

const tabWidthAt = chars.tabWidthAt;

// ─── Utility ─────────────────────────────────────────────────────────

pub fn isBlank(s: []const u8) bool {
    for (s) |c| {
        if (!chars.isLineWs(c)) return false;
    }
    return true;
}

pub fn trimWs(s: []const u8) []const u8 {
    var start: usize = 0;
    while (start < s.len and chars.isWsByte(s[start])) : (start += 1) {}
    var end: usize = s.len;
    while (end > start and chars.isWsByte(s[end - 1])) : (end -= 1) {}
    return s[start..end];
}

pub const IndentResult = struct { content: []const u8, cols_removed: usize };

pub fn padWith(arena: Allocator, n: usize, rest: []const u8) ParseError![]const u8 {
    if (n == 0) return rest;
    const out = try arena.alloc(u8, n + rest.len);
    @memset(out[0..n], ' ');
    @memcpy(out[n..], rest);
    return out;
}

/// Filters GFM disallowed raw HTML tags in block content: replaces the `<` of
/// each disallowed tag (case-insensitive) with `&lt;`. If no disallowed tags
/// are found, returns the original slice unchanged.
pub fn filterDisallowedHtml(arena: Allocator, html: []const u8) ParseError![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(arena);

    // Nothing is copied until the first disallowed tag turns up, and that is
    // the overwhelmingly common case — building a full copy only to throw it
    // away costs the whole block.
    var i: usize = 0;
    var plain_start: usize = 0;
    while (i < html.len) {
        if (html[i] == '<' and i + 1 < html.len) {
            if (chars.extractHtmlTagName(html[i..])) |tag| {
                if (chars.isDisallowedHtmlTag(tag)) {
                    try out.appendSlice(arena, html[plain_start..i]);
                    try out.appendSlice(arena, "&lt;");
                    i += 1;
                    plain_start = i;
                    continue;
                }
            }
        }
        i += 1;
    }

    if (plain_start == 0) return try arena.dupe(u8, html);
    try out.appendSlice(arena, html[plain_start..]);
    return out.toOwnedSlice(arena);
}

// ─── Fenced code ─────────────────────────────────────────────────────

pub const FenceInfo = struct {
    fence_char: u8,
    open_len: usize,
    open_indent: usize,
    info: []const u8,
};

pub fn isFencedCodeOpening(line: []const u8) ?FenceInfo {
    var i = chars.skipUpTo3Cols(line);
    const open_indent = i;
    if (i >= line.len) return null;

    const fence_char = line[i];
    if (fence_char != '`' and fence_char != '~') return null;

    var open_len: usize = 0;
    while (i < line.len and line[i] == fence_char) : (i += 1) {
        open_len += 1;
    }
    if (open_len < 3) return null;

    const info = line[i..];
    if (fence_char == '`') {
        for (info) |c| {
            if (c == '`') return null;
        }
    }

    return .{ .fence_char = fence_char, .open_len = open_len, .open_indent = open_indent, .info = info };
}

// ─── ATX heading ─────────────────────────────────────────────────────

pub const AtxInfo = struct { depth: u8, content: []const u8 };

pub fn atxInfo(line: []const u8) ?AtxInfo {
    var i = chars.skipUpTo3Cols(line);
    if (i >= line.len or line[i] != '#') return null;

    var count: usize = 0;
    while (i < line.len and line[i] == '#') : (i += 1) {
        count += 1;
    }
    if (count < 1 or count > 6) return null;

    if (i < line.len and line[i] != ' ' and line[i] != '\t') return null;

    const content = atxContent(line[i..]);
    return .{ .depth = @intCast(count), .content = content };
}

pub fn atxContent(raw: []const u8) []const u8 {
    var end = raw.len;
    while (end > 0 and chars.isWsByte(raw[end - 1])) : (end -= 1) {}

    var hash_count: usize = 0;
    var j = end;
    while (j > 0 and raw[j - 1] == '#') : (j -= 1) {
        hash_count += 1;
    }
    var new_end = end;
    if (hash_count > 0) {
        if (j == 0 or chars.isWsByte(raw[j - 1])) {
            new_end = j;
            while (new_end > 0 and chars.isWsByte(raw[new_end - 1])) : (new_end -= 1) {}
        }
    }

    var start: usize = 0;
    while (start < new_end and chars.isWsByte(raw[start])) : (start += 1) {}

    return raw[start..new_end];
}

// ─── Setext heading ──────────────────────────────────────────────────

pub fn isSetextUnderline(line: []const u8) ?u8 {
    var i = chars.skipUpTo3Cols(line);
    if (i >= line.len) return null;

    const c = line[i];
    if (c != '=' and c != '-') return null;

    while (i < line.len and line[i] == c) : (i += 1) {}
    while (i < line.len) : (i += 1) {
        if (line[i] != ' ' and line[i] != '\t') return null;
    }

    return if (c == '=') @as(u8, 1) else @as(u8, 2);
}

// ─── Thematic break ──────────────────────────────────────────────────

pub fn isThematicBreak(line: []const u8) bool {
    var i = chars.skipUpTo3Cols(line);
    if (i >= line.len) return false;

    const c = line[i];
    if (c != '*' and c != '-' and c != '_') return false;

    var count: usize = 0;
    while (i < line.len) : (i += 1) {
        if (line[i] == c) {
            count += 1;
        } else if (line[i] == ' ' or line[i] == '\t') {} else {
            return false;
        }
    }
    return count >= 3;
}

// ─── List marker parsing ─────────────────────────────────────────────

pub const ListMarkerInfo = struct {
    ordered: bool,
    bullet_char: u8,
    start: usize,
    delimiter: u8,
    marker_byte_start: usize,
    marker_byte_len: usize,
    content_byte_start: usize,
    content_indent: usize,
    leading_col: usize,
};

pub fn canListMarkerInterruptParagraph(line: []const u8, base_col: usize) bool {
    const mi = parseListMarker(line, base_col) orelse return false;
    if (mi.leading_col > 3) return false;
    if (mi.ordered and mi.start != 1) return false;
    const after_marker = mi.marker_byte_start + mi.marker_byte_len;
    if (after_marker >= line.len) return false;
    return line[after_marker] == ' ' or line[after_marker] == '\t';
}

pub fn parseListMarker(line: []const u8, base_col: usize) ?ListMarkerInfo {
    var i: usize = 0;
    var col: usize = base_col;
    while (i < line.len) {
        if (line[i] == ' ') {
            col += 1;
            i += 1;
        } else if (line[i] == '\t') {
            col += tabWidthAt(col);
            i += 1;
        } else break;
    }
    if (i >= line.len) return null;
    if (col - base_col > 3) return null;

    const marker_col = col - base_col;
    const marker_byte_start = i;

    // Bullet marker
    if (line[i] == '-' or line[i] == '+' or line[i] == '*') {
        const bc = line[i];
        i += 1;
        if (i < line.len and line[i] != ' ' and line[i] != '\t') return null;

        var after_col = col + 1;
        while (i < line.len and (line[i] == ' ' or line[i] == '\t')) {
            if (line[i] == ' ') after_col += 1 else after_col += tabWidthAt(after_col);
            i += 1;
        }
        const ws_cols = after_col - (col + 1);
        const content_indent = if (i >= line.len or ws_cols > 4)
            marker_col + 2
        else
            after_col - base_col;

        return .{
            .ordered = false,
            .bullet_char = bc,
            .start = 0,
            .delimiter = 0,
            .marker_byte_start = marker_byte_start,
            .marker_byte_len = 1,
            .content_byte_start = i,
            .content_indent = content_indent,
            .leading_col = marker_col,
        };
    }

    // Ordered marker: digits + '.' or ')'
    if (std.ascii.isDigit(line[i])) {
        const ord_marker_start = i;
        var num: usize = 0;
        var digit_count: usize = 0;
        while (i < line.len and std.ascii.isDigit(line[i])) {
            num = num * 10 + (line[i] - '0');
            digit_count += 1;
            i += 1;
        }
        if (digit_count > 9) return null;
        if (i >= line.len) return null;
        const delim = line[i];
        if (delim != '.' and delim != ')') return null;
        i += 1;
        if (i < line.len and line[i] != ' ' and line[i] != '\t') return null;

        const marker_byte_len = i - ord_marker_start;
        var after_col = col + marker_byte_len;
        while (i < line.len and (line[i] == ' ' or line[i] == '\t')) {
            if (line[i] == ' ') after_col += 1 else after_col += tabWidthAt(after_col);
            i += 1;
        }
        const ws_cols = after_col - (col + marker_byte_len);
        const content_indent = if (i >= line.len or ws_cols > 4)
            marker_col + marker_byte_len + 1
        else
            after_col - base_col;

        return .{
            .ordered = true,
            .bullet_char = 0,
            .start = num,
            .delimiter = delim,
            .marker_byte_start = ord_marker_start,
            .marker_byte_len = marker_byte_len,
            .content_byte_start = i,
            .content_indent = content_indent,
            .leading_col = marker_col,
        };
    }

    return null;
}

// ─── HTML block detection ────────────────────────────────────────────

pub const block_tag_names = std.StaticStringMap(void).initComptime(.{
    .{ "address", {} },  .{ "article", {} },    .{ "aside", {} },
    .{ "base", {} },     .{ "basefont", {} },   .{ "blockquote", {} },
    .{ "body", {} },     .{ "caption", {} },    .{ "center", {} },
    .{ "col", {} },      .{ "colgroup", {} },   .{ "dd", {} },
    .{ "details", {} },  .{ "dialog", {} },     .{ "dir", {} },
    .{ "div", {} },      .{ "dl", {} },         .{ "dt", {} },
    .{ "fieldset", {} }, .{ "figcaption", {} }, .{ "figure", {} },
    .{ "footer", {} },   .{ "form", {} },       .{ "frame", {} },
    .{ "frameset", {} }, .{ "h1", {} },         .{ "h2", {} },
    .{ "h3", {} },       .{ "h4", {} },         .{ "h5", {} },
    .{ "h6", {} },       .{ "head", {} },       .{ "header", {} },
    .{ "hr", {} },       .{ "html", {} },       .{ "iframe", {} },
    .{ "legend", {} },   .{ "li", {} },         .{ "link", {} },
    .{ "main", {} },     .{ "menu", {} },       .{ "menuitem", {} },
    .{ "nav", {} },      .{ "noframes", {} },   .{ "ol", {} },
    .{ "optgroup", {} }, .{ "option", {} },     .{ "p", {} },
    .{ "param", {} },    .{ "search", {} },     .{ "section", {} },
    .{ "summary", {} },  .{ "table", {} },      .{ "tbody", {} },
    .{ "td", {} },       .{ "tfoot", {} },      .{ "th", {} },
    .{ "thead", {} },    .{ "title", {} },      .{ "tr", {} },
    .{ "track", {} },    .{ "ul", {} },
});

pub fn startsWithCi(s: []const u8, prefix: []const u8) bool {
    if (s.len < prefix.len) return false;
    return std.ascii.eqlIgnoreCase(s[0..prefix.len], prefix);
}

pub fn containsCi(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var match = true;
        for (needle, 0..) |c, j| {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(c)) {
                match = false;
                break;
            }
        }
        if (match) return true;
    }
    return false;
}

pub fn htmlBlockType(line: []const u8) ?u8 {
    const i = chars.skipUpTo3Cols(line);
    if (i >= line.len) return null;
    if (line[i] != '<') return null;

    if (startsWithCi(line[i..], "<script")) return 1;
    if (startsWithCi(line[i..], "<pre")) return 1;
    if (startsWithCi(line[i..], "<style")) return 1;
    if (startsWithCi(line[i..], "<textarea")) return 1;
    if (std.mem.startsWith(u8, line[i..], "<!--")) return 2;
    if (i + 1 < line.len and line[i + 1] == '?') return 3;
    if (i + 2 < line.len and line[i + 1] == '!' and (line[i + 2] >= 'A' and line[i + 2] <= 'Z')) return 4;
    if (startsWithCi(line[i..], "<![CDATA[")) return 5;
    if (checkHtmlBlockType6(line, i)) return 6;
    if (checkHtmlBlockType7(line, i)) return 7;
    return null;
}

pub fn htmlBlockInterruptType(line: []const u8) ?u8 {
    const t = htmlBlockType(line) orelse return null;
    if (t <= 6) return t;
    return null;
}

fn checkHtmlBlockType6(line: []const u8, lt_pos: usize) bool {
    var pos = lt_pos + 1;
    if (pos >= line.len) return false;
    if (line[pos] == '/') pos += 1;
    if (pos >= line.len) return false;

    const name_start = pos;
    while (pos < line.len and (std.ascii.isAlphanumeric(line[pos]) or line[pos] == '-')) : (pos += 1) {}
    if (pos == name_start) return false;

    if (pos < line.len) {
        const c = line[pos];
        if (!chars.isWsByte(c) and c != '>') return false;
    }

    const name = line[name_start..pos];
    var buf: [32]u8 = undefined;
    if (name.len > buf.len) return false;
    for (name, 0..) |c, j| buf[j] = std.ascii.toLower(c);
    return block_tag_names.has(buf[0..name.len]);
}

fn checkHtmlBlockType7(line: []const u8, lt_pos: usize) bool {
    var pos = lt_pos + 1;
    if (pos >= line.len) return false;

    var is_closing = false;
    if (line[pos] == '/') {
        is_closing = true;
        pos += 1;
    }

    if (pos >= line.len or !std.ascii.isAlphabetic(line[pos])) return false;
    pos += 1;
    while (pos < line.len and (std.ascii.isAlphanumeric(line[pos]) or line[pos] == '-')) : (pos += 1) {}

    if (is_closing) {
        while (pos < line.len and chars.isWsByte(line[pos])) : (pos += 1) {}
        if (pos >= line.len or line[pos] != '>') return false;
        pos += 1;
    } else {
        if (pos >= line.len) return false;
        if (line[pos] == '>') {
            pos += 1;
        } else if (line[pos] == '/' and pos + 1 < line.len and line[pos + 1] == '>') {
            pos += 2;
        } else if (chars.isWsByte(line[pos])) {
            var found_gt = false;
            while (pos < line.len) {
                while (pos < line.len and chars.isWsByte(line[pos])) : (pos += 1) {}
                if (pos >= line.len) break;

                if (line[pos] == '>') {
                    pos += 1;
                    found_gt = true;
                    break;
                }
                if (line[pos] == '/') {
                    pos += 1;
                    if (pos < line.len and line[pos] == '>') {
                        pos += 1;
                        found_gt = true;
                    } else return false;
                    break;
                }

                if (!chars.isAttrNameChar(line[pos])) return false;
                while (pos < line.len and chars.isAttrNameChar(line[pos])) : (pos += 1) {}

                if (pos < line.len and line[pos] == '=') {
                    pos += 1;
                    while (pos < line.len and chars.isWsByte(line[pos])) : (pos += 1) {}
                    if (pos < line.len) {
                        if (line[pos] == '"' or line[pos] == '\'') {
                            const q = line[pos];
                            pos += 1;
                            while (pos < line.len and line[pos] != q) : (pos += 1) {}
                            if (pos >= line.len) return false;
                            pos += 1;
                        } else {
                            while (pos < line.len and !chars.isWsByte(line[pos]) and line[pos] != '>') : (pos += 1) {}
                        }
                    }
                }

                if (pos < line.len and !chars.isWsByte(line[pos]) and line[pos] != '>' and line[pos] != '/') {
                    return false;
                }
            }
            if (!found_gt) return false;
        } else {
            return false;
        }
    }

    while (pos < line.len and chars.isWsByte(line[pos])) : (pos += 1) {}
    return pos == line.len;
}

pub fn htmlBlockEndFound(t: u8, line: []const u8) bool {
    return switch (t) {
        1 => containsCi(line, "</script>") or containsCi(line, "</pre>") or
            containsCi(line, "</style>") or containsCi(line, "</textarea>"),
        2 => std.mem.indexOf(u8, line, "-->") != null,
        3 => std.mem.indexOf(u8, line, "?>") != null,
        4 => std.mem.indexOf(u8, line, ">") != null,
        5 => std.mem.indexOf(u8, line, "]]>") != null,
        else => false,
    };
}

// ─── Tests ───────────────────────────────────────────────────────────

test "two paragraphs separated by blank line" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const html = try @import("../root.zig").toHtml(a, "foo\n\nbar\n", .{}, .{});
    try std.testing.expectEqualStrings("<p>foo</p>\n<p>bar</p>\n", html);
}

test "single paragraph" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const html = try @import("../root.zig").toHtml(a, "hello world\n", .{}, .{});
    try std.testing.expectEqualStrings("<p>hello world</p>\n", html);
}

test "multi-line paragraph" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const html = try @import("../root.zig").toHtml(a, "line1\nline2\nline3\n", .{}, .{});
    try std.testing.expectEqualStrings("<p>line1\nline2\nline3</p>\n", html);
}

test "HTML escaping in text" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const html = try @import("../root.zig").toHtml(a, "a < b > c & d\n", .{}, .{});
    try std.testing.expectEqualStrings("<p>a &lt; b &gt; c &amp; d</p>\n", html);
}

test "--> is not an HTML block start condition (T3.1)" {
    const md = @import("../root.zig");
    const a = std.testing.allocator;

    {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const out = try md.toHtml(arena.allocator(), "-->", .{}, .{});
        try std.testing.expect(std.mem.indexOf(u8, out, "<p>") != null);
    }
    {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const out = try md.toHtml(arena.allocator(), "a\n-->", .{}, .{});
        try std.testing.expect(std.mem.indexOf(u8, out, "--&gt;") != null);
    }
}

test "comment block ends only with --> not </pre> (T3.2)" {
    const md = @import("../root.zig");
    const a = std.testing.allocator;

    {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const src = "<!-- a\n</pre>\nb\n-->";
        const out = try md.toHtml(arena.allocator(), src, .{}, .{});
        try std.testing.expect(std.mem.indexOf(u8, out, "<!-- a") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "<p>b</p>") == null);
    }
    {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const out = try md.toHtml(arena.allocator(), "<!-->", .{}, .{});
        try std.testing.expect(std.mem.indexOf(u8, out, "<!-->") != null);
    }
    {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const out = try md.toHtml(arena.allocator(), "<!--->", .{}, .{});
        try std.testing.expect(std.mem.indexOf(u8, out, "<!--->") != null);
    }
}
