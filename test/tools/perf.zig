//! Scalability gate for SPEC §16.4: parsing must stay linear in input length.
//!
//! Absolute timings depend on the machine, so nothing here asserts on them.
//! Each case is built at three sizes roughly 4x apart and judged on
//! *normalised* cost (ns per input byte). Linear work keeps that flat; a
//! quadratic path multiplies it by ~4 every time the input grows 4x.
//!
//! Run with `zig build test-perf`.
const std = @import("std");
const md = @import("markdown");

/// A quadratic path shows ~4.0 here per 4x growth; linear shows ~1.0.
/// The gap is wide enough that a generous threshold still catches it.
const max_normalised_growth: f64 = 2.0;

/// Cases smaller than this are dominated by measurement noise, so their
/// ratios are reported but not enforced. Sizes below are chosen so every case
/// clears it — an unenforced case is a case this gate has stopped guarding.
const min_meaningful_ns: u64 = 100_000;

fn nowNs() u64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

/// One conversion, timed. A parse error still counts: rejecting a document
/// must be linear too, or an erroring input is still a denial of service.
fn renderOnce(gpa: std.mem.Allocator, src: []const u8, opts: md.ParseOptions) u64 {
    const t0 = nowNs();
    if (md.toHtml(gpa, src, opts, .{})) |out| gpa.free(out) else |_| {}
    return nowNs() - t0;
}

/// Median of three runs. One warm-up pass first so the first measured run is
/// not paying for cold caches.
fn measure(gpa: std.mem.Allocator, src: []const u8, opts: md.ParseOptions) !u64 {
    _ = renderOnce(gpa, src, opts);
    var samples: [3]u64 = undefined;
    for (&samples) |*s| s.* = renderOnce(gpa, src, opts);
    std.mem.sort(u64, &samples, {}, std.sort.asc(u64));
    return samples[1];
}

const Build = *const fn (std.mem.Allocator, usize) anyerror![]u8;

const Case = struct {
    name: []const u8,
    build: Build,
    /// Scale factors; each step grows the input ~4x.
    scales: [3]usize,
    options: md.ParseOptions = .{},
};

fn report(name: []const u8, len: usize, ns: u64, per_byte: f64) void {
    std.debug.print("  {s:<28} len={d:>8}  {d:>8.2} ms  {d:>7.2} ns/byte\n", .{
        name, len, @as(f64, @floatFromInt(ns)) / 1e6, per_byte,
    });
}

fn runCase(gpa: std.mem.Allocator, case: Case) !bool {
    std.debug.print("{s}\n", .{case.name});

    var per_byte: [3]f64 = undefined;
    var ns: [3]u64 = undefined;
    var lens: [3]usize = undefined;

    for (case.scales, 0..) |scale, i| {
        const src = try case.build(gpa, scale);
        defer gpa.free(src);
        lens[i] = src.len;
        ns[i] = try measure(gpa, src, case.options);
        per_byte[i] = @as(f64, @floatFromInt(ns[i])) / @as(f64, @floatFromInt(src.len));
        report("", lens[i], ns[i], per_byte[i]);
    }

    var ok = true;
    for (0..2) |i| {
        const growth = per_byte[i + 1] / per_byte[i];
        const enforced = ns[i] >= min_meaningful_ns;
        const failed = enforced and growth > max_normalised_growth;
        if (failed) ok = false;
        std.debug.print("    step {d}->{d}: normalised growth {d:.2}x  {s}\n", .{
            i,                                                                                      i + 1, growth,
            if (failed) "FAIL" else if (enforced) "ok" else "ok (below noise floor, not enforced)",
        });
    }
    return ok;
}

// ── Case builders ──────────────────────────────────────────────────

fn repeat(gpa: std.mem.Allocator, unit: []const u8, n: usize) ![]u8 {
    var b: std.ArrayList(u8) = .empty;
    errdefer b.deinit(gpa);
    try b.ensureTotalCapacity(gpa, unit.len * n);
    for (0..n) |_| b.appendSliceAssumeCapacity(unit);
    return b.toOwnedSlice(gpa);
}

/// Openers pile up while every closer fails to match, which is what makes a
/// naive `findOpener` walk the whole stack each time (SPEC §11.1).
fn buildEmphasis(gpa: std.mem.Allocator, n: usize) ![]u8 {
    return repeat(gpa, "*a_ ", n);
}

/// Backtick runs of every length 1..k, so no run ever finds its partner and a
/// naive scan walks to EOF each time (SPEC §11).
fn buildCodeSpanLadder(gpa: std.mem.Allocator, k: usize) ![]u8 {
    var b: std.ArrayList(u8) = .empty;
    errdefer b.deinit(gpa);
    for (1..k + 1) |len| {
        for (0..len) |_| try b.append(gpa, '`');
        try b.append(gpa, 'x');
    }
    return b.toOwnedSlice(gpa);
}

/// Every trailing `)` stripped from an autolink re-counts the parens.
fn buildAutolinkParens(gpa: std.mem.Allocator, n: usize) ![]u8 {
    var b: std.ArrayList(u8) = .empty;
    errdefer b.deinit(gpa);
    try b.appendSlice(gpa, "http://x.com/");
    for (0..n) |_| try b.append(gpa, ')');
    return b.toOwnedSlice(gpa);
}

/// A flow expression spanning many lines; re-scanning the accumulated buffer
/// on every line is quadratic (SPEC §9.1).
fn buildMdxFlowExpr(gpa: std.mem.Allocator, n: usize) ![]u8 {
    var b: std.ArrayList(u8) = .empty;
    errdefer b.deinit(gpa);
    try b.appendSlice(gpa, "{a\n");
    for (0..n) |_| try b.appendSlice(gpa, "xxxxxxxxxxxxxxxxxxxx\n");
    try b.appendSlice(gpa, "}\n");
    return b.toOwnedSlice(gpa);
}

/// Every line inside an open JSX container is tested against the closing tag.
fn buildMdxJsxContainer(gpa: std.mem.Allocator, n: usize) ![]u8 {
    var b: std.ArrayList(u8) = .empty;
    errdefer b.deinit(gpa);
    try b.appendSlice(gpa, "<Comp>\n\n");
    for (0..n) |_| try b.appendSlice(gpa, "hello world\n\n");
    try b.appendSlice(gpa, "</Comp>\n");
    return b.toOwnedSlice(gpa);
}

/// An opening tag that never closes, one attribute per line: re-scanning the
/// accumulated buffer on every continuation line is quadratic (SPEC §16.4).
fn buildMdxMultilineTag(gpa: std.mem.Allocator, n: usize) ![]u8 {
    var b: std.ArrayList(u8) = .empty;
    errdefer b.deinit(gpa);
    try b.appendSlice(gpa, "<a\n");
    for (0..n) |_| try b.appendSlice(gpa, "x=\"1\"\n");
    return b.toOwnedSlice(gpa);
}

/// Unmatched braces inside a JSX text element's children: the child-boundary
/// search must not rescan to EOF from every `{` (SPEC §16.4).
fn buildMdxJsxTextBraces(gpa: std.mem.Allocator, n: usize) ![]u8 {
    var b: std.ArrayList(u8) = .empty;
    errdefer b.deinit(gpa);
    try b.appendSlice(gpa, "x <b>");
    for (0..n) |_| try b.append(gpa, '{');
    return b.toOwnedSlice(gpa);
}

/// Sanity baseline: ordinary prose must stay flat too.
fn buildProse(gpa: std.mem.Allocator, n: usize) ![]u8 {
    return repeat(gpa, "The quick **brown** fox jumps over the [lazy](http://x) dog.\n\n", n);
}

/// n references against a single definition: the numbering pass must stay
/// linear in the reference count, not quadratic in it (SPEC §13.4).
fn buildFootnoteRefs(gpa: std.mem.Allocator, n: usize) ![]u8 {
    var b: std.ArrayList(u8) = .empty;
    errdefer b.deinit(gpa);
    for (0..n) |_| try b.appendSlice(gpa, "see[^fn] again\n\n");
    try b.appendSlice(gpa, "[^fn]: body\n");
    return b.toOwnedSlice(gpa);
}

/// n distinct definitions, none referenced: collection must stay linear too.
fn buildFootnoteDefs(gpa: std.mem.Allocator, n: usize) ![]u8 {
    var b: std.ArrayList(u8) = .empty;
    errdefer b.deinit(gpa);
    var tmp: [64]u8 = undefined;
    for (0..n) |i| {
        const s = try std.fmt.bufPrint(&tmp, "[^d{d}]: body\n\n", .{i});
        try b.appendSlice(gpa, s);
    }
    return b.toOwnedSlice(gpa);
}

const cases = [_]Case{
    .{ .name = "emphasis delimiters (openers_bottom)", .build = buildEmphasis, .scales = .{ 2_000, 8_000, 32_000 } },
    .{ .name = "code span backtick ladder", .build = buildCodeSpanLadder, .scales = .{ 300, 600, 1_200 } },
    .{ .name = "gfm autolink trailing parens", .build = buildAutolinkParens, .scales = .{ 16_000, 64_000, 256_000 }, .options = .{ .gfm = true } },
    .{ .name = "mdx multiline flow expression", .build = buildMdxFlowExpr, .scales = .{ 4_000, 16_000, 64_000 }, .options = .{ .mdx = true } },
    .{ .name = "mdx jsx container lines", .build = buildMdxJsxContainer, .scales = .{ 1_000, 4_000, 16_000 }, .options = .{ .mdx = true } },
    .{ .name = "mdx multiline opening tag", .build = buildMdxMultilineTag, .scales = .{ 10_000, 40_000, 160_000 }, .options = .{ .mdx = true } },
    .{ .name = "mdx jsx text unclosed braces", .build = buildMdxJsxTextBraces, .scales = .{ 64_000, 256_000, 1_024_000 }, .options = .{ .mdx = true } },
    .{ .name = "prose baseline", .build = buildProse, .scales = .{ 2_000, 8_000, 32_000 }, .options = .{ .gfm = true } },
    .{ .name = "footnote references", .build = buildFootnoteRefs, .scales = .{ 2_000, 8_000, 32_000 }, .options = .{ .gfm = true } },
    .{ .name = "footnote definitions", .build = buildFootnoteDefs, .scales = .{ 2_000, 8_000, 32_000 }, .options = .{ .gfm = true } },
};

pub fn main() !u8 {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    std.debug.print("\n=== Scalability (SPEC §16.4) ===\n", .{});
    var failures: usize = 0;
    for (cases) |case| {
        if (!try runCase(gpa, case)) failures += 1;
    }

    if (failures == 0) {
        std.debug.print("\nall {d} cases linear\n\n", .{cases.len});
        return 0;
    }
    std.debug.print("\n{d}/{d} cases grew superlinearly\n\n", .{ failures, cases.len });
    return 1;
}
