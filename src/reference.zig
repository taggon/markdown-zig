const std = @import("std");
const Allocator = std.mem.Allocator;

const Node = @import("node.zig").Node;
const ParseError = @import("root.zig").ParseError;
const chars = @import("chars.zig");
const escape = @import("escape.zig");
const casefold = @import("casefold.zig");
const bracket = @import("inline/bracket.zig");

/// Lookup map shared with the block phase: identifier → definition node.
pub const DefinitionsMap = std.StringHashMapUnmanaged(*Node);

/// Read-only lookup map built by the renderer from a finished tree.
pub const ResolvedMap = std.StringHashMapUnmanaged(*const Node);

/// Walk `root` and collect every definition node into an identifier → node map.
/// The first definition for an identifier wins, matching parse-time behaviour.
/// Caller owns the map and must `deinit(gpa)` it.
pub fn collect(gpa: Allocator, root: *const Node) error{ NestingTooDeep, OutOfMemory }!ResolvedMap {
    var defs: ResolvedMap = .empty;
    errdefer defs.deinit(gpa);
    try collectInto(gpa, &defs, root, 0);
    return defs;
}

fn collectInto(gpa: Allocator, defs: *ResolvedMap, node: *const Node, depth: usize) error{ NestingTooDeep, OutOfMemory }!void {
    if (depth > 512) return error.NestingTooDeep;
    if (node.data == .definition) {
        const gop = try defs.getOrPut(gpa, node.data.definition.identifier);
        if (!gop.found_existing) gop.value_ptr.* = node;
    }
    var child = node.first_child;
    while (child) |c| : (child = c.next) try collectInto(gpa, defs, c, depth + 1);
}

/// Normalize a link label into a lookup identifier.
/// CommonMark: Unicode case fold + collapse runs of whitespace to a single
/// space + trim. Backslash escapes are assumed already resolved by the caller.
pub fn normalizeIdentifier(arena: Allocator, label: []const u8) ParseError![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(arena);

    var last_ws = false;
    var started = false;
    var i: usize = 0;
    while (i < label.len) {
        const c = label[i];
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0c) {
            if (started) last_ws = true;
            i += 1;
            continue;
        }
        if (last_ws) {
            try out.append(arena, ' ');
            last_ws = false;
        }
        started = true;

        if (c < 0x80) {
            try out.append(arena, std.ascii.toLower(c));
            i += 1;
            continue;
        }
        // Fold whole code points: a fold may lengthen the text (`ẞ` → `ss`),
        // so it cannot be done byte by byte.
        const len = std.unicode.utf8ByteSequenceLength(c) catch 1;
        const end = @min(i + len, label.len);
        const cp = label[i..end];
        try out.appendSlice(arena, casefold.folds.get(cp) orelse cp);
        i = end;
    }
    return out.toOwnedSlice(arena);
}

/// Outcome of an optional-title scan after a destination.
/// - `ok` is false only when the line holds non-whitespace junk (definition invalid).
/// - `title` is null when no title is present (definition still valid).
/// - `end_pos` points at the end of the title line (at a newline or EOF).
const TitleScan = struct { ok: bool, title: ?[]const u8, end_pos: usize };

fn scanOptionalTitle(text: []const u8, url_end: usize) TitleScan {
    var probe = url_end;
    var had_ws = false;
    while (probe < text.len and chars.isLineWs(text[probe])) : (probe += 1) had_ws = true;

    if (probe < text.len and text[probe] != '\n') {
        // A title on the same line requires separating whitespace (CommonMark §4.7).
        if (had_ws) {
            if (bracket.scanTitle(text, probe)) |ts| {
                var tail = ts.end_pos;
                while (tail < text.len and chars.isLineWs(text[tail])) tail += 1;
                if (tail >= text.len or text[tail] == '\n') {
                    return .{ .ok = true, .title = ts.title, .end_pos = tail };
                }
                return .{ .ok = false, .title = null, .end_pos = url_end };
            }
        }
        // No title: the rest of the line must be whitespace only.
        var tail = probe;
        while (tail < text.len and text[tail] != '\n') : (tail += 1) {
            if (!chars.isLineWs(text[tail])) return .{ .ok = false, .title = null, .end_pos = url_end };
        }
        return .{ .ok = true, .title = null, .end_pos = tail };
    }

    if (probe < text.len and text[probe] == '\n') {
        var nprobe = probe + 1;
        while (nprobe < text.len and chars.isLineWs(text[nprobe])) nprobe += 1;
        if (nprobe < text.len and text[nprobe] != '\n') {
            if (bracket.scanTitle(text, nprobe)) |ts| {
                var tail = ts.end_pos;
                while (tail < text.len and chars.isLineWs(text[tail])) tail += 1;
                if (tail >= text.len or text[tail] == '\n') {
                    return .{ .ok = true, .title = ts.title, .end_pos = tail };
                }
            }
        }
    }

    return .{ .ok = true, .title = null, .end_pos = probe };
}

/// Skips spaces and tabs, optionally crossing a single line ending. Returns
/// null when a blank line follows, which terminates the definition.
fn skipWsOverOneNewline(text: []const u8, start: usize) ?usize {
    var pos = start;
    while (pos < text.len and chars.isLineWs(text[pos])) pos += 1;
    if (pos >= text.len or text[pos] != '\n') return pos;

    var after = pos + 1;
    while (after < text.len and chars.isLineWs(text[after])) after += 1;
    if (after >= text.len or text[after] == '\n') return null; // blank line
    return after;
}

const DefResult = struct {
    identifier: []const u8,
    label: []const u8,
    url: []const u8,
    title: ?[]const u8,
    next_pos: usize,
};

/// Try to match a single link reference definition beginning at `start` in
/// `text`. `text` is the paragraph raw-text buffer (lines joined by `\n`).
/// Returns the parsed fields and the byte position just past the definition's
/// final newline, or null if no definition matches here.
fn parseDef(arena: Allocator, text: []const u8, start: usize) ParseError!?DefResult {
    var pos = start;
    while (pos < text.len and chars.isLineWs(text[pos])) pos += 1;

    if (pos >= text.len or text[pos] != '[') return null;
    pos += 1;

    // Label: up to `]`, with backslash escapes. `[`/`]` may not appear
    // unescaped. The label may wrap across lines, but a blank line ends it.
    var label: std.ArrayList(u8) = .empty;
    var has_nonspace = false;
    var last_ws = false;
    while (pos < text.len) {
        const c = text[pos];
        if (c == ']') break;
        if (c == '\n') {
            if (pos + 1 < text.len and text[pos + 1] == '\n') return null;
            if (has_nonspace) last_ws = true;
            pos += 1;
            continue;
        }
        if (c == '\\' and pos + 1 < text.len and chars.isAsciiPunct(text[pos + 1])) {
            try label.append(arena, '\\');
            try label.append(arena, text[pos + 1]);
            has_nonspace = true;
            last_ws = false;
            pos += 2;
            continue;
        }
        if (c == '[') return null; // unescaped opening bracket inside label
        if (c == ' ' or c == '\t') {
            if (has_nonspace) last_ws = true;
        } else {
            if (last_ws) {
                try label.append(arena, ' ');
                last_ws = false;
            }
            try label.append(arena, c);
            has_nonspace = true;
        }
        pos += 1;
    }
    if (pos >= text.len or text[pos] != ']') return null; // no closing `]`
    if (!has_nonspace) return null; // label needs ≥1 non-space char
    // Trim a trailing collapsed space if present.
    if (label.items.len > 0 and label.items[label.items.len - 1] == ' ') _ = label.pop();
    pos += 1;

    if (pos >= text.len or text[pos] != ':') return null;
    pos += 1;

    // Optional whitespace before the destination, which may sit on the next
    // line (CommonMark §4.7 allows up to one line ending here).
    pos = skipWsOverOneNewline(text, pos) orelse return null;

    // Destination — use the unified scanner from bracket.zig (SPEC §3.1).
    const is_angle = pos < text.len and text[pos] == '<';
    var dest_memo: bracket.DestMemo = .{};
    const dest = bracket.scanDestination(text, pos, &dest_memo) orelse return null;
    if (!is_angle and dest.url.len == 0) return null;
    pos = dest.end_pos;

    // Optional title: on the same line after whitespace, or on the next line.
    const ts = scanOptionalTitle(text, pos);
    if (!ts.ok) return null;
    const title: ?[]const u8 = ts.title;
    pos = ts.end_pos;

    // Consume the trailing newline (if any) so the next definition candidate
    // starts at the beginning of the following line.
    if (pos < text.len and text[pos] == '\n') pos += 1;

    const label_slice = try label.toOwnedSlice(arena);
    const identifier = try normalizeIdentifier(arena, label_slice);

    return DefResult{
        .identifier = identifier,
        .label = try arena.dupe(u8, label_slice),
        .url = try escape.resolve(arena, dest.url),
        .title = if (title) |t| try escape.resolve(arena, t) else null,
        .next_pos = pos,
    };
}

/// Walk the paragraph raw-text buffer, peeling leading link reference
/// definitions off the front. Each definition becomes a `.definition` node
/// appended to `parent` (preserving document order); the first definition for
/// a given identifier wins. The buffer is rewritten to hold only the remaining
/// paragraph text; if everything was consumed the paragraph node is unlinked.
pub fn extractFromParagraph(
    arena: Allocator,
    definitions: *DefinitionsMap,
    parent: *Node,
    para: *Node,
    buf: *std.ArrayList(u8),
) ParseError!void {
    var pos: usize = 0;
    var consumed_any = false;

    // Definitions must be inserted at the paragraph's position. Temporarily
    // detach the paragraph; it is re-attached iff leftover text remains.
    para.unlink();

    while (true) {
        const result = (try parseDef(arena, buf.items, pos)) orelse break;

        const def_node = try arena.create(Node);
        def_node.* = .{ .data = .{ .definition = .{
            .identifier = result.identifier,
            .label = result.label,
            .url = result.url,
            .title = result.title,
        } } };
        parent.appendChild(def_node);

        const gop = try definitions.getOrPut(arena, result.identifier);
        if (!gop.found_existing) gop.value_ptr.* = def_node;

        pos = result.next_pos;
        consumed_any = true;
    }

    if (!consumed_any) {
        parent.appendChild(para);
        return;
    }

    var remaining = buf.items[pos..];
    while (remaining.len > 0 and chars.isWsByte(remaining[0])) remaining = remaining[1..];

    if (remaining.len == 0) {
        buf.clearRetainingCapacity();
    } else {
        parent.appendChild(para);
        std.mem.copyForwards(u8, buf.items[0..remaining.len], remaining);
        buf.items.len = remaining.len;
    }
}

test "normalizeIdentifier collapses whitespace and lowercases" {
    const a = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectEqualStrings("foo bar", try normalizeIdentifier(arena, "Foo   bar"));
    try std.testing.expectEqualStrings("baz", try normalizeIdentifier(arena, "\t Baz \n"));
    try std.testing.expectEqualStrings("", try normalizeIdentifier(arena, "   "));
}

test "parseDef basic with title" {
    const a = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const text = "[foo]: /url \"title\"\n";
    const r = (try parseDef(arena, text, 0)).?;
    try std.testing.expectEqualStrings("foo", r.identifier);
    try std.testing.expectEqualStrings("/url", r.url);
    try std.testing.expectEqualStrings("title", r.title.?);
    try std.testing.expectEqual(text.len, r.next_pos);
}

test "parseDef bare url without title" {
    const a = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const text = "[bar]: example.com\n";
    const r = (try parseDef(arena, text, 0)).?;
    try std.testing.expectEqualStrings("bar", r.identifier);
    try std.testing.expectEqualStrings("example.com", r.url);
    try std.testing.expect(r.title == null);
}

test "parseDef title on next line" {
    const a = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const text = "[a]: url\n   \"My Title\"\n";
    const r = (try parseDef(arena, text, 0)).?;
    try std.testing.expectEqualStrings("My Title", r.title.?);
}

test "parseDef fails on trailing junk" {
    const a = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const text = "[a]: url junk\n";
    try std.testing.expect((try parseDef(arena, text, 0)) == null);
}
