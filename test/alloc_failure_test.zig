//! Allocator failure injection — sweeps every allocation index across
//! parse + render, asserting that the only error surfaced is `OutOfMemory`
//! with no panics or leaks. (SPEC §16.2 Robustness, §18 step 20.)
const std = @import("std");
const markdown = @import("markdown");

test "parse/render survive allocation failure at every index" {
    const gpa = std.testing.allocator;

    const src =
        \\# h
        \\
        \\- [a](/u "t") *b* `c` ~~d~~
        \\
        \\> q
        \\
        \\<div>
        \\plain html block
        \\</div>
        \\
        \\    indented code
        \\
        \\```zig
        \\fenced
        \\```
        \\
        \\[r]: /d "t"
        \\
        \\![a *b*][r]
        \\
        \\| a | b |
        \\| - | - |
        \\| 1 | 2 |
        \\
        \\ref[^fn] and again[^fn]
        \\
        \\[^fn]: body with *emphasis*
        \\
        \\[^code]:
        \\        indented code in a footnote
        \\
        \\[^unused]: never referenced
        \\
    ;

    var idx: usize = 0;
    var swept_all = false;
    while (idx < 16384) : (idx += 1) {
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();

        var fail = std.testing.FailingAllocator.init(
            arena_state.allocator(),
            .{ .fail_index = idx },
        );

        const root = markdown.parse(fail.allocator(), src, .{ .gfm = true }) catch |e| {
            try std.testing.expectEqual(error.OutOfMemory, e);
            continue;
        };

        const out = markdown.renderHtml(fail.allocator(), root, .{}) catch |e| {
            try std.testing.expectEqual(error.OutOfMemory, e);
            continue;
        };
        fail.allocator().free(out);
        swept_all = true;
        break;
    }

    try std.testing.expect(swept_all);
}

test "parser rejects nesting beyond max_nesting" {
    const gpa = std.testing.allocator;
    const limit: usize = 50;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    // limit+1 nested blockquotes → should fail
    var deep = std.ArrayList(u8).empty;
    defer deep.deinit(gpa);
    var i: usize = 0;
    while (i < limit + 1) : (i += 1) {
        try deep.appendSlice(gpa, "> ");
    }
    try deep.appendSlice(gpa, "x\n");

    try std.testing.expectError(
        error.NestingTooDeep,
        markdown.parse(arena_state.allocator(), deep.items, .{ .max_nesting = limit }),
    );
}

test "parser accepts nesting at max_nesting" {
    const gpa = std.testing.allocator;
    const limit: usize = 50;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    // limit-1 blockquotes + 1 paragraph = exactly `limit` open frames.
    var deep = std.ArrayList(u8).empty;
    defer deep.deinit(gpa);
    var i: usize = 0;
    while (i < limit - 1) : (i += 1) {
        try deep.appendSlice(gpa, "> ");
    }
    try deep.appendSlice(gpa, "x\n");

    const root = try markdown.parse(arena_state.allocator(), deep.items, .{ .max_nesting = limit });
    const out = try markdown.renderHtml(gpa, root, .{});
    defer gpa.free(out);
    try std.testing.expect(out.len > 0);
}

test "renderer guards against deep hand-built tree" {
    const gpa = std.testing.allocator;
    const Node = markdown.Node;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Build a chain of blockquotes deeper than max_render_depth (512).
    const depth = 600;
    const root = try arena.create(Node);
    root.* = .{ .data = .root };
    var cur = root;
    var i: usize = 0;
    while (i < depth) : (i += 1) {
        const child = try arena.create(Node);
        child.* = .{ .data = .blockquote };
        cur.appendChild(child);
        cur = child;
    }

    try std.testing.expectError(
        error.NestingTooDeep,
        markdown.renderHtml(gpa, root, .{}),
    );
}

// ── MDX robustness (SPEC §14, §15) ──────────────────────────────────

test "MDX: alloc failure injection with mdx constructs" {
    const gpa = std.testing.allocator;

    const src =
        \\{a + b}
        \\
        \\a {b} c
        \\
        \\<Component />
        \\
        \\<Component>
        \\
        \\**bold**
        \\
        \\</Component>
        \\
        \\# Heading {expr}
        \\
        \\- item {expr}
        \\
        \\a <b><i>**x**</i></b> d
        \\
        \\<Component
        \\  a="1"
        \\  b={2}
        \\>text</Component>
        \\
        \\{a} tail
        \\
    ;

    var idx: usize = 0;
    var swept_all = false;
    while (idx < 8192) : (idx += 1) {
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();

        var fail = std.testing.FailingAllocator.init(
            arena_state.allocator(),
            .{ .fail_index = idx },
        );

        const root = markdown.parse(fail.allocator(), src, .{ .mdx = true }) catch |e| {
            try std.testing.expect(e == error.OutOfMemory);
            continue;
        };

        const out = markdown.renderHtml(fail.allocator(), root, .{}) catch |e| {
            try std.testing.expect(e == error.OutOfMemory);
            continue;
        };
        fail.allocator().free(out);
        swept_all = true;
        break;
    }

    try std.testing.expect(swept_all);
}

test "MDX: deep JSX nesting hits max_nesting" {
    const gpa = std.testing.allocator;
    const limit: usize = 50;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    // limit+1 nested JSX elements → should fail
    var deep = std.ArrayList(u8).empty;
    defer deep.deinit(gpa);
    var i: usize = 0;
    while (i < limit + 1) : (i += 1) {
        try deep.appendSlice(gpa, "<A>\n\n");
    }
    try deep.appendSlice(gpa, "x\n");

    try std.testing.expectError(
        error.NestingTooDeep,
        markdown.parse(arena_state.allocator(), deep.items, .{ .mdx = true, .max_nesting = limit }),
    );
}

test "MDX: many braces don't cause quadratic blowup" {
    const gpa = std.testing.allocator;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    // 1000 valid expressions on one line — should be fast
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(gpa);
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        try buf.appendSlice(gpa, "{a} ");
    }

    const root = try markdown.parse(arena_state.allocator(), buf.items, .{ .mdx = true });
    const out = try markdown.renderHtml(gpa, root, .{});
    defer gpa.free(out);
    // .strip: all expressions produce 0 bytes, output is just spaces
    try std.testing.expect(out.len < 2000);
}
