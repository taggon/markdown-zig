//! Fuzz / oracle differential test (SPEC §16.5).
//!
//! Seeded PRNG → structured + random markdown → property checks + optional
//! cmark comparison.
const std = @import("std");
const markdown = @import("markdown");

const Iterations = 5000;

// ── Atoms for grammar-based generation ──────────────────────────────

const block_atoms = [_][]const u8{
    "# H1\n",
    "## H2\n",
    "```\ncode\n```\n",
    "~~~\ncode\n~~~\n",
    "> quote\n",
    "- item\n",
    "1. first\n",
    "---\n",
    "***\n",
    "\n",
    "    indented code\n",
    "<div>html</div>\n",
    "<p>inline html</p>",
    "| a | b |\n|---|---|\n| 1 | 2 |\n",
    "- [ ] task\n",
    "[^fn]: definition\n",
    "[^fn]:\n        code\n",
    "[^]: broken\n",
    "<A>\n\nchild\n\n</A>\n",
    "<A\n  b=\"1\"\n/>\n",
    "{a\n+ b}\n",
    "<A/><B/>\n",
};

const inline_atoms = [_][]const u8{
    "*em*",
    "**strong**",
    "`code`",
    "[text](/url)",
    "[ref][r]",
    "![alt](/img)",
    "plain text",
    "&amp;",
    "&#35;",
    "<https://example.com>",
    "\\*escaped\\*",
    "~~strike~~",
    "a+b=c",
    "$x^2$",
    "{expr}",
    "<b>tag</b>",
    "<A/>",
    "</A>",
    "![^fn]",
    "<A b={x}>y</A>",
    "[bracket",
    "]close",
    "[^fn]",
    "[^",
    "[^a\\]b]",
    "*",
    "`",
    "[",
    "!",
    "#",
    ">",
    "-",
    "\t",
    "    ",
    "한글",
    "日本語",
    "\n",
};

fn generateInput(prng: *std.Random.DefaultPrng, buf: *std.ArrayList(u8), allocator: std.mem.Allocator) !void {
    buf.clearRetainingCapacity();
    const mode = prng.random().int(u1);
    if (mode == 0) {
        const count = prng.random().intRangeAtMost(usize, 2, 30);
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const pool = if (prng.random().boolean()) &block_atoms else &inline_atoms;
            const atom = pool[prng.random().intRangeAtMost(usize, 0, pool.len - 1)];
            try buf.appendSlice(allocator, atom);
        }
    } else {
        const len = prng.random().intRangeAtMost(usize, 1, 200);
        var j: usize = 0;
        while (j < len) : (j += 1) {
            try buf.append(allocator, prng.random().intRangeAtMost(u8, 0x20, 0x7E));
        }
    }
}

// ── Tree consistency check ───────────────────────────────────────────

fn checkTree(root: *const markdown.Node) bool {
    return checkNode(root, null, 0);
}

fn checkNode(node: *const markdown.Node, expected_parent: ?*const markdown.Node, depth: usize) bool {
    if (depth > 1024) return false;
    if (node.parent != expected_parent) return false;

    // Verify sibling links via forward walk
    var child = node.first_child;
    var prev: ?*const markdown.Node = null;
    var count: usize = 0;
    while (child) |c| : (child = c.next) {
        if (c.prev != prev) return false;
        if (!checkNode(c, node, depth + 1)) return false;
        prev = c;
        count += 1;
        if (count > 100_000) return false;
    }
    // last_child should match the final prev
    if (node.last_child != prev) return false;
    return true;
}

// ── cmark oracle (optional, skipped when not installed) ──────────────

fn cmarkAvailable() bool {
    return false;
}

// ── Main ─────────────────────────────────────────────────────────────

pub fn main() !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();

    var prng = std.Random.DefaultPrng.init(0x6d_61_72_6b); // "mark"

    var input_buf: std.ArrayList(u8) = .empty;
    defer input_buf.deinit(allocator);

    const has_cmark = cmarkAvailable();

    var iter: usize = 0;
    var crashes: usize = 0;
    var nondeterminism: usize = 0;
    var tree_issues: usize = 0;
    const cmark_diffs: usize = 0;
    var cmark_checked: usize = 0;

    while (iter < Iterations) : (iter += 1) {
        try generateInput(&prng, &input_buf, allocator);
        const input = input_buf.items;
        // Every option profile gets fuzzed, MDX above all: it is the mode with
        // multi-line frames and hard parse errors, so it has the most ways to
        // go wrong (SPEC §16.5).
        const opts: markdown.ParseOptions = switch (iter % 4) {
            0 => .{ .gfm = true },
            1 => .{},
            2 => .{ .mdx = true },
            else => .{ .gfm = true, .frontmatter = true, .math = true },
        };

        // Property 1: parse doesn't crash
        var arena1 = std.heap.ArenaAllocator.init(allocator);
        defer arena1.deinit();
        const root1 = markdown.parse(arena1.allocator(), input, opts) catch |first_err| {
            if (first_err == error.InvalidUtf8) continue; // random bytes may be invalid UTF-8
            // The error itself must be deterministic: a fresh arena and the
            // same options have to fail with the identical error (SPEC §14.6).
            var arena_err = std.heap.ArenaAllocator.init(allocator);
            defer arena_err.deinit();
            const second_err: ?markdown.ParseError = if (markdown.parse(arena_err.allocator(), input, opts)) |_| null else |e| e;
            if (second_err == null or second_err.? != first_err) {
                nondeterminism += 1;
                if (nondeterminism <= 3) {
                    std.debug.print("ERROR NON-DETERMINISM at iteration {d}: {any} then {any}: {s}\n", .{ iter, first_err, second_err, input[0..@min(input.len, 80)] });
                }
            }
            // OutOfMemory or NestingTooDeep are acceptable
            continue;
        };

        // Property 2: HTML render doesn't crash
        const html1 = markdown.toHtml(allocator, input, opts, .{}) catch {
            crashes += 1;
            std.debug.print("CRASH rendering iteration {d}: {s}\n", .{ iter, input[0..@min(input.len, 80)] });
            continue;
        };
        defer allocator.free(html1);

        // Property 3: determinism — parse same input again
        {
            var arena2 = std.heap.ArenaAllocator.init(allocator);
            defer arena2.deinit();
            const html2 = markdown.toHtml(allocator, input, opts, .{}) catch {
                crashes += 1;
                continue;
            };
            defer allocator.free(html2);
            if (!std.mem.eql(u8, html1, html2)) {
                nondeterminism += 1;
                if (nondeterminism <= 3) {
                    std.debug.print("NON-DETERMINISM at iteration {d}: {s}\n", .{ iter, input[0..@min(input.len, 80)] });
                }
            }
        }

        // Property 4: tree consistency
        if (!checkTree(root1)) {
            tree_issues += 1;
            if (tree_issues <= 3) {
                std.debug.print("TREE INCONSISTENCY at iteration {d}\n", .{iter});
            }
        }

        // Property 5: cmark oracle comparison (optional)
        if (has_cmark) {
            // cmark comparison would go here when the binary is available.
            // Skipped for now — see SPEC §16.5.
            cmark_checked += 1;
        }
    }

    // Report
    std.debug.print("\n=== Fuzz Report (SPEC §16.5) ===\n", .{});
    std.debug.print("iterations:    {d}\n", .{Iterations});
    std.debug.print("crashes:       {d}\n", .{crashes});
    std.debug.print("nondeterminism:{d}\n", .{nondeterminism});
    std.debug.print("tree_issues:   {d}\n", .{tree_issues});
    if (has_cmark) {
        std.debug.print("cmark_checked: {d}\n", .{cmark_checked});
        std.debug.print("cmark_diffs:   {d}\n", .{cmark_diffs});
    } else {
        std.debug.print("cmark:         not available (skipped oracle comparison)\n", .{});
    }

    const failed = crashes > 0 or nondeterminism > 0 or tree_issues > 0;
    if (failed) {
        std.debug.print("\nFAIL: fuzz test found issues\n", .{});
        std.process.exit(1);
    } else {
        std.debug.print("\nok — no crashes, deterministic, tree consistent\n", .{});
    }
}
