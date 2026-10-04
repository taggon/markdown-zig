const std = @import("std");
const Allocator = std.mem.Allocator;
const Node = @import("../node.zig").Node;
const ParseError = @import("../root.zig").ParseError;
const unicode = @import("unicode.zig");

pub const RunInfo = struct {
    char: u8,
    count: usize,
    can_open: bool,
    can_close: bool,
    run_start: usize,
    run_end: usize,
};

pub fn analyzeRun(text: []const u8, pos: usize) ?RunInfo {
    if (pos >= text.len) return null;
    const c = text[pos];
    if (c != '*' and c != '_' and c != '~') return null;

    var count: usize = 0;
    var p = pos;
    while (p < text.len and text[p] == c) : (p += 1) count += 1;
    const run_end = p;

    const before = unicode.decodeBefore(text, pos);
    const after = unicode.decodeAt(text, run_end);

    const preceded_ws = if (before) |cp| unicode.isUnicodeWhitespace(cp) else true;
    const preceded_punct = if (before) |cp| unicode.isUnicodePunctuation(cp) else false;
    const followed_ws = if (after) |cp| unicode.isUnicodeWhitespace(cp) else true;
    const followed_punct = if (after) |cp| unicode.isUnicodePunctuation(cp) else false;

    const left_flanking = !followed_ws and
        (!followed_punct or preceded_ws or preceded_punct);
    const right_flanking = !preceded_ws and
        (!preceded_punct or followed_ws or followed_punct);

    var can_open: bool = undefined;
    var can_close: bool = undefined;
    if (c == '*' or c == '~') {
        can_open = left_flanking;
        can_close = right_flanking;
    } else {
        can_open = left_flanking and (!right_flanking or preceded_punct);
        can_close = right_flanking and (!left_flanking or followed_punct);
    }

    return RunInfo{
        .char = c,
        .count = count,
        .can_open = can_open,
        .can_close = can_close,
        .run_start = pos,
        .run_end = run_end,
    };
}

pub const Delimiter = struct {
    char: u8,
    count: usize,
    orig_count: usize,
    node: *Node,
    can_open: bool,
    can_close: bool,
    prev: ?*Delimiter,
    next: ?*Delimiter,
};

pub const DelimiterStack = struct {
    head: ?*Delimiter = null,
    tail: ?*Delimiter = null,

    pub fn append(self: *DelimiterStack, arena: Allocator, d: Delimiter) Allocator.Error!*Delimiter {
        const ptr = try arena.create(Delimiter);
        ptr.* = d;
        ptr.prev = self.tail;
        ptr.next = null;
        if (self.tail) |t| t.next = ptr else self.head = ptr;
        self.tail = ptr;
        return ptr;
    }

    pub fn remove(self: *DelimiterStack, d: *Delimiter) void {
        if (d.prev) |p| p.next = d.next else self.head = d.next;
        if (d.next) |n| n.prev = d.prev else self.tail = d.prev;
        d.prev = null;
        d.next = null;
    }

    pub fn truncateAfter(self: *DelimiterStack, bottom: ?*Delimiter) void {
        if (bottom) |b| {
            var cur = b.next;
            while (cur) |d| {
                const next = d.next;
                self.remove(d);
                cur = next;
            }
        } else {
            self.head = null;
            self.tail = null;
        }
    }

    pub fn process(self: *DelimiterStack, arena: Allocator, parent: *Node, bottom: ?*Delimiter) ParseError!void {
        // Per-class floor below which no opener can match (SPEC §11.1). Without
        // it every failing closer re-walks the stack to the bottom, which is
        // quadratic on inputs that pile up openers no closer can use.
        var openers_bottom: OpenersBottom = .init(bottom);

        var closer: ?*Delimiter = if (bottom) |b| b.next else self.head;
        while (closer) |cl| {
            if (!cl.can_close) {
                closer = cl.next;
                continue;
            }

            const op = findOpener(cl, openers_bottom.get(cl), bottom);
            if (op == null) {
                // Nothing between `floor` and `cl` can open for this class, and
                // openers are never added during processing — so later closers
                // of the same class need not look below `cl` either.
                openers_bottom.set(cl, cl.prev);
                const nextc = cl.next;
                if (!cl.can_open) self.remove(cl);
                closer = nextc;
                continue;
            }
            const opener_delim = op.?;
            const used: usize = if (opener_delim.char == '~')
                2
            else if (opener_delim.count >= 2 and cl.count >= 2) 2 else 1;

            const new_node = try arena.create(Node);
            new_node.* = .{ .data = if (opener_delim.char == '~')
                .delete
            else if (used == 2) .strong else .emphasis };

            var cur = opener_delim.node.next;
            while (cur) |cn| {
                if (cn == cl.node) break;
                const next_node = cn.next;
                cn.unlink();
                new_node.appendChild(cn);
                cur = next_node;
            }

            parent.insertAfter(opener_delim.node, new_node);

            var dd: ?*Delimiter = opener_delim.next;
            while (dd) |d| {
                if (d == cl) break;
                const dd_next = d.next;
                self.remove(d);
                dd = dd_next;
            }

            opener_delim.count -= used;
            cl.count -= used;

            const nextc = cl.next;
            if (opener_delim.count == 0) {
                opener_delim.node.unlink();
                self.remove(opener_delim);
            } else {
                const trimmed_op = opener_delim.node.data.text[0..opener_delim.count];
                opener_delim.node.data = .{ .text = trimmed_op };
            }

            if (cl.count == 0) {
                cl.node.unlink();
                self.remove(cl);
                closer = nextc;
            } else {
                const trimmed_cl = cl.node.data.text[used..];
                cl.node.data = .{ .text = trimmed_cl };
                closer = cl;
            }
        }
    }
};

/// The floor a closer may search down to, kept per matching class. `findOpener`
/// applies the rule of three, so a failure for one class says nothing about the
/// others — the class must include everything that rule reads: the delimiter
/// character, the closer's run length mod 3, and whether the closer can also
/// open (SPEC §11.1).
const OpenersBottom = struct {
    /// [char][orig_count % 3][can_open]
    slots: [3][3][2]?*Delimiter,

    fn init(bottom: ?*Delimiter) OpenersBottom {
        return .{ .slots = @splat(@splat(@splat(bottom))) };
    }

    fn charIndex(c: u8) usize {
        return switch (c) {
            '*' => 0,
            '_' => 1,
            else => 2, // '~'
        };
    }

    fn get(self: *const OpenersBottom, closer: *const Delimiter) ?*Delimiter {
        return self.slots[charIndex(closer.char)][closer.orig_count % 3][@intFromBool(closer.can_open)];
    }

    fn set(self: *OpenersBottom, closer: *const Delimiter, floor: ?*Delimiter) void {
        self.slots[charIndex(closer.char)][closer.orig_count % 3][@intFromBool(closer.can_open)] = floor;
    }
};

/// Walks down from `closer` for a matching opener.
///
/// Both limits are honoured, whichever comes first. `floor` is the per-class
/// optimisation and may name a delimiter that has since been unlinked, in which
/// case the walk would sail straight past it — `hard_bottom` is what keeps the
/// search inside the current bracket no matter what (SPEC §11.1, §11.2).
fn findOpener(closer: *Delimiter, floor: ?*Delimiter, hard_bottom: ?*Delimiter) ?*Delimiter {
    var opener = closer.prev;
    while (opener) |op| {
        if (op == floor or op == hard_bottom) return null;
        if (op.can_open and op.char == closer.char) {
            if (op.char == '~') {
                if (op.orig_count >= 2 and closer.orig_count >= 2) return op;
            } else {
                const sum_mod_3: usize = (op.orig_count + closer.orig_count) % 3;
                const match_ok = !(closer.can_open or op.can_close) or
                    (closer.orig_count % 3 == 0) or
                    (sum_mod_3 != 0);
                if (match_ok) return op;
            }
        }
        opener = op.prev;
    }
    return null;
}

test "analyzeRun: asterisk basic flanking" {
    const text = "*foo*";
    const r0 = analyzeRun(text, 0).?;
    try std.testing.expectEqual(@as(u8, '*'), r0.char);
    try std.testing.expectEqual(@as(usize, 1), r0.count);
    try std.testing.expect(r0.can_open);

    const r4 = analyzeRun(text, 4).?;
    try std.testing.expectEqual(@as(u8, '*'), r4.char);
    try std.testing.expectEqual(@as(usize, 1), r4.count);
    try std.testing.expect(r4.can_close);
}

test "analyzeRun: underscore intraword" {
    const text = "_foo_";
    const r0 = analyzeRun(text, 0).?;
    try std.testing.expectEqual(@as(u8, '_'), r0.char);

    const intraword = "foo_bar";
    const ri = analyzeRun(intraword, 3).?;
    try std.testing.expectEqual(@as(u8, '_'), ri.char);
    try std.testing.expect(!ri.can_open);
    try std.testing.expect(!ri.can_close);
}

test "DelimiterStack.process: simple emphasis" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const parent = try arena.create(Node);
    parent.* = .{ .data = .paragraph };

    const star1 = try arena.create(Node);
    star1.* = .{ .data = .{ .text = "*" } };
    const mid = try arena.create(Node);
    mid.* = .{ .data = .{ .text = "a" } };
    const star2 = try arena.create(Node);
    star2.* = .{ .data = .{ .text = "*" } };
    parent.appendChild(star1);
    parent.appendChild(mid);
    parent.appendChild(star2);

    var stack: DelimiterStack = .{};
    _ = try stack.append(arena, .{
        .char = '*',
        .count = 1,
        .orig_count = 1,
        .node = star1,
        .can_open = true,
        .can_close = false,
        .prev = null,
        .next = null,
    });
    _ = try stack.append(arena, .{
        .char = '*',
        .count = 1,
        .orig_count = 1,
        .node = star2,
        .can_open = false,
        .can_close = true,
        .prev = null,
        .next = null,
    });

    try stack.process(arena, parent, null);

    try std.testing.expectEqual(@as(usize, 1), parent.childCount());
    const em = parent.first_child.?;
    try std.testing.expect(em.data == .emphasis);
    try std.testing.expectEqual(@as(usize, 1), em.childCount());
    try std.testing.expectEqualStrings("a", em.first_child.?.data.text);
}
