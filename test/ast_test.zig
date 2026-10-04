//! mdast AST snapshot tests — verifies tree structure beyond HTML comparison.
//! SPEC §16.2 AST layer.
const std = @import("std");
const markdown = @import("markdown");
const Node = markdown.Node;
const NodeData = markdown.NodeData;

/// DFS search for the first node whose `data` active tag matches `tag`.
fn findFirst(root: *const Node, tag: std.meta.Tag(NodeData)) ?*const Node {
    if (@as(std.meta.Tag(NodeData), root.data) == tag) return root;
    var child = root.first_child;
    while (child) |c| : (child = c.next) {
        if (findFirst(c, tag)) |found| return found;
    }
    return null;
}

/// DFS search for the Nth (0-based) node matching `tag`.
fn findNth(root: *const Node, tag: std.meta.Tag(NodeData), n: usize) ?*const Node {
    var count: usize = 0;
    return findNthRec(root, tag, n, &count);
}

fn findNthRec(node: *const Node, tag: std.meta.Tag(NodeData), n: usize, count: *usize) ?*const Node {
    if (@as(std.meta.Tag(NodeData), node.data) == tag) {
        if (count.* == n) return node;
        count.* += 1;
    }
    var child = node.first_child;
    while (child) |c| : (child = c.next) {
        if (findNthRec(c, tag, n, count)) |found| return found;
    }
    return null;
}

// ─── reference_type preservation ─────────────────────────────────────

test "AST: full reference" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const root = try markdown.parse(arena.allocator(), "[a][b]\n\n[b]: /url", .{});
    const lr = findFirst(root, .link_reference).?;
    try std.testing.expectEqualStrings("b", lr.data.link_reference.identifier);
    try std.testing.expectEqualStrings("b", lr.data.link_reference.label);
    try std.testing.expectEqual(.full, lr.data.link_reference.reference_type);
}

test "AST: collapsed reference" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const root = try markdown.parse(arena.allocator(), "[a][]\n\n[a]: /url", .{});
    const lr = findFirst(root, .link_reference).?;
    try std.testing.expectEqualStrings("a", lr.data.link_reference.identifier);
    try std.testing.expectEqual(.collapsed, lr.data.link_reference.reference_type);
}

test "AST: shortcut reference" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const root = try markdown.parse(arena.allocator(), "[a]\n\n[a]: /url", .{});
    const lr = findFirst(root, .link_reference).?;
    try std.testing.expectEqualStrings("a", lr.data.link_reference.identifier);
    try std.testing.expectEqual(.shortcut, lr.data.link_reference.reference_type);
}

// ─── definition identifier vs label ──────────────────────────────────

test "AST: definition identifier is normalized, label preserves whitespace-collapsed text" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const root = try markdown.parse(arena.allocator(), "[Foo  Bar]: /url \"t\"", .{});
    const def = findFirst(root, .definition).?;
    try std.testing.expectEqualStrings("foo bar", def.data.definition.identifier);
    try std.testing.expectEqualStrings("Foo Bar", def.data.definition.label);
    try std.testing.expectEqualStrings("/url", def.data.definition.url);
    try std.testing.expectEqualStrings("t", def.data.definition.title.?);
}

// ─── soft line ending in text ────────────────────────────────────────

test "AST: soft line break preserved as \\n in text" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const root = try markdown.parse(arena.allocator(), "a\nb", .{});
    const para = findFirst(root, .paragraph).?;
    const text_node = para.first_child.?;
    try std.testing.expect(text_node.data == .text);
    try std.testing.expectEqualStrings("a\nb", text_node.data.text);
}

// ─── image alt flattening ────────────────────────────────────────────

test "AST: image alt flattens inline content" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const root = try markdown.parse(arena.allocator(), "![a *b* `c`](/url)", .{});
    const img = findFirst(root, .image).?;
    try std.testing.expectEqualStrings("a b c", img.data.image.alt);
}

// ─── list spread (tight/loose) ───────────────────────────────────────

test "AST: tight list has spread=false" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const root = try markdown.parse(arena.allocator(), "- a\n- b\n", .{});
    const list = findFirst(root, .list).?;
    try std.testing.expectEqual(false, list.data.list.spread);
}

test "AST: loose list has spread=true" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const root = try markdown.parse(arena.allocator(), "- a\n\n- b\n", .{});
    const list = findFirst(root, .list).?;
    try std.testing.expectEqual(true, list.data.list.spread);
}

// ─── list_item.checked ───────────────────────────────────────────────

test "AST: task list item checked state" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const root = try markdown.parse(arena.allocator(), "- [x] done\n- [ ] todo\n", .{ .gfm = true });

    const item0 = findNth(root, .list_item, 0).?;
    try std.testing.expectEqual(@as(?bool, true), item0.data.list_item.checked);

    const item1 = findNth(root, .list_item, 1).?;
    try std.testing.expectEqual(@as(?bool, false), item1.data.list_item.checked);
}

test "AST: non-task list item has checked=null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const root = try markdown.parse(arena.allocator(), "- plain\n", .{});
    const item = findFirst(root, .list_item).?;
    try std.testing.expectEqual(@as(?bool, null), item.data.list_item.checked);
}

// ─── frontmatter (SPEC §9.3) ─────────────────────────────────────────

test "AST: YAML frontmatter produces yaml node" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const root = try markdown.parse(
        arena.allocator(),
        "---\ntitle: Hello\ntags: [a, b]\n---\n\nBody\n",
        .{ .frontmatter = true },
    );
    const yaml = root.first_child.?;
    try std.testing.expect(yaml.data == .yaml);
    try std.testing.expectEqualStrings("title: Hello\ntags: [a, b]", yaml.data.yaml);
}

test "AST: TOML frontmatter produces toml node" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const root = try markdown.parse(
        arena.allocator(),
        "+++\ntitle = \"Hi\"\n+++\n\nBody\n",
        .{ .frontmatter = true },
    );
    const toml = root.first_child.?;
    try std.testing.expect(toml.data == .toml);
    try std.testing.expectEqualStrings("title = \"Hi\"", toml.data.toml);
}

test "AST: frontmatter is first child, body follows" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const root = try markdown.parse(
        arena.allocator(),
        "---\nx: 1\n---\n# Heading\n",
        .{ .frontmatter = true },
    );
    const yaml = root.first_child.?;
    try std.testing.expect(yaml.data == .yaml);
    const heading = yaml.next.?;
    try std.testing.expect(heading.data == .heading);
    try std.testing.expectEqual(@as(u8, 1), heading.data.heading.depth);
}

test "AST: no closing fence is not frontmatter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const root = try markdown.parse(
        arena.allocator(),
        "---\nhello\n",
        .{ .frontmatter = true },
    );
    // Without a closing fence, --- is a thematic break and hello a paragraph.
    try std.testing.expect(findFirst(root, .yaml) == null);
    try std.testing.expect(findFirst(root, .thematic_break) != null);
}

test "AST: frontmatter not on first line is not recognised" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const root = try markdown.parse(
        arena.allocator(),
        "\n---\nx: 1\n---\n",
        .{ .frontmatter = true },
    );
    try std.testing.expect(findFirst(root, .yaml) == null);
}

test "AST: empty frontmatter content" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const root = try markdown.parse(
        arena.allocator(),
        "---\n---\n\nBody\n",
        .{ .frontmatter = true },
    );
    const yaml = root.first_child.?;
    try std.testing.expect(yaml.data == .yaml);
    try std.testing.expectEqualStrings("", yaml.data.yaml);
}

test "AST: frontmatter disabled treats --- as markdown" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const root = try markdown.parse(
        arena.allocator(),
        "---\ntitle: Hello\n---\n\nBody\n",
        .{},
    );
    try std.testing.expect(findFirst(root, .yaml) == null);
}

test "AST: frontmatter works with GFM combination" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const root = try markdown.parse(
        arena.allocator(),
        "---\ntitle: Hi\n---\n\n~~strike~~\n",
        .{ .frontmatter = true, .gfm = true },
    );
    const yaml = root.first_child.?;
    try std.testing.expect(yaml.data == .yaml);
    try std.testing.expectEqualStrings("title: Hi", yaml.data.yaml);
    try std.testing.expect(findFirst(root, .delete) != null);
}

test "HTML: frontmatter produces no output" {
    const html = try markdown.toHtml(
        std.testing.allocator,
        "---\ntitle: Secret\n---\n\nHello\n",
        .{ .frontmatter = true },
        .{},
    );
    defer std.testing.allocator.free(html);
    try std.testing.expect(std.mem.indexOf(u8, html, "Secret") == null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<p>Hello</p>") != null);
}

// ─── math (SPEC §9.4) ────────────────────────────────────────────────

test "AST: block math multiline" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const root = try markdown.parse(
        arena.allocator(),
        "$$\na^2 + b^2\n$$\n",
        .{ .math = true },
    );
    const m = findFirst(root, .math).?;
    try std.testing.expectEqualStrings("a^2 + b^2", m.data.math);
}

test "AST: block math single-line" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const root = try markdown.parse(
        arena.allocator(),
        "$$x^2$$\n",
        .{ .math = true },
    );
    const m = findFirst(root, .math).?;
    try std.testing.expectEqualStrings("x^2", m.data.math);
}

test "AST: block math no closing consumes to EOF" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const root = try markdown.parse(
        arena.allocator(),
        "$$\nunclosed math\n",
        .{ .math = true },
    );
    const m = findFirst(root, .math).?;
    try std.testing.expectEqualStrings("unclosed math", m.data.math);
}

test "AST: block math interrupts paragraph" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const root = try markdown.parse(
        arena.allocator(),
        "text\n$$\nmath\n$$\n",
        .{ .math = true },
    );
    const para = root.first_child.?;
    try std.testing.expect(para.data == .paragraph);
    const m = para.next.?;
    try std.testing.expect(m.data == .math);
    try std.testing.expectEqualStrings("math", m.data.math);
}

test "AST: inline math basic" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const root = try markdown.parse(
        arena.allocator(),
        "The formula $a + b$ works\n",
        .{ .math = true },
    );
    const m = findFirst(root, .inline_math).?;
    try std.testing.expectEqualStrings("a + b", m.data.inline_math);
}

test "AST: inline math rejects space after opener" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const root = try markdown.parse(
        arena.allocator(),
        "$ a$ is not math\n",
        .{ .math = true },
    );
    try std.testing.expect(findFirst(root, .inline_math) == null);
}

test "AST: inline math rejects mid-word dollar" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const root = try markdown.parse(
        arena.allocator(),
        "a$b$ is not math\n",
        .{ .math = true },
    );
    try std.testing.expect(findFirst(root, .inline_math) == null);
}

test "AST: inline math math disabled treats dollar as literal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const root = try markdown.parse(
        arena.allocator(),
        "$a + b$\n",
        .{},
    );
    try std.testing.expect(findFirst(root, .inline_math) == null);
}

test "HTML: math renders LaTeX markers" {
    const html = try markdown.toHtml(
        std.testing.allocator,
        "$$x^2$$\n\nInline $a+b$ here\n",
        .{ .math = true },
        .{},
    );
    defer std.testing.allocator.free(html);
    try std.testing.expect(std.mem.indexOf(u8, html, "\\[x^2\\]") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "\\(a+b\\)") != null);
}

// ─── Source positions (SPEC §7) ──────────────────────────────────────

test "position: root covers entire document" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const root = try markdown.parse(arena.allocator(), "hello\nworld\n", .{});
    const pos = root.position.?;
    try std.testing.expectEqual(@as(usize, 1), pos.start.line);
    try std.testing.expectEqual(@as(usize, 1), pos.start.column);
    try std.testing.expectEqual(@as(usize, 0), pos.start.offset);
    try std.testing.expectEqual(@as(usize, 2), pos.end.line);
}

test "position: empty document has null position" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const root = try markdown.parse(arena.allocator(), "", .{});
    try std.testing.expect(root.position == null);
}

test "position: simple paragraph" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const root = try markdown.parse(arena.allocator(), "hello", .{});
    const para = findFirst(root, .paragraph).?;
    const pos = para.position.?;
    try std.testing.expectEqual(@as(usize, 1), pos.start.line);
    try std.testing.expectEqual(@as(usize, 1), pos.start.column);
    try std.testing.expectEqual(@as(usize, 0), pos.start.offset);
    try std.testing.expectEqual(@as(usize, 1), pos.end.line);
    try std.testing.expectEqual(@as(usize, 6), pos.end.column);
    try std.testing.expectEqual(@as(usize, 5), pos.end.offset);
}

test "position: multiline paragraph" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const root = try markdown.parse(arena.allocator(), "hello\nworld\n", .{});
    const para = findFirst(root, .paragraph).?;
    const pos = para.position.?;
    try std.testing.expectEqual(@as(usize, 1), pos.start.line);
    try std.testing.expectEqual(@as(usize, 2), pos.end.line);
    try std.testing.expectEqual(@as(usize, 6), pos.end.column);
    try std.testing.expectEqual(@as(usize, 11), pos.end.offset);
}

test "position: ATX heading" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const root = try markdown.parse(arena.allocator(), "# Title", .{});
    const h = findFirst(root, .heading).?;
    const pos = h.position.?;
    try std.testing.expectEqual(@as(usize, 1), pos.start.line);
    try std.testing.expectEqual(@as(usize, 1), pos.start.column);
    try std.testing.expectEqual(@as(usize, 8), pos.end.column);
}

test "position: setext heading" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const root = try markdown.parse(arena.allocator(), "Title\n=====\n", .{});
    const h = findFirst(root, .heading).?;
    const pos = h.position.?;
    try std.testing.expectEqual(@as(usize, 1), pos.start.line);
    try std.testing.expectEqual(@as(usize, 2), pos.end.line);
}

test "position: fenced code" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const root = try markdown.parse(arena.allocator(), "```\ncode\n```\n", .{});
    const code = findFirst(root, .code).?;
    const pos = code.position.?;
    try std.testing.expectEqual(@as(usize, 1), pos.start.line);
    try std.testing.expectEqual(@as(usize, 3), pos.end.line);
}

test "position: thematic break" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const root = try markdown.parse(arena.allocator(), "---\n", .{});
    const tb = findFirst(root, .thematic_break).?;
    const pos = tb.position.?;
    try std.testing.expectEqual(@as(usize, 1), pos.start.line);
    try std.testing.expectEqual(@as(usize, 1), pos.start.column);
    try std.testing.expectEqual(@as(usize, 4), pos.end.column);
}

test "position: blockquote" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const root = try markdown.parse(arena.allocator(), "> hello\n", .{});
    const bq = findFirst(root, .blockquote).?;
    const pos = bq.position.?;
    try std.testing.expectEqual(@as(usize, 1), pos.start.line);
    try std.testing.expectEqual(@as(usize, 1), pos.start.column);
    try std.testing.expectEqual(@as(usize, 8), pos.end.column);
    // Paragraph inside starts after "> "
    const para = findFirst(root, .paragraph).?;
    const ppos = para.position.?;
    try std.testing.expectEqual(@as(usize, 1), ppos.start.line);
    try std.testing.expectEqual(@as(usize, 3), ppos.start.column);
    try std.testing.expectEqual(@as(usize, 2), ppos.start.offset);
}

test "position: list and list_item" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const root = try markdown.parse(arena.allocator(), "- item\n", .{});
    const list = findFirst(root, .list).?;
    const lpos = list.position.?;
    try std.testing.expectEqual(@as(usize, 1), lpos.start.line);
    try std.testing.expectEqual(@as(usize, 7), lpos.end.column);
    const item = findFirst(root, .list_item).?;
    const ipos = item.position.?;
    try std.testing.expectEqual(@as(usize, 1), ipos.start.line);
}

test "position: multibyte UTF-8 column" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const root = try markdown.parse(arena.allocator(), "한글", .{});
    const para = findFirst(root, .paragraph).?;
    const pos = para.position.?;
    try std.testing.expectEqual(@as(usize, 1), pos.start.line);
    try std.testing.expectEqual(@as(usize, 1), pos.start.column);
    try std.testing.expectEqual(@as(usize, 3), pos.end.column); // 2 code points + 1
    try std.testing.expectEqual(@as(usize, 6), pos.end.offset); // 6 bytes
}

test "position: CRLF line ending" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const root = try markdown.parse(arena.allocator(), "hello\r\nworld\r\n", .{});
    const para = findFirst(root, .paragraph).?;
    const pos = para.position.?;
    try std.testing.expectEqual(@as(usize, 1), pos.start.line);
    try std.testing.expectEqual(@as(usize, 2), pos.end.line);
    try std.testing.expectEqual(@as(usize, 6), pos.end.column);
}

test "position: inline text node" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const root = try markdown.parse(arena.allocator(), "hello", .{});
    const para = findFirst(root, .paragraph).?;
    const text = para.first_child.?;
    const pos = text.position.?;
    try std.testing.expectEqual(@as(usize, 1), pos.start.line);
    try std.testing.expectEqual(@as(usize, 1), pos.start.column);
    try std.testing.expectEqual(@as(usize, 6), pos.end.column);
    try std.testing.expectEqual(@as(usize, 0), pos.start.offset);
    try std.testing.expectEqual(@as(usize, 5), pos.end.offset);
}

test "position: inline emphasis" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const root = try markdown.parse(arena.allocator(), "*bold*", .{});
    const para = findFirst(root, .paragraph).?;
    const em = para.first_child.?;
    try std.testing.expect(em.data == .emphasis);
    const pos = em.position.?;
    try std.testing.expectEqual(@as(usize, 1), pos.start.line);
    try std.testing.expectEqual(@as(usize, 2), pos.start.column); // 'b' after *
    try std.testing.expectEqual(@as(usize, 6), pos.end.column); // after 'd', before closing *
}

test "position: inline code span" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const root = try markdown.parse(arena.allocator(), "a `code` b", .{});
    const code = findFirst(root, .inline_code).?;
    const pos = code.position.?;
    try std.testing.expectEqual(@as(usize, 1), pos.start.line);
    try std.testing.expectEqual(@as(usize, 3), pos.start.column); // opening `
    try std.testing.expectEqual(@as(usize, 9), pos.end.column); // after closing `
}

test "position: inline link" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const root = try markdown.parse(arena.allocator(), "[text](/url)", .{});
    const link = findFirst(root, .link).?;
    const pos = link.position.?;
    try std.testing.expectEqual(@as(usize, 1), pos.start.line);
    try std.testing.expectEqual(@as(usize, 1), pos.start.column);
    try std.testing.expectEqual(@as(usize, 13), pos.end.column); // after )
}

test "position: frontmatter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const root = try markdown.parse(arena.allocator(), "---\nkey: val\n---\n", .{ .frontmatter = true });
    const yaml = findFirst(root, .yaml).?;
    const pos = yaml.position.?;
    try std.testing.expectEqual(@as(usize, 1), pos.start.line);
    try std.testing.expectEqual(@as(usize, 3), pos.end.line);
}

test "position: math block" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const root = try markdown.parse(arena.allocator(), "$$x^2$$\n", .{ .math = true });
    const math = findFirst(root, .math).?;
    const pos = math.position.?;
    try std.testing.expectEqual(@as(usize, 1), pos.start.line);
    try std.testing.expectEqual(@as(usize, 8), pos.end.column);
}

// ─── footnote definitions (SPEC §13.2) ───────────────────────────────

test "AST: footnote definition identifier and label" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const root = try markdown.parse(
        arena.allocator(),
        "x[^Ref]\n\n[^Ref]: body\n",
        .{ .gfm = true },
    );
    const def = findFirst(root, .footnote_definition).?;
    try std.testing.expectEqualStrings("ref", def.data.footnote_definition.identifier);
    try std.testing.expectEqualStrings("Ref", def.data.footnote_definition.label);
    try std.testing.expect(def.first_child.?.data == .paragraph);
}

test "AST: footnote definition content indent is 4, not the colon column" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const root = try markdown.parse(
        arena.allocator(),
        "x[^a]\n\n[^a]:       plain text\n",
        .{ .gfm = true },
    );
    const def = findFirst(root, .footnote_definition).?;
    try std.testing.expect(def.first_child.?.data == .paragraph);
    try std.testing.expect(findFirst(root, .code) == null);
}

test "AST: 8-space continuation inside a definition is a code block" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const root = try markdown.parse(
        arena.allocator(),
        "x[^a]\n\n[^a]:\n        code\n",
        .{ .gfm = true },
    );
    const def = findFirst(root, .footnote_definition).?;
    try std.testing.expect(def.first_child.?.data == .code);
    try std.testing.expectEqualStrings("code\n", def.first_child.?.data.code.value);
}

test "AST: a line indented less than 4 closes the definition" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const root = try markdown.parse(
        arena.allocator(),
        "x[^a]\n\n[^a]: one\n\nafter\n",
        .{ .gfm = true },
    );
    const def = findFirst(root, .footnote_definition).?;
    try std.testing.expect(def.next != null);
    try std.testing.expect(def.next.?.data == .paragraph);
}

test "AST: definition interrupts a paragraph" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const root = try markdown.parse(
        arena.allocator(),
        "x[^a]\n\npara text\n[^a]: body\n",
        .{ .gfm = true },
    );
    try std.testing.expect(findFirst(root, .footnote_definition) != null);
}

test "AST: definition is inert without gfm" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const root = try markdown.parse(arena.allocator(), "[^a]: body\n", .{});
    try std.testing.expect(findFirst(root, .footnote_definition) == null);
}

test "AST: footnote definition has a source position" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const root = try markdown.parse(
        arena.allocator(),
        "x[^a]\n\n[^a]: body\n",
        .{ .gfm = true },
    );
    const def = findFirst(root, .footnote_definition).?;
    const pos = def.position.?;
    try std.testing.expectEqual(@as(usize, 3), pos.start.line);
    try std.testing.expectEqual(@as(usize, 1), pos.start.column);
}

test "AST: a leaf construct on the definition line opens inside it (MDX flow)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const root = try markdown.parse(
        arena.allocator(),
        "x[^1]\n\n[^1]: <a>\n    content\n    </a>\n",
        .{ .gfm = true, .mdx = true },
    );
    // The `<a>` after the marker is the definition's first content line: the
    // JSX flow element — and its paragraph child — live inside the definition
    // instead of the element's close tag hitting an empty document frame.
    const def = findFirst(root, .footnote_definition).?;
    const elem = def.first_child.?;
    try std.testing.expect(elem.data == .mdx_jsx_flow_element);
    try std.testing.expectEqualStrings("a", elem.data.mdx_jsx_flow_element.name.?);
    try std.testing.expectEqualStrings("<a>\n    content\n    </a>", elem.data.mdx_jsx_flow_element.raw);
    const para = elem.first_child.?;
    try std.testing.expect(para.data == .paragraph);
    try std.testing.expectEqualStrings("content", para.first_child.?.data.text);

    const html = try markdown.toHtml(
        arena.allocator(),
        "x[^1]\n\n[^1]: <a>\n    content\n    </a>\n",
        .{ .gfm = true, .mdx = true },
        .{},
    );
    try std.testing.expectEqualStrings(
        "<p>x<sup class=\"footnote-ref\"><a href=\"#fn-1\" id=\"fnref-1\" data-footnote-ref>1</a></sup></p>\n" ++
            "<section class=\"footnotes\" data-footnotes>\n<ol>\n<li id=\"fn-1\">\n" ++
            "<p>content</p>\n" ++
            "<a href=\"#fnref-1\" class=\"footnote-backref\" data-footnote-backref data-footnote-backref-idx=\"1\" aria-label=\"Back to reference 1\">↩</a>\n" ++
            "</li>\n</ol>\n</section>\n",
        html,
    );
}

// ─── footnote references (SPEC §13.3) ────────────────────────────────

test "AST: reference resolves to a defined footnote" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const root = try markdown.parse(
        arena.allocator(),
        "see[^Note]\n\n[^note]: body\n",
        .{ .gfm = true },
    );
    const ref = findFirst(root, .footnote_reference).?;
    try std.testing.expectEqualStrings("note", ref.data.footnote_reference.identifier);
    try std.testing.expectEqualStrings("Note", ref.data.footnote_reference.label);
    try std.testing.expect(ref.first_child == null);
}

test "AST: undefined reference stays literal text" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const root = try markdown.parse(
        arena.allocator(),
        "no referent[^nope].\n",
        .{ .gfm = true },
    );
    try std.testing.expect(findFirst(root, .footnote_reference) == null);
}

test "AST: reference before its definition still resolves" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const root = try markdown.parse(
        arena.allocator(),
        "a[^x]\n\n[^x]: body\n",
        .{ .gfm = true },
    );
    try std.testing.expect(findFirst(root, .footnote_reference) != null);
}

test "AST: reference is inert without gfm" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const root = try markdown.parse(arena.allocator(), "a[^x]\n\n[^x]: b\n", .{});
    try std.testing.expect(findFirst(root, .footnote_reference) == null);
}

test "AST: `![^x]` is a literal `!` plus a reference (cmark-gfm, SPEC §13.3)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const root = try markdown.parse(
        arena.allocator(),
        "![^x]\n\n[^x]: body\n",
        .{ .gfm = true },
    );
    const para = root.first_child.?;
    try std.testing.expect(para.data == .paragraph);
    const bang = para.first_child.?;
    try std.testing.expectEqualStrings("!", bang.data.text);
    try std.testing.expect(bang.next.?.data == .footnote_reference);
    try std.testing.expect(findFirst(root, .image) == null);
}

test "AST: `![^x]` stays an image when the reference does not resolve" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const root = try markdown.parse(
        arena.allocator(),
        "![^x](/url)\n",
        .{ .gfm = true },
    );
    const img = findFirst(root, .image) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("/url", img.data.image.url);
    try std.testing.expectEqualStrings("^x", img.data.image.alt);
    try std.testing.expect(findFirst(root, .footnote_reference) == null);
}

test "AST: footnote reference has a source position" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const root = try markdown.parse(
        arena.allocator(),
        "ab[^x]\n\n[^x]: body\n",
        .{ .gfm = true },
    );
    const pos = findFirst(root, .footnote_reference).?.position.?;
    try std.testing.expectEqual(@as(usize, 1), pos.start.line);
    try std.testing.expectEqual(@as(usize, 3), pos.start.column);
    try std.testing.expectEqual(@as(usize, 7), pos.end.column);
}

// ─── footnote HTML (SPEC §13.5) ──────────────────────────────────────

fn renderGfm(arena: std.mem.Allocator, src: []const u8) ![]u8 {
    return markdown.toHtml(arena, src, .{ .gfm = true }, .{});
}

test "HTML: reference and section" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try renderGfm(arena.allocator(), "A[^x]\n\n[^x]: ex\n");
    try std.testing.expectEqualStrings(
        "<p>A<sup class=\"footnote-ref\"><a href=\"#fn-x\" id=\"fnref-x\" data-footnote-ref>1</a></sup></p>\n" ++
            "<section class=\"footnotes\" data-footnotes>\n<ol>\n<li id=\"fn-x\">\n" ++
            "<p>ex <a href=\"#fnref-x\" class=\"footnote-backref\" data-footnote-backref data-footnote-backref-idx=\"1\" aria-label=\"Back to reference 1\">↩</a></p>\n" ++
            "</li>\n</ol>\n</section>\n",
        out,
    );
}

test "HTML: no section when nothing is referenced" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try renderGfm(arena.allocator(), "plain\n\n[^x]: ex\n");
    try std.testing.expectEqualStrings("<p>plain</p>\n", out);
}

test "HTML: backref sits on its own line after a non-paragraph block" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try renderGfm(arena.allocator(), "A[^x]\n\n[^x]:\n        code\n");
    try std.testing.expect(std.mem.endsWith(
        u8,
        out,
        "</code></pre>\n<a href=\"#fnref-x\" class=\"footnote-backref\" data-footnote-backref data-footnote-backref-idx=\"1\" aria-label=\"Back to reference 1\">↩</a>\n</li>\n</ol>\n</section>\n",
    ));
}

test "HTML: repeated references produce numbered backrefs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try renderGfm(arena.allocator(), "A[^x] B[^x]\n\n[^x]: ex\n");
    try std.testing.expect(std.mem.indexOf(u8, out, "id=\"fnref-x-2\"") != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        out,
        "data-footnote-backref-idx=\"1-2\" aria-label=\"Back to reference 1-2\">↩<sup class=\"footnote-ref\">2</sup></a>",
    ) != null);
}

test "HTML: identifier is href escaped" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try renderGfm(
        arena.allocator(),
        "Hello[^\"><script>alert(1)</script>]\n\n[^\"><script>alert(1)</script>]: pwned\n",
    );
    try std.testing.expect(std.mem.indexOf(
        u8,
        out,
        "href=\"#fn-%22%3E%3Cscript%3Ealert(1)%3C/script%3E\"",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "<script>") == null);
}

test "HTML: gfm_footnote_label inserts an h2" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try markdown.toHtml(
        arena.allocator(),
        "A[^x]\n\n[^x]: ex\n",
        .{ .gfm = true },
        .{ .gfm_footnote_label = "Footnotes" },
    );
    try std.testing.expect(std.mem.indexOf(
        u8,
        out,
        "<section class=\"footnotes\" data-footnotes>\n<h2 class=\"sr-only\" id=\"footnote-label\">Footnotes</h2>\n<ol>\n",
    ) != null);
}

test "HTML: a reference with no definition falls back to literal text" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Hand-built tree: the parser never makes an unresolved reference, but a
    // caller can (SPEC §13.5).
    const root = try arena.create(Node);
    root.* = .{ .data = .root };
    const para = try arena.create(Node);
    para.* = .{ .data = .paragraph };
    root.appendChild(para);
    const ref = try arena.create(Node);
    ref.* = .{ .data = .{ .footnote_reference = .{ .identifier = "x", .label = "x" } } };
    para.appendChild(ref);

    const out = try markdown.renderHtml(arena, root, .{});
    try std.testing.expectEqualStrings("<p>[^x]</p>\n", out);
}

// ─── MDX flow vs text judgement (SPEC §14.2) ─────────────────────────

const mdx_opts: markdown.ParseOptions = .{ .mdx = true };

test "AST: a tag followed by text is not flow" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const root = try markdown.parse(arena.allocator(), "<A/> tail\n", mdx_opts);
    try std.testing.expect(root.first_child.?.data == .paragraph);
    try std.testing.expect(findFirst(root, .mdx_jsx_text_element) != null);
    try std.testing.expect(findFirst(root, .mdx_jsx_flow_element) == null);
}

test "AST: a tag chain is flow" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const root = try markdown.parse(arena.allocator(), "<A/><B/>\n", mdx_opts);
    try std.testing.expect(findFirst(root, .paragraph) == null);
    try std.testing.expectEqual(@as(usize, 2), root.childCount());
    try std.testing.expect(root.first_child.?.data == .mdx_jsx_flow_element);
}

test "AST: flow interrupts a paragraph, non-flow does not" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const interrupted = try markdown.parse(arena.allocator(), "a\n<A/>\n", mdx_opts);
    try std.testing.expectEqual(@as(usize, 2), interrupted.childCount());
    try std.testing.expect(interrupted.last_child.?.data == .mdx_jsx_flow_element);

    const kept = try markdown.parse(arena.allocator(), "a\n<A>b</A>\n", mdx_opts);
    try std.testing.expectEqual(@as(usize, 1), kept.childCount());
    try std.testing.expect(findFirst(kept, .mdx_jsx_text_element) != null);
}

test "AST: same-name nesting keeps both elements" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const root = try markdown.parse(arena.allocator(), "<A>\n\n<A>\n\nx\n\n</A>\n\n</A>\n", mdx_opts);
    const outer = root.first_child.?;
    try std.testing.expect(outer.data == .mdx_jsx_flow_element);
    try std.testing.expect(outer.first_child.?.data == .mdx_jsx_flow_element);
}

test "AST: element raw covers the whole element, not just the opening tag" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const text_root = try markdown.parse(arena.allocator(), "a <b>c</b> d\n", mdx_opts);
    const text_elem = findFirst(text_root, .mdx_jsx_text_element).?;
    try std.testing.expectEqualStrings("<b>c</b>", text_elem.data.mdx_jsx_text_element.raw);

    const flow_root = try markdown.parse(arena.allocator(), "<A>\n\nx\n\n</A>\n", mdx_opts);
    const flow_elem = findFirst(flow_root, .mdx_jsx_flow_element).?;
    try std.testing.expectEqualStrings("<A>\n\nx\n\n</A>", flow_elem.data.mdx_jsx_flow_element.raw);
}

// SPEC §14.6 error taxonomy: EOF while still inside an attribute expression
// reports UnclosedMdxExpression; EOF anywhere else mid-tag reports
// InvalidMdxJsx. The expr_pending reset is what keeps a *closed* expression
// followed by more tag from being misreported as an expression error.
test "AST: a close tag inside an expression does not close the element" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The child-boundary judgement is shared by both phases (mdx_scan
    // .findMatchingClose, SPEC §3.1): a same-name close tag inside a `{…}`
    // span is expression content, not the element's close.
    const root = try markdown.parse(arena, "<Box\n> {</Box>} </Box>\n", .{ .mdx = true });
    const elem = root.first_child.?;
    try std.testing.expect(elem.data == .mdx_jsx_flow_element);
    try std.testing.expectEqualStrings("Box", elem.data.mdx_jsx_flow_element.name.?);
    const para = elem.first_child.?;
    try std.testing.expect(para.data == .paragraph);
    const expr = para.first_child.?;
    try std.testing.expect(expr.data == .mdx_text_expression);
    try std.testing.expectEqualStrings("</Box>", expr.data.mdx_text_expression.value);
    try std.testing.expect(elem.next == null);

    // Same judgement on the inline path: the element spans its expression
    // child and closes on the real tag.
    const root2 = try markdown.parse(arena, "x <Box>{</Box>}</Box>\n", .{ .mdx = true });
    const p2 = root2.first_child.?;
    try std.testing.expect(p2.data == .paragraph);
    const elem2 = p2.first_child.?.next.?;
    try std.testing.expect(elem2.data == .mdx_jsx_text_element);
    const expr2 = elem2.first_child.?;
    try std.testing.expect(expr2.data == .mdx_text_expression);
    try std.testing.expectEqualStrings("</Box>", expr2.data.mdx_text_expression.value);
}

test "position: text adjacent to a code span or MDX construct keeps its span" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The text before a code span ends where the span begins, and the text
    // after a construct begins where the construct ends — a flushed node
    // must not claim its neighbour's bytes (SPEC §7.2).
    const root = try markdown.parse(arena, "> # h `c`\n", .{});
    const heading = root.first_child.?.first_child.?;
    const text = heading.first_child.?;
    try std.testing.expect(text.data == .text);
    try std.testing.expectEqual(@as(usize, 1), text.position.?.start.line);
    try std.testing.expectEqual(@as(usize, 5), text.position.?.start.column);
    try std.testing.expectEqual(@as(usize, 7), text.position.?.end.column);
    const code = text.next.?;
    try std.testing.expect(code.data == .inline_code);
    try std.testing.expectEqual(@as(usize, 7), code.position.?.start.column);
    try std.testing.expectEqual(@as(usize, 10), code.position.?.end.column);

    const root2 = try markdown.parse(arena, "a <b>c</b> d\n", .{ .mdx = true });
    const para = root2.first_child.?;
    const elem = para.first_child.?.next.?;
    try std.testing.expect(elem.data == .mdx_jsx_text_element);
    const tail = elem.next.?;
    try std.testing.expect(tail.data == .text);
    try std.testing.expectEqualStrings(" d", tail.data.text);
    try std.testing.expectEqual(@as(usize, 11), tail.position.?.start.column);
    try std.testing.expectEqual(@as(usize, 13), tail.position.?.end.column);
}

test "source: a tab-straddled close line keeps the whole element raw" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The close-tag line sits behind a blockquote marker and a straddled
    // tab; synthetic pad bytes are not source bytes, so the element raw must
    // still span opening tag through close (§12.2) instead of silently
    // keeping the opening tag only.
    const out = try markdown.toHtml(
        arena,
        "> <A>\n>\n> x\n>\n>\t</A>\n",
        .{ .mdx = true },
        .{ .mdx_html = .source },
    );
    try std.testing.expectEqualStrings(
        "<blockquote>\n&lt;A&gt;\n&gt;\n&gt; x\n&gt;\n&gt;\t&lt;/A&gt;\n</blockquote>\n",
        out,
    );
}

test "AST: §14.6 error taxonomy — UnclosedMdxExpression vs InvalidMdxJsx" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // EOF inside an attribute expression (the `}` never arrives).
    try std.testing.expectError(error.UnclosedMdxExpression, markdown.parse(a, "<A b={x>", mdx_opts));
    try std.testing.expectError(error.UnclosedMdxExpression, markdown.parse(a, "<A b={", mdx_opts));
    // Expression closed (`{x}` has its `}`), then EOF mid-tag: the tag — not
    // the expression — is what ran out, so this is InvalidMdxJsx.
    try std.testing.expectError(error.InvalidMdxJsx, markdown.parse(a, "<A b={x}", mdx_opts));
    // Same shape with the tag continuing onto another line: pins the
    // expr_pending reset back to false once the expression closes.
    try std.testing.expectError(error.InvalidMdxJsx, markdown.parse(a, "<A b={x}\nc", mdx_opts));
    // EOF mid-tag with no expression involved at all.
    try std.testing.expectError(error.InvalidMdxJsx, markdown.parse(a, "<A\nb", mdx_opts));
    // Text context maps the split the same way (inline phase).
    try std.testing.expectError(error.UnclosedMdxExpression, markdown.parse(a, "a <b c={", mdx_opts));
}

// advanceLine is column-aware: tabs inside a consumed JSX tag pay their
// tab-stop width, so tabs in the leftover tail land on the right stops.
test "AST: tab inside a JSX close tag keeps the tail's column math honest" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // `</\tA\t>` spans 9 columns, not its 6 bytes; the following tab then
    // adds 3 columns (col 9 → 12) and the space completes 4 columns of
    // indent — an indented code block. A byte-counted column would put the
    // tail at col 6, count the tab as 2, and leave it a paragraph.
    const root = try markdown.parse(arena.allocator(), "<A>\n\n</\tA\t>\t x\n", mdx_opts);
    const elem = root.first_child.?;
    try std.testing.expect(elem.data == .mdx_jsx_flow_element);
    try std.testing.expectEqualStrings("<A>\n\n</\tA\t>", elem.data.mdx_jsx_flow_element.raw);
    const code = elem.next.?;
    try std.testing.expect(code.data == .code);
    try std.testing.expectEqualStrings("x\n", code.data.code.value);
}

test "AST: same-line list content after a tabbed close tag is a paragraph tail" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // The close tag is consumed mid-line; the tail flows through the
    // open-new-blocks leaf path, which holds no container dispatch, so the
    // `- x` is paragraph text (the same tail shape MDX fixtures 20/21 pin).
    // Tabs inside the close tag must not break the line or its positions.
    const root = try markdown.parse(arena.allocator(), "<A>\n\n</\tA\t> \t- x\n", mdx_opts);
    const elem = root.first_child.?;
    try std.testing.expect(elem.data == .mdx_jsx_flow_element);
    const para = elem.next.?;
    try std.testing.expect(para.data == .paragraph);
    try std.testing.expectEqualStrings("- x", para.first_child.?.data.text);
}

test "position: MDX text element and its children" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const root = try markdown.parse(arena.allocator(), "a <b>c</b> d\n", mdx_opts);
    const elem = findFirst(root, .mdx_jsx_text_element).?;
    const pos = elem.position.?;
    try std.testing.expectEqual(@as(usize, 1), pos.start.line);
    try std.testing.expectEqual(@as(usize, 3), pos.start.column);
    try std.testing.expectEqual(@as(usize, 11), pos.end.column);

    // The child text node is parsed by a nested phase; its position must be
    // mapped through the parent's anchors (SPEC §7.2).
    const child = elem.first_child.?;
    try std.testing.expectEqual(@as(usize, 6), child.position.?.start.column);
}

test "position: MDX flow constructs sharing a line" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const root = try markdown.parse(arena.allocator(), "<A/><B/>\n", mdx_opts);
    const first = root.first_child.?;
    const second = first.next.?;
    try std.testing.expectEqual(@as(usize, 1), first.position.?.start.column);
    try std.testing.expectEqual(@as(usize, 5), first.position.?.end.column);
    try std.testing.expectEqual(@as(usize, 5), second.position.?.start.column);
    try std.testing.expectEqual(@as(usize, 9), second.position.?.end.column);
}

test "position: a leaf starts at its first content character, not the indent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const root = try markdown.parse(arena.allocator(), "   indented para\n", .{});
    const pos = root.first_child.?.position.?;
    try std.testing.expectEqual(@as(usize, 4), pos.start.column);
    try std.testing.expectEqual(@as(usize, 3), pos.start.offset);
}

// ─── GFM autolink literals × brackets/links (cmark-gfm 0.29.0.gfm.13 oracle) ─

test "HTML: www autolink never fires inside link text" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try renderGfm(arena.allocator(), "[www.example.com](/x)\n");
    try std.testing.expectEqualStrings("<p><a href=\"/x\">www.example.com</a></p>\n", out);
}

test "HTML: url autolink never fires inside link text" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try renderGfm(arena.allocator(), "[visit https://x.io/a now](/y)\n");
    try std.testing.expectEqualStrings("<p><a href=\"/y\">visit https://x.io/a now</a></p>\n", out);
}

test "HTML: www/url autolinks stay plain inside a failed bracket" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const www = try renderGfm(arena.allocator(), "[a www.b.com] x\n");
    try std.testing.expectEqualStrings("<p>[a www.b.com] x</p>\n", www);
    const url = try renderGfm(arena.allocator(), "[https://x.io/a] y\n");
    try std.testing.expectEqualStrings("<p>[https://x.io/a] y</p>\n", url);
}

test "HTML: email autolink fires inside a failed bracket but not inside a link" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const failed = try renderGfm(arena.allocator(), "x[foo@bar.com] y\n");
    try std.testing.expectEqualStrings(
        "<p>x[<a href=\"mailto:foo@bar.com\">foo@bar.com</a>] y</p>\n",
        failed,
    );
    const in_link = try renderGfm(arena.allocator(), "[a foo@b.io](/x)\n");
    try std.testing.expectEqualStrings("<p><a href=\"/x\">a foo@b.io</a></p>\n", in_link);
}

test "HTML: autolink boundary characters match cmark-gfm" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // www needs whitespace or *_~( before it; a backtick, digit, or dot does not qualify.
    const after_code = try renderGfm(arena.allocator(), "`x`www.a.com\n");
    try std.testing.expectEqualStrings("<p><code>x</code>www.a.com</p>\n", after_code);
    const after_digit = try renderGfm(arena.allocator(), "1www.a.com b\n");
    try std.testing.expectEqualStrings("<p>1www.a.com b</p>\n", after_digit);
    const after_dot = try renderGfm(arena.allocator(), "foo.www.a.com\n");
    try std.testing.expectEqualStrings("<p>foo.www.a.com</p>\n", after_dot);
    // A url scheme only needs a non-alphabetic character before it.
    const url_after_dot = try renderGfm(arena.allocator(), ".https://x.io/a b\n");
    try std.testing.expectEqualStrings(
        "<p>.<a href=\"https://x.io/a\">https://x.io/a</a> b</p>\n",
        url_after_dot,
    );
    const url_after_digit = try renderGfm(arena.allocator(), "1https://x.io/a b\n");
    try std.testing.expectEqualStrings(
        "<p>1<a href=\"https://x.io/a\">https://x.io/a</a> b</p>\n",
        url_after_digit,
    );
}

test "HTML: autolinks still fire in plain text and inside emphasis" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const www = try renderGfm(arena.allocator(), "www.example.com\n");
    try std.testing.expectEqualStrings(
        "<p><a href=\"http://www.example.com\">www.example.com</a></p>\n",
        www,
    );
    const strong = try renderGfm(arena.allocator(), "**www.a.com** x\n");
    try std.testing.expectEqualStrings(
        "<p><strong><a href=\"http://www.a.com\">www.a.com</a></strong> x</p>\n",
        strong,
    );
    const email = try renderGfm(arena.allocator(), "a foo@bar.com b\n");
    try std.testing.expectEqualStrings(
        "<p>a <a href=\"mailto:foo@bar.com\">foo@bar.com</a> b</p>\n",
        email,
    );
}

test "HTML: email autolink fires on escape-decoded text (cmark-gfm 606)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // The GFM email postprocess runs on unescaped text, so the `+` freed by
    // the backslash still takes part in the link — CommonMark 606, listed in
    // gfm_core xfail, expects it to stay literal.
    const out = try renderGfm(arena.allocator(), "<foo\\+@bar.example.com>\n");
    try std.testing.expectEqualStrings(
        "<p>&lt;<a href=\"mailto:foo+@bar.example.com\">foo+@bar.example.com</a>&gt;</p>\n",
        out,
    );
}

// ─── position regressions ────────────────────────────────────────────

test "position: lines after frontmatter keep their source numbers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const root = try markdown.parse(
        arena.allocator(),
        "---\ntitle: x\n---\n\n# Head\n",
        .{ .frontmatter = true },
    );
    const fm = root.first_child.?;
    try std.testing.expectEqual(@as(usize, 1), fm.position.?.start.line);
    try std.testing.expectEqual(@as(usize, 3), fm.position.?.end.line);
    const heading = fm.next.?;
    try std.testing.expectEqual(@as(usize, 5), heading.position.?.start.line);
    try std.testing.expectEqual(@as(usize, 18), heading.position.?.start.offset);
}

test "position: hard break covers only the trailing spaces and newline" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const root = try markdown.parse(arena.allocator(), "foo  \nbar\n", .{});
    const br = findFirst(root, .break_).?;
    try std.testing.expectEqual(@as(usize, 1), br.position.?.start.line);
    try std.testing.expectEqual(@as(usize, 4), br.position.?.start.column);
    try std.testing.expectEqual(@as(usize, 3), br.position.?.start.offset);
    try std.testing.expectEqual(@as(usize, 2), br.position.?.end.line);
    try std.testing.expectEqual(@as(usize, 1), br.position.?.end.column);
}

test "position: ATX heading inline children carry positions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const root = try markdown.parse(arena.allocator(), "# Head\n", .{});
    const text = findFirst(root, .text).?;
    const pos = text.position.?;
    try std.testing.expectEqual(@as(usize, 1), pos.start.line);
    try std.testing.expectEqual(@as(usize, 3), pos.start.column);
    try std.testing.expectEqual(@as(usize, 2), pos.start.offset);
    try std.testing.expectEqual(@as(usize, 7), pos.end.column);
}

test "position: synthetic pad bytes for a straddled tab are not source bytes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // `>`\t` — the tab straddles the blockquote's one-column indent, so the
    // line is re-based on synthetic spaces. Those bytes have no source
    // counterpart and must not shift the heading's start (column 3, at the
    // `#`) or its text anchor (column 5, at the `h`).
    const root = try markdown.parse(arena.allocator(), ">\t# h\n", .{});
    const heading = findFirst(root, .heading).?;
    const hpos = heading.position.?;
    try std.testing.expectEqual(@as(usize, 3), hpos.start.column);
    try std.testing.expectEqual(@as(usize, 2), hpos.start.offset);
    const text = findFirst(root, .text).?;
    const tpos = text.position.?;
    try std.testing.expectEqual(@as(usize, 5), tpos.start.column);
    try std.testing.expectEqual(@as(usize, 4), tpos.start.offset);
}
