const std = @import("std");
const Allocator = std.mem.Allocator;
const node_mod = @import("../node.zig");
const Node = node_mod.Node;
const ParseError = @import("../root.zig").ParseError;
const ParseOptions = @import("../options.zig").ParseOptions;
const delimiter = @import("delimiter.zig");
const bracket = @import("bracket.zig");
const reference = @import("../reference.zig");
const chars = @import("../chars.zig");
const escape = @import("../escape.zig");
const mdx = @import("../mdx/scan.zig");
const Point = @import("../point.zig").Point;
const Position = @import("../point.zig").Position;
const LineAnchor = @import("../block/phase.zig").LineAnchor;
const BlockPhase = @import("../block/phase.zig").BlockPhase;

const BracketOpen = struct {
    open_pos: usize,
    node: *Node,
    is_image: bool,
    active: bool = true,
    delimiter_bottom: ?*delimiter.Delimiter,
};

pub const InlinePhase = struct {
    arena: Allocator,
    text: []const u8,
    pos: usize,
    parent: *Node,
    options: *const ParseOptions,
    definitions: *const reference.DefinitionsMap,
    footnote_definitions: *const reference.DefinitionsMap,
    delimiters: delimiter.DelimiterStack = .{},
    brackets: std.ArrayList(BracketOpen) = .empty,
    dest_memo: bracket.DestMemo = .{},
    backtick_runs: std.AutoHashMapUnmanaged(usize, usize) = .empty,
    backtick_runs_built: bool = false,
    /// `{` position → matching `}` position, built lazily from the shared
    /// `mdx.buildBracePairs` pass. The JSX child-boundary search consults it
    /// instead of rescanning from every unmatched `{`, which is quadratic
    /// (SPEC §16.4).
    brace_match: std.AutoHashMapUnmanaged(usize, usize) = .empty,
    brace_match_built: bool = false,
    depth: usize = 0,

    // Source position tracking (SPEC §7.2)
    anchors: []const LineAnchor = &.{},
    bp: ?*const BlockPhase = null,
    /// Offset of `text` inside the text the anchors were built for. Non-zero
    /// only for a nested phase — a JSX text element's children (§14.5.1) —
    /// which parses a slice of its parent's text.
    text_base: usize = 0,
    flush_start: usize = 0,
    // Cache to avoid O(n²) code point counting within a single line
    pt_cache_line: usize = 0,
    pt_cache_copy_off: usize = 0,
    pt_cache_col: usize = 0,

    pub fn init(
        arena: Allocator,
        text: []const u8,
        parent: *Node,
        options: *const ParseOptions,
        definitions: *const reference.DefinitionsMap,
        footnote_definitions: *const reference.DefinitionsMap,
        anchors: []const LineAnchor,
        bp: ?*const BlockPhase,
    ) InlinePhase {
        return .{
            .arena = arena,
            .text = text,
            .pos = 0,
            .parent = parent,
            .options = options,
            .definitions = definitions,
            .footnote_definitions = footnote_definitions,
            .anchors = anchors,
            .bp = bp,
        };
    }

    // ── Position helpers (SPEC §7.2) ─────────────────────────────────

    fn pointAt(self: *InlinePhase, local_offset: usize) ?Point {
        if (self.anchors.len == 0 or self.bp == null) return null;
        const bp = self.bp.?;
        const text_offset = local_offset + self.text_base;
        var lo: usize = 0;
        var hi: usize = self.anchors.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.anchors[mid].text_offset <= text_offset) lo = mid + 1 else hi = mid;
        }
        const idx = if (lo > 0) lo - 1 else 0;
        const anchor = self.anchors[idx];
        const within = text_offset - anchor.text_offset;
        const copy_off = anchor.content_start_offset + within;

        var col: usize = 0;
        var i: usize = 0;
        if (self.pt_cache_line == anchor.source_line and copy_off >= self.pt_cache_copy_off) {
            col = self.pt_cache_col;
            i = self.pt_cache_copy_off;
        } else {
            i = anchor.line_start_offset;
        }
        const source = bp.source;
        while (i < copy_off and i < source.len) {
            const len = std.unicode.utf8ByteSequenceLength(source[i]) catch 1;
            i += len;
            col += 1;
        }
        self.pt_cache_line = anchor.source_line;
        self.pt_cache_copy_off = copy_off;
        self.pt_cache_col = col;

        return .{
            .line = anchor.source_line,
            .column = col + 1,
            .offset = bp.copyToOriginalOffset(copy_off),
        };
    }

    fn rangePos(self: *InlinePhase, start_off: usize, end_off: usize) ?Position {
        const s = self.pointAt(start_off) orelse return null;
        const e = self.pointAt(end_off) orelse return null;
        return .{ .start = s, .end = e };
    }

    /// Runs the inline phase over `text`, appending inline child nodes to
    /// `parent`.
    pub fn run(self: *InlinePhase) ParseError!void {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.arena);
        defer self.brackets.deinit(self.arena);
        defer self.backtick_runs.deinit(self.arena);
        defer self.brace_match.deinit(self.arena);

        while (self.pos < self.text.len) {
            const c = self.text[self.pos];
            switch (c) {
                '`' => {
                    const bt_start = self.pos;
                    if (try self.scanCodeSpan()) |code| {
                        try self.flushTextEnd(&buf, bt_start);
                        const node = try self.arena.create(Node);
                        node.* = .{ .data = .{ .inline_code = try codeSpanValue(self.arena, code) } };
                        node.position = self.rangePos(bt_start, self.pos);
                        self.parent.appendChild(node);
                        continue;
                    }
                    // No matching close run: the whole opening backtick run is literal.
                    var tick_count: usize = 0;
                    while (self.pos + tick_count < self.text.len and self.text[self.pos + tick_count] == '`') : (tick_count += 1) {}
                    try buf.appendSlice(self.arena, self.text[self.pos .. self.pos + tick_count]);
                    self.pos += tick_count;
                },
                '*', '_', '~' => {
                    if (c == '~' and !self.options.gfm) {
                        try buf.append(self.arena, '~');
                        self.pos += 1;
                        continue;
                    }
                    const ri = delimiter.analyzeRun(self.text, self.pos) orelse {
                        try buf.append(self.arena, c);
                        self.pos += 1;
                        continue;
                    };
                    try self.flushText(&buf);
                    const run_text = try self.arena.dupe(u8, self.text[self.pos..ri.run_end]);
                    const text_node = try self.arena.create(Node);
                    text_node.* = .{ .data = .{ .text = run_text } };
                    self.parent.appendChild(text_node);
                    _ = try self.delimiters.append(self.arena, .{
                        .char = ri.char,
                        .count = ri.count,
                        .orig_count = ri.count,
                        .node = text_node,
                        .can_open = ri.can_open,
                        .can_close = ri.can_close,
                        .prev = null,
                        .next = null,
                    });
                    self.pos = ri.run_end;
                    self.flush_start = self.pos;
                },
                '!' => {
                    if (self.pos + 1 < self.text.len and self.text[self.pos + 1] == '[') {
                        try self.flushText(&buf);
                        const bnode = try self.arena.create(Node);
                        bnode.* = .{ .data = .{ .text = "![" } };
                        self.parent.appendChild(bnode);
                        try self.brackets.append(self.arena, .{
                            .open_pos = self.pos + 1,
                            .node = bnode,
                            .is_image = true,
                            .delimiter_bottom = self.delimiters.tail,
                        });
                        self.pos += 2;
                        self.flush_start = self.pos;
                        continue;
                    }
                    try buf.append(self.arena, '!');
                    self.pos += 1;
                },
                '[' => {
                    try self.flushText(&buf);
                    const bnode = try self.arena.create(Node);
                    bnode.* = .{ .data = .{ .text = "[" } };
                    self.parent.appendChild(bnode);
                    try self.brackets.append(self.arena, .{
                        .open_pos = self.pos,
                        .node = bnode,
                        .is_image = false,
                        .delimiter_bottom = self.delimiters.tail,
                    });
                    self.pos += 1;
                    self.flush_start = self.pos;
                },
                ']' => {
                    try self.flushText(&buf);
                    if (self.brackets.items.len > 0) {
                        if (try self.tryCloseBracket()) {
                            self.flush_start = self.pos;
                            continue;
                        }
                    }
                    try buf.append(self.arena, ']');
                    self.pos += 1;
                },
                '\\' => {
                    if (self.pos + 1 < self.text.len) {
                        const next = self.text[self.pos + 1];
                        if (chars.isAsciiPunct(next)) {
                            try buf.append(self.arena, next);
                            self.pos += 2;
                            continue;
                        }
                        if (next == '\n') {
                            const br_start = self.pos;
                            try self.flushText(&buf);
                            const br = try self.arena.create(Node);
                            br.* = .{ .data = .break_ };
                            br.position = self.rangePos(br_start, self.pos + 2);
                            self.parent.appendChild(br);
                            self.pos += 2;
                            self.flush_start = self.pos;
                            continue;
                        }
                    }
                    try buf.append(self.arena, '\\');
                    self.pos += 1;
                },
                '&' => {
                    if (try escape.decodeEntityAt(self.arena, &buf, self.text[self.pos..])) |consumed| {
                        self.pos += consumed;
                        continue;
                    }
                    try buf.append(self.arena, '&');
                    self.pos += 1;
                },
                '<' => {
                    const lt_start = self.pos;
                    if (self.scanAutolink()) |r| {
                        try self.flushText(&buf);
                        const link_node = try self.arena.create(Node);
                        link_node.* = .{ .data = .{ .link = .{ .url = r.url } } };
                        const text_node = try self.arena.create(Node);
                        text_node.* = .{ .data = .{ .text = r.text } };
                        link_node.appendChild(text_node);
                        link_node.position = self.rangePos(lt_start, r.new_pos);
                        self.parent.appendChild(link_node);
                        self.pos = r.new_pos;
                        self.flush_start = self.pos;
                        continue;
                    }
                    if (self.options.mdx) {
                        if (try self.tryMdxJsxText(&buf)) {
                            self.flush_start = self.pos;
                            continue;
                        }
                    } else {
                        if (self.scanRawHtml()) |r| {
                            try self.flushText(&buf);
                            const node = try self.arena.create(Node);
                            node.* = .{ .data = .{ .html = r.raw } };
                            node.position = self.rangePos(lt_start, r.new_pos);
                            self.parent.appendChild(node);
                            self.pos = r.new_pos;
                            self.flush_start = self.pos;
                            continue;
                        }
                    }
                    try buf.append(self.arena, '<');
                    self.pos += 1;
                },
                '{' => {
                    if (self.options.mdx) {
                        const brace_start = self.pos;
                        const expr = (mdx.scanExpression(self.text, self.pos) catch {
                            return error.UnclosedMdxExpression;
                        }) orelse {
                            try buf.append(self.arena, '{');
                            self.pos += 1;
                            continue;
                        };
                        try self.flushText(&buf);
                        const node = try self.arena.create(Node);
                        node.* = .{ .data = .{ .mdx_text_expression = .{
                            .value = try self.arena.dupe(u8, expr.value),
                            .raw = try self.arena.dupe(u8, expr.raw),
                        } } };
                        node.position = self.rangePos(brace_start, expr.end_pos);
                        self.parent.appendChild(node);
                        self.pos = expr.end_pos;
                        self.flush_start = self.pos;
                        continue;
                    }
                    try buf.append(self.arena, '{');
                    self.pos += 1;
                },
                '$' => {
                    if (self.options.math) {
                        const math_start = self.pos;
                        if (try self.scanInlineMath()) |content| {
                            try self.flushTextEnd(&buf, math_start);
                            const node = try self.arena.create(Node);
                            node.* = .{ .data = .{ .inline_math = try self.arena.dupe(u8, content) } };
                            node.position = self.rangePos(math_start, self.pos);
                            self.parent.appendChild(node);
                            continue;
                        }
                    }
                    try buf.append(self.arena, '$');
                    self.pos += 1;
                },
                '\n' => {
                    var spaces: usize = 0;
                    while (spaces < buf.items.len and buf.items[buf.items.len - 1 - spaces] == ' ') spaces += 1;
                    if (spaces >= 2) {
                        var i: usize = 0;
                        while (i < spaces) : (i += 1) _ = buf.pop();
                        // The break owns the trailing spaces and the newline;
                        // the flushed text ends where the spaces begin.
                        const br_start = self.pos - spaces;
                        const saved_pos = self.pos;
                        self.pos = br_start;
                        try self.flushText(&buf);
                        self.pos = saved_pos;
                        const br = try self.arena.create(Node);
                        br.* = .{ .data = .break_ };
                        br.position = self.rangePos(br_start, self.pos + 1);
                        self.parent.appendChild(br);
                        self.flush_start = self.pos + 1;
                    } else {
                        // Soft break: strip trailing spaces, render newline.
                        var i: usize = 0;
                        while (i < spaces) : (i += 1) _ = buf.pop();
                        try buf.append(self.arena, '\n');
                    }
                    self.pos += 1;
                },
                else => {
                    // cmark-gfm suppresses www/url autolinks inside any open
                    // bracket, even one that never becomes a link.
                    if (self.options.gfm and self.brackets.items.len == 0 and
                        try self.tryGfmAutolink(&buf)) continue;
                    try buf.append(self.arena, c);
                    self.pos += 1;
                },
            }
        }
        try self.flushText(&buf);
        try self.delimiters.process(self.arena, self.parent, null);
        fillContainerPositions(self.parent, 0);
        // Email autolinks are a post-pass over the finished tree, matching
        // cmark-gfm: they fire in any text outside a link — literal brackets
        // included — but never inside one. Text runs are consolidated first
        // (cmark does the same) so the email rewind sees across the seams that
        // unmatched delimiters and bracket literals leave behind. The
        // outermost phase walks the whole subtree, so nested phases (JSX text
        // children) skip this.
        if (self.options.gfm and self.depth == 0) {
            try self.consolidateText(self.parent, 0);
            try self.autolinkEmails(self.parent, 0);
        }
    }

    /// Recursively fills position on emphasis/strong/delete nodes from their
    /// children's positions (bottom-up).
    fn fillContainerPositions(node: *Node, depth: usize) void {
        if (depth > 512) return;
        var child = node.first_child;
        while (child) |c| : (child = c.next) {
            fillContainerPositions(c, depth + 1);
        }
        switch (node.data) {
            .emphasis, .strong, .delete => {
                if (node.position == null) {
                    const first = node.first_child orelse return;
                    const last = node.last_child orelse return;
                    if (first.position != null and last.position != null) {
                        node.position = .{
                            .start = first.position.?.start,
                            .end = last.position.?.end,
                        };
                    }
                }
            },
            else => {},
        }
    }

    fn tryCloseBracket(self: *InlinePhase) ParseError!bool {
        const b = self.brackets.items[self.brackets.items.len - 1];

        if (!b.active) {
            _ = self.brackets.pop();
            return false;
        }

        // A footnote reference is matched before link syntax: `[^x]` is never
        // a link label. An image opener joins in: cmark-gfm renders
        // `text![^1]` as `text!` plus a reference, so the `!` survives as
        // literal text — but only once the reference actually resolves, or
        // `![^x](/url)` would lose its image (SPEC §13.3).
        if (self.options.gfm) {
            if (bracket.tryFootnoteRef(self.text, b.open_pos)) |fscan| {
                const label = try escape.backslashes(
                    self.arena,
                    self.text[fscan.label_start..fscan.label_end],
                );
                const identifier = try reference.normalizeIdentifier(self.arena, label);
                if (self.footnote_definitions.contains(identifier)) {
                    self.delimiters.truncateAfter(b.delimiter_bottom);
                    try self.finalizeFootnoteRef(b, identifier, label, fscan.end_pos);
                    self.pos = fscan.end_pos;
                    _ = self.brackets.pop();
                    return true;
                }
            }
        }

        // Emphasis inside the brackets is resolved only once the link is
        // confirmed. Doing it eagerly would discard closers that belong to a
        // delimiter run started before the `[` (example 523).
        if (bracket.tryInlineLink(self.text, b.open_pos, &self.dest_memo)) |scan| {
            try self.delimiters.process(self.arena, self.parent, b.delimiter_bottom);
            try self.finalizeLink(b, scan.url, scan.title, scan.end_pos);
            self.delimiters.truncateAfter(b.delimiter_bottom);
            if (!b.is_image) self.deactivateNonImageOpeners();
            self.pos = scan.end_pos;
            _ = self.brackets.pop();
            return true;
        }

        if (bracket.tryReference(self.text, b.open_pos)) |rscan| {
            const identifier = try self.referenceIdentifier(rscan);
            if (self.definitions.contains(identifier)) {
                try self.delimiters.process(self.arena, self.parent, b.delimiter_bottom);
                try self.finalizeReference(b, rscan, identifier);
                self.delimiters.truncateAfter(b.delimiter_bottom);
                if (!b.is_image) self.deactivateNonImageOpeners();
                self.pos = rscan.end_pos;
                _ = self.brackets.pop();
                return true;
            }
        }

        _ = self.brackets.pop();
        return false;
    }

    fn deactivateNonImageOpeners(self: *InlinePhase) void {
        for (self.brackets.items) |*op| {
            if (!op.is_image) op.active = false;
        }
    }

    /// Lookup key for a reference: a full reference uses its own label, the
    /// other two forms use the bracket text.
    fn referenceIdentifier(self: *InlinePhase, rscan: bracket.ReferenceScan) ParseError![]const u8 {
        const label_source = if (rscan.kind == .collapsed)
            self.text[rscan.text_inner_start..rscan.text_inner_end]
        else
            self.text[rscan.label_start..rscan.label_end];
        return reference.normalizeIdentifier(self.arena, label_source);
    }

    fn finalizeReference(
        self: *InlinePhase,
        b: BracketOpen,
        rscan: bracket.ReferenceScan,
        identifier: []const u8,
    ) ParseError!void {
        const ref_type: node_mod.ReferenceType = switch (rscan.kind) {
            .full => .full,
            .collapsed => .collapsed,
            .shortcut => .shortcut,
        };
        const display_label = if (rscan.kind == .full)
            try escape.backslashes(self.arena, self.text[rscan.label_start..rscan.label_end])
        else
            "";

        const new_node = try self.arena.create(Node);
        new_node.* = .{ .data = if (b.is_image) .{ .image_reference = .{
            .identifier = identifier,
            .label = display_label,
            .reference_type = ref_type,
            .alt = "",
        } } else .{ .link_reference = .{
            .identifier = identifier,
            .label = display_label,
            .reference_type = ref_type,
        } } };

        moveBracketContent(b.node, new_node);
        const start = if (b.is_image and b.open_pos > 0) b.open_pos - 1 else b.open_pos;
        new_node.position = self.rangePos(start, rscan.end_pos);
        self.replaceOpener(b, new_node);
    }

    fn finalizeLink(self: *InlinePhase, b: BracketOpen, url: []const u8, title: ?[]const u8, end_pos: usize) ParseError!void {
        const url_dup = try escape.resolve(self.arena, url);
        const title_dup: ?[]const u8 = if (title) |t|
            try escape.resolve(self.arena, t)
        else
            null;

        const new_node = try self.arena.create(Node);

        if (b.is_image) {
            // An image keeps no children: its content collapses into `alt`.
            var alt_buf: std.ArrayList(u8) = .empty;
            var cur = b.node.next;
            while (cur) |cn| {
                const nxt = cn.next;
                try node_mod.collectAlt(&alt_buf, self.arena, cn);
                cn.unlink();
                cur = nxt;
            }
            const alt = try alt_buf.toOwnedSlice(self.arena);
            new_node.* = .{ .data = .{ .image = .{ .url = url_dup, .title = title_dup, .alt = alt } } };
        } else {
            new_node.* = .{ .data = .{ .link = .{ .url = url_dup, .title = title_dup } } };
            moveBracketContent(b.node, new_node);
        }

        self.replaceOpener(b, new_node);
        const start = if (b.is_image and b.open_pos > 0) b.open_pos - 1 else b.open_pos;
        new_node.position = self.rangePos(start, end_pos);
    }

    /// A footnote reference has no inline children: `[^a *b*]` is one identifier,
    /// not emphasis. Everything the bracket opener accumulated is discarded.
    fn finalizeFootnoteRef(
        self: *InlinePhase,
        b: BracketOpen,
        identifier: []const u8,
        label: []const u8,
        end_pos: usize,
    ) ParseError!void {
        var cur = b.node.next;
        while (cur) |cn| {
            const nxt = cn.next;
            cn.unlink();
            cur = nxt;
        }

        const new_node = try self.arena.create(Node);
        new_node.* = .{ .data = .{ .footnote_reference = .{
            .identifier = identifier,
            .label = label,
        } } };
        if (b.is_image) {
            // The opener node holds `![`. Only the `[` becomes the reference;
            // the `!` stays where it was as literal text (SPEC §13.3).
            b.node.data = .{ .text = "!" };
            b.node.position = self.rangePos(b.open_pos - 1, b.open_pos);
            const parent = b.node.parent orelse self.parent;
            parent.insertAfter(b.node, new_node);
        } else {
            self.replaceOpener(b, new_node);
        }
        new_node.position = self.rangePos(b.open_pos, end_pos);
    }

    fn replaceOpener(self: *InlinePhase, b: BracketOpen, new_node: *Node) void {
        const insert_prev = b.node.prev;
        const insert_parent = b.node.parent orelse self.parent;
        b.node.unlink();
        insert_parent.insertAfter(insert_prev, new_node);
    }

    fn flushText(self: *InlinePhase, buf: *std.ArrayList(u8)) ParseError!void {
        return self.flushTextEnd(buf, self.pos);
    }

    /// Flushes pending text with an explicit end offset — for branches that
    /// scan a construct first and only then advance `pos` past it: the text
    /// BEFORE the construct must not claim the construct's bytes (§7.2).
    /// `flush_start` still moves to `pos`: the next text run begins after the
    /// construct.
    fn flushTextEnd(self: *InlinePhase, buf: *std.ArrayList(u8), end: usize) ParseError!void {
        if (buf.items.len == 0) {
            self.flush_start = self.pos;
            return;
        }
        const text_value = try self.arena.dupe(u8, buf.items);
        const text_node = try self.arena.create(Node);
        text_node.* = .{ .data = .{ .text = text_value } };
        text_node.position = self.rangePos(self.flush_start, end);
        self.parent.appendChild(text_node);
        buf.clearRetainingCapacity();
        self.flush_start = self.pos;
    }

    /// Offset of the closing tag that ends the element opened at `start`,
    /// counting nested elements of the same name — the shared walker
    /// `mdx.findMatchingClose` is the one child-boundary judgement for both
    /// phases (SPEC §3.1). The brace-pair table comes from the shared
    /// `mdx.buildBracePairs`, built lazily and reused across nested
    /// searches; the `last_gt` guard stays local: a tag needs a `>` to
    /// complete, so with none in reach nothing can match.
    fn findChildEnd(self: *InlinePhase, start: usize, name: ?[]const u8) ParseError!?usize {
        if (!self.brace_match_built) {
            try mdx.buildBracePairs(self.arena, self.text, &self.brace_match);
            self.brace_match_built = true;
        }
        _ = std.mem.lastIndexOfScalar(u8, self.text, '>') orelse return null;
        return mdx.findMatchingClose(self.text, start, name, &self.brace_match);
    }

    /// Records the last position of every backtick run length in `text`, so an
    /// opening run with no possible partner is rejected without a forward scan.
    fn buildBacktickRuns(self: *InlinePhase) ParseError!void {
        self.backtick_runs_built = true;
        var i: usize = 0;
        while (i < self.text.len) {
            if (self.text[i] != '`') {
                i += 1;
                continue;
            }
            const run_start = i;
            while (i < self.text.len and self.text[i] == '`') : (i += 1) {}
            try self.backtick_runs.put(self.arena, i - run_start, run_start);
        }
    }

    /// Attempts to scan inline math starting at `self.pos` (pointing at `$`).
    /// On success, advances `self.pos` past the closing `$` and returns the
    /// raw content slice. On failure, leaves `self.pos` unchanged and returns
    /// null (SPEC §9.4).
    fn scanInlineMath(self: *InlinePhase) ParseError!?[]const u8 {
        const start = self.pos;

        // Opener flanking: next byte must exist, be non-ws, and not `$`.
        if (start + 1 >= self.text.len) return null;
        const next = self.text[start + 1];
        if (next == ' ' or next == '\t' or next == '\n' or next == '$') return null;

        // Opener preceding: start of text, or preceded by ws/punct.
        if (start > 0) {
            const prev = self.text[start - 1];
            if (!isMathFlank(prev)) return null;
        }

        var i = start + 2;
        while (i < self.text.len) : (i += 1) {
            if (self.text[i] != '$') continue;
            // Closer flanking: preceding byte must be non-ws and non-$.
            const before = self.text[i - 1];
            if (before == ' ' or before == '\t' or before == '\n' or before == '$') continue;
            self.pos = i + 1;
            return self.text[start + 1 .. i];
        }
        return null;
    }

    /// Attempts to scan a code span starting at `self.pos` (which must point at
    /// a backtick). On success, advances `self.pos` past the closing backticks
    /// and returns the raw content slice. On failure, leaves `self.pos`
    /// unchanged and returns null.
    fn scanCodeSpan(self: *InlinePhase) ParseError!?[]const u8 {
        const start = self.pos;
        var n: usize = 0;
        var p = start;
        while (p < self.text.len and self.text[p] == '`') : (p += 1) {
            n += 1;
        }
        std.debug.assert(n > 0);

        // A run of this length must exist *after* this one, or there is no
        // closer and scanning forward would walk to EOF for nothing. Every
        // surviving scan consumes the span it walks, keeping the total linear.
        if (!self.backtick_runs_built) try self.buildBacktickRuns();
        const last_of_len = self.backtick_runs.get(n) orelse return null;
        if (last_of_len <= start) return null;

        var search = p;
        while (search < self.text.len) {
            if (self.text[search] != '`') {
                search += 1;
                continue;
            }
            var close_n: usize = 0;
            var s = search;
            while (s < self.text.len and self.text[s] == '`') : (s += 1) {
                close_n += 1;
            }
            if (close_n == n) {
                self.pos = s;
                return self.text[p..search];
            }
            search = s;
        }
        return null;
    }

    const AutolinkResult = struct { url: []const u8, text: []const u8, new_pos: usize };

    /// Tries to parse a JSX text element at `self.pos` (pointing at `<`).
    /// In MDX mode, this replaces raw HTML (SPEC §14.1, §11).
    /// Returns true if a JSX element was parsed and node(s) created.
    fn tryMdxJsxText(self: *InlinePhase, buf: *std.ArrayList(u8)) ParseError!bool {
        const start = self.pos;
        const tag = mdx.scanTag(self.arena, self.text, self.pos) catch |err| switch (err) {
            // A `<` that cannot start a tag is literal text; a tag whose
            // grammar breaks after its name has no other reading (SPEC §14.6).
            error.InvalidJsx => return error.InvalidMdxJsx,
            // The inline phase already holds the whole leaf, so "ran out of
            // input" here means the tag really is truncated.
            error.IncompleteJsx => return false,
            error.IncompleteJsxExpression => return error.UnclosedMdxExpression,
            error.OutOfMemory => return error.OutOfMemory,
        } orelse return false;

        try self.flushText(buf);

        switch (tag.kind) {
            .self_closing => {
                const node = try self.arena.create(Node);
                node.* = .{ .data = .{ .mdx_jsx_text_element = .{
                    .name = if (tag.name) |n| try self.arena.dupe(u8, n) else null,
                    .attributes = tag.attributes,
                    .self_closing = true,
                    .raw = try self.arena.dupe(u8, tag.raw),
                } } };
                node.position = self.rangePos(start, tag.end_pos);
                self.parent.appendChild(node);
                self.pos = tag.end_pos;
                return true;
            },
            .opening => {
                const close_start = (try self.findChildEnd(tag.end_pos, tag.name)) orelse
                    return error.InvalidMdxJsx;
                const children = self.text[tag.end_pos..close_start];
                const end = closeTagEnd(self.text, close_start);

                const elem_node = try self.arena.create(Node);
                elem_node.* = .{
                    .data = .{
                        .mdx_jsx_text_element = .{
                            .name = if (tag.name) |n| try self.arena.dupe(u8, n) else null,
                            .attributes = tag.attributes,
                            .self_closing = false,
                            // The whole element, opening tag through closing tag —
                            // `.source` renders this and must not drop the children
                            // (SPEC §12.2).
                            .raw = try self.arena.dupe(u8, self.text[start..end]),
                        },
                    },
                };
                elem_node.position = self.rangePos(start, end);
                self.parent.appendChild(elem_node);

                // Children are inline content, not literal text: nested
                // elements, emphasis, expressions and character references all
                // have to be parsed (SPEC §14.5.1). A fresh phase gives them
                // their own delimiter and bracket stacks, which is exactly the
                // boundary the element represents. The anchors carry over —
                // `text_base` maps the child slice back onto them (§7.2).
                if (children.len > 0) {
                    var child = InlinePhase.init(self.arena, children, elem_node, self.options, self.definitions, self.footnote_definitions, self.anchors, self.bp);
                    child.text_base = self.text_base + tag.end_pos;
                    child.depth = self.depth + 1;
                    if (child.depth > self.options.max_nesting) return error.NestingTooDeep;
                    try child.run();
                }

                self.pos = end;
                return true;
            },
            .closing => return error.InvalidMdxJsx,
        }
    }

    /// Attempts to scan an autolink at `self.pos` (which points at `<`). On
    /// success returns the URL, display text, and the position past the closing
    /// `>`, leaving `self.pos` unchanged. On failure returns null.
    fn scanAutolink(self: *InlinePhase) ?AutolinkResult {
        const body = autolinkBody(self.text, self.pos) orelse return null;
        const content = self.text[self.pos + 1 .. body.end];

        if (body.is_email) {
            const mailto = std.fmt.allocPrint(self.arena, "mailto:{s}", .{content}) catch return null;
            return .{ .url = mailto, .text = content, .new_pos = body.end + 1 };
        }
        return .{ .url = content, .text = content, .new_pos = body.end + 1 };
    }

    const RawHtmlResult = struct { raw: []const u8, new_pos: usize };

    /// Attempts to scan raw inline HTML starting at `self.pos` (points at `<`).
    /// On success returns the raw slice and the position past it, leaving
    /// `self.pos` unchanged. On failure returns null.
    fn scanRawHtml(self: *InlinePhase) ?RawHtmlResult {
        if (self.pos >= self.text.len or self.text[self.pos] != '<') return null;
        const end = scanInlineHtmlEnd(self.text[self.pos..]) orelse return null;

        // GFM: disallowed raw HTML tag names are not recognized as raw HTML.
        if (self.options.gfm) {
            const slice = self.text[self.pos .. self.pos + end];
            if (chars.extractHtmlTagName(slice)) |tag| {
                if (chars.isDisallowedHtmlTag(tag)) return null;
            }
        }

        return .{ .raw = self.text[self.pos .. self.pos + end], .new_pos = self.pos + end };
    }

    // ---- GFM autolink literals ----

    /// www and scheme autolinks, tried inline. The boundary rules differ per
    /// trigger (cmark-gfm): `www.` needs whitespace or `*_~(` before it, while
    /// a scheme only needs a non-alphabetic character (an alphabetic one would
    /// have been part of the scheme).
    fn tryGfmAutolink(self: *InlinePhase, buf: *std.ArrayList(u8)) ParseError!bool {
        const text = self.text;
        const pos = self.pos;
        const c = text[pos];
        if (c != 'w' and c != 'h' and c != 'f') return false;

        if (pos > 0) {
            const prev = text[pos - 1];
            if (c == 'w') {
                if (!isWwwPrev(prev)) return false;
            } else if (std.ascii.isAlphabetic(prev)) return false;
        }

        const r = self.scanUrlAutolink() orelse return false;
        try self.flushText(buf);
        const link_node = try self.arena.create(Node);
        link_node.* = .{ .data = .{ .link = .{ .url = r.href } } };
        const text_node = try self.arena.create(Node);
        text_node.* = .{ .data = .{ .text = r.text } };
        link_node.appendChild(text_node);
        self.parent.appendChild(link_node);
        self.pos = r.new_pos;
        self.flush_start = self.pos;
        return true;
    }

    /// Merges runs of adjacent text siblings (cmark's consolidation).
    /// Unmatched delimiter runs and bracket literals leave one logical text
    /// split across nodes; the email rewind has to see across those seams.
    fn consolidateText(self: *InlinePhase, node: *Node, depth: usize) ParseError!void {
        if (depth > self.options.max_nesting) return;
        var child = node.first_child;
        while (child) |c| {
            if (c.data == .text) {
                if (c.next != null and c.next.?.data == .text) {
                    var buf: std.ArrayList(u8) = .empty;
                    try buf.appendSlice(self.arena, c.data.text);
                    var have_pos = c.position != null;
                    var last_pos = c.position;
                    while (c.next != null and c.next.?.data == .text) {
                        const n = c.next.?;
                        try buf.appendSlice(self.arena, n.data.text);
                        have_pos = have_pos and n.position != null;
                        last_pos = n.position;
                        n.unlink();
                    }
                    c.data = .{ .text = try buf.toOwnedSlice(self.arena) };
                    c.position = if (have_pos)
                        .{ .start = c.position.?.start, .end = last_pos.?.end }
                    else
                        null;
                }
            } else {
                try self.consolidateText(c, depth + 1);
            }
            child = c.next;
        }
    }

    /// Walks the finished tree inserting email autolinks into text nodes,
    /// skipping link subtrees (cmark-gfm's postprocess).
    fn autolinkEmails(self: *InlinePhase, node: *Node, depth: usize) ParseError!void {
        if (depth > self.options.max_nesting) return;
        var child = node.first_child;
        while (child) |c| {
            const next = c.next;
            switch (c.data) {
                .link => {}, // no autolinks inside links
                .text => |t| try self.autolinkEmailText(c, t),
                else => try self.autolinkEmails(c, depth + 1),
            }
            child = next;
        }
    }

    /// Splits `node` around every email found in its value. New nodes carry no
    /// position: the value may differ from the source bytes (entities,
    /// escapes), so sub-ranges cannot be mapped back reliably.
    fn autolinkEmailText(self: *InlinePhase, node: *Node, value: []const u8) ParseError!void {
        const parent = node.parent orelse return;
        var insert_after: ?*Node = node.prev;
        var seg_start: usize = 0;
        var replaced = false;

        var i: usize = 0;
        while (i < value.len) {
            if (value[i] != '@') {
                i += 1;
                continue;
            }
            const m = matchEmailAt(self.arena, value, i, seg_start) orelse {
                i += 1;
                continue;
            };
            if (m.start > seg_start) {
                const tn = try self.arena.create(Node);
                tn.* = .{ .data = .{ .text = value[seg_start..m.start] } };
                parent.insertAfter(insert_after, tn);
                insert_after = tn;
            }
            const link_node = try self.arena.create(Node);
            link_node.* = .{ .data = .{ .link = .{ .url = m.href } } };
            const tn = try self.arena.create(Node);
            tn.* = .{ .data = .{ .text = m.text } };
            link_node.appendChild(tn);
            parent.insertAfter(insert_after, link_node);
            insert_after = link_node;
            seg_start = m.end;
            i = m.end;
            replaced = true;
        }

        if (!replaced) return;
        if (seg_start < value.len) {
            node.data = .{ .text = value[seg_start..] };
            node.position = null;
        } else {
            node.unlink();
        }
    }

    const GfmAutolinkResult = struct { href: []const u8, text: []const u8, new_pos: usize };

    fn scanUrlAutolink(self: *InlinePhase) ?GfmAutolinkResult {
        const text = self.text;
        const pos = self.pos;

        var scheme_len: usize = 0;
        var is_www = false;
        if (matchesAt(text, pos, "www.")) {
            scheme_len = 4;
            is_www = true;
        } else if (matchesAt(text, pos, "http://")) {
            scheme_len = 7;
        } else if (matchesAt(text, pos, "https://")) {
            scheme_len = 8;
        } else if (matchesAt(text, pos, "ftp://")) {
            scheme_len = 6;
        } else return null;

        var dpos = pos + scheme_len;
        var has_dot = false;
        while (dpos < text.len) : (dpos += 1) {
            const dc = text[dpos];
            if (std.ascii.isAlphanumeric(dc) or dc == '-' or dc == '_') continue;
            if (dc == '.') {
                has_dot = true;
                continue;
            }
            break;
        }
        if (!has_dot) return null;
        while (dpos > pos + scheme_len and (text[dpos - 1] == '-' or text[dpos - 1] == '_' or text[dpos - 1] == '.')) dpos -= 1;
        if (dpos == pos + scheme_len) return null;

        while (dpos < text.len) {
            const pc = text[dpos];
            if (pc == ' ' or pc == '\t' or pc == '\n' or pc == '\r' or pc == '\x0c' or pc == '<') break;
            if (pc == '&' and looksLikeEntityRef(text, dpos)) break;
            dpos += 1;
        }

        dpos = trimTrailingPunct(text, pos, dpos);

        const url_text = text[pos..dpos];
        const href = if (is_www)
            std.fmt.allocPrint(self.arena, "http://{s}", .{url_text}) catch return null
        else
            url_text;

        return .{ .href = href, .text = url_text, .new_pos = dpos };
    }

};

const EmailMatch = struct { start: usize, href: []const u8, text: []const u8, end: usize };

/// Matches an email whose `@` sits at `at` in `value`. The local part is found
/// by rewinding, cmark-gfm style, but never past `floor` (content already
/// consumed by an earlier match).
fn matchEmailAt(arena: Allocator, value: []const u8, at: usize, floor: usize) ?EmailMatch {
    var start = at;
    while (start > floor) {
        const pc = value[start - 1];
        if (std.ascii.isAlphanumeric(pc) or pc == '.' or pc == '+' or pc == '-' or pc == '_') {
            start -= 1;
        } else break;
    }
    if (start == at) return null; // empty local part

    var pos = at + 1;
    var has_dot = false;
    while (pos < value.len) : (pos += 1) {
        const dc = value[pos];
        if (std.ascii.isAlphanumeric(dc) or dc == '-') continue;
        if (dc == '.') {
            has_dot = true;
            continue;
        }
        break;
    }
    if (!has_dot) return null;
    while (pos > at + 1 and value[pos - 1] == '.') pos -= 1;
    if (pos == at + 1) return null;
    if (value[pos - 1] == '-') return null;

    if (pos < value.len) {
        const nc = value[pos];
        if (std.ascii.isAlphanumeric(nc) or nc == '_') return null;
    }

    const email = value[start..pos];
    const href = std.fmt.allocPrint(arena, "mailto:{s}", .{email}) catch return null;
    return .{ .start = start, .href = href, .text = email, .end = pos };
}

// ---- GFM autolink literal helpers ----

/// Whether `c` may precede a `$` inline-math opener: whitespace or ASCII
/// punctuation (SPEC §9.4).
fn isMathFlank(c: u8) bool {
    if (c == ' ' or c == '\t' or c == '\n') return true;
    return chars.isAsciiPunct(c);
}

/// Characters cmark-gfm accepts before a `www.` autolink: whitespace or one
/// of `*_~(`. Anything else — letters, digits, dots, brackets — suppresses it.
fn isWwwPrev(c: u8) bool {
    return switch (c) {
        ' ', '\t', '\n', '\r', 0x0b, '\x0c', '*', '_', '~', '(' => true,
        else => false,
    };
}

fn matchesAt(text: []const u8, pos: usize, prefix: []const u8) bool {
    if (pos + prefix.len > text.len) return false;
    return std.mem.eql(u8, text[pos .. pos + prefix.len], prefix);
}

fn looksLikeEntityRef(text: []const u8, pos: usize) bool {
    var i = pos + 1;
    if (i >= text.len) return false;
    if (text[i] == '#') {
        i += 1;
        if (i < text.len and (text[i] == 'x' or text[i] == 'X')) i += 1;
        var digits: usize = 0;
        while (i < text.len and std.ascii.isAlphanumeric(text[i])) : (i += 1) digits += 1;
        return digits > 0 and i < text.len and text[i] == ';';
    }
    var name_len: usize = 0;
    while (i < text.len and std.ascii.isAlphanumeric(text[i])) : (i += 1) name_len += 1;
    return name_len > 0 and i < text.len and text[i] == ';';
}

fn trimTrailingPunct(text: []const u8, start: usize, initial_end: usize) usize {
    // Parens are counted once and kept in step as the tail is peeled. Counting
    // the whole range again for every `)` removed is quadratic (SPEC §16.4).
    var opens: usize = 0;
    var closes: usize = 0;
    for (text[start..initial_end]) |c| {
        if (c == '(') opens += 1;
        if (c == ')') closes += 1;
    }

    var end = initial_end;
    while (end > start) {
        const c = text[end - 1];
        if (c == '.' or c == ',' or c == '?' or c == '!' or c == ':' or
            c == ';' or c == '"' or c == '\'' or c == '*' or c == '_' or c == '~')
        {
            end -= 1;
        } else if (c == ')') {
            if (closes <= opens) break;
            closes -= 1;
            end -= 1;
        } else break;
    }
    return end;
}

fn closeTagEnd(text: []const u8, close_start: usize) usize {
    const tag = (mdx.scanTagBounds(text, close_start) catch null) orelse return text.len;
    return tag.end_pos;
}

/// Moves every sibling after `opener` (the literal `[`/`![` text node) into
/// `new_node`, in order.
fn moveBracketContent(opener: *Node, new_node: *Node) void {
    var cur = opener.next;
    while (cur) |cn| {
        const nxt = cn.next;
        cn.unlink();
        new_node.appendChild(cn);
        cur = nxt;
    }
}

/// The `>` position of the autolink starting at `text[pos]` (which must be
/// `<`), or null when there is no autolink there.
///
/// Kept as a free function because the block phase needs the same judgement:
/// in MDX mode a `<` is only JSX once autolink has been ruled out, in flow
/// exactly as in text (SPEC §14.1).
pub fn autolinkBody(text: []const u8, pos: usize) ?struct { end: usize, is_email: bool } {
    if (pos >= text.len or text[pos] != '<') return null;

    // Body: anything except `<`, `>`, or ASCII whitespace.
    var end = pos + 1;
    while (end < text.len) : (end += 1) {
        const c = text[end];
        if (c == '>') break;
        if (c == '<' or chars.isWsByte(c)) return null;
    }
    if (end >= text.len or text[end] != '>') return null;
    if (end == pos + 1) return null; // `<>`

    const content = text[pos + 1 .. end];

    // URI autolink: `<scheme:rest>` with a valid scheme.
    if (std.mem.indexOfScalar(u8, content, ':')) |colon_pos| {
        if (colon_pos > 0 and isValidScheme(content[0..colon_pos])) {
            return .{ .end = end, .is_email = false };
        }
    }
    if (isValidEmail(content)) return .{ .end = end, .is_email = true };
    return null;
}

/// URI scheme validation: `[a-zA-Z][a-zA-Z0-9+.-]{1,31}` (2–32 chars total).
fn isValidScheme(s: []const u8) bool {
    if (s.len < 2 or s.len > 32) return false;
    if (!std.ascii.isAlphabetic(s[0])) return false;
    for (s[1..]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '+' and c != '-' and c != '.') return false;
    }
    return true;
}

/// Very permissive (CommonMark-compatible) email check: local part and domain
/// must each be non-empty and only contain their respective allowed chars.
fn isValidEmail(s: []const u8) bool {
    const at = std.mem.indexOfScalar(u8, s, '@') orelse return false;
    if (at == 0 or at >= s.len - 1) return false;
    for (s[0..at]) |c| {
        if (!isEmailLocalChar(c)) return false;
    }
    for (s[at + 1 ..]) |c| {
        if (!isDomainChar(c)) return false;
    }
    return true;
}

fn isEmailLocalChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '!' or c == '#' or c == '$' or
        c == '%' or c == '&' or c == '\'' or c == '*' or c == '+' or c == '-' or
        c == '/' or c == '=' or c == '?' or c == '^' or c == '_' or c == '`' or
        c == '{' or c == '|' or c == '}' or c == '~' or c == '.';
}

fn isDomainChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-' or c == '.';
}

/// Returns the length of a raw inline HTML construct starting at `slice[0]`
/// (which is `<`), or null if `slice` does not begin with a complete,
/// well-formed inline HTML tag/comment/declaration/CDATA/PI.
fn scanInlineHtmlEnd(slice: []const u8) ?usize {
    if (slice.len < 2 or slice[0] != '<') return null;

    // `<!-->` and `<!--->` are complete comments on their own (CommonMark §6.6).
    if (std.mem.startsWith(u8, slice, "<!--->")) return 6;
    if (std.mem.startsWith(u8, slice, "<!-->")) return 5;
    if (std.mem.startsWith(u8, slice, "<!--")) {
        const end = std.mem.indexOf(u8, slice[4..], "-->") orelse return null;
        return 4 + end + 3;
    }
    if (std.mem.startsWith(u8, slice, "<![CDATA[")) {
        const end = std.mem.indexOf(u8, slice[9..], "]]>") orelse return null;
        return 9 + end + 3;
    }
    if (std.mem.startsWith(u8, slice, "<!")) {
        const end = std.mem.indexOfScalar(u8, slice[2..], '>') orelse return null;
        return 2 + end + 1;
    }
    if (std.mem.startsWith(u8, slice, "<?")) {
        const end = std.mem.indexOf(u8, slice[2..], "?>") orelse return null;
        return 2 + end + 2;
    }

    var pos: usize = 1;
    var is_closing = false;
    if (pos < slice.len and slice[pos] == '/') {
        is_closing = true;
        pos += 1;
    }

    // Tag name: ASCII letter followed by alphanumeric or hyphen.
    if (pos >= slice.len or !std.ascii.isAlphabetic(slice[pos])) return null;
    pos += 1;
    while (pos < slice.len and (std.ascii.isAlphanumeric(slice[pos]) or slice[pos] == '-')) : (pos += 1) {}

    if (is_closing) {
        while (pos < slice.len and chars.isWsByte(slice[pos])) : (pos += 1) {}
        if (pos >= slice.len or slice[pos] != '>') return null;
        return pos + 1;
    }

    while (true) {
        var had_ws = false;
        while (pos < slice.len and chars.isWsByte(slice[pos])) : (pos += 1) had_ws = true;
        if (pos >= slice.len) return null;

        if (slice[pos] == '>') return pos + 1;
        if (slice[pos] == '/' and pos + 1 < slice.len and slice[pos + 1] == '>') return pos + 2;

        // An attribute must be preceded by whitespace (CommonMark §6.7).
        if (!had_ws) return null;

        // Attribute name.
        if (!chars.isAttrNameChar(slice[pos])) return null;
        while (pos < slice.len and chars.isAttrNameChar(slice[pos])) : (pos += 1) {}

        // Optional `=` value. Whitespace is allowed on both sides of the `=`,
        // so it is only consumed once the `=` is actually there.
        var eq = pos;
        while (eq < slice.len and chars.isWsByte(slice[eq])) : (eq += 1) {}
        if (eq < slice.len and slice[eq] == '=') {
            pos = eq + 1;
            while (pos < slice.len and chars.isWsByte(slice[pos])) : (pos += 1) {}
            if (pos < slice.len) {
                if (slice[pos] == '"' or slice[pos] == '\'') {
                    const q = slice[pos];
                    pos += 1;
                    while (pos < slice.len and slice[pos] != q) : (pos += 1) {}
                    if (pos >= slice.len) return null;
                    pos += 1;
                } else {
                    // Unquoted value: no whitespace, ", ', <, >, =, or ` (CommonMark §6.7).
                    while (pos < slice.len) : (pos += 1) {
                        const v = slice[pos];
                        if (chars.isWsByte(v) or v == '"' or v == '\'' or v == '<' or v == '>' or v == '=' or v == '`') break;
                    }
                }
            }
        }
    }
}

/// Normalizes raw code-span content (CommonMark §6.1), in this order:
/// line endings become spaces, then one leading and one trailing space are
/// stripped if both are present and the content is not all spaces. The order
/// matters — `` `` \nfoo\n `` `` must lose the spaces the newlines became.
fn codeSpanValue(arena: Allocator, raw: []const u8) ParseError![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(arena);
    try out.ensureTotalCapacity(arena, raw.len);
    for (raw) |c| out.appendAssumeCapacity(if (c == '\n') ' ' else c);

    const items = out.items;
    if (items.len > 2 and items[0] == ' ' and items[items.len - 1] == ' ' and !isAllSpaces(items)) {
        std.mem.copyForwards(u8, items[0 .. items.len - 2], items[1 .. items.len - 1]);
        out.items.len -= 2;
    }
    return out.toOwnedSlice(arena);
}

fn isAllSpaces(s: []const u8) bool {
    for (s) |c| {
        if (c != ' ') return false;
    }
    return true;
}

/// Reference-free tests parse against an empty definition set.
const no_definitions: reference.DefinitionsMap = .empty;
const no_options: ParseOptions = .{};

test "code span: basic" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const parent = try arena.create(Node);
    parent.* = .{ .data = .paragraph };
    var ip = InlinePhase.init(arena, "a `code` b", parent, &no_options, &no_definitions, &no_definitions, &.{}, null);
    try ip.run();

    // Expect 3 children: text "a ", inline_code "code", text " b"
    try std.testing.expectEqual(@as(usize, 3), parent.childCount());
    var child = parent.first_child.?;
    try std.testing.expectEqualStrings("a ", child.data.text);
    child = child.next.?;
    try std.testing.expectEqualStrings("code", child.data.inline_code);
    child = child.next.?;
    try std.testing.expectEqualStrings(" b", child.data.text);
}

test "code span: unmatched backticks are literal" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const parent = try arena.create(Node);
    parent.* = .{ .data = .paragraph };
    var ip = InlinePhase.init(arena, "no `code here", parent, &no_options, &no_definitions, &no_definitions, &.{}, null);
    try ip.run();

    try std.testing.expectEqual(@as(usize, 1), parent.childCount());
    try std.testing.expectEqualStrings("no `code here", parent.first_child.?.data.text);
}

test "entity: named and numeric" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const parent = try arena.create(Node);
    parent.* = .{ .data = .paragraph };
    var ip = InlinePhase.init(arena, "&amp; &#35; &#X22; &unknown;", parent, &no_options, &no_definitions, &no_definitions, &.{}, null);
    try ip.run();

    try std.testing.expectEqual(@as(usize, 1), parent.childCount());
    // &amp;→&, &#35;→#, &#X22;→", &unknown;→literal
    try std.testing.expectEqualStrings("& # \" &unknown;", parent.first_child.?.data.text);
}

test "autolink: uri and email" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const parent = try arena.create(Node);
    parent.* = .{ .data = .paragraph };
    var ip = InlinePhase.init(arena, "<https://x.io> <a@b.com>", parent, &no_options, &no_definitions, &no_definitions, &.{}, null);
    try ip.run();

    // link | text " " | link
    var count: usize = 0;
    var child_opt = parent.first_child;
    while (child_opt) |c| : (child_opt = c.next) count += 1;
    try std.testing.expectEqual(@as(usize, 3), count);

    var child = parent.first_child.?;
    try std.testing.expect(child.data == .link);
    try std.testing.expectEqualStrings("https://x.io", child.data.link.url);
    child = child.next.?;
    try std.testing.expectEqualStrings(" ", child.data.text);
    child = child.next.?;
    try std.testing.expect(child.data == .link);
    try std.testing.expectEqualStrings("mailto:a@b.com", child.data.link.url);
}

test "hard break: two trailing spaces" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const parent = try arena.create(Node);
    parent.* = .{ .data = .paragraph };
    var ip = InlinePhase.init(arena, "foo  \nbaz", parent, &no_options, &no_definitions, &no_definitions, &.{}, null);
    try ip.run();

    // text "foo" | break_ | text "baz"
    var count: usize = 0;
    var child_opt = parent.first_child;
    while (child_opt) |c| : (child_opt = c.next) count += 1;
    try std.testing.expectEqual(@as(usize, 3), count);

    var child = parent.first_child.?;
    try std.testing.expectEqualStrings("foo", child.data.text);
    child = child.next.?;
    try std.testing.expect(child.data == .break_);
    child = child.next.?;
    try std.testing.expectEqualStrings("baz", child.data.text);
}

test "strikethrough: basic GFM" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const parent = try arena.create(Node);
    parent.* = .{ .data = .paragraph };
    const opts: ParseOptions = .{ .gfm = true };
    var ip = InlinePhase.init(arena, "~~Hi~~ Hello, world!", parent, &opts, &no_definitions, &no_definitions, &.{}, null);
    try ip.run();

    // delete | text " Hello, world!"
    var child = parent.first_child.?;
    try std.testing.expect(child.data == .delete);
    try std.testing.expectEqual(@as(usize, 1), child.childCount());
    try std.testing.expectEqualStrings("Hi", child.first_child.?.data.text);
    child = child.next.?;
    try std.testing.expectEqualStrings(" Hello, world!", child.data.text);
}
