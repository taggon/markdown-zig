const std = @import("std");
const Allocator = std.mem.Allocator;

pub const point = @import("point.zig");
pub const Point = point.Point;
pub const Position = point.Position;

pub const node = @import("node.zig");
pub const Node = node.Node;
pub const NodeData = node.NodeData;

pub const block_phase = @import("block/phase.zig");
pub const block_core = @import("block/core.zig");
pub const block_gfm = @import("block/gfm.zig");
pub const inline_phase = @import("inline/phase.zig");
pub const mdx_scan = @import("mdx/scan.zig");
pub const reference = @import("reference.zig");
pub const html_renderer = @import("render/html.zig");

pub const ParseOptions = @import("options.zig").ParseOptions;
pub const HtmlOptions = @import("options.zig").HtmlOptions;

pub const ParseError = error{ InvalidUtf8, UnclosedMdxExpression, InvalidMdxJsx, NestingTooDeep, OutOfMemory };
pub const RenderError = error{ MdxNodeInErrorMode, NestingTooDeep, OutOfMemory };

pub const Parser = struct {
    options: ParseOptions,

    pub fn init(options: ParseOptions) Parser {
        return .{ .options = options };
    }

    pub fn parse(self: *const Parser, arena: Allocator, source: []const u8) ParseError!*Node {
        if (!std.unicode.utf8ValidateSlice(source)) return error.InvalidUtf8;

        var fffd_ends: std.ArrayList(usize) = .empty;
        const copy = blk: {
            if (std.mem.indexOfScalar(u8, source, 0)) |_| {
                const buf = try arena.alloc(u8, source.len + countNul(source) * 2);
                var j: usize = 0;
                for (source) |c| {
                    if (c == 0) {
                        buf[j] = 0xEF;
                        buf[j + 1] = 0xBF;
                        buf[j + 2] = 0xBD;
                        fffd_ends.append(arena, j + 3) catch return error.OutOfMemory;
                        j += 3;
                    } else {
                        buf[j] = c;
                        j += 1;
                    }
                }
                break :blk buf;
            }
            break :blk try arena.dupe(u8, source);
        };
        const fffd_slice = fffd_ends.toOwnedSlice(arena) catch return error.OutOfMemory;

        const root = try arena.create(Node);
        root.* = .{ .data = .root };

        var bp = block_phase.BlockPhase.init(arena, &self.options, root, copy, fffd_slice);
        defer bp.deinit();
        try bp.run();

        return root;
    }
};

pub fn parse(arena: Allocator, source: []const u8, options: ParseOptions) ParseError!*Node {
    return (Parser.init(options)).parse(arena, source);
}

fn countNul(s: []const u8) usize {
    var n: usize = 0;
    for (s) |c| if (c == 0) {
        n += 1;
    };
    return n;
}

pub fn renderHtml(gpa: Allocator, root: *const Node, options: HtmlOptions) RenderError![]u8 {
    return html_renderer.render(gpa, root, options);
}

pub fn toHtml(
    gpa: Allocator,
    source: []const u8,
    parse_options: ParseOptions,
    html_options: HtmlOptions,
) (ParseError || RenderError)![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const root = try parse(arena, source, parse_options);
    return try renderHtml(gpa, root, html_options);
}

test "parse empty source returns root node with copied source lifetime" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const root = try parse(arena_state.allocator(), "hello", .{});
    try std.testing.expect(root.data == .root);
}

test "NUL bytes are replaced with U+FFFD (T4.1)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const out = try toHtml(arena_state.allocator(), "a\x00b", .{}, .{});
    try std.testing.expect(std.mem.indexOf(u8, out, "\x00") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\xEF\xBF\xBD") != null);
}

test "invalid UTF-8 is rejected (T4.2)" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    try std.testing.expectError(
        error.InvalidUtf8,
        parse(arena_state.allocator(), "a \xff\xfe *b*", .{}),
    );
}

test {
    _ = @import("render/footnotes.zig");
}
