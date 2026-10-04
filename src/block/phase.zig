const std = @import("std");
const Allocator = std.mem.Allocator;
const Node = @import("../node.zig").Node;
const Align = @import("../node.zig").Align;
const ParseOptions = @import("../options.zig").ParseOptions;
const ParseError = @import("../root.zig").ParseError;
const Point = @import("../point.zig").Point;
const Position = @import("../point.zig").Position;
const chars = @import("../chars.zig");
const InlinePhase = @import("../inline/phase.zig").InlinePhase;
const autolinkBody = @import("../inline/phase.zig").autolinkBody;
const reference = @import("../reference.zig");
const escape = @import("../escape.zig");
const mdx_scan = @import("../mdx/scan.zig");

const nameEql = mdx_scan.nameEql;

/// Advances an MDX expression's open-brace depth across `text`, which must be
/// a region not yet accounted for. Returns the index just past the `}` that
/// brought the depth to zero, or null if the expression is still open.
///
/// Carrying the depth forward is what keeps a multi-line expression linear:
/// re-scanning the accumulated buffer on every line is quadratic (SPEC §9.1).
fn advanceBraceDepth(text: []const u8, depth: *usize) ?usize {
    std.debug.assert(depth.* > 0);
    for (text, 0..) |c, i| switch (c) {
        '{' => depth.* += 1,
        '}' => {
            depth.* -= 1;
            if (depth.* == 0) return i + 1;
        },
        else => {},
    };
    return null;
}

/// What an MDX-mode line starts with, once container prefixes are gone. A
/// construct counts as *flow* only when it owns the whole line (SPEC §14.2);
/// otherwise the line is a paragraph and the inline phase reads the construct
/// as text.
const MdxFlow = union(enum) {
    none,
    /// `{…}` owning the line. `end` counts bytes from the `{` and is null
    /// while the expression still spans lines, in which case `depth` carries
    /// the open-brace count forward.
    expression: struct { indent: usize, end: ?usize, depth: usize },
    /// A chain of tags and expressions filling the line.
    jsx: struct { indent: usize },
    /// An opening tag cut off by the end of the line.
    incomplete_tag: struct { indent: usize, expr_pending: bool },
};

/// Classifies an MDX line (SPEC §14.2). Pure: it only looks, so the caller can
/// use the same judgement to decide whether a paragraph is interrupted.
///
/// The error split follows §14.6 — a `<` that cannot start a tag at all is
/// literal text, but a tag whose grammar breaks *after* its name is an error.
fn mdxFlowKind(line: []const u8) ParseError!MdxFlow {
    const ind = chars.skipUpTo3Cols(line);
    if (ind >= line.len) return .none;
    switch (line[ind]) {
        '{' => {
            var depth: usize = 1;
            const rel = advanceBraceDepth(line[ind + 1 ..], &depth) orelse
                return .{ .expression = .{ .indent = ind, .end = null, .depth = depth } };
            const end = 1 + rel;
            // An expression that leaves content behind is not flow; the line
            // becomes a paragraph holding a text expression (SPEC §14.3).
            if (!isBlank(line[ind + end ..])) return .none;
            return .{ .expression = .{ .indent = ind, .end = end, .depth = 0 } };
        },
        '<' => {
            var i = ind;
            var first = true;
            while (true) {
                while (i < line.len and chars.isLineWs(line[i])) i += 1;
                if (i >= line.len) return .{ .jsx = .{ .indent = ind } };
                switch (line[i]) {
                    '<' => {
                        // Autolink wins over JSX, in flow just as in text
                        // (SPEC §14.1) — otherwise `<https://x>` would be a
                        // malformed tag and error out.
                        if (autolinkBody(line, i) != null) return .none;
                        const tag = mdx_scan.scanTagBounds(line, i) catch |err| switch (err) {
                            error.InvalidJsx => return error.InvalidMdxJsx,
                            // Only a tag that opens the line may keep reading:
                            // a truncated tag further along means the line is
                            // not a clean chain, so it is not flow.
                            error.IncompleteJsx => return if (first)
                                .{ .incomplete_tag = .{ .indent = ind, .expr_pending = false } }
                            else
                                .none,
                            error.IncompleteJsxExpression => return if (first)
                                .{ .incomplete_tag = .{ .indent = ind, .expr_pending = true } }
                            else
                                .none,
                        } orelse return .none;
                        i = tag.end_pos;
                    },
                    '{' => {
                        const expr = (mdx_scan.scanExpression(line, i) catch return .none) orelse return .none;
                        i = expr.end_pos;
                    },
                    else => return .none,
                }
                first = false;
            }
        },
        else => return .none,
    }
}

/// Whether a line opens a math block: `$$` (exactly two `$`) at 0–3 columns of
/// indentation. `$$$` or more is not a math fence (SPEC §9.4).
fn isMathBlockOpening(line: []const u8) bool {
    const i = chars.skipUpTo3Cols(line);
    if (i + 2 > line.len) return false;
    if (line[i] != '$' or line[i + 1] != '$') return false;
    if (i + 2 < line.len and line[i + 2] == '$') return false;
    return true;
}


// Pure scanners and construct detectors live in core.zig / gfm.zig.
const core = @import("core.zig");
const gfm = @import("gfm.zig");
const frontmatter = @import("frontmatter.zig");
const isBlank = core.isBlank;
const trimWs = core.trimWs;
const padWith = core.padWith;
const filterDisallowedHtml = core.filterDisallowedHtml;
const IndentResult = core.IndentResult;
const isFencedCodeOpening = core.isFencedCodeOpening;
const atxInfo = core.atxInfo;
const isSetextUnderline = core.isSetextUnderline;
const isThematicBreak = core.isThematicBreak;
const canListMarkerInterruptParagraph = core.canListMarkerInterruptParagraph;
const ListMarkerInfo = core.ListMarkerInfo;
const parseListMarker = core.parseListMarker;
const htmlBlockType = core.htmlBlockType;
const htmlBlockInterruptType = core.htmlBlockInterruptType;
const htmlBlockEndFound = core.htmlBlockEndFound;
const splitTableRow = gfm.splitTableRow;
const parseDelimiterRow = gfm.parseDelimiterRow;

pub const LineInfo = struct {
    text: []const u8,
    offset: usize,
};

pub fn lineIterator(source: []const u8) LineIterator {
    return .{ .source = source, .pos = 0 };
}

pub const LineIterator = struct {
    source: []const u8,
    pos: usize,

    pub fn next(self: *LineIterator) ?LineInfo {
        if (self.pos >= self.source.len) return null;
        const start = self.pos;
        var end = start;
        while (end < self.source.len) : (end += 1) {
            const c = self.source[end];
            if (c == '\n') {
                self.pos = end + 1;
                return .{ .text = self.source[start..end], .offset = start };
            }
            if (c == '\r') {
                if (end + 1 < self.source.len and self.source[end + 1] == '\n') {
                    self.pos = end + 2;
                } else {
                    self.pos = end + 1;
                }
                return .{ .text = self.source[start..end], .offset = start };
            }
        }
        self.pos = end;
        return .{ .text = self.source[start..end], .offset = start };
    }
};

const tabWidthAt = chars.tabWidthAt;

pub const BlockKind = enum {
    document,
    paragraph,
    thematic_break,
    atx_heading,
    setext_heading,
    fenced_code,
    indented_code,
    html_block,
    math_block,
    mdx_flow_expression,
    mdx_jsx_tag,
    mdx_jsx_flow,
    blockquote,
    list,
    list_item,
    table,
    footnote_definition,
};

pub const ParagraphState = struct {
    text: std.ArrayList(u8),
    /// Source map anchors for each line in the paragraph text (SPEC §7.2).
    anchors: std.ArrayList(LineAnchor) = .empty,
};
pub const FencedCodeState = struct {
    fence_char: u8,
    open_len: usize,
    open_indent: usize,
    content: std.ArrayList(u8),
};
pub const IndentedCodeState = struct { content: std.ArrayList(u8) };
pub const HtmlBlockState = struct { html_type: u8, content: std.ArrayList(u8) };
pub const MathBlockState = struct { open_indent: usize, content: std.ArrayList(u8) };

pub const MdxFlowExprState = struct {
    /// Braces still open. Updated per appended line, never recomputed.
    depth: usize,
    content: std.ArrayList(u8),
};

/// An opening tag that did not finish on its line. Lines accumulate here until
/// the tag parses, at which point the frame becomes a leaf or a container
/// (SPEC §14.5). Scanning is incremental: `scanned` is the last validated
/// attribute boundary and `attrs` holds the attributes completed so far, so
/// each continuation line scans only the new bytes — a tag spanning N lines
/// costs O(N), not O(N²) (SPEC §16.4).
pub const MdxJsxTagState = struct {
    content: std.ArrayList(u8),
    /// Offset in `content` of the next attribute boundary. Everything before
    /// it is validated and never rescanned. `0` means the head (name) itself
    /// is still unfinished.
    scanned: usize = 0,
    /// The tag name once the head has been read; `null` until then. A slice
    /// into `content` (arena memory).
    name: ?[]const u8 = null,
    /// Attributes completed so far. Values are slices into `content`, like
    /// the completed tag's raw.
    attrs: mdx_scan.AttrList = .empty,
    /// Whether the tag is waiting on an attribute expression rather than on
    /// the rest of the tag. Decides which error EOF reports (SPEC §14.6).
    expr_pending: bool = false,
};

/// A JSX flow element holding children. Same-name nesting is not counted here:
/// a nested element opens its own frame, so the frame stack *is* the depth
/// (SPEC §14.5).
pub const MdxJsxFlowState = struct {
    name: ?[]const u8, // null = fragment
    closed: bool = false,
};
pub const ListItemState = struct {
    /// Columns a continuation line must have to stay inside the item.
    content_indent: usize,
    /// Line the item was opened on; an item that is still empty on that same
    /// line does not count as ending with a blank line.
    start_line: usize,
};

/// A footnote definition frame. Unlike a list item the content indent is not
/// derived from the marker: it is fixed at 4 columns (SPEC §13.2).
pub const FootnoteDefState = struct { start_line: usize };

/// Columns a footnote definition's continuation lines must carry.
const footnote_content_indent: usize = 4;

pub const ListState = struct {
    bullet_char: u8,
    delimiter: u8,
};

pub const TableState = struct {
    align_: []const Align,
    header_cells: [][]const u8,
    data_lines: std.ArrayList([]const u8),
};

pub const ConstructState = union(enum) {
    document: void,
    paragraph: ParagraphState,
    thematic_break: void,
    atx_heading: void,
    setext_heading: void,
    fenced_code: FencedCodeState,
    indented_code: IndentedCodeState,
    html_block: HtmlBlockState,
    math_block: MathBlockState,
    mdx_flow_expression: MdxFlowExprState,
    mdx_jsx_tag: MdxJsxTagState,
    mdx_jsx_flow: MdxJsxFlowState,
    blockquote: void,
    list: ListState,
    list_item: ListItemState,
    table: TableState,
    footnote_definition: FootnoteDefState,
};

pub const Frame = struct {
    node: *Node,
    kind: BlockKind,
    state: ConstructState,
    start_offset: usize = 0,
    start_line: usize = 0,
    end_line: usize = 0,
};

/// Source mapping anchor for one line of inline text (SPEC §7.2).
pub const LineAnchor = struct {
    text_offset: usize,
    source_line: usize,
    line_start_offset: usize,
    content_start_offset: usize,
};

/// An inline leaf waiting for the inline phase, which runs only once the block
/// phase has collected every definition (SPEC §10.1).
const PendingInline = struct {
    node: *Node,
    text: []const u8,
    anchors: []const LineAnchor,
};

pub const BlockPhase = struct {
    arena: Allocator,
    options: *const ParseOptions,
    root: *Node,
    source: []const u8,
    stack: std.ArrayList(Frame),

    /// The line currently being processed. Container markers are consumed by
    /// trimming from the front, so this shrinks as the stack is descended.
    line: []const u8,
    /// Absolute column of `line[0]`. Tab stops are every 4 columns of the
    /// *original* line, so trimming the front must not reset this.
    col: usize,
    blank: bool,
    line_no: usize,

    /// Byte offset of `self.line[0]` in the source copy (SPEC §7.1).
    line_byte_start: usize,
    /// Width in bytes of the synthetic space prefix that currently stands in
    /// for the tail of a straddled tab. Those pad bytes exist only in the
    /// padded line buffer, so offset arithmetic must not count them as source
    /// bytes (SPEC §7.1). Reset at every line start.
    pad_prefix: usize = 0,
    /// Byte offset of each source line start, 0-based index.
    line_starts: []usize = &.{},
    /// Sorted copy offsets for NUL→FFFD correction (SPEC §7.3).
    fffd_ends: []const usize,

    definitions: std.StringHashMapUnmanaged(*Node),
    /// identifier → footnote definition node. Complete by the time the inline
    /// phase runs, so a reference resolves regardless of definition order.
    footnote_definitions: std.StringHashMapUnmanaged(*Node),
    /// Nodes whose last line was blank. cmark decides tight vs loose from this
    /// when a list is finalized; judging it incrementally while parsing leaks a
    /// nested list's blank lines out to the enclosing list.
    last_line_blank: std.AutoHashMapUnmanaged(*Node, void),
    /// Inline leaves in document order, parsed after the block phase finishes.
    pending_inline: std.ArrayList(PendingInline),

    pub fn init(arena: Allocator, options: *const ParseOptions, root: *Node, source: []const u8, fffd_ends: []const usize) BlockPhase {
        return .{
            .arena = arena,
            .options = options,
            .root = root,
            .source = source,
            .stack = .empty,
            .line = "",
            .col = 0,
            .blank = true,
            .line_no = 0,
            .line_byte_start = 0,
            .fffd_ends = fffd_ends,
            .definitions = .empty,
            .footnote_definitions = .empty,
            .last_line_blank = .empty,
            .pending_inline = .empty,
        };
    }

    pub fn deinit(self: *BlockPhase) void {
        self.stack.deinit(self.arena);
        self.definitions.deinit(self.arena);
        self.footnote_definitions.deinit(self.arena);
        self.last_line_blank.deinit(self.arena);
        self.pending_inline.deinit(self.arena);
    }

    // ── Position helpers (SPEC §7) ────────────────────────────────────

    pub fn copyToOriginalOffset(self: *const BlockPhase, copy_off: usize) usize {
        var lo: usize = 0;
        var hi: usize = self.fffd_ends.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.fffd_ends[mid] <= copy_off) lo = mid + 1 else hi = mid;
        }
        return copy_off - 2 * lo;
    }

    fn lineStartOff(self: *const BlockPhase, line_no: usize) usize {
        if (line_no == 0 or line_no > self.line_starts.len) return 0;
        return self.line_starts[line_no - 1];
    }

    fn lineEndOff(self: *const BlockPhase, line_no: usize) usize {
        if (line_no == 0 or line_no >= self.line_starts.len) return self.source.len;
        const next = self.line_starts[line_no];
        if (next == 0) return self.source.len;
        if (next >= 2 and self.source[next - 2] == '\r' and self.source[next - 1] == '\n') {
            return next - 2;
        }
        return next - 1;
    }

    fn makePoint(self: *const BlockPhase, line_no: usize, copy_off: usize) Point {
        const ls = self.lineStartOff(line_no);
        var col: usize = 0;
        var i = ls;
        while (i < copy_off and i < self.source.len) {
            const len = std.unicode.utf8ByteSequenceLength(self.source[i]) catch 1;
            i += len;
            col += 1;
        }
        return .{
            .line = line_no,
            .column = col + 1,
            .offset = self.copyToOriginalOffset(copy_off),
        };
    }

    fn spanPosition(self: *const BlockPhase, start_line: usize, start_off: usize, end_line: usize) Position {
        return .{
            .start = self.makePoint(start_line, start_off),
            .end = self.makePoint(end_line, self.lineEndOff(end_line)),
        };
    }

    /// Byte offset of the first non-whitespace byte on the current line. A
    /// leaf block's position starts at its first content character, not at the
    /// indentation in front of it (SPEC §7.1). Synthetic pad bytes standing in
    /// for a straddled tab have no source counterpart, so they are subtracted.
    fn contentStart(self: *const BlockPhase) usize {
        var i: usize = 0;
        while (i < self.line.len and chars.isLineWs(self.line[i])) i += 1;
        return self.line_byte_start + i -| self.pad_prefix;
    }

    /// Position for a block that ends inside a line rather than at its end —
    /// what the MDX flow constructs need, since several can share one line.
    fn spanOffsets(self: *const BlockPhase, start_line: usize, start_off: usize, end_line: usize, end_off: usize) Position {
        return .{
            .start = self.makePoint(start_line, start_off),
            .end = self.makePoint(end_line, end_off),
        };
    }

    fn buildLineStarts(arena: Allocator, source: []const u8) Allocator.Error![]usize {
        var list: std.ArrayList(usize) = .empty;
        try list.append(arena, 0);
        var i: usize = 0;
        while (i < source.len) : (i += 1) {
            if (source[i] == '\n') {
                try list.append(arena, i + 1);
            } else if (source[i] == '\r') {
                if (i + 1 < source.len and source[i + 1] == '\n') {
                    try list.append(arena, i + 2);
                    i += 1;
                } else {
                    try list.append(arena, i + 1);
                }
            }
        }
        return list.toOwnedSlice(arena);
    }

    // ── Frame management ──────────────────────────────────────────────

    fn pushFrame(self: *BlockPhase, frame: Frame) ParseError!void {
        if (self.stack.items.len >= self.options.max_nesting) return error.NestingTooDeep;
        try self.stack.append(self.arena, frame);
    }

    fn pushFrameAt(self: *BlockPhase, node: *Node, kind: BlockKind, state: ConstructState, start_off: usize) ParseError!void {
        try self.pushFrame(.{
            .node = node,
            .kind = kind,
            .state = state,
            .start_offset = start_off,
            .start_line = self.line_no,
            .end_line = self.line_no,
        });
    }

    pub fn run(self: *BlockPhase) ParseError!void {
        self.line_starts = try buildLineStarts(self.arena, self.source);
        var iter = lineIterator(self.source);

        // Frontmatter is recognised only at the very start of the document,
        // before any other content (SPEC §9.3).
        if (self.options.frontmatter) {
            try self.consumeFrontmatter(&iter);
        }

        while (iter.next()) |line_info| {
            self.line = line_info.text;
            self.line_byte_start = line_info.offset;
            self.col = 0;
            self.pad_prefix = 0;
            self.line_no += 1;
            self.blank = isBlank(self.line);
            try self.processLine();
            try self.markLastLineBlank();
            for (self.stack.items) |*f| f.end_line = self.line_no;
        }

        // Finalize remaining frames, then stamp the root position, and only
        // then run the inline phase: `definitions` is complete at this point,
        // so references that point forward in the document resolve (SPEC §10.1).
        while (self.stack.items.len > 0) {
            try self.finalizeTop();
        }

        if (self.source.len == 0) {
            self.root.position = null;
        } else {
            const end_line = if (self.line_no > 0) self.line_no else @max(1, self.line_starts.len -| 1);
            self.root.position = self.spanPosition(1, 0, end_line);
        }

        for (self.pending_inline.items) |job| {
            var ip = InlinePhase.init(self.arena, job.text, job.node, self.options, &self.definitions, &self.footnote_definitions, job.anchors, self);
            try ip.run();
        }
    }

    fn processLine(self: *BlockPhase) ParseError!void {
        var consumed = false;

        consumed = try self.processContainers();
        if (consumed) return;

        if (self.stack.items.len > 0) {
            const top_kind = self.stack.items[self.stack.items.len - 1].kind;
            switch (top_kind) {
                .paragraph => {
                    if (self.blank) {
                        try self.finalizeTop();
                    } else {
                        const setext_depth = isSetextUnderline(self.line);
                        if (setext_depth) |depth| {
                            try self.closeSetext(depth);
                            consumed = true;
                        } else if (atxInfo(self.line) != null) {
                            try self.finalizeTop();
                        } else if (isThematicBreak(self.line)) {
                            try self.finalizeTop();
                        } else if (isFencedCodeOpening(self.line) != null) {
                            try self.finalizeTop();
                        } else if (self.options.math and isMathBlockOpening(self.line)) {
                            try self.finalizeTop();
                        } else if (self.options.gfm and gfm.footnoteDefInfo(self.line) != null) {
                            try self.finalizeTop();
                            // MDX mode has no HTML blocks, so their interrupt
                            // rules do not apply either (SPEC §14.1).
                        } else if (!self.options.mdx and htmlBlockInterruptType(self.line) != null) {
                            try self.finalizeTop();
                        } else if (self.options.mdx and try self.mdxFlowInterrupts()) {
                            try self.finalizeTop();
                        } else if (self.options.gfm and try self.tryTableFromParagraph()) {
                            consumed = true;
                        } else {
                            try self.appendParagraphLine();
                            consumed = true;
                        }
                    }
                },
                .fenced_code => consumed = try self.continueFencedCode(),
                .indented_code => consumed = try self.continueIndentedCode(),
                .html_block => consumed = try self.continueHtmlBlock(),
                .math_block => consumed = try self.continueMathBlock(),
                .mdx_flow_expression => consumed = try self.continueMdxFlowExpression(),
                .mdx_jsx_tag => consumed = try self.continueMdxJsxTag(),
                .mdx_jsx_flow => consumed = try self.continueMdxJsxFlow(),
                .table => consumed = try self.continueTable(),
                else => {},
            }
        }

        if (consumed) return;

        // Open new blocks
        if (!self.blank) {
            // A list frame with no open item cannot hold a leaf. It stays open
            // across blank lines so a later marker can continue the list, but
            // any other block closes it first.
            while (self.stack.items.len > 0 and
                self.stack.items[self.stack.items.len - 1].kind == .list)
            {
                try self.finalizeTop();
            }

            if (try self.tryOpenLeafConstruct()) return;
            // A footnote definition is a container: after opening it, the
            // remaining line content must fall through to openParagraph or
            // another block construct as its child. When the opener line
            // has no content, return so no empty paragraph is created.
            if (self.options.gfm) {
                if (try self.tryFootnoteDefinition()) {
                    if (self.line.len == 0 or isBlank(self.line)) return;
                    // The marker is consumed; what is left of the opener line
                    // is the definition's first content line, so it gets the
                    // same leaf dispatch a top-level line would get.
                    if (try self.tryOpenLeafConstruct()) return;
                }
            }

            const top_is_paragraph = self.stack.items.len > 0 and
                self.stack.items[self.stack.items.len - 1].kind == .paragraph;
            if (!top_is_paragraph) {
                if (try self.tryIndentedCode()) return;
            }

            try self.openParagraph();
        }
    }

    /// Turns the open paragraph into a setext heading. Link reference
    /// definitions are peeled off first: an underline below a paragraph that
    /// holds nothing but definitions has no heading content, so it is ordinary
    /// paragraph text instead (CommonMark §4.3).
    fn closeSetext(self: *BlockPhase, depth: u8) ParseError!void {
        const frame = &self.stack.items[self.stack.items.len - 1];
        const attach_parent = frame.node.parent orelse self.root;
        try reference.extractFromParagraph(
            self.arena,
            &self.definitions,
            attach_parent,
            frame.node,
            &frame.state.paragraph.text,
        );
        if (frame.state.paragraph.text.items.len > 0) {
            frame.node.data = .{ .heading = .{ .depth = depth } };
            frame.end_line = self.line_no;
            try self.finalizeTop();
        } else {
            attach_parent.appendChild(frame.node);
            try self.appendParagraphLine();
        }
    }

    /// Records whether each open block's last line was blank (cmark's
    /// `lastLineBlank`). Only the deepest open block and its ancestors are
    /// stamped; a list reads these at finalize time to decide tight vs loose.
    fn markLastLineBlank(self: *BlockPhase) ParseError!void {
        const container = self.currentParent();
        if (self.blank) {
            if (container.last_child) |lc| try self.last_line_blank.put(self.arena, lc, {});
        }

        // A blockquote line is never blank (it starts with `>`), blank lines
        // inside a fenced code block do not count, and an item opened by this
        // very line has not "ended with" anything yet.
        var blank = self.blank;
        if (blank and self.stack.items.len > 0) {
            const top = self.stack.items[self.stack.items.len - 1];
            blank = switch (top.kind) {
                .blockquote, .fenced_code => false,
                .list_item => top.node.first_child != null or
                    top.state.list_item.start_line != self.line_no,
                .footnote_definition => top.node.first_child != null or
                    top.state.footnote_definition.start_line != self.line_no,
                else => true,
            };
        }

        var node: ?*Node = container;
        while (node) |n| {
            if (blank) {
                try self.last_line_blank.put(self.arena, n, {});
            } else {
                _ = self.last_line_blank.remove(n);
            }
            node = n.parent;
        }
    }

    /// Whether `node`'s content ends on a blank line, descending through the
    /// last child of lists and items the way cmark's `ends_with_blank_line` does.
    fn endsWithBlankLine(self: *BlockPhase, node: *Node) bool {
        var cur: ?*Node = node;
        while (cur) |n| {
            if (self.last_line_blank.contains(n)) return true;
            switch (n.data) {
                .list, .list_item => cur = n.last_child,
                else => return false,
            }
        }
        return false;
    }

    /// A list is loose if any item ends with a blank line and is not the last,
    /// or if any block inside an item ends with a blank line and is followed by
    /// more content (CommonMark §5.3).
    fn listIsLoose(self: *BlockPhase, list_node: *Node) bool {
        var item = list_node.first_child;
        while (item) |it| : (item = it.next) {
            if (it.next != null and self.endsWithBlankLine(it)) return true;
            var sub = it.first_child;
            while (sub) |s| : (sub = s.next) {
                if ((it.next != null or s.next != null) and self.endsWithBlankLine(s)) return true;
            }
        }
        return false;
    }

    fn currentParent(self: *BlockPhase) *Node {
        if (self.stack.items.len > 0) {
            return self.stack.items[self.stack.items.len - 1].node;
        }
        return self.root;
    }

    fn processContainers(self: *BlockPhase) ParseError!bool {
        // Match existing container frames.
        var match_count: usize = 0;
        while (match_count < self.stack.items.len) : (match_count += 1) {
            // Each consumed marker can expose a blank remainder (`>>`), so the
            // blank flag is re-derived as the stack is descended.
            self.blank = isBlank(self.line);
            switch (self.stack.items[match_count].kind) {
                .blockquote => {
                    if (try self.consumeBqMarker()) |_| continue else break;
                },
                // Pass-through containers: they carry no line prefix, so every
                // line matches and the frames below decide.
                .list, .mdx_jsx_flow => continue,
                .list_item => {
                    if (self.blank) {
                        // A blank line right after an item that never got any
                        // content ends the item (CommonMark §5.2).
                        if (self.stack.items[match_count].node.first_child == null) break;
                        continue;
                    }
                    const ci = self.stack.items[match_count].state.list_item.content_indent;
                    if (self.countLeadingCols() < ci) break;
                    try self.advanceCols(ci);
                    continue;
                },
                .footnote_definition => {
                    if (self.blank) {
                        if (self.stack.items[match_count].node.first_child == null) break;
                        continue;
                    }
                    if (self.countLeadingCols() < footnote_content_indent) break;
                    try self.advanceCols(footnote_content_indent);
                    continue;
                },
                else => break,
            }
        }
        self.blank = isBlank(self.line);

        // Close non-matching containers.
        if (match_count < self.stack.items.len) {
            const unmatched_kind = self.stack.items[match_count].kind;
            if (unmatched_kind == .blockquote or unmatched_kind == .list_item or
                unmatched_kind == .footnote_definition)
            {
                const innermost = self.stack.items[self.stack.items.len - 1].kind;
                if (!self.blank and innermost == .paragraph) {
                    // Lazy continuation: the line belongs to the open paragraph.
                    if (!try self.opensNewBlock()) {
                        try self.appendParagraphLine();
                        return true;
                    }
                }
                while (self.stack.items.len > match_count) {
                    try self.finalizeTop();
                }
            }
        }

        // Open new containers.
        if (!self.blank) {
            var can_open = self.stack.items.len == 0;
            if (!can_open) {
                const top_kind = self.stack.items[self.stack.items.len - 1].kind;
                if (top_kind == .blockquote or top_kind == .list or
                    top_kind == .list_item or top_kind == .footnote_definition or
                    // A JSX flow element holds ordinary flow content, so a list
                    // or blockquote may open directly inside it (SPEC §14.5).
                    top_kind == .mdx_jsx_flow)
                {
                    can_open = true;
                } else if (top_kind == .paragraph) {
                    if (self.bqMarkerAhead() or canListMarkerInterruptParagraph(self.line, self.col)) {
                        try self.finalizeTop();
                        can_open = true;
                    }
                } else if (top_kind == .indented_code) {
                    // A marker at 0–3 columns of indentation ends the code block;
                    // close it so the container can open on this line.
                    if (self.bqMarkerAhead() or parseListMarker(self.line, self.col) != null) {
                        try self.finalizeTop();
                        can_open = true;
                    }
                } else if (top_kind == .table) {
                    if (self.bqMarkerAhead() or parseListMarker(self.line, self.col) != null) {
                        try self.finalizeTop();
                        can_open = true;
                    }
                }
            }

            if (can_open) {
                while (!self.blank) {
                    if (try self.consumeBqMarker()) |off| {
                        try self.openBlockquote(off);
                        continue;
                    }
                    if (isThematicBreak(self.line)) break;
                    if (try self.tryOpenListItem()) {
                        continue;
                    }
                    break;
                }
            }
        }

        self.blank = isBlank(self.line);
        return false;
    }

    /// Columns of whitespace at the front of the current line, counted from the
    /// container's content start (so it is directly comparable to a stored
    /// `content_indent`).
    fn countLeadingCols(self: *BlockPhase) usize {
        var cols: usize = 0;
        var col = self.col;
        for (self.line) |c| {
            if (c == ' ') {
                cols += 1;
                col += 1;
            } else if (c == '\t') {
                const w = tabWidthAt(col);
                cols += w;
                col += w;
            } else break;
        }
        return cols;
    }

    /// Advances past `target` columns of leading whitespace. A tab that
    /// straddles the target is replaced by the spaces it still owes, so the
    /// remaining line always starts on a byte boundary (cmark's
    /// `partially_consumed_tab`).
    fn advanceCols(self: *BlockPhase, target: usize) ParseError!void {
        var remaining = target;
        var i: usize = 0;
        while (remaining > 0 and i < self.line.len) {
            if (self.line[i] == ' ') {
                i += 1;
                self.col += 1;
                remaining -= 1;
            } else if (self.line[i] == '\t') {
                const w = tabWidthAt(self.col);
                if (w > remaining) {
                    self.col += remaining;
                    self.line_byte_start += i + 1;
                    self.line = try padWith(self.arena, w - remaining, self.line[i + 1 ..]);
                    self.pad_prefix = w - remaining;
                    return;
                }
                i += 1;
                self.col += w;
                remaining -= w;
            } else break;
        }
        self.line_byte_start += i;
        self.line = self.line[i..];
    }

    /// Consumes every space/tab at the head of the current line, keeping `col`
    /// in sync (a tab advances to the next 4-column stop). Used by the footnote
    /// definition opener, which swallows all whitespace after `]:` so that a long
    /// run of spaces cannot turn the content into an indented code block.
    fn skipLineWhitespace(self: *BlockPhase) void {
        while (self.line.len > 0) {
            const c = self.line[0];
            if (c == ' ') {
                self.col += 1;
            } else if (c == '\t') {
                self.col += chars.tabWidthAt(self.col);
            } else break;
            self.line = self.line[1..];
            self.line_byte_start += 1;
        }
    }

    /// Strips up to `target` columns of indentation from the current line
    /// without touching parser state. Reports how many columns actually came
    /// off so callers can tell a full indent from a short one.
    fn stripIndent(self: *BlockPhase, target: usize) ParseError!IndentResult {
        var removed: usize = 0;
        var col = self.col;
        var i: usize = 0;
        while (removed < target and i < self.line.len) {
            if (self.line[i] == ' ') {
                i += 1;
                col += 1;
                removed += 1;
            } else if (self.line[i] == '\t') {
                const w = tabWidthAt(col);
                if (removed + w > target) {
                    const owed = removed + w - target;
                    return .{
                        .content = try padWith(self.arena, owed, self.line[i + 1 ..]),
                        .cols_removed = target,
                    };
                }
                i += 1;
                col += w;
                removed += w;
            } else break;
        }
        return .{ .content = self.line[i..], .cols_removed = removed };
    }

    /// Whether the line starts a block once the unmatched containers are
    /// closed. A lazy continuation candidate is measured against the *matched*
    /// container, not the open paragraph, so the paragraph-interruption
    /// restrictions (setext underline, ordered lists starting at 1) do not
    /// apply — the paragraph is no longer the container being interrupted.
    fn opensNewBlock(self: *BlockPhase) ParseError!bool {
        if (self.bqMarkerAhead()) return true;
        if (atxInfo(self.line) != null) return true;
        if (isFencedCodeOpening(self.line) != null) return true;
        if (self.options.mdx) {
            if (try self.mdxFlowInterrupts()) return true;
        } else if (htmlBlockInterruptType(self.line) != null) return true;
        if (isThematicBreak(self.line)) return true;
        if (self.options.math and isMathBlockOpening(self.line)) return true;
        return parseListMarker(self.line, self.col) != null;
    }

    /// The `list` frame that owns the `list_item` frame at `item_idx`, if any.
    fn listFrameOf(self: *BlockPhase, item_idx: usize) ?*ListState {
        if (item_idx == 0 or self.stack.items[item_idx - 1].kind != .list) return null;
        return &self.stack.items[item_idx - 1].state.list;
    }

    fn tryOpenListItem(self: *BlockPhase) ParseError!bool {
        const mi = parseListMarker(self.line, self.col) orelse return false;
        const marker_off = self.line_byte_start + mi.marker_byte_start;

        var existing_list_idx: ?usize = null;
        if (self.stack.items.len > 0) {
            const top = self.stack.items[self.stack.items.len - 1];
            if (top.kind == .list) {
                const ls = top.state.list;
                const same_kind = if (mi.ordered)
                    ls.delimiter == mi.delimiter
                else
                    ls.bullet_char == mi.bullet_char;
                if (same_kind) {
                    existing_list_idx = self.stack.items.len - 1;
                } else {
                    try self.finalizeTop();
                }
            }
        }

        if (existing_list_idx) |li| {
            const list_node = self.stack.items[li].node;
            try self.pushListItem(list_node, mi, marker_off);
        } else {
            const list_node = try self.arena.create(Node);
            list_node.* = .{ .data = .{ .list = .{
                .ordered = mi.ordered,
                .start = if (mi.ordered) mi.start else null,
                .spread = false,
            } } };
            self.currentParent().appendChild(list_node);
            try self.pushFrameAt(list_node, .list, .{ .list = .{
                .bullet_char = mi.bullet_char,
                .delimiter = mi.delimiter,
            } }, marker_off);
            try self.pushListItem(list_node, mi, marker_off);
        }

        const marker_end = mi.marker_byte_start + mi.marker_byte_len;
        self.line = self.line[marker_end..];
        self.line_byte_start += marker_end;
        self.col += mi.leading_col + mi.marker_byte_len;
        try self.advanceCols(mi.content_indent - mi.leading_col - mi.marker_byte_len);

        // GFM task list item: [ ], [x], or [X] followed by whitespace.
        if (self.options.gfm and self.line.len >= 3 and
            self.line[0] == '[' and self.line[2] == ']' and
            (self.line[1] == ' ' or self.line[1] == 'x' or self.line[1] == 'X') and
            (self.line.len == 3 or chars.isLineWs(self.line[3])))
        {
            const item_frame = &self.stack.items[self.stack.items.len - 1];
            item_frame.node.data.list_item.checked = !(self.line[1] == ' ');
            const consume: usize = if (self.line.len > 3 and chars.isLineWs(self.line[3])) 4 else 3;
            self.advanceLine(consume);
        }

        return true;
    }

    fn pushListItem(self: *BlockPhase, list_node: *Node, mi: ListMarkerInfo, marker_off: usize) ParseError!void {
        const item = try self.arena.create(Node);
        item.* = .{ .data = .{ .list_item = .{ .spread = false } } };
        list_node.appendChild(item);
        try self.pushFrameAt(item, .list_item, .{ .list_item = .{
            .content_indent = mi.content_indent,
            .start_line = self.line_no,
        } }, marker_off);
    }

    fn consumeBqMarker(self: *BlockPhase) ParseError!?usize {
        if (!self.bqMarkerAhead()) return null;
        const ws = chars.skipUpTo3Cols(self.line);
        const marker_off = self.line_byte_start + ws;
        const i = ws + 1;
        self.advanceLine(i);
        if (self.line.len > 0 and (self.line[0] == ' ' or self.line[0] == '\t')) {
            try self.advanceCols(1);
        }
        return marker_off;
    }

    fn bqMarkerAhead(self: *BlockPhase) bool {
        const i = chars.skipUpTo3Cols(self.line);
        return i < self.line.len and self.line[i] == '>';
    }

    fn openBlockquote(self: *BlockPhase, start_off: usize) ParseError!void {
        const bq = try self.arena.create(Node);
        bq.* = .{ .data = .blockquote };
        self.currentParent().appendChild(bq);
        try self.pushFrameAt(bq, .blockquote, .blockquote, start_off);
    }

    /// Opens a `[^label]:` footnote definition as a container block (SPEC §13.2).
    fn tryFootnoteDefinition(self: *BlockPhase) ParseError!bool {
        const info = gfm.footnoteDefInfo(self.line) orelse return false;
        const marker_off = self.line_byte_start + chars.skipUpTo3Cols(self.line);

        const label = try escape.backslashes(self.arena, info.label);
        const identifier = try reference.normalizeIdentifier(self.arena, label);

        const node = try self.arena.create(Node);
        node.* = .{ .data = .{ .footnote_definition = .{
            .identifier = identifier,
            .label = label,
        } } };
        self.currentParent().appendChild(node);
        try self.pushFrameAt(node, .footnote_definition, .{
            .footnote_definition = .{ .start_line = self.line_no },
        }, marker_off);

        // The first definition for an identifier wins (SPEC §13.2), matching how
        // link reference definitions behave.
        const gop = try self.footnote_definitions.getOrPut(self.arena, identifier);
        if (!gop.found_existing) gop.value_ptr.* = node;

        // Everything through `]:` is single-byte ASCII, so the byte count is the
        // column count. (A tab inside a label would skew the reported column but
        // never the structure — continuation indent is fixed at 4 and measured
        // independently on later lines.)
        self.advanceLine(info.content_byte);
        self.skipLineWhitespace();
        return true;
    }

    /// The leaf-construct dispatch the open-new-blocks flow runs, in fixed
    /// order: ATX heading, fenced code, MDX flow (or HTML block outside MDX
    /// mode), thematic break, math block. Returns true when one of them
    /// consumed the line.
    fn tryOpenLeafConstruct(self: *BlockPhase) ParseError!bool {
        if (try self.tryAtxHeading()) return true;
        if (try self.tryFencedCode()) return true;
        // SPEC §14.1: MDX mode replaces HTML block with MDX flow constructs.
        if (self.options.mdx) {
            if (try self.tryMdxFlow()) return true;
        } else {
            if (try self.tryHtmlBlock()) return true;
        }
        if (try self.tryThematicBreak()) return true;
        if (self.options.math and try self.tryMathBlock()) return true;
        return false;
    }

    fn tryAtxHeading(self: *BlockPhase) ParseError!bool {
        const info = atxInfo(self.line) orelse return false;
        const heading = try self.arena.create(Node);
        heading.* = .{ .data = .{ .heading = .{ .depth = info.depth } } };
        self.currentParent().appendChild(heading);
        heading.position = self.spanPosition(self.line_no, self.contentStart(), self.line_no);
        if (info.content.len > 0) {
            // A single anchor maps the heading text back to the source so the
            // inline children get positions too (SPEC §7.2). `content` is a
            // subslice of `line`, so its byte offset is pointer arithmetic;
            // synthetic pad bytes substituted for a straddled tab are not
            // source bytes and are subtracted (clamped at 0).
            const content_off = @intFromPtr(info.content.ptr) - @intFromPtr(self.line.ptr) -| self.pad_prefix;
            const anchors = try self.arena.alloc(LineAnchor, 1);
            anchors[0] = .{
                .text_offset = 0,
                .source_line = self.line_no,
                .line_start_offset = self.lineStartOff(self.line_no),
                .content_start_offset = self.line_byte_start + content_off,
            };
            try self.queueInline(heading, info.content, anchors);
        }
        return true;
    }

    fn tryThematicBreak(self: *BlockPhase) ParseError!bool {
        if (!isThematicBreak(self.line)) return false;

        const node = try self.arena.create(Node);
        node.* = .{ .data = .thematic_break };
        self.currentParent().appendChild(node);
        node.position = self.spanPosition(self.line_no, self.contentStart(), self.line_no);
        return true;
    }

    // ── Math block (SPEC §9.4) ────────────────────────────────────────

    fn tryMathBlock(self: *BlockPhase) ParseError!bool {
        if (!isMathBlockOpening(self.line)) return false;

        const indent = chars.skipUpTo3Cols(self.line);
        const after_fence = self.line[indent + 2 ..];
        const after_trimmed = trimWs(after_fence);

        // Single-line math: $$ content $$ on one line (SPEC §9.4).
        if (after_trimmed.len > 2 and
            after_trimmed[after_trimmed.len - 1] == '$' and
            after_trimmed[after_trimmed.len - 2] == '$' and
            after_trimmed[after_trimmed.len - 3] != '$')
        {
            const inner = trimWs(after_trimmed[0 .. after_trimmed.len - 2]);
            const node = try self.arena.create(Node);
            node.* = .{ .data = .{ .math = try self.arena.dupe(u8, inner) } };
            self.currentParent().appendChild(node);
            node.position = self.spanPosition(self.line_no, self.contentStart(), self.line_no);
            return true;
        }

        const node = try self.arena.create(Node);
        node.* = .{ .data = .{ .math = "" } };
        self.currentParent().appendChild(node);

        var content: std.ArrayList(u8) = .empty;
        if (after_trimmed.len > 0) {
            try content.appendSlice(self.arena, after_trimmed);
            try content.append(self.arena, '\n');
        }

        try self.pushFrameAt(node, .math_block, .{ .math_block = .{
            .open_indent = indent,
            .content = content,
        } }, self.contentStart());
        return true;
    }

    fn continueMathBlock(self: *BlockPhase) ParseError!bool {
        const idx = self.stack.items.len - 1;
        const state = &self.stack.items[idx].state.math_block;

        if (isMathBlockOpening(self.line)) {
            const close_indent = chars.skipUpTo3Cols(self.line);
            if (isBlank(self.line[close_indent + 2 ..])) {
                self.stack.items[idx].end_line = self.line_no;
                try self.finalizeTop();
                return true;
            }
        }

        const r = try self.stripIndent(state.open_indent);
        try state.content.appendSlice(self.arena, r.content);
        try state.content.append(self.arena, '\n');
        return true;
    }

    fn finishMath(self: *BlockPhase, node: *Node, buf: *std.ArrayList(u8)) ParseError!void {
        var value = buf.items;
        if (value.len > 0 and value[value.len - 1] == '\n') value = value[0 .. value.len - 1];
        node.data = .{ .math = try self.arena.dupe(u8, value) };
        buf.deinit(self.arena);
    }

    fn tryFencedCode(self: *BlockPhase) ParseError!bool {
        const fi = isFencedCodeOpening(self.line) orelse return false;

        var lang: ?[]const u8 = null;
        var meta: ?[]const u8 = null;
        const info_trimmed = trimWs(fi.info);
        if (info_trimmed.len > 0) {
            var j: usize = 0;
            while (j < info_trimmed.len and !chars.isWsByte(info_trimmed[j])) : (j += 1) {}
            lang = try escape.resolve(self.arena, info_trimmed[0..j]);
            var k = j;
            while (k < info_trimmed.len and chars.isWsByte(info_trimmed[k])) : (k += 1) {}
            if (k < info_trimmed.len) {
                meta = try escape.resolve(self.arena, info_trimmed[k..]);
            }
        }

        const node = try self.arena.create(Node);
        node.* = .{ .data = .{ .code = .{ .lang = lang, .meta = meta, .value = "" } } };
        self.currentParent().appendChild(node);

        try self.pushFrameAt(node, .fenced_code, .{ .fenced_code = .{
            .fence_char = fi.fence_char,
            .open_len = fi.open_len,
            .open_indent = fi.open_indent,
            .content = .empty,
        } }, self.contentStart());
        return true;
    }

    fn tryIndentedCode(self: *BlockPhase) ParseError!bool {
        const r = try self.stripIndent(4);
        if (r.cols_removed < 4) return false;

        const node = try self.arena.create(Node);
        node.* = .{ .data = .{ .code = .{ .lang = null, .meta = null, .value = "" } } };
        self.currentParent().appendChild(node);

        try self.pushFrameAt(node, .indented_code, .{ .indented_code = .{ .content = .empty } }, self.line_byte_start);
        var buf = &self.stack.items[self.stack.items.len - 1].state.indented_code.content;
        try buf.appendSlice(self.arena, r.content);
        try buf.append(self.arena, '\n');
        return true;
    }

    fn continueFencedCode(self: *BlockPhase) ParseError!bool {
        const fc = self.stack.items[self.stack.items.len - 1].state.fenced_code;

        const i = chars.skipUpTo3Cols(self.line);

        if (i < self.line.len and self.line[i] == fc.fence_char) {
            var count: usize = 0;
            var j = i;
            while (j < self.line.len and self.line[j] == fc.fence_char) : (j += 1) {
                count += 1;
            }
            if (count >= fc.open_len) {
                var k = j;
                while (k < self.line.len and (self.line[k] == ' ' or self.line[k] == '\t')) : (k += 1) {}
                if (k == self.line.len) {
                    self.stack.items[self.stack.items.len - 1].end_line = self.line_no;
                    try self.finalizeTop();
                    return true;
                }
            }
        }

        const r = try self.stripIndent(fc.open_indent);
        var buf = &self.stack.items[self.stack.items.len - 1].state.fenced_code.content;
        try buf.appendSlice(self.arena, r.content);
        try buf.append(self.arena, '\n');
        return true;
    }

    fn continueIndentedCode(self: *BlockPhase) ParseError!bool {
        const r = try self.stripIndent(4);
        // A blank line stays in the block; it is trimmed away at finalize time
        // if the block ends there.
        if (!self.blank and r.cols_removed < 4) {
            try self.finalizeTop();
            return false;
        }

        var buf = &self.stack.items[self.stack.items.len - 1].state.indented_code.content;
        try buf.appendSlice(self.arena, r.content);
        try buf.append(self.arena, '\n');
        return true;
    }

    fn tryHtmlBlock(self: *BlockPhase) ParseError!bool {
        const t = htmlBlockType(self.line) orelse return false;

        const node = try self.arena.create(Node);
        node.* = .{ .data = .{ .html = "" } };
        self.currentParent().appendChild(node);

        var content: std.ArrayList(u8) = .empty;
        try content.appendSlice(self.arena, self.line);
        try content.append(self.arena, '\n');

        if (t <= 5 and htmlBlockEndFound(t, self.line)) {
            node.data = .{ .html = try self.arena.dupe(u8, content.items) };
            node.position = self.spanPosition(self.line_no, self.contentStart(), self.line_no);
            content.deinit(self.arena);
            return true;
        }

        try self.pushFrameAt(node, .html_block, .{ .html_block = .{
            .html_type = t,
            .content = content,
        } }, self.contentStart());
        return true;
    }

    fn continueHtmlBlock(self: *BlockPhase) ParseError!bool {
        const idx = self.stack.items.len - 1;
        const t = self.stack.items[idx].state.html_block.html_type;

        if (t <= 5) {
            var content = &self.stack.items[idx].state.html_block.content;
            try content.appendSlice(self.arena, self.line);
            try content.append(self.arena, '\n');
            if (htmlBlockEndFound(t, self.line)) {
                self.stack.items[idx].end_line = self.line_no;
                try self.finalizeTop();
            }
            return true;
        } else {
            if (self.blank) {
                try self.finalizeTop();
            } else {
                var content = &self.stack.items[idx].state.html_block.content;
                try content.appendSlice(self.arena, self.line);
                try content.append(self.arena, '\n');
            }
            return true;
        }
    }

    // ── MDX flow constructs (SPEC §14.2 – §14.5) ─────────────────────

    /// Opens whatever MDX flow construct this line starts. Returns true when
    /// the line is fully consumed.
    fn tryMdxFlow(self: *BlockPhase) ParseError!bool {
        switch (try mdxFlowKind(self.line)) {
            .none => return false,
            .expression => |e| {
                self.advanceLine(e.indent);
                return self.openMdxFlowExpression(e.end, e.depth);
            },
            .incomplete_tag => |t| {
                self.advanceLine(t.indent);
                return self.openMdxJsxTagAccumulator(t.expr_pending);
            },
            .jsx => |j| {
                self.advanceLine(j.indent);
                return self.consumeMdxJsxChain();
            },
        }
    }

    /// Whether this line starts a flow construct, i.e. whether it would
    /// interrupt an open paragraph (SPEC §14.2).
    fn mdxFlowInterrupts(self: *BlockPhase) ParseError!bool {
        return (try mdxFlowKind(self.line)) != .none;
    }

    /// Trims `n` bytes off the front of the current line, keeping the byte
    /// offset and column in step. The column walks the removed bytes: a space
    /// adds 1, a tab adds its tab-stop width, a UTF-8 continuation byte adds 0
    /// (its lead byte already paid for the character), and every other byte
    /// adds 1 (SPEC §3.1 column rule).
    fn advanceLine(self: *BlockPhase, n: usize) void {
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const c = self.line[i];
            if (c == '\t') {
                self.col += tabWidthAt(self.col);
            } else if ((c & 0xC0) == 0x80) {
                // UTF-8 continuation byte: no column of its own.
            } else {
                self.col += 1;
            }
        }
        self.line = self.line[n..];
        self.line_byte_start += n;
    }

    fn openMdxFlowExpression(self: *BlockPhase, end: ?usize, depth: usize) ParseError!bool {
        if (end) |e| {
            try self.appendMdxFlowExpression(
                self.line[1 .. e - 1],
                self.line[0..e],
                self.spanOffsets(self.line_no, self.line_byte_start, self.line_no, self.line_byte_start + e),
            );
            return true;
        }

        var content: std.ArrayList(u8) = .empty;
        try content.appendSlice(self.arena, self.line);
        try content.append(self.arena, '\n');

        const node = try self.arena.create(Node);
        node.* = .{ .data = .{ .mdx_flow_expression = .{ .value = "", .raw = "" } } };
        self.currentParent().appendChild(node);

        try self.pushFrameAt(node, .mdx_flow_expression, .{ .mdx_flow_expression = .{ .depth = depth, .content = content } }, self.line_byte_start);
        return true;
    }

    fn continueMdxFlowExpression(self: *BlockPhase) ParseError!bool {
        const idx = self.stack.items.len - 1;
        const state = &self.stack.items[idx].state.mdx_flow_expression;

        const closed_at = advanceBraceDepth(self.line, &state.depth);

        const consume = closed_at orelse self.line.len;
        try state.content.appendSlice(self.arena, self.line[0..consume]);
        if (closed_at == null) {
            try state.content.append(self.arena, '\n');
            return true;
        }

        const rest = self.line[consume..];
        self.stack.items[idx].end_line = self.line_no;
        try self.finalizeTop();
        if (isBlank(rest)) return true;

        self.advanceLine(consume);
        self.blank = false;
        return false;
    }

    // ── MDX JSX flow element (SPEC §14.4, §14.5) ────────────────────

    /// Consumes a line made only of JSX tags and expressions — the shape
    /// §14.2 accepts as flow. `self.line` starts at the first `<`.
    /// Returns true when the whole line is gone.
    fn consumeMdxJsxChain(self: *BlockPhase) ParseError!bool {
        while (true) {
            var ws: usize = 0;
            while (ws < self.line.len and chars.isLineWs(self.line[ws])) ws += 1;
            if (ws > 0) self.advanceLine(ws);
            if (self.line.len == 0) return true;

            if (self.line[0] == '{') {
                const expr = (mdx_scan.scanExpression(self.line, 0) catch
                    return error.UnclosedMdxExpression) orelse return error.InvalidMdxJsx;
                try self.appendMdxFlowExpression(
                    expr.value,
                    expr.raw,
                    self.spanOffsets(self.line_no, self.line_byte_start, self.line_no, self.line_byte_start + expr.end_pos),
                );
                self.advanceLine(expr.end_pos);
                continue;
            }

            // mdxFlowKind already walked this chain, so a tag scan here can
            // only fail on allocation.
            const tag = (mdx_scan.scanTag(self.arena, self.line, 0) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.InvalidMdxJsx,
            }) orelse return error.InvalidMdxJsx;

            switch (tag.kind) {
                .closing => {
                    if (!try self.closeMdxJsxFrame(tag.name, tag.end_pos)) return error.InvalidMdxJsx;
                    self.advanceLine(tag.end_pos);
                },
                .self_closing => {
                    _ = try self.appendMdxFlowElement(
                        tag,
                        true,
                        self.spanOffsets(self.line_no, self.line_byte_start, self.line_no, self.line_byte_start + tag.end_pos),
                    );
                    self.advanceLine(tag.end_pos);
                },
                .opening => {
                    try self.openMdxJsxContainer(tag, self.line_no, self.line_byte_start);
                    self.advanceLine(tag.end_pos);
                },
            }
        }
    }

    /// Creates an `mdx_flow_expression` node with arena-owned copies of
    /// `value` and `raw`, attaches it to the current parent, and stamps its
    /// position. The single assembly point for one-line flow expressions
    /// (SPEC §14.2).
    fn appendMdxFlowExpression(self: *BlockPhase, value: []const u8, raw: []const u8, position: Position) ParseError!void {
        const node = try self.arena.create(Node);
        node.* = .{ .data = .{ .mdx_flow_expression = .{
            .value = try self.arena.dupe(u8, value),
            .raw = try self.arena.dupe(u8, raw),
        } } };
        node.position = position;
        self.currentParent().appendChild(node);
    }

    /// Creates an `mdx_jsx_flow_element` node from a scanned tag, attaches it
    /// to the current parent, and stamps its position. Returns the node so a
    /// container frame can be pushed onto it. `self_closing` is passed
    /// explicitly because the node flag outlives the tag scan (SPEC §14.4).
    fn appendMdxFlowElement(self: *BlockPhase, tag: mdx_scan.TagScan, self_closing: bool, position: Position) ParseError!*Node {
        const node = try self.arena.create(Node);
        node.* = .{ .data = .{ .mdx_jsx_flow_element = .{
            .name = if (tag.name) |n| try self.arena.dupe(u8, n) else null,
            .attributes = tag.attributes,
            .self_closing = self_closing,
            .raw = try self.arena.dupe(u8, tag.raw),
        } } };
        node.position = position;
        self.currentParent().appendChild(node);
        return node;
    }

    /// Pushes a container frame for an opening tag. Children — whether they
    /// follow on this line or on later ones — are ordinary flow content.
    /// The frame's final position is stamped at finalize time; the position
    /// passed here only covers the opening tag and is overwritten then.
    fn openMdxJsxContainer(self: *BlockPhase, tag: mdx_scan.TagScan, start_line: usize, start_off: usize) ParseError!void {
        const elem_node = try self.appendMdxFlowElement(
            tag,
            false,
            self.spanOffsets(start_line, start_off, self.line_no, self.line_byte_start),
        );
        try self.pushFrame(.{
            .node = elem_node,
            .kind = .mdx_jsx_flow,
            .state = .{ .mdx_jsx_flow = .{ .name = tag.name } },
            .start_offset = start_off,
            .start_line = start_line,
            .end_line = self.line_no,
        });
    }

    /// Closes the innermost JSX flow frame when `name` is its closing tag.
    /// `tag_end` is the byte just past `>` in the current line.
    fn closeMdxJsxFrame(self: *BlockPhase, name: ?[]const u8, tag_end: usize) ParseError!bool {
        if (self.stack.items.len == 0) return false;
        const idx = self.stack.items.len - 1;
        const frame = &self.stack.items[idx];
        if (frame.kind != .mdx_jsx_flow) return false;
        if (!nameEql(name, frame.state.mdx_jsx_flow.name)) return false;

        frame.state.mdx_jsx_flow.closed = true;
        frame.end_line = self.line_no;
        // `.source` renders this, so it has to be the whole element — opening
        // tag through closing tag — not just the tag that opened it (§12.2).
        // Synthetic pad bytes (a tab straddling the container indent) are not
        // source bytes, so they come back out of the end offset, and the end
        // is clamped to the line: the update must not be silently skipped,
        // which would leave `.source` showing only the opening tag.
        const raw_end = (self.line_byte_start + tag_end) -| self.pad_prefix;
        const end = @min(raw_end, self.lineEndOff(self.line_no));
        if (frame.start_offset <= end) {
            frame.node.data.mdx_jsx_flow_element.raw = self.source[frame.start_offset..end];
        }
        try self.finalizeTop();
        return true;
    }

    /// Starts collecting an opening tag that spans several lines.
    fn openMdxJsxTagAccumulator(self: *BlockPhase, expr_pending: bool) ParseError!bool {
        var content: std.ArrayList(u8) = .empty;
        try content.appendSlice(self.arena, self.line);
        try content.append(self.arena, '\n');
        try self.pushFrameAt(self.currentParent(), .mdx_jsx_tag, .{ .mdx_jsx_tag = .{
            .content = content,
            .expr_pending = expr_pending,
        } }, self.line_byte_start);
        return true;
    }

    fn continueMdxJsxTag(self: *BlockPhase) ParseError!bool {
        const idx = self.stack.items.len - 1;
        const state = &self.stack.items[idx].state.mdx_jsx_tag;
        try state.content.appendSlice(self.arena, self.line);
        try state.content.append(self.arena, '\n');

        const buf = state.content.items;
        // Incremental scan (SPEC §16.4): only the bytes past the last
        // validated attribute boundary are scanned, and completed attributes
        // accumulate in the frame, so nothing is rescanned or re-allocated.
        const sink = mdx_scan.AttrSink{ .arena = self.arena, .list = &state.attrs };
        const tag: mdx_scan.TagScan = switch (mdx_scan.scanTagResume(buf, state.scanned, state.name, sink) catch |err| switch (err) {
            error.InvalidJsx => return error.InvalidMdxJsx,
            error.OutOfMemory => return error.OutOfMemory,
        }) {
            .not_tag => return error.InvalidMdxJsx,
            .incomplete => |r| {
                state.scanned = r.boundary;
                if (r.name != null) state.name = r.name;
                state.expr_pending = false;
                return true; // still reading
            },
            .incomplete_expr => |r| {
                state.scanned = r.boundary;
                if (r.name != null) state.name = r.name;
                state.expr_pending = true;
                return true;
            },
            .done => |b| .{
                .kind = b.kind,
                .name = b.name,
                .attributes = state.attrs.items,
                .raw = b.raw,
                .end_pos = b.end_pos,
            },
        };

        // The tag is complete. It can only have ended on the line just added,
        // so what follows it is the tail of `self.line` — mapping it back
        // there keeps byte offsets (and therefore positions) source-accurate.
        //
        // `buf` is NOT freed: `tag.raw` and the attribute values point into
        // it and end up on the node. It is arena memory.
        var rest = buf[tag.end_pos..];
        if (rest.len > 0 and rest[rest.len - 1] == '\n') rest = rest[0 .. rest.len - 1];
        const start_off = self.stack.items[idx].start_offset;
        const start_line = self.stack.items[idx].start_line;
        _ = self.stack.pop();
        if (rest.len <= self.line.len) self.advanceLine(self.line.len - rest.len);

        switch (tag.kind) {
            .closing => return error.InvalidMdxJsx, // unexpected closing in flow
            .self_closing => {
                _ = try self.appendMdxFlowElement(
                    tag,
                    true,
                    self.spanOffsets(start_line, start_off, self.line_no, self.line_byte_start),
                );
            },
            .opening => {
                try self.openMdxJsxContainer(tag, start_line, start_off);
                // A multi-line tag cannot withdraw its flow judgement the way
                // a single-line one does (§14.8), so children and a closing
                // tag left on this line are handled right here.
                var brace_pairs: std.AutoHashMapUnmanaged(usize, usize) = .empty;
                try mdx_scan.buildBracePairs(self.arena, self.line, &brace_pairs);
                if (mdx_scan.findMatchingClose(self.line, 0, tag.name, &brace_pairs)) |cp| {
                    const close = (mdx_scan.scanTagBounds(self.line, cp) catch null) orelse
                        return error.InvalidMdxJsx;
                    const close_len = close.end_pos - cp;
                    try self.appendMdxInlineChild(self.line[0..cp]);
                    self.advanceLine(cp);
                    _ = try self.closeMdxJsxFrame(tag.name, close_len);
                    self.advanceLine(close_len);
                }
            },
        }

        // Whatever is left on the line is content, not something to drop
        // (§17-10). A multi-line tag cannot withdraw its flow judgement the
        // way a single-line one does, so the tail becomes the next block
        // instead of joining a paragraph (§14.8).
        self.blank = isBlank(self.line);
        return self.blank;
    }

    /// Attaches same-line element content as a paragraph child.
    fn appendMdxInlineChild(self: *BlockPhase, content: []const u8) ParseError!void {
        if (isBlank(content)) return;
        const para = try self.arena.create(Node);
        para.* = .{ .data = .paragraph };
        self.currentParent().appendChild(para);
        var s: usize = 0;
        while (s < content.len and chars.isLineWs(content[s])) : (s += 1) {}
        try self.queueInline(para, content[s..], &.{});
    }

    fn continueMdxJsxFlow(self: *BlockPhase) ParseError!bool {
        const ind = chars.skipUpTo3Cols(self.line);
        if (ind >= self.line.len or self.line[ind] != '<') return false;
        const tag = (mdx_scan.scanTagBounds(self.line, ind) catch return false) orelse return false;
        // A nested element of the same name opens its own frame, so only a
        // closing tag is handled here (SPEC §14.5).
        if (tag.kind != .closing) return false;
        if (!nameEql(tag.name, self.stack.items[self.stack.items.len - 1].state.mdx_jsx_flow.name)) return false;

        self.advanceLine(ind);
        const tag_len = tag.end_pos - ind;
        _ = try self.closeMdxJsxFrame(tag.name, tag_len);
        self.advanceLine(tag_len);
        self.blank = isBlank(self.line);
        return self.blank;
    }

    // ── Frontmatter (SPEC §9.3) ──────────────────────────────────────

    /// Tries to consume a frontmatter block from the start of the document.
    /// If the first line is a valid opening fence (`---`/`+++`), scans for the
    /// matching closing fence. On success, creates a `yaml`/`toml` node as the
    /// first child of root and leaves the iterator past the closing fence.
    /// On failure (no opening fence, or no closing fence before EOF), restores
    /// the iterator so normal block parsing handles every line.
    fn consumeFrontmatter(self: *BlockPhase, iter: *LineIterator) ParseError!void {
        const saved_pos = iter.pos;

        const first = iter.next() orelse {
            iter.pos = saved_pos;
            return;
        };
        const fence = frontmatter.openingFence(first.text) orelse {
            iter.pos = saved_pos;
            return;
        };

        var content: std.ArrayList(u8) = .empty;
        var found_close = false;
        var close_line: usize = 2; // opening is line 1, first content/closing is line 2
        while (iter.next()) |line| {
            if (frontmatter.closingFence(line.text, fence)) {
                found_close = true;
                break;
            }
            if (content.items.len > 0) try content.append(self.arena, '\n');
            try content.appendSlice(self.arena, line.text);
            close_line += 1;
        }

        if (!found_close) {
            content.deinit(self.arena);
            iter.pos = saved_pos;
            return;
        }

        const node = try self.arena.create(Node);
        node.* = switch (fence) {
            .yaml => .{ .data = .{ .yaml = try self.arena.dupe(u8, content.items) } },
            .toml => .{ .data = .{ .toml = try self.arena.dupe(u8, content.items) } },
        };
        self.root.appendChild(node);
        node.position = self.spanPosition(1, 0, close_line);
        content.deinit(self.arena);
        // The main loop numbers lines by counting; the frontmatter lines it
        // never sees must still be counted or every position after this block
        // reports a line number shifted up by the frontmatter's height.
        self.line_no = close_line;
    }

    fn openParagraph(self: *BlockPhase) ParseError!void {
        const para = try self.arena.create(Node);
        para.* = .{ .data = .paragraph };
        self.currentParent().appendChild(para);

        try self.pushFrameAt(para, .paragraph, .{ .paragraph = .{ .text = .empty } }, self.contentStart());
        try self.appendParagraphLine();
    }

    fn finalizeTop(self: *BlockPhase) ParseError!void {
        var frame = &self.stack.items[self.stack.items.len - 1];
        const start_off = frame.start_offset;
        const start_ln = frame.start_line;
        const end_ln = frame.end_line;
        switch (frame.kind) {
            .paragraph => {
                var buf = &frame.state.paragraph.text;
                while (buf.items.len > 0 and (buf.items[buf.items.len - 1] == ' ' or buf.items[buf.items.len - 1] == '\t')) {
                    _ = buf.pop();
                }
                const attach_parent = frame.node.parent orelse self.root;
                try reference.extractFromParagraph(
                    self.arena,
                    &self.definitions,
                    attach_parent,
                    frame.node,
                    buf,
                );
                if (buf.items.len > 0) {
                    const anchors = frame.state.paragraph.anchors.toOwnedSlice(self.arena) catch return error.OutOfMemory;
                    const text = buf.toOwnedSlice(self.arena) catch return error.OutOfMemory;
                    try self.queueInline(frame.node, text, anchors);
                } else {
                    buf.deinit(self.arena);
                }
                frame.state.paragraph.anchors.deinit(self.arena);
            },
            .fenced_code => try self.finishCode(frame.node, &frame.state.fenced_code.content, false),
            .indented_code => try self.finishCode(frame.node, &frame.state.indented_code.content, true),
            .math_block => try self.finishMath(frame.node, &frame.state.math_block.content),
            .html_block => {
                var buf = &frame.state.html_block.content;
                if (self.options.gfm) {
                    frame.node.data = .{ .html = try filterDisallowedHtml(self.arena, buf.items) };
                } else {
                    frame.node.data = .{ .html = try self.arena.dupe(u8, buf.items) };
                }
                buf.deinit(self.arena);
            },
            .mdx_flow_expression => {
                var buf = &frame.state.mdx_flow_expression.content;
                if (frame.state.mdx_flow_expression.depth != 0) return error.UnclosedMdxExpression;
                const raw = try self.arena.dupe(u8, buf.items);
                frame.node.data = .{ .mdx_flow_expression = .{
                    .value = raw[1 .. raw.len - 1],
                    .raw = raw,
                } };
                buf.deinit(self.arena);
            },
            // The document ended inside an opening tag. Which error depends on
            // what the tag was still waiting for (SPEC §14.6).
            .mdx_jsx_tag => return if (frame.state.mdx_jsx_tag.expr_pending)
                error.UnclosedMdxExpression
            else
                error.InvalidMdxJsx,
            .list => frame.node.data.list.spread = self.listIsLoose(frame.node),
            .table => try self.finalizeTable(frame),
            .mdx_jsx_flow => {
                if (!frame.state.mdx_jsx_flow.closed) return error.InvalidMdxJsx;
            },
            else => {},
        }
        frame.node.position = self.spanPosition(start_ln, start_off, end_ln);
        _ = self.stack.pop();
    }

    /// Hands a finished inline leaf to the inline phase, which runs after the
    /// whole block phase. `text` must be arena memory (the source copy, a
    /// padWith buffer, or an owned slice) — it is stored, not copied.
    fn queueInline(self: *BlockPhase, node: *Node, text: []const u8, anchors: []const LineAnchor) ParseError!void {
        try self.pending_inline.append(self.arena, .{
            .node = node,
            .text = text,
            .anchors = anchors,
        });
    }

    /// Appends the current line to the open paragraph's raw-text buffer.
    /// CommonMark forms paragraph content by stripping each line's leading
    /// whitespace, so indentation never reaches the inline phase.
    fn appendParagraphLine(self: *BlockPhase) ParseError!void {
        var i: usize = 0;
        while (i < self.line.len and chars.isLineWs(self.line[i])) : (i += 1) {}
        var buf = &self.stack.items[self.stack.items.len - 1].state.paragraph.text;
        const anchors = &self.stack.items[self.stack.items.len - 1].state.paragraph.anchors;
        if (buf.items.len > 0) try buf.append(self.arena, '\n');
        // Record source mapping anchor for this line (SPEC §7.2).
        try anchors.append(self.arena, .{
            .text_offset = buf.items.len,
            .source_line = self.line_no,
            .line_start_offset = self.lineStartOff(self.line_no),
            .content_start_offset = self.line_byte_start + i,
        });
        try buf.appendSlice(self.arena, self.line[i..]);
    }

    /// Moves an accumulated code buffer into `node`. Every appended line already
    /// carries its newline. `trim_blanks` drops trailing blank lines, which are
    /// not part of an indented code block — a fenced block keeps them.
    fn finishCode(self: *BlockPhase, node: *Node, buf: *std.ArrayList(u8), trim_blanks: bool) ParseError!void {
        if (trim_blanks) {
            var end = buf.items.len;
            while (end > 0) {
                var start = end - 1; // the line's own newline
                while (start > 0 and buf.items[start - 1] != '\n') start -= 1;
                if (!isBlank(buf.items[start .. end - 1])) break;
                end = start;
            }
            buf.shrinkRetainingCapacity(end);
        }
        node.data.code.value = try self.arena.dupe(u8, buf.items);
        buf.deinit(self.arena);
    }

    // ─── GFM table support ──────────────────────────────────────────

    /// Converts the open paragraph into a table when the current line is a
    /// valid delimiter row and the paragraph text is a valid header row.
    fn tryTableFromParagraph(self: *BlockPhase) ParseError!bool {
        // Like any block construct, the delimiter row must start within 0–3
        // columns; a line indented 4+ is a lazy paragraph continuation.
        if (self.countLeadingCols() >= 4) return false;

        const para_frame = &self.stack.items[self.stack.items.len - 1];
        const para_text = para_frame.state.paragraph.text.items;

        // Table header must be a single line.
        if (std.mem.indexOfScalar(u8, para_text, '\n') != null) return false;

        const aligns = (try parseDelimiterRow(self.arena, self.line)) orelse return false;
        const header_cells = try splitTableRow(self.arena, para_text);
        if (header_cells.len == 0 or aligns.len != header_cells.len) return false;

        para_frame.state.paragraph.text.deinit(self.arena);
        para_frame.node.data = .{ .table = .{ .align_ = aligns } };
        para_frame.kind = .table;
        para_frame.state = .{ .table = .{
            .align_ = aligns,
            .header_cells = header_cells,
            .data_lines = .empty,
        } };
        return true;
    }

    fn continueTable(self: *BlockPhase) ParseError!bool {
        if (self.blank) {
            try self.finalizeTop();
            return false;
        }
        // Container interrupts (blockquote, list) were handled earlier; this
        // only checks leaf-block interrupts.
        const html_or_mdx = if (self.options.mdx)
            try self.mdxFlowInterrupts()
        else
            htmlBlockInterruptType(self.line) != null;
        if (atxInfo(self.line) != null or
            isFencedCodeOpening(self.line) != null or
            html_or_mdx or
            isThematicBreak(self.line))
        {
            try self.finalizeTop();
            return false;
        }
        const line_copy = try self.arena.dupe(u8, self.line);
        try self.stack.items[self.stack.items.len - 1].state.table.data_lines.append(
            self.arena,
            line_copy,
        );
        return true;
    }

    fn finalizeTable(self: *BlockPhase, frame: *Frame) ParseError!void {
        const ts = &frame.state.table;
        const table_node = frame.node;
        const n_cols = ts.header_cells.len;

        const header_row = try self.arena.create(Node);
        header_row.* = .{ .data = .table_row };
        table_node.appendChild(header_row);
        for (ts.header_cells) |cell_text| {
            const cell = try self.arena.create(Node);
            cell.* = .{ .data = .table_cell };
            header_row.appendChild(cell);
            if (cell_text.len > 0) try self.queueInline(cell, cell_text, &.{});
        }

        for (ts.data_lines.items) |row_line| {
            const row_cells = try splitTableRow(self.arena, row_line);
            const row = try self.arena.create(Node);
            row.* = .{ .data = .table_row };
            table_node.appendChild(row);

            var col: usize = 0;
            while (col < n_cols) : (col += 1) {
                const cell_text: []const u8 = if (col < row_cells.len) row_cells[col] else "";
                const cell = try self.arena.create(Node);
                cell.* = .{ .data = .table_cell };
                row.appendChild(cell);
                if (cell_text.len > 0) try self.queueInline(cell, cell_text, &.{});
            }
        }

        ts.data_lines.deinit(self.arena);
    }
};

test "line scanner handles LF/CRLF/CR and tab column" {
    const src = "a\r\nb\rc\n\td";
    var lines = lineIterator(src);
    try std.testing.expectEqualStrings("a", lines.next().?.text);
    try std.testing.expectEqualStrings("b", lines.next().?.text);
    try std.testing.expectEqualStrings("c", lines.next().?.text);
    const last = lines.next().?;
    try std.testing.expectEqualStrings("\td", last.text);
    try std.testing.expect(lines.next() == null);
}
