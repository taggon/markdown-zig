const std = @import("std");
const chars = @import("../chars.zig");
const ParseError = @import("../root.zig").ParseError;

pub const RefKind = enum { full, collapsed, shortcut };

/// Memo for destination scan: once we've verified that the range
/// [from, until) contains no ')' and ends at a hard terminator, any scan
/// starting within that range reaches the same end position.
pub const DestMemo = struct {
    from: usize = 0,
    until: usize = 0,
};

pub const InlineLinkScan = struct {
    text_inner_start: usize,
    text_inner_end: usize,
    url: []const u8,
    title: ?[]const u8,
    end_pos: usize,
};

pub const ReferenceScan = struct {
    text_inner_start: usize,
    text_inner_end: usize,
    label_start: usize,
    label_end: usize,
    end_pos: usize,
    kind: RefKind,
};

pub const DestScan = struct { url: []const u8, end_pos: usize };
pub const TitleScan = struct { title: []const u8, end_pos: usize };

const LinkTextScan = struct { inner_start: usize, inner_end: usize, after_close: usize };

fn scanLinkText(text: []const u8, open_pos: usize) ?LinkTextScan {
    if (open_pos >= text.len or text[open_pos] != '[') return null;
    var p = open_pos + 1;
    const inner_start = p;
    var depth: usize = 1;
    while (p < text.len) {
        const c = text[p];
        if (c == '\\' and p + 1 < text.len) {
            p += 2;
            continue;
        }
        if (c == '[') {
            depth += 1;
        } else if (c == ']') {
            depth -= 1;
            if (depth == 0) {
                return .{ .inner_start = inner_start, .inner_end = p, .after_close = p + 1 };
            }
        }
        p += 1;
    }
    return null;
}

pub fn scanDestination(text: []const u8, pos: usize, memo: *DestMemo) ?DestScan {
    if (pos >= text.len) return null;

    // Short-circuit: if pos falls inside a previously verified ')' -free
    // range, the scan ends at memo.until without re-walking.
    if (memo.from <= pos and pos < memo.until) {
        return .{ .url = text[pos..memo.until], .end_pos = memo.until };
    }

    if (text[pos] == '<') {
        var p = pos + 1;
        const start = p;
        while (p < text.len) {
            const c = text[p];
            if (c == '\\' and p + 1 < text.len) {
                p += 2;
                continue;
            }
            if (c == '<' or c == '>' or c == '\n' or chars.isCtrl(c)) break;
            p += 1;
        }
        if (p >= text.len or text[p] != '>') return null;
        return .{ .url = text[start..p], .end_pos = p + 1 };
    }
    const start = pos;
    var p = pos;
    var paren_depth: i32 = 0;
    var saw_close_paren = false;
    while (p < text.len) {
        const c = text[p];
        if (c == '\\' and p + 1 < text.len) {
            p += 2;
            continue;
        }
        if (chars.isWsByte(c) or chars.isCtrl(c)) break;
        if (c == '(') {
            paren_depth += 1;
        } else if (c == ')') {
            saw_close_paren = true;
            if (paren_depth == 0) break;
            paren_depth -= 1;
        }
        p += 1;
    }

    // If this scan reached a hard terminator (or EOF) without encountering
    // any ')', memo the range so future scans starting inside it skip.
    if (!saw_close_paren) {
        memo.from = start;
        memo.until = p;
    }

    return .{ .url = text[start..p], .end_pos = p };
}

pub fn scanTitle(text: []const u8, pos: usize) ?TitleScan {
    if (pos >= text.len) return null;
    const open = text[pos];
    const close: u8 = switch (open) {
        '"' => '"',
        '\'' => '\'',
        '(' => ')',
        else => return null,
    };
    var p = pos + 1;
    const start = p;
    while (p < text.len) {
        const c = text[p];
        if (c == '\\' and p + 1 < text.len) {
            p += 2;
            continue;
        }
        if (c == close) {
            return .{ .title = text[start..p], .end_pos = p + 1 };
        }
        p += 1;
    }
    return null;
}

pub fn tryInlineLink(text: []const u8, open_pos: usize, memo: *DestMemo) ?InlineLinkScan {
    const lt = scanLinkText(text, open_pos) orelse return null;
    var p = lt.after_close;
    if (p >= text.len or text[p] != '(') return null;
    p += 1;
    while (p < text.len and chars.isWsByte(text[p])) p += 1;
    const dest = scanDestination(text, p, memo) orelse return null;
    p = dest.end_pos;
    var had_ws = false;
    while (p < text.len and chars.isWsByte(text[p])) {
        had_ws = true;
        p += 1;
    }
    var title: ?[]const u8 = null;
    if (p < text.len and (text[p] == '"' or text[p] == '\'' or text[p] == '(')) {
        if (!had_ws) return null;
        const ts = scanTitle(text, p) orelse return null;
        title = ts.title;
        p = ts.end_pos;
        while (p < text.len and chars.isWsByte(text[p])) p += 1;
    }
    if (p >= text.len or text[p] != ')') return null;
    p += 1;
    return .{
        .text_inner_start = lt.inner_start,
        .text_inner_end = lt.inner_end,
        .url = dest.url,
        .title = title,
        .end_pos = p,
    };
}

pub fn tryReference(text: []const u8, open_pos: usize) ?ReferenceScan {
    const lt = scanLinkText(text, open_pos) orelse return null;
    const after = lt.after_close;
    // No `(` guard here: an inline link is always tried first, so reaching this
    // point means `[foo](…)` failed to parse and CommonMark falls back to a
    // shortcut reference (example 568).
    if (after < text.len and text[after] == '[') {
        var p = after + 1;
        const label_start = p;
        while (p < text.len) {
            const c = text[p];
            if (c == '\\' and p + 1 < text.len) {
                p += 2;
                continue;
            }
            if (c == ']') {
                const label_end = p;
                const after2 = p + 1;
                const kind: RefKind = if (label_end == label_start) .collapsed else .full;
                return .{
                    .text_inner_start = lt.inner_start,
                    .text_inner_end = lt.inner_end,
                    .label_start = label_start,
                    .label_end = label_end,
                    .end_pos = after2,
                    .kind = kind,
                };
            }
            p += 1;
        }
        return null;
    }
    if (lt.inner_end == lt.inner_start) return null;
    return .{
        .text_inner_start = lt.inner_start,
        .text_inner_end = lt.inner_end,
        .label_start = lt.inner_start,
        .label_end = lt.inner_end,
        .end_pos = after,
        .kind = .shortcut,
    };
}

pub const FootnoteRefScan = struct {
    label_start: usize,
    label_end: usize,
    /// Byte index just past the closing `]`.
    end_pos: usize,
};

/// Scans a `[^label]` footnote reference whose `[` sits at `open_pos`
/// (SPEC §13.3). The label must be non-empty and may not hold an unescaped
/// `[` or a newline. Whether a matching definition exists is the caller's
/// concern.
pub fn tryFootnoteRef(text: []const u8, open_pos: usize) ?FootnoteRefScan {
    if (open_pos + 2 >= text.len) return null;
    if (text[open_pos] != '[' or text[open_pos + 1] != '^') return null;

    const label_start = open_pos + 2;
    var i = label_start;
    while (i < text.len) {
        const c = text[i];
        if (c == '\\' and i + 1 < text.len) {
            i += 2;
            continue;
        }
        if (c == ']') break;
        if (c == '[' or c == '\n') return null;
        i += 1;
    }
    if (i >= text.len or text[i] != ']') return null;
    if (i == label_start) return null; // empty label
    return .{ .label_start = label_start, .label_end = i, .end_pos = i + 1 };
}

test "tryInlineLink basic" {
    var memo: DestMemo = .{};
    const t = "[a](http://x)";
    const r = tryInlineLink(t, 0, &memo).?;
    try std.testing.expectEqual(@as(usize, 1), r.text_inner_start);
    try std.testing.expectEqual(@as(usize, 2), r.text_inner_end);
    try std.testing.expectEqualStrings("http://x", r.url);
    try std.testing.expect(r.title == null);
    try std.testing.expectEqual(@as(usize, 13), r.end_pos);
}

test "tryInlineLink with title" {
    var memo: DestMemo = .{};
    const t = "[a](u \"t\")";
    const r = tryInlineLink(t, 0, &memo).?;
    try std.testing.expectEqualStrings("u", r.url);
    try std.testing.expectEqualStrings("t", r.title.?);
    try std.testing.expectEqual(@as(usize, 10), r.end_pos);
}

test "tryInlineLink angle destination" {
    var memo: DestMemo = .{};
    const t = "[a](<http://x>)";
    const r = tryInlineLink(t, 0, &memo).?;
    try std.testing.expectEqualStrings("http://x", r.url);
    try std.testing.expect(r.title == null);
    try std.testing.expectEqual(@as(usize, 15), r.end_pos);
}

test "tryInlineLink nested brackets" {
    var memo: DestMemo = .{};
    const t = "[a [b] c](u)";
    const r = tryInlineLink(t, 0, &memo).?;
    try std.testing.expectEqualStrings("a [b] c", t[r.text_inner_start..r.text_inner_end]);
    try std.testing.expectEqualStrings("u", r.url);
    try std.testing.expectEqual(@as(usize, 12), r.end_pos);
}

test "tryInlineLink no match without paren" {
    var memo: DestMemo = .{};
    const t = "[a]";
    try std.testing.expect(tryInlineLink(t, 0, &memo) == null);
}

test "tryReference full" {
    const t = "[a][b]";
    const r = tryReference(t, 0).?;
    try std.testing.expectEqual(RefKind.full, r.kind);
    try std.testing.expectEqualStrings("b", t[r.label_start..r.label_end]);
    try std.testing.expectEqual(@as(usize, 6), r.end_pos);
}

test "tryReference collapsed" {
    const t = "[a][]";
    const r = tryReference(t, 0).?;
    try std.testing.expectEqual(RefKind.collapsed, r.kind);
    try std.testing.expectEqual(@as(usize, 5), r.end_pos);
}

test "tryReference shortcut" {
    const t = "[a]";
    const r = tryReference(t, 0).?;
    try std.testing.expectEqual(RefKind.shortcut, r.kind);
    try std.testing.expectEqual(r.text_inner_start, r.label_start);
    try std.testing.expectEqual(r.text_inner_end, r.label_end);
    try std.testing.expectEqual(@as(usize, 3), r.end_pos);
}

test "tryReference falls back to shortcut when the inline link failed" {
    const t = "[a](u)";
    const r = tryReference(t, 0).?;
    try std.testing.expectEqual(RefKind.shortcut, r.kind);
    try std.testing.expectEqual(@as(usize, 3), r.end_pos);
}

test "scanDestination bare and angle" {
    var m1: DestMemo = .{};
    const bare = scanDestination("http://x rest", 0, &m1).?;
    try std.testing.expectEqualStrings("http://x", bare.url);
    try std.testing.expectEqual(@as(usize, 8), bare.end_pos);
    var m2: DestMemo = .{};
    const angle = scanDestination("<http://x>", 0, &m2).?;
    try std.testing.expectEqualStrings("http://x", angle.url);
    try std.testing.expectEqual(@as(usize, 10), angle.end_pos);
}

test "scanTitle three forms and newline" {
    const dq = scanTitle("\"t\"", 0).?;
    try std.testing.expectEqualStrings("t", dq.title);
    try std.testing.expectEqual(@as(usize, 3), dq.end_pos);
    try std.testing.expectEqualStrings("t", scanTitle("'t'", 0).?.title);
    try std.testing.expectEqualStrings("t", scanTitle("(t)", 0).?.title);
    const nl = scanTitle("\"a\nb\"", 0).?;
    try std.testing.expectEqualStrings("a\nb", nl.title);
}

test "tryFootnoteRef: basic" {
    const s = tryFootnoteRef("a[^x]b", 1).?;
    try std.testing.expectEqualStrings("x", "a[^x]b"[s.label_start..s.label_end]);
    try std.testing.expectEqual(@as(usize, 5), s.end_pos);
}

test "tryFootnoteRef: rejects non-footnote brackets" {
    try std.testing.expect(tryFootnoteRef("[x]", 0) == null);
    try std.testing.expect(tryFootnoteRef("[^]", 0) == null); // empty label
    try std.testing.expect(tryFootnoteRef("[^x", 0) == null); // unterminated
    try std.testing.expect(tryFootnoteRef("[^a[b]", 0) == null); // unescaped [
}

test "tryFootnoteRef: backslash escape inside the label" {
    const text = "[^a\\]b]";
    const s = tryFootnoteRef(text, 0).?;
    try std.testing.expectEqualStrings("a\\]b", text[s.label_start..s.label_end]);
}

test "tryFootnoteRef: newline inside the label is rejected" {
    try std.testing.expect(tryFootnoteRef("[^a\nb]", 0) == null);
}
