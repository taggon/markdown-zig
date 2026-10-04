//! Footnote numbering and ordering for the HTML renderer (SPEC §13.4).
//!
//! Definitions are collected first, then the tree is walked once in document
//! order: a definition gets its number the first time something references it,
//! and each reference gets a 1-based index within its definition. Definitions
//! nothing points at never enter the result.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Node = @import("../node.zig").Node;

pub const Error = error{ NestingTooDeep, OutOfMemory };

const max_depth: usize = 512;

pub const RefInfo = struct {
    /// 1-based footnote number shown in the reference and the section.
    ix: usize,
    /// 1-based index of this reference among those sharing a definition.
    ref_ix: usize,
};

pub const Entry = struct {
    node: *const Node,
    identifier: []const u8,
    ix: usize,
    ref_count: usize,
};

pub const Map = struct {
    /// Referenced definitions, already in `ix` ascending order.
    entries: []Entry,
    refs: std.AutoHashMapUnmanaged(*const Node, RefInfo),

    pub fn deinit(self: *Map, gpa: Allocator) void {
        gpa.free(self.entries);
        self.refs.deinit(gpa);
    }

    pub fn ref(self: *const Map, node: *const Node) ?RefInfo {
        return self.refs.get(node);
    }
};

pub fn build(gpa: Allocator, root: *const Node) Error!Map {
    var defs: std.StringHashMapUnmanaged(*const Node) = .empty;
    defer defs.deinit(gpa);
    try collectDefs(gpa, &defs, root, 0);

    var entries: std.ArrayList(Entry) = .empty;
    errdefer entries.deinit(gpa);
    var refs: std.AutoHashMapUnmanaged(*const Node, RefInfo) = .empty;
    errdefer refs.deinit(gpa);
    var index_of: std.StringHashMapUnmanaged(usize) = .empty;
    defer index_of.deinit(gpa);

    try assign(gpa, root, &defs, &entries, &refs, &index_of, 0);

    return .{ .entries = try entries.toOwnedSlice(gpa), .refs = refs };
}

fn collectDefs(
    gpa: Allocator,
    defs: *std.StringHashMapUnmanaged(*const Node),
    node: *const Node,
    depth: usize,
) Error!void {
    if (depth > max_depth) return error.NestingTooDeep;
    if (node.data == .footnote_definition) {
        const gop = try defs.getOrPut(gpa, node.data.footnote_definition.identifier);
        if (!gop.found_existing) gop.value_ptr.* = node;
    }
    var child = node.first_child;
    while (child) |c| : (child = c.next) try collectDefs(gpa, defs, c, depth + 1);
}

fn assign(
    gpa: Allocator,
    node: *const Node,
    defs: *const std.StringHashMapUnmanaged(*const Node),
    entries: *std.ArrayList(Entry),
    refs: *std.AutoHashMapUnmanaged(*const Node, RefInfo),
    index_of: *std.StringHashMapUnmanaged(usize),
    depth: usize,
) Error!void {
    if (depth > max_depth) return error.NestingTooDeep;

    if (node.data == .footnote_reference) {
        const id = node.data.footnote_reference.identifier;
        const def = defs.get(id) orelse return;
        const gop = try index_of.getOrPut(gpa, id);
        if (!gop.found_existing) {
            gop.value_ptr.* = entries.items.len;
            try entries.append(gpa, .{
                .node = def,
                .identifier = id,
                .ix = entries.items.len + 1,
                .ref_count = 0,
            });
        }
        const entry = &entries.items[gop.value_ptr.*];
        entry.ref_count += 1;
        try refs.put(gpa, node, .{ .ix = entry.ix, .ref_ix = entry.ref_count });
        return;
    }

    var child = node.first_child;
    while (child) |c| : (child = c.next) {
        try assign(gpa, c, defs, entries, refs, index_of, depth + 1);
    }
}

test "build: numbering follows first-reference order" {
    const markdown = @import("../root.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const root = try markdown.parse(
        arena.allocator(),
        "A[^x] B[^y]\n\n[^y]: why\n\n[^x]: ex\n",
        .{ .gfm = true },
    );
    var map = try build(std.testing.allocator, root);
    defer map.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), map.entries.len);
    try std.testing.expectEqualStrings("x", map.entries[0].identifier);
    try std.testing.expectEqual(@as(usize, 1), map.entries[0].ix);
    try std.testing.expectEqualStrings("y", map.entries[1].identifier);
    try std.testing.expectEqual(@as(usize, 2), map.entries[1].ix);
}

test "build: unreferenced definitions are dropped" {
    const markdown = @import("../root.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const root = try markdown.parse(
        arena.allocator(),
        "A[^x]\n\n[^x]: ex\n\n[^unused]: never\n",
        .{ .gfm = true },
    );
    var map = try build(std.testing.allocator, root);
    defer map.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), map.entries.len);
    try std.testing.expectEqualStrings("x", map.entries[0].identifier);
}

test "build: repeated references get increasing ref_ix" {
    const markdown = @import("../root.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const root = try markdown.parse(
        arena.allocator(),
        "A[^x] B[^x] C[^x]\n\n[^x]: ex\n",
        .{ .gfm = true },
    );
    var map = try build(std.testing.allocator, root);
    defer map.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), map.entries.len);
    try std.testing.expectEqual(@as(usize, 3), map.entries[0].ref_count);
}

test "build: empty when there are no footnotes" {
    const markdown = @import("../root.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const root = try markdown.parse(arena.allocator(), "plain\n", .{ .gfm = true });
    var map = try build(std.testing.allocator, root);
    defer map.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), map.entries.len);
}
