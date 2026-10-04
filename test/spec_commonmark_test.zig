const std = @import("std");
const harness = @import("harness");

test "commonmark conformance (known-fail gated)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const cases = try harness.loadJson(arena, harness.commonmark.fixture);
    try std.testing.expect(cases.len > 100);

    var report = try harness.run(std.testing.allocator, cases, harness.commonmark.xfail, .{});
    defer report.failing_examples.deinit(std.testing.allocator);
    defer report.unexpected_pass_examples.deinit(std.testing.allocator);

    std.debug.print("\n=== CommonMark Conformance ===\n", .{});
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
