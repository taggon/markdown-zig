pub const ParseOptions = struct {
    gfm: bool = false,
    mdx: bool = false,
    frontmatter: bool = false,
    math: bool = false,
    max_nesting: usize = 512,
};

pub const MdxHtmlPolicy = enum { err, strip, source };

pub const HtmlOptions = struct {
    mdx_html: MdxHtmlPolicy = .strip,
    /// null keeps the footnote section headingless, matching cmark-gfm's
    /// output. A value emits GitHub's `<h2 class="sr-only" id="footnote-label">`
    /// (SPEC §13.5).
    gfm_footnote_label: ?[]const u8 = null,
};
