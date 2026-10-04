const std = @import("std");
const testing = std.testing;

pub const Heading = struct { depth: u8 };
pub const List = struct { ordered: bool, start: ?usize = null, spread: bool = false };
pub const ListItem = struct { spread: bool = false, checked: ?bool = null };
pub const Code = struct { lang: ?[]const u8 = null, meta: ?[]const u8 = null, value: []const u8 };
pub const Link = struct { url: []const u8, title: ?[]const u8 = null };
pub const Image = struct { url: []const u8, title: ?[]const u8 = null, alt: []const u8 = "" };
pub const ReferenceType = enum { full, collapsed, shortcut };
pub const LinkReference = struct { identifier: []const u8, label: []const u8, reference_type: ReferenceType };
pub const ImageReference = struct { identifier: []const u8, label: []const u8, reference_type: ReferenceType, alt: []const u8 = "" };
pub const Definition = struct { identifier: []const u8, label: []const u8, url: []const u8, title: ?[]const u8 = null };
pub const Align = enum { none, left, center, right };
pub const Table = struct { align_: []const Align };
pub const FootnoteDefinition = struct { identifier: []const u8, label: []const u8 };
pub const FootnoteReference = struct { identifier: []const u8, label: []const u8 };
pub const MdxExpression = struct { value: []const u8, raw: []const u8 };
pub const MdxJsxAttr = union(enum) {
    static: struct { name: []const u8, value: ?[]const u8 },
    expression: struct { name: []const u8, value: []const u8 },
    spread: []const u8,
};
pub const MdxJsxElement = struct {
    name: ?[]const u8,
    attributes: []MdxJsxAttr,
    self_closing: bool,
    raw: []const u8,
};

pub const NodeData = union(enum) {
    root,
    blockquote,
    list: List,
    list_item: ListItem,
    footnote_definition: FootnoteDefinition,
    paragraph,
    heading: Heading,
    thematic_break,
    code: Code,
    html: []const u8,
    definition: Definition,
    text: []const u8,
    emphasis,
    strong,
    inline_code: []const u8,
    break_,
    link: Link,
    image: Image,
    link_reference: LinkReference,
    image_reference: ImageReference,
    delete,
    table: Table,
    table_row,
    table_cell,
    footnote_reference: FootnoteReference,
    mdx_flow_expression: MdxExpression,
    mdx_text_expression: MdxExpression,
    mdx_jsx_flow_element: MdxJsxElement,
    mdx_jsx_text_element: MdxJsxElement,
    yaml: []const u8,
    toml: []const u8,
    math: []const u8,
    inline_math: []const u8,
};

pub const Node = struct {
    data: NodeData,
    position: ?@import("point.zig").Position = null,
    parent: ?*Node = null,
    first_child: ?*Node = null,
    last_child: ?*Node = null,
    next: ?*Node = null,
    prev: ?*Node = null,

    pub fn appendChild(self: *Node, child: *Node) void {
        child.parent = self;
        child.prev = self.last_child;
        child.next = null;
        if (self.last_child) |last| last.next = child else self.first_child = child;
        self.last_child = child;
    }

    pub fn unlink(self: *Node) void {
        if (self.prev) |p| p.next = self.next else if (self.parent) |par| par.first_child = self.next;
        if (self.next) |n| n.prev = self.prev else if (self.parent) |par| par.last_child = self.prev;
        self.parent = null;
        self.prev = null;
        self.next = null;
    }

    /// Links `child` into `self` directly after `ref`, or as the first child
    /// when `ref` is null. `child` must already be unlinked.
    pub fn insertAfter(self: *Node, ref: ?*Node, child: *Node) void {
        child.parent = self;
        if (ref) |r| {
            child.prev = r;
            child.next = r.next;
            if (r.next) |n| n.prev = child else self.last_child = child;
            r.next = child;
        } else {
            child.prev = null;
            child.next = self.first_child;
            if (self.first_child) |f| f.prev = child else self.last_child = child;
            self.first_child = child;
        }
    }

    pub fn childCount(self: *const Node) usize {
        var n: usize = 0;
        var c = self.first_child;
        while (c) |x| : (c = x.next) n += 1;
        return n;
    }
};

/// Inline trees can nest arbitrarily deep — block `max_nesting` does not bound
/// them — so this walk needs its own ceiling or a crafted document takes the
/// process down with a stack overflow instead of an error (SPEC §15).
pub const max_alt_depth: usize = 512;

pub const CollectAltError = error{ OutOfMemory, NestingTooDeep };

/// Flatten a subtree into the plain text used for an image `alt` attribute.
/// Text, inline_code, and the alt of nested images contribute. This is the
/// single canonical implementation used by both the parser and renderer.
pub fn collectAlt(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, node: *const Node) CollectAltError!void {
    return collectAltDepth(buf, allocator, node, 0);
}

fn collectAltDepth(
    buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    node: *const Node,
    depth: usize,
) CollectAltError!void {
    if (depth > max_alt_depth) return error.NestingTooDeep;
    switch (node.data) {
        .text => |t| try buf.appendSlice(allocator, t),
        .inline_code => |code| try buf.appendSlice(allocator, code),
        .image => |img| try buf.appendSlice(allocator, img.alt),
        .image_reference => |ir| try buf.appendSlice(allocator, ir.alt),
        else => {
            var child = node.first_child;
            while (child) |c| : (child = c.next) try collectAltDepth(buf, allocator, c, depth + 1);
        },
    }
}

test "appendChild links parent/sibling; unlink restores" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const root = try a.create(Node);
    root.* = .{ .data = .root };
    const p1 = try a.create(Node);
    p1.* = .{ .data = .paragraph };
    const p2 = try a.create(Node);
    p2.* = .{ .data = .paragraph };

    root.appendChild(p1);
    root.appendChild(p2);

    try testing.expectEqual(root, p1.parent.?);
    try testing.expectEqual(p1, root.first_child.?);
    try testing.expectEqual(p2, root.last_child.?);
    try testing.expectEqual(p2, p1.next.?);
    try testing.expectEqual(p1, p2.prev.?);

    p1.unlink();
    try testing.expectEqual(p2, root.first_child.?);
    try testing.expect(p2.prev == null);
    try testing.expect(p1.parent == null);
    try testing.expectEqual(@as(usize, 1), root.childCount());
}

test "insertAfter places node at head and after a sibling" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const root = try a.create(Node);
    root.* = .{ .data = .root };
    const p1 = try a.create(Node);
    p1.* = .{ .data = .paragraph };
    root.appendChild(p1);

    const head = try a.create(Node);
    head.* = .{ .data = .thematic_break };
    root.insertAfter(null, head);
    try testing.expectEqual(head, root.first_child.?);
    try testing.expectEqual(p1, head.next.?);

    const tail = try a.create(Node);
    tail.* = .{ .data = .thematic_break };
    root.insertAfter(p1, tail);
    try testing.expectEqual(tail, root.last_child.?);
    try testing.expectEqual(p1, tail.prev.?);
    try testing.expectEqual(@as(usize, 3), root.childCount());
}
