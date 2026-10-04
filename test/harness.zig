const std = @import("std");
const Allocator = std.mem.Allocator;
const markdown = @import("markdown");
const normalize = @import("normalize");

/// Fixtures and their known-fail allowlists, wired up in one place so every
/// consumer (conformance test, debug tool) sees the same inputs.
pub const commonmark = struct {
    pub const fixture = @embedFile("fixtures/commonmark-0.31.2.json");
    pub const xfail = @import("known_fail.zig").commonmark;
};

pub const commonmark_gfm = struct {
    pub const fixture = @embedFile("fixtures/commonmark-0.31.2.json");
    pub const xfail = @import("known_fail_gfm_core.zig").gfm_core;
};

pub const gfm = struct {
    pub const fixture = @embedFile("fixtures/gfm-extension-examples.json");
    pub const xfail = @import("known_fail_gfm.zig").gfm;
};

pub const footnote = struct {
    pub const fixture = @embedFile("fixtures/gfm-footnote.json");
    pub const xfail = @import("known_fail_footnote.zig").footnote;
};

pub const mdx_expression = struct {
    pub const fixture = @embedFile("fixtures/mdx/expression.json");
    pub const xfail = @import("known_fail_mdx.zig").mdx_expression;
};

pub const mdx_jsx = struct {
    pub const fixture = @embedFile("fixtures/mdx/jsx.json");
    pub const xfail = @import("known_fail_mdx.zig").mdx_jsx;
};

pub const mdx_errors = struct {
    pub const fixture = @embedFile("fixtures/mdx/errors.json");
    pub const xfail = @import("known_fail_mdx.zig").mdx_errors;
};

// ── Non-MDX regression axis (SPEC §16.2.1) ──────────────────────────
// Same CommonMark/GFM fixtures, but run with `.mdx = true`.
// Only HTML block / inline raw HTML examples may appear in xfail.
pub const commonmark_mdx = struct {
    pub const fixture = @embedFile("fixtures/commonmark-0.31.2.json");
    pub const xfail = @import("known_fail_mdx_core.zig").commonmark_mdx;
};

pub const gfm_mdx = struct {
    pub const fixture = @embedFile("fixtures/gfm-extension-examples.json");
    pub const xfail = @import("known_fail_mdx_core.zig").gfm_mdx;
};

pub const Case = struct {
    example: usize,
    section: []const u8,
    markdown: []const u8,
    expected_html: ?[]const u8, // null = parse error expected (MDX)
};

pub const RunReport = struct {
    passed: usize = 0,
    xfailed: usize = 0,
    unexpected_fail: usize = 0,
    unexpected_pass: usize = 0,
    failing_examples: std.ArrayList(usize) = .empty,
    unexpected_pass_examples: std.ArrayList(usize) = .empty,
};

/// Parse spec.json bytes into Case array (arena-allocated).
/// Handles null "html" values (MDX error cases where expected_html is null).
pub fn loadJson(arena: Allocator, bytes: []const u8) ![]Case {
    var parsed = try std.json.parseFromSlice(std.json.Value, arena, bytes, .{});
    defer parsed.deinit();

    const arr = parsed.value.array;
    const cases = try arena.alloc(Case, arr.items.len);
    for (arr.items, 0..) |item, i| {
        const obj = item.object;
        const html_value = obj.get("html").?;
        const expected_html: ?[]const u8 = switch (html_value) {
            .string => |s| try arena.dupe(u8, s),
            else => null,
        };
        cases[i] = .{
            .example = @intCast(obj.get("example").?.integer),
            .section = try arena.dupe(u8, obj.get("section").?.string),
            .markdown = try arena.dupe(u8, obj.get("markdown").?.string),
            .expected_html = expected_html,
        };
    }
    return cases;
}

fn isXfailExample(xfail_examples: []const usize, example: usize) bool {
    for (xfail_examples) |ex| {
        if (ex == example) return true;
    }
    return false;
}

pub fn run(
    gpa: Allocator,
    cases: []const Case,
    xfail_examples: []const usize,
    parse_options: markdown.ParseOptions,
) !RunReport {
    var report: RunReport = .{};
    errdefer {
        report.failing_examples.deinit(gpa);
        report.unexpected_pass_examples.deinit(gpa);
    }

    for (cases) |case| {
        const xfail = isXfailExample(xfail_examples, case.example);

        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        // null expected_html = expect parse error (SPEC §16, MDX error cases).
        if (case.expected_html == null) {
            _ = markdown.toHtml(arena, case.markdown, parse_options, .{}) catch {
                // Parse errored as expected.
                if (xfail) {
                    report.unexpected_pass += 1;
                    try report.unexpected_pass_examples.append(gpa, case.example);
                } else {
                    report.passed += 1;
                }
                continue;
            };
            // Parse did NOT error — expectation not met.
            if (xfail) {
                report.xfailed += 1;
            } else {
                report.unexpected_fail += 1;
                try report.failing_examples.append(gpa, case.example);
            }
            continue;
        }

        // Normal case: compare normalized HTML output.
        const actual_html = markdown.toHtml(arena, case.markdown, parse_options, .{}) catch {
            if (xfail) {
                report.xfailed += 1;
            } else {
                report.unexpected_fail += 1;
                try report.failing_examples.append(gpa, case.example);
            }
            continue;
        };

        const actual_norm = try normalize.normalize(gpa, actual_html);
        defer gpa.free(actual_norm);
        const expected_norm = try normalize.normalize(gpa, case.expected_html.?);
        defer gpa.free(expected_norm);

        const matched = std.mem.eql(u8, actual_norm, expected_norm);

        if (matched) {
            if (xfail) {
                report.unexpected_pass += 1;
                try report.unexpected_pass_examples.append(gpa, case.example);
            } else {
                report.passed += 1;
            }
        } else {
            if (xfail) {
                report.xfailed += 1;
            } else {
                report.unexpected_fail += 1;
                try report.failing_examples.append(gpa, case.example);
            }
        }
    }

    return report;
}
