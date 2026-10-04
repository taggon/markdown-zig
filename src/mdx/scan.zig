const std = @import("std");
const Allocator = std.mem.Allocator;
const Node = @import("../node.zig");

// ── Expression scanner (SPEC §14.3) ─────────────────────────────────

pub const ExprScan = struct {
    value: []const u8,
    raw: []const u8,
    end_pos: usize,
};

/// Scans an MDX expression starting at `pos` (must point to `{`).
/// Tracks brace depth only — does NOT parse JS string/comment/regex
/// literals (SPEC §14.3 known limitation: `{"}"}`  cuts at first `}`).
///
/// Returns `null` if `text[pos] != '{'`.
/// Returns `error.UnclosedMdxExpression` if no matching `}` found.
pub fn scanExpression(text: []const u8, pos: usize) error{UnclosedMdxExpression}!?ExprScan {
    if (pos >= text.len or text[pos] != '{') return null;
    var depth: usize = 1;
    var i = pos + 1;
    while (i < text.len) : (i += 1) {
        switch (text[i]) {
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if (depth == 0) {
                    return .{
                        .value = text[pos + 1 .. i],
                        .raw = text[pos .. i + 1],
                        .end_pos = i + 1,
                    };
                }
            },
            else => {},
        }
    }
    return error.UnclosedMdxExpression;
}

// ── JSX tag scanner (SPEC §14.4) ───────────────────────────────────

/// JSX element names match byte for byte; a fragment (`null`) matches only
/// another fragment (SPEC §14.4). Single source for block and inline phases.
pub fn nameEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

/// Pairs every `{` in `text` with its matching `}` by one stack pass —
/// the same blind judgement `scanExpression` makes; it does not understand
/// JS strings, so `{"}"}` cuts at the first `}`. Unmatched braces get no
/// entry. One pass, constant-time lookups: callers that walk a text looking
/// for close tags must not rescan from every unmatched `{`, which is
/// quadratic (SPEC §16.4).
pub fn buildBracePairs(
    arena: Allocator,
    text: []const u8,
    pairs: *std.AutoHashMapUnmanaged(usize, usize),
) Allocator.Error!void {
    var stack: std.ArrayList(usize) = .empty;
    defer stack.deinit(arena);
    for (text, 0..) |c, i| switch (c) {
        '{' => try stack.append(arena, i),
        '}' => if (stack.pop()) |open| try pairs.put(arena, open, i),
        else => {},
    };
}

/// Offset of the `<` of the closing tag that matches an element named `name`,
/// counting nested same-name elements — the one child-boundary judgement both
/// phases need (SPEC §3.1: one definition, two callers). Bounds-only tag
/// scans: tags walked past here are re-parsed properly if they turn out to be
/// children. `{…}` expressions are skipped whole, via `brace_pairs` from
/// `buildBracePairs` — their braces can hold anything, including a `<` that
/// must not look like a tag. An unterminated expression has no entry: its
/// `{` counts as a single literal byte and the walk continues, so the
/// unterminated-expression error can still surface from the content scan
/// (§14.6).
pub fn findMatchingClose(
    text: []const u8,
    start: usize,
    name: ?[]const u8,
    brace_pairs: *const std.AutoHashMapUnmanaged(usize, usize),
) ?usize {
    var pos = start;
    var depth: usize = 1;
    while (pos < text.len) {
        switch (text[pos]) {
            '<' => {
                const tag = (scanTagBounds(text, pos) catch null) orelse {
                    pos += 1;
                    continue;
                };
                if (nameEql(tag.name, name)) {
                    switch (tag.kind) {
                        .closing => {
                            depth -= 1;
                            if (depth == 0) return pos;
                        },
                        .opening => depth += 1,
                        .self_closing => {},
                    }
                }
                pos = tag.end_pos;
            },
            '{' => {
                if (brace_pairs.get(pos)) |close| {
                    pos = close + 1;
                } else pos += 1;
            },
            else => pos += 1,
        }
    }
    return null;
}

pub const TagKind = enum { opening, closing, self_closing };

pub const TagScan = struct {
    kind: TagKind,
    name: ?[]const u8, // null = fragment
    attributes: []Node.MdxJsxAttr,
    raw: []const u8,
    end_pos: usize,
};

/// What `scanTagBounds` reports: everything except the attribute list.
pub const TagBounds = struct {
    kind: TagKind,
    name: ?[]const u8,
    raw: []const u8,
    end_pos: usize,
};

/// `InvalidJsx` — the text breaks the tag grammar; more input cannot help.
/// `IncompleteJsx` — the tag is well formed so far but the input ran out. The
/// block phase appends the next line and retries (SPEC §14.4, §14.5).
/// `IncompleteJsxExpression` — same, but what ran out was an attribute
/// expression. The distinction only decides which error a document that ends
/// there reports (SPEC §14.6).
pub const BoundsError = error{ InvalidJsx, IncompleteJsx, IncompleteJsxExpression };
pub const ScanError = BoundsError || error{OutOfMemory};

/// Where a parsed attribute goes. `null` means "parse but discard", which is
/// what the bounds-only scan does — it must still walk the grammar to find the
/// tag's end, but nothing is allocated (SPEC §14.4).
pub const AttrList = std.ArrayList(Node.MdxJsxAttr);
pub const AttrSink = struct {
    arena: Allocator,
    list: *AttrList,

    pub fn put(sink: ?AttrSink, attr: Node.MdxJsxAttr) error{OutOfMemory}!void {
        const s = sink orelse return;
        try s.list.append(s.arena, attr);
    }
};

/// Whitespace allowed inside JSX tags — includes newlines (SPEC §14.4).
fn isTagWs(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0c;
}

fn isIdentStart(c: u8) bool {
    return (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or c == '_' or c == '$';
}

fn isIdentCont(c: u8) bool {
    return isIdentStart(c) or (c >= '0' and c <= '9') or c == '-';
}

/// Parses a JSX identifier starting at `text[i]`.
/// Returns the end index (one past the last ident char), or null if
/// `text[i]` is not a valid identifier start.
fn scanIdent(text: []const u8, i: usize) ?usize {
    if (i >= text.len or !isIdentStart(text[i])) return null;
    var j = i + 1;
    while (j < text.len and isIdentCont(text[j])) : (j += 1) {}
    return j;
}

/// Parses a JSX element/attribute name:
///   `ident ( '.' ident )*`  (member)   <Foo.Bar>
///   `ident ':' ident`       (namespace) <svg:rect>
/// Returns the name slice and end index, or null.
fn scanName(text: []const u8, i: usize) ?struct { name: []const u8, end: usize } {
    const id1_end = scanIdent(text, i) orelse return null;
    if (id1_end < text.len and text[id1_end] == '.') {
        var last_end = id1_end;
        var j = id1_end;
        while (j < text.len and text[j] == '.') {
            const next = scanIdent(text, j + 1) orelse break;
            last_end = next;
            j = next;
        }
        return .{ .name = text[i..last_end], .end = last_end };
    }
    if (id1_end < text.len and text[id1_end] == ':') {
        const ns_end = scanIdent(text, id1_end + 1) orelse return null;
        return .{ .name = text[i..ns_end], .end = ns_end };
    }
    return .{ .name = text[i..id1_end], .end = id1_end };
}

/// Scans an attribute name (may contain a single `:` for namespaced attrs).
fn scanAttrName(text: []const u8, i: usize) ?struct { name: []const u8, end: usize } {
    const id1_end = scanIdent(text, i) orelse return null;
    if (id1_end < text.len and text[id1_end] == ':') {
        const ns_end = scanIdent(text, id1_end + 1) orelse return null;
        return .{ .name = text[i..ns_end], .end = ns_end };
    }
    return .{ .name = text[i..id1_end], .end = id1_end };
}

/// Parses attributes inside a JSX opening/self-closing tag. `pos` is the
/// index after the tag name — or, when resuming, any earlier attribute
/// boundary. Attributes go to `sink`, which may be null when only the tag's
/// extent is wanted.
///
/// Running out of input is not an error but `.incomplete` with the boundary
/// the scan reached: everything before it is validated, so a caller that
/// accumulates more text resumes from there and never rescans the prefix
/// (SPEC §16.4).
const AttrProgress = union(enum) {
    /// Index of `>` or the `/` of `/>`.
    done: usize,
    /// Out of input; the offset to resume scanning from (the next
    /// attribute boundary).
    incomplete: usize,
    /// Same, but what ran out was an attribute expression: a document that
    /// ends there reports UnclosedMdxExpression (§14.6).
    incomplete_expr: usize,
};

fn scanAttributes(text: []const u8, pos: usize, sink: ?AttrSink) error{ InvalidJsx, OutOfMemory }!AttrProgress {
    var i = pos;

    while (i < text.len) {
        while (i < text.len and isTagWs(text[i])) : (i += 1) {}

        if (i >= text.len) return .{ .incomplete = i };

        if (text[i] == '>') return .{ .done = i };
        if (text[i] == '/') {
            if (i + 1 >= text.len) return .{ .incomplete = i };
            if (text[i + 1] == '>') return .{ .done = i };
            return error.InvalidJsx;
        }

        // Boundary for this attribute: an incomplete anywhere inside it
        // rewinds to here, so the next attempt rescans only this attribute.
        const boundary = i;

        // Spread attribute: { ...expr }
        if (text[i] == '{') {
            var j = i + 1;
            while (j < text.len and isTagWs(text[j])) : (j += 1) {}
            if (j + 2 >= text.len) return .{ .incomplete = boundary };
            if (text[j] != '.' or text[j + 1] != '.' or text[j + 2] != '.') return error.InvalidJsx;
            const expr = (scanExpression(text, i) catch return .{ .incomplete_expr = boundary }) orelse return error.InvalidJsx;
            // Spread value: everything after the `...` up to the closing `}`.
            var val_start = i + 1;
            while (val_start < expr.end_pos and isTagWs(text[val_start])) : (val_start += 1) {}
            val_start += 3;
            const spread_value = text[val_start .. expr.end_pos - 1];
            try AttrSink.put(sink, .{ .spread = spread_value });
            i = expr.end_pos;
            continue;
        }

        // Regular attribute: name [= value]
        const name_scan = scanAttrName(text, i) orelse return error.InvalidJsx;
        const attr_name = name_scan.name;
        var k = name_scan.end;

        // Whitespace is allowed on both sides of `=`, so it is only consumed
        // once the `=` is actually there — otherwise the separator before the
        // next attribute is lost (SPEC §14.4).
        const ws_start = k;
        while (k < text.len and isTagWs(text[k])) : (k += 1) {}

        if (k < text.len and text[k] == '=') {
            k += 1;
            while (k < text.len and isTagWs(text[k])) : (k += 1) {}

            if (k >= text.len) return .{ .incomplete = boundary };

            if (text[k] == '"' or text[k] == '\'') {
                const quote = text[k];
                const val_start = k + 1;
                k += 1;
                while (k < text.len and text[k] != quote) : (k += 1) {}
                if (k >= text.len) return .{ .incomplete = boundary }; // quote may close on a later line
                const attr_val = text[val_start..k];
                k += 1; // skip closing quote
                try AttrSink.put(sink, .{ .static = .{ .name = attr_name, .value = attr_val } });
            } else if (text[k] == '{') {
                // An attribute expression may span lines (SPEC §14.4), so
                // running out of input here means "read more", not "broken".
                const expr = (scanExpression(text, k) catch return .{ .incomplete_expr = boundary }) orelse return error.InvalidJsx;
                const expr_val = text[k + 1 .. expr.end_pos - 1];
                try AttrSink.put(sink, .{ .expression = .{ .name = attr_name, .value = expr_val } });
                k = expr.end_pos;
            } else {
                return error.InvalidJsx;
            }
        } else {
            // Boolean attribute (no value): <input disabled />
            k = ws_start;
            try AttrSink.put(sink, .{ .static = .{ .name = attr_name, .value = null } });
        }
        i = k;
    }
    return .{ .incomplete = i }; // ran off the end without '>'
}

/// How far an incomplete tag scan got — the resume contract for callers that
/// accumulate more text and try again (SPEC §16.4).
pub const TagResume = struct {
    /// Attribute-boundary offset in `text` to continue scanning from.
    /// Everything before it is validated; `0` means the head itself is
    /// unfinished and the whole scan restarts (bounded by one line: tag names
    /// cannot span lines).
    boundary: usize,
    /// The tag name, once the scan has read it (null otherwise).
    name: ?[]const u8,
};

pub const TagScanProgress = union(enum) {
    done: TagBounds,
    incomplete: TagResume,
    incomplete_expr: TagResume,
    /// A `<` that cannot start a tag — the caller treats it as literal text.
    not_tag: void,
};

/// The endgame after the attribute list: `>` or `/>`, or a resume point when
/// the input stops at the `/`.
fn finishTag(text: []const u8, pos: usize, i: usize, name: ?[]const u8) error{ InvalidJsx, OutOfMemory }!TagScanProgress {
    if (text[i] == '/') {
        if (i + 1 >= text.len) return .{ .incomplete = .{ .boundary = i, .name = name } };
        if (text[i + 1] != '>') return error.InvalidJsx;
        return .{ .done = .{ .kind = .self_closing, .name = name, .raw = text[pos .. i + 2], .end_pos = i + 2 } };
    }

    if (text[i] == '>') {
        return .{ .done = .{ .kind = .opening, .name = name, .raw = text[pos .. i + 1], .end_pos = i + 1 } };
    }

    return error.InvalidJsx;
}

/// The single walk over the tag grammar. `sink` decides whether attributes are
/// materialised; the traversal is identical either way, so the two public
/// entry points can never drift apart. Incomplete input reports a resume
/// point instead of an error so multi-line tags can accumulate without
/// rescanning (SPEC §16.4).
fn scanTagInner(text: []const u8, pos: usize, sink: ?AttrSink) error{ InvalidJsx, OutOfMemory }!TagScanProgress {
    if (pos >= text.len or text[pos] != '<') return .not_tag;
    var i = pos + 1;

    if (i >= text.len) return .not_tag;

    // MDX has no comments, CDATA, processing instructions or declarations —
    // `<!` and `<?` can only be a malformed tag (SPEC §14.1). Unlike a `<`
    // that simply cannot start a name, these have no other reading, so they
    // are an error rather than literal text (SPEC §14.6).
    if (text[i] == '!' or text[i] == '?') return error.InvalidJsx;

    // Closing tag: </name> or </> (fragment close)
    if (text[i] == '/') {
        i += 1;
        while (i < text.len and isTagWs(text[i])) : (i += 1) {}
        if (i >= text.len) return .{ .incomplete = .{ .boundary = 0, .name = null } };

        if (text[i] == '>') {
            // Fragment close </>
            return .{ .done = .{ .kind = .closing, .name = null, .raw = text[pos .. i + 1], .end_pos = i + 1 } };
        }

        const name_scan = scanName(text, i) orelse return error.InvalidJsx;
        i = name_scan.end;
        while (i < text.len and isTagWs(text[i])) : (i += 1) {}
        if (i >= text.len) return .{ .incomplete = .{ .boundary = 0, .name = name_scan.name } };
        if (text[i] != '>') return error.InvalidJsx;
        return .{ .done = .{ .kind = .closing, .name = name_scan.name, .raw = text[pos .. i + 1], .end_pos = i + 1 } };
    }

    // Fragment open: <ws* '>'>
    if (isTagWs(text[i]) or text[i] == '>') {
        var j = i;
        while (j < text.len and isTagWs(text[j])) : (j += 1) {}
        if (j < text.len and text[j] == '>') {
            return .{ .done = .{ .kind = .opening, .name = null, .raw = text[pos .. j + 1], .end_pos = j + 1 } };
        }
        // Not a fragment — `<` followed by ws then non-'>'. A tag needs a name
        // first, so this is not JSX at all.
        return .not_tag;
    }

    // Opening or self-closing tag: <name ...>
    const name_scan = scanName(text, i) orelse return .not_tag;
    i = name_scan.end;

    if (i >= text.len) return .{ .incomplete = .{ .boundary = name_scan.end, .name = name_scan.name } };

    if (text[i] == '>') {
        return .{ .done = .{ .kind = .opening, .name = name_scan.name, .raw = text[pos .. i + 1], .end_pos = i + 1 } };
    }

    const attrs = try scanAttributes(text, i, sink);
    const end = switch (attrs) {
        .done => |e| e,
        .incomplete => |r| return .{ .incomplete = .{ .boundary = r, .name = name_scan.name } },
        .incomplete_expr => |r| return .{ .incomplete_expr = .{ .boundary = r, .name = name_scan.name } },
    };

    return finishTag(text, pos, end, name_scan.name);
}

/// Tag extent, kind and name — without building the attribute list, and
/// without an allocator. This is what closing-tag checks, nesting depth counts
/// and child-boundary searches need (SPEC §14.4).
pub fn scanTagBounds(text: []const u8, pos: usize) BoundsError!?TagBounds {
    // Unreachable OOM with a null sink: nothing is allocated.
    const prog = scanTagInner(text, pos, null) catch return error.InvalidJsx;
    return switch (prog) {
        .done => |b| b,
        .incomplete => error.IncompleteJsx,
        .incomplete_expr => error.IncompleteJsxExpression,
        .not_tag => null,
    };
}

/// Scans a JSX tag starting at `pos` (must point to `<`), including its
/// attributes. Use only when a node is actually being built.
///
/// Returns `null` if the text doesn't start a valid JSX tag pattern
/// (e.g. `< a>`, `<1abc>`). The caller should treat `<` as literal text.
pub fn scanTag(arena: Allocator, text: []const u8, pos: usize) ScanError!?TagScan {
    var attrs: AttrList = .empty;
    errdefer attrs.deinit(arena);

    switch (try scanTagInner(text, pos, .{ .arena = arena, .list = &attrs })) {
        .done => |core| return .{
            .kind = core.kind,
            .name = core.name,
            .attributes = try attrs.toOwnedSlice(arena),
            .raw = core.raw,
            .end_pos = core.end_pos,
        },
        .incomplete => return error.IncompleteJsx,
        .incomplete_expr => return error.IncompleteJsxExpression,
        .not_tag => {
            attrs.deinit(arena);
            return null;
        },
    }
}

/// Continues an incomplete tag scan whose prefix is immutable: `boundary`
/// and `name` come from the previous attempt's `.incomplete(.expr)` on this
/// same `text` (typically a growable buffer holding the tag from offset 0).
/// Attributes completed from `boundary` onward are appended to `sink`'s
/// list, so the caller accumulates them across attempts and builds the final
/// tag exactly once — every byte is scanned exactly once (SPEC §16.4).
pub fn scanTagResume(text: []const u8, boundary: usize, name: ?[]const u8, sink: ?AttrSink) error{ InvalidJsx, OutOfMemory }!TagScanProgress {
    if (boundary == 0) return scanTagInner(text, 0, sink);
    const attrs = try scanAttributes(text, boundary, sink);
    const end = switch (attrs) {
        .done => |e| e,
        .incomplete => |r| return .{ .incomplete = .{ .boundary = r, .name = name } },
        .incomplete_expr => |r| return .{ .incomplete_expr = .{ .boundary = r, .name = name } },
    };
    return finishTag(text, 0, end, name);
}

// ── Tests ──────────────────────────────────────────────────────────

test "scanExpression: basic" {
    const text = "{a}";
    const r = (try scanExpression(text, 0)).?;
    try std.testing.expectEqualStrings("a", r.value);
    try std.testing.expectEqualStrings("{a}", r.raw);
    try std.testing.expectEqual(@as(usize, 3), r.end_pos);
}

test "scanExpression: empty" {
    const text = "{}";
    const r = (try scanExpression(text, 0)).?;
    try std.testing.expectEqualStrings("", r.value);
    try std.testing.expectEqualStrings("{}", r.raw);
}

test "scanExpression: nested" {
    const text = "{ {a} }";
    const r = (try scanExpression(text, 0)).?;
    try std.testing.expectEqualStrings(" {a} ", r.value);
}

test "scanExpression: multiline" {
    const text = "{a\n+ b}";
    const r = (try scanExpression(text, 0)).?;
    try std.testing.expectEqualStrings("a\n+ b", r.value);
}

test "scanExpression: unclosed" {
    try std.testing.expectError(error.UnclosedMdxExpression, scanExpression("{unclosed", 0));
    try std.testing.expectError(error.UnclosedMdxExpression, scanExpression("{", 0));
}

test "scanExpression: known limitation — string braces not parsed" {
    // {"}"}  —  first } closes expression. This is a known limitation (SPEC §14.3).
    const text = "{\"}\"}";
    const r = (try scanExpression(text, 0)).?;
    try std.testing.expectEqualStrings("\"", r.value);
    try std.testing.expectEqual(@as(usize, 3), r.end_pos);
}

test "scanExpression: not a brace" {
    try std.testing.expect((try scanExpression("abc", 0)) == null);
}

test "scanTag: self-closing" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const r = (try scanTag(arena, "<A/>", 0)).?;
    try std.testing.expectEqual(TagKind.self_closing, r.kind);
    try std.testing.expectEqualStrings("A", r.name.?);
    try std.testing.expectEqual(@as(usize, 0), r.attributes.len);
    try std.testing.expectEqual(@as(usize, 4), r.end_pos);
}

test "scanTag: self-closing with space" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const r = (try scanTag(arena, "<A />", 0)).?;
    try std.testing.expectEqual(TagKind.self_closing, r.kind);
    try std.testing.expectEqualStrings("A", r.name.?);
}

test "scanTag: opening" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const r = (try scanTag(arena, "<A>", 0)).?;
    try std.testing.expectEqual(TagKind.opening, r.kind);
    try std.testing.expectEqualStrings("A", r.name.?);
}

test "scanTag: closing" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const r = (try scanTag(arena, "</A>", 0)).?;
    try std.testing.expectEqual(TagKind.closing, r.kind);
    try std.testing.expectEqualStrings("A", r.name.?);
}

test "scanTag: fragment open" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const r = (try scanTag(arena, "<>", 0)).?;
    try std.testing.expectEqual(TagKind.opening, r.kind);
    try std.testing.expect(r.name == null);
}

test "scanTag: fragment close" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const r = (try scanTag(arena, "</>", 0)).?;
    try std.testing.expectEqual(TagKind.closing, r.kind);
    try std.testing.expect(r.name == null);
}

test "scanTag: member name" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const r = (try scanTag(arena, "<A.B>", 0)).?;
    try std.testing.expectEqualStrings("A.B", r.name.?);
}

test "scanTag: namespace name" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const r = (try scanTag(arena, "<svg:rect>", 0)).?;
    try std.testing.expectEqualStrings("svg:rect", r.name.?);
}

test "scanTag: static attribute" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const r = (try scanTag(arena, "<a href=\"x\">", 0)).?;
    try std.testing.expectEqualStrings("a", r.name.?);
    try std.testing.expectEqual(@as(usize, 1), r.attributes.len);
    try std.testing.expectEqualStrings("href", r.attributes[0].static.name);
    try std.testing.expectEqualStrings("x", r.attributes[0].static.value.?);
}

test "scanTag: expression attribute" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const r = (try scanTag(arena, "<a x={1 + 2}>", 0)).?;
    try std.testing.expectEqual(@as(usize, 1), r.attributes.len);
    try std.testing.expectEqualStrings("x", r.attributes[0].expression.name);
    try std.testing.expectEqualStrings("1 + 2", r.attributes[0].expression.value);
}

test "scanTag: spread attribute" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const r = (try scanTag(arena, "<div {...props}>", 0)).?;
    try std.testing.expectEqual(@as(usize, 1), r.attributes.len);
    try std.testing.expectEqualStrings("props", r.attributes[0].spread);
}

test "scanTag: boolean attribute (no value)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const r = (try scanTag(arena, "<input disabled>", 0)).?;
    try std.testing.expectEqual(@as(usize, 1), r.attributes.len);
    try std.testing.expectEqualStrings("disabled", r.attributes[0].static.name);
    try std.testing.expect(r.attributes[0].static.value == null);
}

test "scanTag: multiline tag" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const r = (try scanTag(arena, "<Component\n  prop=\"value\"\n/>", 0)).?;
    try std.testing.expectEqual(TagKind.self_closing, r.kind);
    try std.testing.expectEqualStrings("Component", r.name.?);
    try std.testing.expectEqual(@as(usize, 1), r.attributes.len);
}

test "scanTag: not a tag returns null" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expect((try scanTag(arena, "< a>", 0)) == null);
    try std.testing.expect((try scanTag(arena, "<1abc>", 0)) == null);
    try std.testing.expect((try scanTag(arena, "abc", 0)) == null);
}

test "scanTag: invalid name returns error" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectError(error.InvalidJsx, scanTag(arena, "<a =b>", 0));
}

test "scanTag: namespaced attribute name" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const r = (try scanTag(arena, "<svg xlink:href=\"#\">", 0)).?;
    try std.testing.expectEqual(@as(usize, 1), r.attributes.len);
    try std.testing.expectEqualStrings("xlink:href", r.attributes[0].static.name);
}
