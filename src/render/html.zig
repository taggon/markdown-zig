const std = @import("std");
const Allocator = std.mem.Allocator;
const Node = @import("../node.zig").Node;
const node_mod = @import("../node.zig");
const Align = @import("../node.zig").Align;
const HtmlOptions = @import("../options.zig").HtmlOptions;
const reference = @import("../reference.zig");
const footnotes = @import("footnotes.zig");

pub fn render(gpa: Allocator, root: *const Node, options: HtmlOptions) RenderError![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    var defs = try reference.collect(gpa, root);
    defer defs.deinit(gpa);
    var notes = try footnotes.build(gpa, root);
    defer notes.deinit(gpa);

    var w: Writer = .{
        .gpa = gpa,
        .buf = &buf,
        .options = options,
        .defs = &defs,
        .notes = &notes,
        .depth = 0,
    };
    try w.renderNode(root);
    return buf.toOwnedSlice(gpa);
}

pub const RenderError = error{ NestingTooDeep, MdxNodeInErrorMode, OutOfMemory };

const max_render_depth: usize = 512;

/// Rendering state. Every helper is a method so `gpa`/`buf`/`defs` are not
/// threaded through the whole tree walk by hand (SPEC §12).
const Writer = struct {
    gpa: Allocator,
    buf: *std.ArrayList(u8),
    options: HtmlOptions,
    defs: *const reference.ResolvedMap,
    notes: *const footnotes.Map,
    depth: usize,

    const Error = RenderError;

    fn write(self: *Writer, s: []const u8) Error!void {
        try self.buf.appendSlice(self.gpa, s);
    }

    /// Starts a fresh line before a block-level tag (cmark's `cr`). Block
    /// closers already end with a newline, so this only fires where inline
    /// content precedes a block — inside a tight `<li>`, above all.
    fn cr(self: *Writer) Error!void {
        if (self.buf.items.len == 0) return;
        if (self.buf.items[self.buf.items.len - 1] == '\n') return;
        try self.buf.append(self.gpa, '\n');
    }

    /// Opens a block-level element on its own line.
    fn openBlock(self: *Writer, tag: []const u8) Error!void {
        try self.cr();
        try self.write(tag);
    }

    fn renderChildren(self: *Writer, node: *const Node) Error!void {
        var child = node.first_child;
        while (child) |c| : (child = c.next) try self.renderNode(c);
    }

    /// Wraps the node's children in `<tag>` … `</tag>`.
    fn wrap(self: *Writer, open: []const u8, node: *const Node, close: []const u8) Error!void {
        try self.write(open);
        try self.renderChildren(node);
        try self.write(close);
    }

    fn renderNode(self: *Writer, node: *const Node) Error!void {
        self.depth += 1;
        defer self.depth -= 1;
        if (self.depth > max_render_depth) return error.NestingTooDeep;
        switch (node.data) {
            .root => {
                try self.renderChildren(node);
                try self.renderFootnoteSection();
            },
            .paragraph => {
                try self.openBlock("<p>");
                try self.renderChildren(node);
                try self.write("</p>\n");
            },
            .emphasis => try self.wrap("<em>", node, "</em>"),
            .strong => try self.wrap("<strong>", node, "</strong>"),
            .delete => try self.wrap("<del>", node, "</del>"),
            .blockquote => {
                try self.openBlock("<blockquote>\n");
                try self.renderChildren(node);
                try self.write("</blockquote>\n");
            },
            .text => |t| try self.escapeText(t),
            .html => |h| {
                // An HTML block starts its own line; inline raw HTML must not.
                if (isFlowParent(node.parent)) try self.cr();
                try self.write(h); // raw HTML passes through verbatim
            },
            .thematic_break => try self.openBlock("<hr />\n"),
            .break_ => try self.write("<br />\n"),
            .definition => {}, // link reference definitions render nothing
            .inline_code => |code| {
                try self.write("<code>");
                try self.escapeText(code);
                try self.write("</code>");
            },
            .code => |c| {
                try self.openBlock("<pre><code");
                if (c.lang) |lang| {
                    try self.write(" class=\"language-");
                    try self.escapeAttr(lang);
                    try self.write("\"");
                }
                try self.write(">");
                try self.escapeText(c.value);
                try self.write("</code></pre>\n");
            },
            .heading => |h| {
                const tag = switch (h.depth) {
                    1 => "h1",
                    2 => "h2",
                    3 => "h3",
                    4 => "h4",
                    5 => "h5",
                    else => "h6",
                };
                try self.cr();
                try self.write("<");
                try self.write(tag);
                try self.write(">");
                try self.renderChildren(node);
                try self.write("</");
                try self.write(tag);
                try self.write(">\n");
            },
            .link => |l| {
                try self.openAnchor(l.url, l.title);
                try self.renderChildren(node);
                try self.write("</a>");
            },
            .image => |img| try self.writeImage(img.url, img.title, img.alt),
            .link_reference => |lr| {
                if (self.defs.get(lr.identifier)) |def| {
                    const d = def.data.definition;
                    try self.openAnchor(d.url, d.title);
                    try self.renderChildren(node);
                    try self.write("</a>");
                } else {
                    try self.write("[");
                    try self.renderChildren(node);
                    try self.write("]");
                    try self.writeReferenceSuffix(lr.reference_type, lr.label);
                }
            },
            .image_reference => |ir| {
                if (self.defs.get(ir.identifier)) |def| {
                    const d = def.data.definition;
                    // The reference's own `alt` is empty; the text lives in its
                    // children, so flatten those rather than the node itself.
                    var alt: std.ArrayList(u8) = .empty;
                    defer alt.deinit(self.gpa);
                    var child = node.first_child;
                    while (child) |c| : (child = c.next) try node_mod.collectAlt(&alt, self.gpa, c);
                    try self.writeImage(d.url, d.title, alt.items);
                } else {
                    try self.write("![");
                    try self.renderChildren(node);
                    try self.write("]");
                    try self.writeReferenceSuffix(ir.reference_type, ir.label);
                }
            },
            .list => |l| {
                if (l.ordered) {
                    try self.openBlock("<ol");
                    if (l.start) |s| {
                        if (s != 1) {
                            // usize decimal fits in 20 digits; [24]u8 is always sufficient.
                            var num_buf: [24]u8 = undefined;
                            try self.write(" start=\"");
                            try self.write(std.fmt.bufPrint(&num_buf, "{d}", .{s}) catch unreachable);
                            try self.write("\"");
                        }
                    }
                    try self.write(">\n");
                    try self.renderChildren(node);
                    try self.write("</ol>\n");
                } else {
                    try self.openBlock("<ul>\n");
                    try self.renderChildren(node);
                    try self.write("</ul>\n");
                }
            },
            .list_item => |li| {
                // A tight list drops the `<p>` wrapper around item paragraphs.
                const tight = if (node.parent) |p|
                    p.data == .list and !p.data.list.spread
                else
                    false;
                try self.openBlock("<li>");
                if (li.checked) |checked| {
                    if (checked) {
                        try self.write("<input checked=\"\" disabled=\"\" type=\"checkbox\"> ");
                    } else {
                        try self.write("<input disabled=\"\" type=\"checkbox\"> ");
                    }
                }
                var child = node.first_child;
                while (child) |c| : (child = c.next) {
                    // Tight items render paragraph content without the wrapper;
                    // every other child stays a block and gets its own line.
                    if (tight and c.data == .paragraph) try self.renderChildren(c) else try self.renderNode(c);
                }
                try self.write("</li>\n");
            },
            .table => |t| {
                try self.openBlock("<table>\n");
                var row_node = node.first_child;
                if (row_node) |header_row| {
                    try self.write("<thead>\n<tr>\n");
                    var cell_node = header_row.first_child;
                    var col: usize = 0;
                    while (cell_node) |cell| : (cell_node = cell.next) {
                        try self.write("<th");
                        if (col < t.align_.len) try self.writeAlignAttr(t.align_[col]);
                        try self.write(">");
                        try self.renderChildren(cell);
                        try self.write("</th>\n");
                        col += 1;
                    }
                    try self.write("</tr>\n</thead>\n");
                    row_node = header_row.next;
                }
                if (row_node != null) {
                    try self.write("<tbody>\n");
                    while (row_node) |body_row| : (row_node = body_row.next) {
                        try self.write("<tr>\n");
                        var cell_node = body_row.first_child;
                        var col: usize = 0;
                        while (cell_node) |cell| : (cell_node = cell.next) {
                            try self.write("<td");
                            if (col < t.align_.len) try self.writeAlignAttr(t.align_[col]);
                            try self.write(">");
                            try self.renderChildren(cell);
                            try self.write("</td>\n");
                            col += 1;
                        }
                        try self.write("</tr>\n");
                    }
                    try self.write("</tbody>\n");
                }
                try self.write("</table>\n");
            },
            .table_row, .table_cell => {}, // rendered by .table
            .footnote_definition => {}, // rendered inside the footnote section
            .footnote_reference => |fr| {
                // A hand-built tree can point at a definition that is not
                // there. Restore the source form rather than swallowing it,
                // the way an unresolved link reference is restored (§13.5).
                const info = self.notes.ref(node) orelse {
                    try self.write("[^");
                    try self.escapeText(fr.label);
                    try self.write("]");
                    return;
                };
                try self.write("<sup class=\"footnote-ref\"><a href=\"#fn-");
                try self.escapeUrl(fr.identifier);
                try self.write("\" id=\"fnref-");
                try self.escapeUrl(fr.identifier);
                if (info.ref_ix > 1) {
                    try self.write("-");
                    try self.writeNum(info.ref_ix);
                }
                try self.write("\" data-footnote-ref>");
                try self.writeNum(info.ix);
                try self.write("</a></sup>");
            },
            .mdx_flow_expression => |expr| try self.renderMdxNode(expr.raw, true),
            .mdx_text_expression => |expr| try self.renderMdxNode(expr.raw, false),
            .mdx_jsx_flow_element, .mdx_jsx_text_element => |elem| {
                if (self.options.mdx_html == .err) return error.MdxNodeInErrorMode;
                if (self.options.mdx_html == .source) {
                    // `raw` is the whole element, children included (§12.2),
                    // so they are not rendered again.
                    try self.renderMdxNode(elem.raw, node.data == .mdx_jsx_flow_element);
                    return;
                }
                // .strip: render children only (tags/attrs produce nothing)
                try self.renderChildren(node);
            },
            .math => |m| {
                try self.cr();
                try self.write("\\[");
                try self.escapeText(m);
                try self.write("\\]\n");
            },
            .inline_math => |m| {
                try self.write("\\(");
                try self.escapeText(m);
                try self.write("\\)");
            },
            // Frontmatter is metadata; it produces no output (SPEC §9.3).
            .yaml, .toml => {},
        }
    }

    fn writeNum(self: *Writer, n: usize) Error!void {
        var tmp: [24]u8 = undefined;
        const s = std.fmt.bufPrint(&tmp, "{d}", .{n}) catch unreachable;
        try self.write(s);
    }

    /// `{ix}` for the first reference, `{ix}-{ref_ix}` for the rest — the shape
    /// cmark-gfm uses for both `data-footnote-backref-idx` and `aria-label`.
    fn writeBackrefIdx(self: *Writer, ix: usize, ref_ix: usize) Error!void {
        try self.writeNum(ix);
        if (ref_ix > 1) {
            try self.write("-");
            try self.writeNum(ref_ix);
        }
    }

    fn writeBackref(self: *Writer, e: footnotes.Entry, ref_ix: usize) Error!void {
        try self.write("<a href=\"#fnref-");
        try self.escapeUrl(e.identifier);
        if (ref_ix > 1) {
            try self.write("-");
            try self.writeNum(ref_ix);
        }
        try self.write("\" class=\"footnote-backref\" data-footnote-backref data-footnote-backref-idx=\"");
        try self.writeBackrefIdx(e.ix, ref_ix);
        try self.write("\" aria-label=\"Back to reference ");
        try self.writeBackrefIdx(e.ix, ref_ix);
        try self.write("\">↩");
        if (ref_ix > 1) {
            try self.write("<sup class=\"footnote-ref\">");
            try self.writeNum(ref_ix);
            try self.write("</sup>");
        }
        try self.write("</a>");
    }

    /// Writes every backref for `e`, space separated. `leading_space` is set when
    /// they follow inline content inside the final paragraph.
    fn writeBackrefs(self: *Writer, e: footnotes.Entry, leading_space: bool) Error!void {
        var n: usize = 1;
        while (n <= e.ref_count) : (n += 1) {
            if (leading_space or n > 1) try self.write(" ");
            try self.writeBackref(e, n);
        }
    }

    /// Renders one definition's children. cmark-gfm tucks the backrefs into the
    /// closing paragraph when there is one, and puts them on their own line
    /// otherwise (e.g. a definition that ends in a code block).
    fn renderFootnoteBody(self: *Writer, e: footnotes.Entry) Error!void {
        const last = e.node.last_child;
        const inline_backrefs = last != null and last.?.data == .paragraph;

        var child = e.node.first_child;
        while (child) |c| : (child = c.next) {
            if (inline_backrefs and c == last.?) {
                try self.openBlock("<p>");
                try self.renderChildren(c);
                try self.writeBackrefs(e, true);
                try self.write("</p>\n");
            } else {
                try self.renderNode(c);
            }
        }

        if (!inline_backrefs) {
            try self.cr();
            try self.writeBackrefs(e, false);
            try self.write("\n");
        }
    }

    fn renderFootnoteSection(self: *Writer) Error!void {
        if (self.notes.entries.len == 0) return;
        try self.openBlock("<section class=\"footnotes\" data-footnotes>\n");
        if (self.options.gfm_footnote_label) |label| {
            try self.write("<h2 class=\"sr-only\" id=\"footnote-label\">");
            try self.escapeText(label);
            try self.write("</h2>\n");
        }
        try self.write("<ol>\n");
        for (self.notes.entries) |e| {
            try self.write("<li id=\"fn-");
            try self.escapeUrl(e.identifier);
            try self.write("\">\n");
            try self.renderFootnoteBody(e);
            try self.write("</li>\n");
        }
        try self.write("</ol>\n</section>\n");
    }

    fn writeAlignAttr(self: *Writer, a: Align) Error!void {
        switch (a) {
            .none => {},
            .left => try self.write(" align=\"left\""),
            .right => try self.write(" align=\"right\""),
            .center => try self.write(" align=\"center\""),
        }
    }

    /// `.source` writes the node's own source, HTML-escaped. A flow node is a
    /// block, so it gets its own line the way every other block does (§12.3).
    fn renderMdxNode(self: *Writer, raw: []const u8, flow: bool) Error!void {
        switch (self.options.mdx_html) {
            .err => return error.MdxNodeInErrorMode,
            .source => {
                if (flow) try self.cr();
                try self.escapeText(raw);
                if (flow) try self.write("\n");
            },
            .strip => {}, // 0 bytes
        }
    }

    fn openAnchor(self: *Writer, url: []const u8, title: ?[]const u8) Error!void {
        try self.write("<a href=\"");
        try self.escapeUrl(url);
        try self.write("\"");
        try self.writeTitle(title);
        try self.write(">");
    }

    fn writeImage(self: *Writer, url: []const u8, title: ?[]const u8, alt: []const u8) Error!void {
        try self.write("<img src=\"");
        try self.escapeUrl(url);
        try self.write("\" alt=\"");
        try self.escapeAttr(alt);
        try self.write("\"");
        try self.writeTitle(title);
        try self.write(" />");
    }

    fn writeTitle(self: *Writer, title: ?[]const u8) Error!void {
        const t = title orelse return;
        try self.write(" title=\"");
        try self.escapeAttr(t);
        try self.write("\"");
    }

    /// Restores the source form of a reference whose definition is missing:
    /// `[label]` for full, `[]` for collapsed, nothing for shortcut.
    fn writeReferenceSuffix(self: *Writer, kind: @import("../node.zig").ReferenceType, label: []const u8) Error!void {
        switch (kind) {
            .full => {
                try self.write("[");
                try self.escapeText(label);
                try self.write("]");
            },
            .collapsed => try self.write("[]"),
            .shortcut => {},
        }
    }

    /// Copies `s`, replacing bytes that `replacement` names. Everything between
    /// two replaced bytes moves in one `appendSlice` — escaping is rare enough
    /// in real documents that a byte-at-a-time loop is pure overhead (§12.1).
    fn escapeInto(self: *Writer, s: []const u8, comptime replacement: fn (u8) ?[]const u8) Error!void {
        var plain_start: usize = 0;
        for (s, 0..) |c, i| {
            const rep = replacement(c) orelse continue;
            if (i > plain_start) try self.write(s[plain_start..i]);
            try self.write(rep);
            plain_start = i + 1;
        }
        if (plain_start < s.len) try self.write(s[plain_start..]);
    }

    fn textReplacement(c: u8) ?[]const u8 {
        return switch (c) {
            '&' => "&amp;",
            '<' => "&lt;",
            '>' => "&gt;",
            '"' => "&quot;",
            else => null,
        };
    }

    fn attrReplacement(c: u8) ?[]const u8 {
        return switch (c) {
            '&' => "&amp;",
            '"' => "&quot;",
            else => null,
        };
    }

    fn escapeText(self: *Writer, text: []const u8) Error!void {
        try self.escapeInto(text, textReplacement);
    }

    fn escapeAttr(self: *Writer, s: []const u8) Error!void {
        try self.escapeInto(s, attrReplacement);
    }

    /// URL attribute encoding, matching cmark's `houdini_escape_href`: bytes
    /// outside the href-safe set become `%XX`, and `&` stays an entity so the
    /// attribute remains well-formed.
    fn escapeUrl(self: *Writer, url: []const u8) Error!void {
        const hex = "0123456789ABCDEF";
        var plain_start: usize = 0;
        for (url, 0..) |c, i| {
            if (c != '&' and isHrefSafe(c)) continue;
            if (i > plain_start) try self.write(url[plain_start..i]);
            if (c == '&') {
                try self.write("&amp;");
            } else {
                try self.write(&[_]u8{ '%', hex[c >> 4], hex[c & 0xf] });
            }
            plain_start = i + 1;
        }
        if (plain_start < url.len) try self.write(url[plain_start..]);
    }
};

/// Characters a URL attribute may carry literally. Everything else — including
/// every non-ASCII byte — is percent-encoded.
fn isHrefSafe(c: u8) bool {
    return switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9' => true,
        '-', '_', '.', '+', '!', '*', '\'', '(', ')', ',', '%', '#', '@', '?', '=', ';', ':', '/', '$', '~', '&' => true,
        else => false,
    };
}

/// True when a node sitting under `parent` is in flow (block) position. The
/// block phase only ever attaches HTML blocks to containers; inline raw HTML
/// always lands inside a paragraph, heading, or another inline node.
fn isFlowParent(parent: ?*Node) bool {
    const p = parent orelse return true;
    return switch (p.data) {
        .root, .blockquote, .list_item, .footnote_definition => true,
        else => false,
    };
}
