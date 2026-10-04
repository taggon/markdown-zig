const std = @import("std");
const harness = @import("harness");

test "mdx expression conformance (known-fail gated)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const cases = try harness.loadJson(arena, harness.mdx_expression.fixture);
    try std.testing.expect(cases.len > 0);

    var report = try harness.run(
        std.testing.allocator,
        cases,
        harness.mdx_expression.xfail,
        .{ .mdx = true },
    );
    defer report.failing_examples.deinit(std.testing.allocator);
    defer report.unexpected_pass_examples.deinit(std.testing.allocator);

    std.debug.print("\n=== MDX Expression Conformance ===\n", .{});
    std.debug.print("passed={d} xfailed={d} unexpected_fail={d} unexpected_pass={d}\n", .{
        report.passed, report.xfailed, report.unexpected_fail, report.unexpected_pass,
    });
    if (report.failing_examples.items.len > 0) {
        std.debug.print("UNEXPECTED_FAIL: {any}\n", .{report.failing_examples.items});
    }
    if (report.unexpected_pass_examples.items.len > 0) {
        std.debug.print("UNEXPECTED_PASS: {any}\n", .{report.unexpected_pass_examples.items});
    }

    try std.testing.expectEqual(@as(usize, 0), report.unexpected_fail);
    try std.testing.expectEqual(@as(usize, 0), report.unexpected_pass);
}

test "mdx jsx conformance (known-fail gated)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const cases = try harness.loadJson(arena, harness.mdx_jsx.fixture);
    try std.testing.expect(cases.len > 0);

    var report = try harness.run(
        std.testing.allocator,
        cases,
        harness.mdx_jsx.xfail,
        .{ .mdx = true },
    );
    defer report.failing_examples.deinit(std.testing.allocator);
    defer report.unexpected_pass_examples.deinit(std.testing.allocator);

    std.debug.print("\n=== MDX JSX Conformance ===\n", .{});
    std.debug.print("passed={d} xfailed={d} unexpected_fail={d} unexpected_pass={d}\n", .{
        report.passed, report.xfailed, report.unexpected_fail, report.unexpected_pass,
    });
    if (report.failing_examples.items.len > 0) {
        std.debug.print("UNEXPECTED_FAIL: {any}\n", .{report.failing_examples.items});
    }
    if (report.unexpected_pass_examples.items.len > 0) {
        std.debug.print("UNEXPECTED_PASS: {any}\n", .{report.unexpected_pass_examples.items});
    }

    try std.testing.expectEqual(@as(usize, 0), report.unexpected_fail);
    try std.testing.expectEqual(@as(usize, 0), report.unexpected_pass);
}

test "mdx error conformance (known-fail gated)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const cases = try harness.loadJson(arena, harness.mdx_errors.fixture);
    try std.testing.expect(cases.len > 0);

    var report = try harness.run(
        std.testing.allocator,
        cases,
        harness.mdx_errors.xfail,
        .{ .mdx = true },
    );
    defer report.failing_examples.deinit(std.testing.allocator);
    defer report.unexpected_pass_examples.deinit(std.testing.allocator);

    std.debug.print("\n=== MDX Error Conformance ===\n", .{});
    std.debug.print("passed={d} xfailed={d} unexpected_fail={d} unexpected_pass={d}\n", .{
        report.passed, report.xfailed, report.unexpected_fail, report.unexpected_pass,
    });
    if (report.failing_examples.items.len > 0) {
        std.debug.print("UNEXPECTED_FAIL: {any}\n", .{report.failing_examples.items});
    }
    if (report.unexpected_pass_examples.items.len > 0) {
        std.debug.print("UNEXPECTED_PASS: {any}\n", .{report.unexpected_pass_examples.items});
    }

    try std.testing.expectEqual(@as(usize, 0), report.unexpected_fail);
    try std.testing.expectEqual(@as(usize, 0), report.unexpected_pass);
}

// ── Non-MDX regression axis (SPEC §16.2.1) ──────────────────────────
// Run CommonMark/GFM fixtures with `.mdx = true`. Only HTML-related
// examples may fail; everything else must still pass.

test "CommonMark conformance with mdx=true (regression axis)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const cases = try harness.loadJson(arena, harness.commonmark_mdx.fixture);
    try std.testing.expect(cases.len > 0);

    var report = try harness.run(
        std.testing.allocator,
        cases,
        harness.commonmark_mdx.xfail,
        .{ .mdx = true },
    );
    defer report.failing_examples.deinit(std.testing.allocator);
    defer report.unexpected_pass_examples.deinit(std.testing.allocator);

    std.debug.print("\n=== CommonMark × MDX Regression ===\n", .{});
    std.debug.print("passed={d} xfailed={d} unexpected_fail={d} unexpected_pass={d}\n", .{
        report.passed, report.xfailed, report.unexpected_fail, report.unexpected_pass,
    });
    if (report.failing_examples.items.len > 0) {
        std.debug.print("UNEXPECTED_FAIL: {any}\n", .{report.failing_examples.items});
    }
    if (report.unexpected_pass_examples.items.len > 0) {
        std.debug.print("UNEXPECTED_PASS: {any}\n", .{report.unexpected_pass_examples.items});
    }

    try std.testing.expectEqual(@as(usize, 0), report.unexpected_fail);
    try std.testing.expectEqual(@as(usize, 0), report.unexpected_pass);
}

test "GFM conformance with mdx=true (regression axis)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const cases = try harness.loadJson(arena, harness.gfm_mdx.fixture);
    try std.testing.expect(cases.len > 0);

    var report = try harness.run(
        std.testing.allocator,
        cases,
        harness.gfm_mdx.xfail,
        .{ .gfm = true, .mdx = true },
    );
    defer report.failing_examples.deinit(std.testing.allocator);
    defer report.unexpected_pass_examples.deinit(std.testing.allocator);

    std.debug.print("\n=== GFM × MDX Regression ===\n", .{});
    std.debug.print("passed={d} xfailed={d} unexpected_fail={d} unexpected_pass={d}\n", .{
        report.passed, report.xfailed, report.unexpected_fail, report.unexpected_pass,
    });
    if (report.failing_examples.items.len > 0) {
        std.debug.print("UNEXPECTED_FAIL: {any}\n", .{report.failing_examples.items});
    }
    if (report.unexpected_pass_examples.items.len > 0) {
        std.debug.print("UNEXPECTED_PASS: {any}\n", .{report.unexpected_pass_examples.items});
    }

    try std.testing.expectEqual(@as(usize, 0), report.unexpected_fail);
    try std.testing.expectEqual(@as(usize, 0), report.unexpected_pass);
}
