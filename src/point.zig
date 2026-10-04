const std = @import("std");
const testing = std.testing;

pub const Point = struct { line: usize, column: usize, offset: usize };
pub const Position = struct { start: Point, end: Point };

test "point/position construction" {
    const p: Point = .{ .line = 1, .column = 1, .offset = 0 };
    const pos: Position = .{ .start = p, .end = .{ .line = 1, .column = 4, .offset = 3 } };
    try testing.expectEqual(@as(usize, 3), pos.end.offset);
    try testing.expectEqual(@as(usize, 1), pos.start.line);
}
