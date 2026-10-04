//! Backslash escapes and character references — the two things CommonMark
//! resolves before a raw slice becomes a node value. Kept in one module so the
//! inline phase, the reference parser and the block phase cannot disagree.
const std = @import("std");
const Allocator = std.mem.Allocator;
const chars = @import("chars.zig");
const entities = @import("entities");

const ParseError = @import("root.zig").ParseError;

/// Longest HTML5 entity name is 31 bytes, so a reference cannot exceed
/// `&` + 31 + `;`.
const max_entity_len = 33;

/// Resolves backslash escapes of ASCII punctuation. The result is always
/// arena-owned (SPEC invariant 6) — never the input slice.
pub fn backslashes(arena: Allocator, s: []const u8) ParseError![]const u8 {
    if (std.mem.indexOfScalar(u8, s, '\\') == null) return arena.dupe(u8, s);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(arena);
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '\\' and i + 1 < s.len and chars.isAsciiPunct(s[i + 1])) {
            try out.append(arena, s[i + 1]);
            i += 2;
        } else {
            try out.append(arena, s[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(arena);
}

/// Resolves backslash escapes *and* character references. Used wherever a raw
/// slice becomes a semantic value rather than rendered text: link destinations,
/// link titles, and code fence info strings (CommonMark §6.1–6.2, §4.5).
pub fn resolve(arena: Allocator, s: []const u8) ParseError![]const u8 {
    if (std.mem.indexOfScalar(u8, s, '\\') == null and
        std.mem.indexOfScalar(u8, s, '&') == null)
    {
        return arena.dupe(u8, s);
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(arena);
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '\\' and i + 1 < s.len and chars.isAsciiPunct(s[i + 1])) {
            try out.append(arena, s[i + 1]);
            i += 2;
            continue;
        }
        if (s[i] == '&') {
            if (try decodeEntityAt(arena, &out, s[i..])) |consumed| {
                i += consumed;
                continue;
            }
        }
        try out.append(arena, s[i]);
        i += 1;
    }
    return out.toOwnedSlice(arena);
}

/// Attempts to decode the character reference beginning at `slice[0]` (which
/// must be `&`). On success appends the replacement text to `buf` and returns
/// the number of bytes consumed; on failure returns null with `buf` untouched.
pub fn decodeEntityAt(arena: Allocator, buf: *std.ArrayList(u8), slice: []const u8) ParseError!?usize {
    if (slice.len < 2 or slice[0] != '&') return null;

    var i: usize = 1;
    while (i < slice.len and i < max_entity_len) : (i += 1) {
        const c = slice[i];
        if (c == ';') break;
        if (chars.isWsByte(c)) return null;
    }
    if (i >= slice.len or slice[i] != ';') return null;
    if (i == 1) return null; // `&;`

    const name = slice[1..i];

    if (name[0] != '#') {
        const text = entities.named_entities.get(name) orelse return null;
        try buf.appendSlice(arena, text);
        return i + 1;
    }

    if (name.len == 1) return null;
    var cp: ?u32 = null;
    if (name.len >= 2 and (name[1] == 'x' or name[1] == 'X')) {
        const digits = name[2..];
        if (digits.len >= 1 and digits.len <= 6)
            cp = std.fmt.parseInt(u32, digits, 16) catch null;
    } else {
        const digits = name[1..];
        if (digits.len >= 1 and digits.len <= 7)
            cp = std.fmt.parseInt(u32, digits, 10) catch null;
    }
    if (cp == null) return null;
    // CommonMark: an unrepresentable numeric reference becomes U+FFFD.
    var c: u32 = cp.?;
    if (c == 0 or c > 0x10FFFF or (c >= 0xD800 and c <= 0xDFFF)) c = 0xFFFD;

    var encoded: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(@intCast(c), &encoded) catch return null;
    try buf.appendSlice(arena, encoded[0..len]);
    return i + 1;
}

test "resolve handles backslash escapes and entities together" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectEqualStrings("/föö", try resolve(arena, "/f&ouml;&ouml;"));
    try std.testing.expectEqualStrings("foo+bar", try resolve(arena, "foo\\+bar"));
    try std.testing.expectEqualStrings("a&unknown;b", try resolve(arena, "a&unknown;b"));
    // Backslash-escaped ampersand is not a reference start.
    try std.testing.expectEqualStrings("&amp;", try resolve(arena, "\\&amp;"));
}
