//! Runs the CommonMark conformance suite and dumps every mismatch — both
//! unexpected failures and known-fail (xfail) cases — with input, expected and
//! actual output. `zig build debug-conformance [-- <section substring>]`.
const std = @import("std");
const harness = @import("harness");
const markdown = @import("markdown");
const normalize = @import("normalize");

pub fn main(init: std.process.Init) !void {
    var arena_state: std.heap.ArenaAllocator = .init(init.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const args = try init.minimal.args.toSlice(arena);
    // args[1] = optional section filter, args[2] = optional "--gfm"
    const filter: ?[]const u8 = blk: {
        if (args.len <= 1) break :blk null;
        if (std.mem.eql(u8, args[1], "--gfm")) break :blk null;
        break :blk args[1];
    };
    const gfm_mode = blk: {
        for (args) |a| if (std.mem.eql(u8, a, "--gfm")) break :blk true;
        break :blk false;
    };

    const fixture = if (gfm_mode) harness.commonmark_gfm.fixture else harness.commonmark.fixture;
    const xfail = if (gfm_mode) harness.commonmark_gfm.xfail else harness.commonmark.xfail;
    const opts: markdown.ParseOptions = if (gfm_mode) .{ .gfm = true } else .{};

    const cases = try harness.loadJson(arena, fixture);

    var buf: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &buf);
    const out = &stdout_writer.interface;

    var mismatched: usize = 0;
    for (cases) |case| {
        if (filter) |f| {
            if (std.mem.indexOf(u8, case.section, f) == null) continue;
        }

        var case_arena: std.heap.ArenaAllocator = .init(init.gpa);
        defer case_arena.deinit();
        const ca = case_arena.allocator();

        const expected = case.expected_html orelse "";
        const actual = markdown.toHtml(ca, case.markdown, opts, .{}) catch |err| {
            mismatched += 1;
            try out.print("\n--- ex {d} [{s}] ERROR {t}\nIN:  {f}\nEXP: {f}\n", .{
                case.example, case.section, err, esc(case.markdown), esc(expected),
            });
            continue;
        };

        const actual_norm = try normalize.normalize(ca, actual);
        const expected_norm = try normalize.normalize(ca, expected);
        if (std.mem.eql(u8, actual_norm, expected_norm)) continue;

        mismatched += 1;
        const is_xfail = for (xfail) |ex| {
            if (ex == case.example) break true;
        } else false;
        try out.print("\n--- ex {d} [{s}]{s}\nIN:  {f}\nEXP: {f}\nGOT: {f}\n", .{
            case.example,       case.section,  if (is_xfail) " (xfail)" else "",
            esc(case.markdown), esc(expected), esc(actual),
        });
    }

    try out.print("\nmismatched={d}\n", .{mismatched});
    try out.flush();
}

/// Renders newlines and tabs visibly so one case stays on a few lines.
fn esc(s: []const u8) std.fmt.Alt([]const u8, formatEscaped) {
    return .{ .data = s };
}

fn formatEscaped(s: []const u8, w: *std.Io.Writer) std.Io.Writer.Error!void {
    for (s) |c| switch (c) {
        '\n' => try w.writeAll("\\n"),
        '\t' => try w.writeAll("\\t"),
        else => try w.writeByte(c),
    };
}
