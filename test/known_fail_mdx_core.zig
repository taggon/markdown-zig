//! Known-fail allowlist for the non-MDX conformance suite run with
//! `.mdx = true`. MDX mode disables HTML block types 1–7 and inline raw
//! HTML (SPEC §14.1) and rejects text that enters the JSX tag grammar and
//! then breaks it (SPEC §14.6), so only examples about those constructs may
//! appear here. Any other failure means the MDX scanner is eating regular
//! Markdown — fix the parser, do not add to this list.

/// HTML block types 1–7 (SPEC §14.1 turns these off in MDX mode). One
/// contiguous run in the CommonMark fixture.
const html_blocks = blk: {
    var run: [44]usize = undefined;
    for (&run, 0..) |*example, i| example.* = 148 + i;
    break :blk run;
};

/// Examples whose divergence is inline raw HTML rather than a whole block.
const inline_raw_html = [_]usize{
    // Backslash escapes / entity refs with raw HTML
    21,
    31,
    // Unterminated attribute quote. A JSX attribute value may span lines
    // (SPEC §14.4), so `<a title="a lot` is an *incomplete* tag that keeps
    // reading — not the literal text CommonMark makes of it. 91 completes on
    // a later line and becomes an element; 620 never completes and is an
    // error, which is what MDX does with an unclosed attribute value.
    91,
    620,
    // Link reference definition containing raw HTML (`<bar>`)
    201,
    // Lists containing HTML comment blocks
    308,
    309,
    // Code span containing raw HTML (`<a href="`">`)
    344,
    // Emphasis with raw HTML (`<img>`, `<b>`, `</b>`)
    475,
    476,
    477,
    // Links containing raw HTML (`<foo\nbar>`, `<bar attr="…">`)
    491,
    494,
    524,
    536,
    // Raw HTML inline
    607,
    609,
    610,
    613,
    614,
    615,
    616,
    617,
    618,
    623,
    625,
    626,
    627,
    628,
    629,
    630,
    631,
    // Hard line breaks containing raw HTML (`<br>`)
    642,
    643,
};

/// Text that reads as a JSX tag up to its name and then breaks the grammar.
/// CommonMark keeps it as literal text; MDX has no other reading for it, so
/// it is a parse error (SPEC §14.6). `@mdx-js/mdx` rejects every one of these
/// with the same reasoning — checked case by case.
const jsx_grammar_errors = [_]usize{
    // Link reference definition whose destination line is `<my url>` — a
    // valid opening tag, so it interrupts the paragraph (SPEC §14.2) and
    // never closes.
    195,
    // `[link](<foo\>)`: the destination does not parse, and the leftover
    // `<foo\>` breaks the tag grammar at `\`.
    493,
    // `<foo\+@bar.example.com>`: not an email autolink (backslash), and `\`
    // cannot continue a tag name.
    606,
    // Malformed attributes: `h*#ref`, `'bar'title=`, unquoted `baz`, a
    // closing tag with attributes, `"` after a quoted value.
    619,
    621,
    622,
    624,
    632,
};

pub const commonmark_mdx: []const usize = &(html_blocks ++ inline_raw_html ++ jsx_grammar_errors);

pub const gfm_mdx: []const usize = &.{
    // Disallowed raw HTML processing (tags like <title>, <style>):
    24,
};
