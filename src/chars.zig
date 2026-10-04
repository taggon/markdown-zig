const std = @import("std");

pub fn isAsciiPunct(c: u8) bool {
    return switch (c) {
        '!'...'/', ':'...'@', '['...'`', '{'...'~' => true,
        else => false,
    };
}

pub fn isWsByte(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r' or c == '\n' or c == 0x0c;
}

pub fn isLineWs(c: u8) bool {
    return c == ' ' or c == '\t';
}

pub fn isCtrl(c: u8) bool {
    return c < 0x20 or c == 0x7f;
}

pub fn isAttrNameChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == '.' or c == ':';
}

/// How many columns a tab occupies when it starts at `col`.
pub fn tabWidthAt(col: usize) usize {
    return 4 - (col % 4);
}

/// Byte index of the first character past up to 3 columns of indentation —
/// the "0 to 3 spaces of indentation" every CommonMark block construct allows.
///
/// Only spaces can contribute. A tab always advances to the next multiple of 4,
/// so wherever it sits in a 0–3 column prefix it lands on column 4 or beyond
/// and therefore cannot be part of the allowance. That makes the returned byte
/// index equal to the number of columns skipped.
pub fn skipUpTo3Cols(line: []const u8) usize {
    var i: usize = 0;
    while (i < line.len and i < 3 and line[i] == ' ') : (i += 1) {}
    return i;
}

// ─── GFM disallowed raw HTML ──────────────────────────────────────

const disallowed_html_tags = std.StaticStringMap(void).initComptime(.{
    .{ "title", {} },    .{ "textarea", {} }, .{ "style", {} },
    .{ "xmp", {} },      .{ "iframe", {} },   .{ "noembed", {} },
    .{ "noframes", {} }, .{ "script", {} },   .{ "plaintext", {} },
});

pub fn isDisallowedHtmlTag(name: []const u8) bool {
    var buf: [32]u8 = undefined;
    if (name.len > buf.len) return false;
    for (name, 0..) |c, i| buf[i] = std.ascii.toLower(c);
    return disallowed_html_tags.has(buf[0..name.len]);
}

/// Extracts the tag name from a raw HTML slice like `<tag ...>` or `</tag>`.
/// Returns null for comments, declarations, PIs, CDATA, or anything that is
/// not a tag pattern.
pub fn extractHtmlTagName(slice: []const u8) ?[]const u8 {
    if (slice.len < 2 or slice[0] != '<') return null;
    var pos: usize = 1;
    if (pos < slice.len and slice[pos] == '/') pos += 1;
    if (pos >= slice.len or !std.ascii.isAlphabetic(slice[pos])) return null;
    const start = pos;
    while (pos < slice.len and (std.ascii.isAlphanumeric(slice[pos]) or slice[pos] == '-')) : (pos += 1) {}
    return slice[start..pos];
}

test "skipUpTo3Cols caps at 3 and never consumes a tab" {
    try std.testing.expectEqual(@as(usize, 0), skipUpTo3Cols("abc"));
    try std.testing.expectEqual(@as(usize, 2), skipUpTo3Cols("  abc"));
    try std.testing.expectEqual(@as(usize, 3), skipUpTo3Cols("   abc"));
    try std.testing.expectEqual(@as(usize, 3), skipUpTo3Cols("     abc"));
    try std.testing.expectEqual(@as(usize, 0), skipUpTo3Cols("\tabc"));
    try std.testing.expectEqual(@as(usize, 2), skipUpTo3Cols("  \tabc"));
}

test "tabWidthAt advances to the next multiple of 4" {
    try std.testing.expectEqual(@as(usize, 4), tabWidthAt(0));
    try std.testing.expectEqual(@as(usize, 3), tabWidthAt(1));
    try std.testing.expectEqual(@as(usize, 2), tabWidthAt(2));
    try std.testing.expectEqual(@as(usize, 1), tabWidthAt(3));
    try std.testing.expectEqual(@as(usize, 4), tabWidthAt(4));
}
