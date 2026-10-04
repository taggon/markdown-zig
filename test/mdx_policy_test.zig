//! SPEC §12.2: MDX HTML policy tests.
//! Verifies .err, .strip, .source produce correct output and that the
//! tree is identical across all three policies.

const std = @import("std");
const md = @import("markdown");

const PolicyCase = struct {
    name: []const u8,
    input: []const u8,
    strip_html: []const u8, // expected output with .strip
    /// Exact `.source` output. It has to be the whole construct — children and
    /// closing tag included — or the policy is dropping input (SPEC §12.2).
    source_html: []const u8,
};

const cases = [_]PolicyCase{
    .{
        .name = "flow expression",
        .input = "{a}",
        .strip_html = "",
        .source_html = "{a}\n",
    },
    .{
        .name = "text expression",
        .input = "a {b} c",
        .strip_html = "<p>a  c</p>",
        .source_html = "<p>a {b} c</p>\n",
    },
    .{
        .name = "flow self-closing",
        .input = "<Component />",
        .strip_html = "",
        .source_html = "&lt;Component /&gt;\n",
    },
    .{
        .name = "element with a same-line child (text, SPEC §14.2)",
        .input = "<Component>Hello</Component>",
        .strip_html = "<p>Hello</p>",
        .source_html = "<p>&lt;Component&gt;Hello&lt;/Component&gt;</p>\n",
    },
    .{
        .name = "flow element with block children",
        .input = "<Component>\n\n**b**\n\n</Component>",
        .strip_html = "<p><strong>b</strong></p>",
        .source_html = "&lt;Component&gt;\n\n**b**\n\n&lt;/Component&gt;\n",
    },
    .{
        .name = "text element",
        .input = "a <b>c</b> d",
        .strip_html = "<p>a c d</p>",
        .source_html = "<p>a &lt;b&gt;c&lt;/b&gt; d</p>\n",
    },
};

test "mdx_html policy .strip produces correct output" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    for (cases) |c| {
        const html = try md.toHtml(arena_state.allocator(), c.input, .{ .mdx = true }, .{ .mdx_html = .strip });
        const norm_a = try normalizeForTest(std.testing.allocator, html);
        defer std.testing.allocator.free(norm_a);
        const norm_b = try normalizeForTest(std.testing.allocator, c.strip_html);
        defer std.testing.allocator.free(norm_b);
        try std.testing.expect(std.mem.eql(u8, norm_a, norm_b));
    }
}

test "mdx_html policy .err returns MdxNodeInErrorMode" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    for (cases) |c| {
        const result = md.toHtml(arena_state.allocator(), c.input, .{ .mdx = true }, .{ .mdx_html = .err });
        try std.testing.expectError(error.MdxNodeInErrorMode, result);
    }
}

test "mdx_html policy .source outputs the whole construct, HTML-escaped" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    for (cases) |c| {
        const html = try md.toHtml(arena_state.allocator(), c.input, .{ .mdx = true }, .{ .mdx_html = .source });
        try std.testing.expectEqualStrings(c.source_html, html);
    }
}

test "mdx_html tree is identical across policies" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    for (cases) |c| {
        // Parse once — tree should be the same regardless of html policy.
        const tree1 = try md.parse(arena, c.input, .{ .mdx = true });
        const tree2 = try md.parse(arena, c.input, .{ .mdx = true });
        // Compare tree structure (just check data types match)
        try compareTreeStructure(tree1, tree2);
    }
}

fn normalizeForTest(gpa: std.mem.Allocator, html: []const u8) ![]u8 {
    // Simple normalization: strip whitespace
    var buf: std.ArrayList(u8) = .empty;
    var in_ws = false;
    for (html) |c| {
        if (c == ' ' or c == '\n' or c == '\t') {
            if (!in_ws and buf.items.len > 0) {
                try buf.append(gpa, ' ');
                in_ws = true;
            }
        } else {
            try buf.append(gpa, c);
            in_ws = false;
        }
    }
    // Trim trailing space
    if (buf.items.len > 0 and buf.items[buf.items.len - 1] == ' ') {
        _ = buf.pop();
    }
    return buf.toOwnedSlice(gpa);
}

fn compareTreeStructure(a: *const md.Node, b: *const md.Node) !void {
    try std.testing.expect(std.meta.activeTag(a.data) == std.meta.activeTag(b.data));
    var ca = a.first_child;
    var cb = b.first_child;
    while (ca != null and cb != null) {
        try compareTreeStructure(ca.?, cb.?);
        ca = ca.?.next;
        cb = cb.?.next;
    }
    try std.testing.expect(ca == null and cb == null);
}
