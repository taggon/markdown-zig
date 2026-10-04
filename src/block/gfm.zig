const std = @import("std");
const Allocator = std.mem.Allocator;
const Align = @import("../node.zig").Align;
const chars = @import("../chars.zig");
const ParseError = @import("../root.zig").ParseError;

/// A matched `[^label]:` footnote definition opener (SPEC §13.2).
pub const FootnoteDefInfo = struct {
    /// Raw label bytes between `[^` and `]`. Backslash escapes are left
    /// unresolved; the caller resolves them before normalizing.
    label: []const u8,
    /// Byte index just past `]:`. Whitespace after the colon is *not*
    /// consumed here — the block phase does that so column tracking stays in
    /// one place.
    content_byte: usize,
};

/// Matches a footnote definition opener at 0–3 columns of indentation.
/// The label must be non-empty and may not hold an unescaped `[` or `]`.
/// No whitespace is required after the colon: `[^a]:x` opens a definition
/// whose content is `x`.
pub fn footnoteDefInfo(line: []const u8) ?FootnoteDefInfo {
    const indent = chars.skipUpTo3Cols(line);
    if (indent + 2 >= line.len) return null;
    if (line[indent] != '[' or line[indent + 1] != '^') return null;

    const label_start = indent + 2;
    var i = label_start;
    while (i < line.len) {
        const c = line[i];
        if (c == '\\' and i + 1 < line.len) {
            i += 2;
            continue;
        }
        if (c == ']') break;
        if (c == '[' or c == '\n') return null;
        i += 1;
    }
    if (i >= line.len or line[i] != ']') return null;
    if (i == label_start) return null; // empty label
    if (i + 1 >= line.len or line[i + 1] != ':') return null;

    return .{ .label = line[label_start..i], .content_byte = i + 2 };
}

/// Splits a GFM table row into cells. `\|` is a literal pipe (backslash
/// consumed); other `\X` pairs pass through for the inline phase. Leading
/// and trailing pipes are optional and stripped if present.
pub fn splitTableRow(arena: Allocator, line: []const u8) ParseError![][]const u8 {
    var s: usize = 0;
    while (s < line.len and (line[s] == ' ' or line[s] == '\t')) : (s += 1) {}
    if (s < line.len and line[s] == '|') s += 1;

    var e: usize = line.len;
    while (e > s and (line[e - 1] == ' ' or line[e - 1] == '\t')) : (e -= 1) {}
    if (e > s and line[e - 1] == '|') e -= 1;

    var cells: std.ArrayList([]const u8) = .empty;
    var buf: std.ArrayList(u8) = .empty;

    var i: usize = s;
    while (i < e) {
        if (line[i] == '\\' and i + 1 < e and line[i + 1] == '|') {
            try buf.append(arena, '|');
            i += 2;
        } else if (line[i] == '|') {
            try cells.append(arena, try trimCellDup(arena, buf.items));
            buf.clearRetainingCapacity();
            i += 1;
        } else {
            try buf.append(arena, line[i]);
            i += 1;
        }
    }
    try cells.append(arena, try trimCellDup(arena, buf.items));

    buf.deinit(arena);
    return cells.toOwnedSlice(arena);
}

pub fn trimCellDup(arena: Allocator, text: []const u8) Allocator.Error![]const u8 {
    var s: usize = 0;
    while (s < text.len and (text[s] == ' ' or text[s] == '\t')) : (s += 1) {}
    var e: usize = text.len;
    while (e > s and (text[e - 1] == ' ' or text[e - 1] == '\t')) : (e -= 1) {}
    return arena.dupe(u8, text[s..e]);
}

/// Parses a delimiter row and returns the per-column alignment, or null if
/// the line is not a valid delimiter row.
/// A delimiter row is made only of these bytes. Checking first keeps every
/// ordinary paragraph line in a GFM document from allocating a cell list that
/// is immediately discarded — the check runs on each line of an open paragraph.
fn couldBeDelimiterRow(line: []const u8) bool {
    var saw_dash = false;
    for (line) |c| switch (c) {
        '-' => saw_dash = true,
        ':', '|', ' ', '\t', '\\' => {},
        else => return false,
    };
    return saw_dash;
}

pub fn parseDelimiterRow(arena: Allocator, line: []const u8) ParseError!?[]const Align {
    if (!couldBeDelimiterRow(line)) return null;
    const cells = try splitTableRow(arena, line);
    if (cells.len == 0) return null;

    const aligns = try arena.alloc(Align, cells.len);
    for (cells, 0..) |cell, i| {
        if (cell.len == 0) return null;
        var has_dash = false;
        for (cell) |c| {
            if (c == '-') has_dash = true else if (c != ':' and c != ' ') return null;
        }
        if (!has_dash) return null;
        const left = cell[0] == ':';
        const right = cell[cell.len - 1] == ':';
        aligns[i] = if (left and right) .center else if (left) .left else if (right) .right else .none;
    }
    return aligns;
}

test "footnoteDefInfo: basic opener" {
    const info = footnoteDefInfo("[^a]: text").?;
    try std.testing.expectEqualStrings("a", info.label);
    try std.testing.expectEqual(@as(usize, 5), info.content_byte);
}

test "footnoteDefInfo: content on the next line" {
    const info = footnoteDefInfo("[^codeblock-note]:").?;
    try std.testing.expectEqualStrings("codeblock-note", info.label);
    try std.testing.expectEqual(@as(usize, 18), info.content_byte);
}

test "footnoteDefInfo: up to 3 columns of indentation" {
    try std.testing.expect(footnoteDefInfo("   [^a]: x") != null);
    try std.testing.expect(footnoteDefInfo("    [^a]: x") == null);
}

test "footnoteDefInfo: label rules" {
    try std.testing.expect(footnoteDefInfo("[^]: x") == null); // empty
    try std.testing.expect(footnoteDefInfo("[^a[b]: x") == null); // unescaped [
    try std.testing.expect(footnoteDefInfo("[^a] : x") == null); // no colon
    try std.testing.expect(footnoteDefInfo("[a]: x") == null); // link definition
    try std.testing.expectEqualStrings("a\\]b", footnoteDefInfo("[^a\\]b]: x").?.label);
}

test "footnoteDefInfo: html-ish label passes through raw" {
    const info = footnoteDefInfo("[^\"><script>alert(1)</script>]: pwned").?;
    try std.testing.expectEqualStrings("\"><script>alert(1)</script>", info.label);
}

test "footnoteDefInfo: no whitespace required after the colon" {
    const info = footnoteDefInfo("[^a]:x").?;
    try std.testing.expectEqual(@as(usize, 5), info.content_byte);
}
