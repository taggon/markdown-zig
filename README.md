# markdown-zig

<div align="center">

**CommonMark-compliant Markdown parser in Zig**

[![Zig](https://img.shields.io/badge/Zig-0.17.0-orange.svg)](https://ziglang.org)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

[Features](#features) · [Installation](#installation) · [Use](#use) · [API](#api)

</div>

## Features

- **compliant** — [CommonMark 0.31.2](https://spec.commonmark.org) 652/652, GFM 24/24, MDX 59/59
- **extensions** — GFM (footnote, table, strikethrough, task list, autolink), MDX (expression/JSX), frontmatter, math
- **[mdast](https://github.com/syntax-tree/mdast)** — parses directly to an mdast tree with source positions; no intermediate event stream
- **arena-friendly** — all AST nodes live in a caller-provided arena; the parser holds no global state
- **zero-dependency** — only the Zig standard library
- **linear-time** — enforced by a scalability gate (`zig build test-perf`)

## What is this?

A Markdown parser written in Zig, using the block/inline two-phase approach
popularized by cmark: the block phase builds container and leaf blocks line by
line, then the inline phase parses each leaf's text into emphasis, links, and
other inline constructs. Extensions are enabled per document via `ParseOptions`.

## Installation

Add to your `build.zig.zon` (run `zig fetch --save=markdown <url>` to fill in
the hash):

```zig
.dependencies = .{
    .markdown = .{
        .url = "https://github.com/taggon/markdown-zig/archive/v0.1.0.tar.gz",
        .hash = "...",
    },
},
```

Then in `build.zig`:

```zig
const markdown = b.dependency("markdown", .{
    .target = target,
    .optimize = optimize,
}).module("markdown");
your_mod.addImport("markdown", markdown);
```

From source:

```sh
git clone https://github.com/taggon/markdown-zig.git
cd markdown-zig
zig build test        # run all tests
```

## Use

### Markdown to HTML

```zig
const markdown = @import("markdown");

pub fn main(init: std.process.Init) !void {
    const html = try markdown.toHtml(init.gpa, "## Hi, *Saturn*! 🪐\n", .{}, .{});
    defer init.gpa.free(html);
    std.debug.print("{s}\n", .{html});
}
```

```html
<h2>Hi, <em>Saturn</em>! 🪐</h2>
```

### Parse to mdast tree

```zig
var arena_state = std.heap.ArenaAllocator.init(gpa);
defer arena_state.deinit();

const root = try markdown.parse(arena_state.allocator(), "# Hi *Earth*!", .{});
// root.data == .root
// root.first_child.data == .{ .heading = .{ .depth = 1 } }
```

### With GFM extensions

```zig
const html = try markdown.toHtml(
    gpa,
    "* [x] done\n~~strikethrough~~\n",
    .{ .gfm = true },
    .{},
);
```

```html
<ul>
<li><input checked="" disabled="" type="checkbox"> done
<del>strikethrough</del></li>
</ul>
```

### With MDX

MDX is a parser feature: expressions and JSX tags become mdast nodes carrying
their `value` and `raw` source, for the host application to evaluate or render:

```zig
const root = try markdown.parse(arena, "Hello <B>MDX</B>! {1 + 2}", .{ .mdx = true });
// paragraph
// ├─ text "Hello "
// ├─ mdx_jsx_text_element  name="B"  raw="<B>MDX</B>"
// │   └─ text "MDX"
// ├─ text "! "
// └─ mdx_text_expression  value="1 + 2"  raw="{1 + 2}"
```

`toHtml` does not evaluate MDX. By default (`mdx_html = .strip`) tags and
expressions produce no output; `.source` emits them verbatim, HTML-escaped, and
`.err` makes them a render error.

## API

| Function | Description |
|---|---|
| `toHtml(gpa, source, parse_options, html_options)` | Parse + render to HTML in one call. Returns a `gpa`-owned byte slice. |
| `parse(arena, source, options)` | Parse to an mdast `*Node`. The tree's lifetime is tied to `arena`. |
| `renderHtml(gpa, root, options)` | Render an existing mdast tree to HTML. |
| `Parser.init(options)` | Reusable `Parser` value (immutable options, thread-safe). |

Extensions are enabled per document via `ParseOptions`. Build-time feature
flags for binary size control are planned but not yet implemented.

```zig
pub const ParseOptions = struct {
    gfm: bool = false,          // strikethrough, autolink-literal, table, task-list, footnote
    mdx: bool = false,          // MDX expressions and JSX
    frontmatter: bool = false,  // YAML/TOML frontmatter
    math: bool = false,         // Math ($...$, $$...$$)
    max_nesting: usize = 512,
};

pub const HtmlOptions = struct {
    mdx_html: MdxHtmlPolicy = .strip,       // .err | .strip | .source
    gfm_footnote_label: ?[]const u8 = null,  // null = no heading, or a label string
};
```

## Test

| Step | Description |
|---|---|
| `zig build test-unit` | Unit tests (`test` blocks inside `src/`) |
| `zig build test-conformance` | CommonMark fixture conformance + HTML normalizer tests |
| `zig build test-robustness` | Allocator failure injection, nesting limits |
| `zig build test-perf` | Scalability gate — parsing must stay linear in input length |
| `zig build test-fuzz` | Property-based fuzz (crash, determinism, tree consistency) |
| `zig build test` | All of the above |
| `zig build debug-conformance` | Dump every failing conformance example with input and expected output |

Current conformance: **652 / 652** CommonMark 0.31.2 examples, **24 / 24** GFM
extension examples, **59 / 59** MDX examples (expression, JSX, errors).

## Limitations

- **MDX expressions are not JavaScript.** Boundaries are found by counting
  braces, so a brace inside a string, comment, template literal or regex is
  not recognised as such: `{"}"}` ends at the first `}`.
- **MDX does not support ESM.** `import` / `export` are parsed as ordinary
  Markdown, not as `mdxjsEsm` nodes.
- **MDX keeps CommonMark autolinks.** `<https://example.com>` is a link here;
  `@mdx-js/mdx` rejects it as a malformed tag. Text that enters the tag grammar
  and then breaks it (`<a =b>`, `<a href=x>`) is a parse error, as in MDX.
- **A multi-line MDX construct cannot take its flow judgement back.** With
  `{a +`↵`b} tail`, the reference parser rereads the whole thing as paragraph
  text; we emit the expression and then a paragraph for `tail`. Single-line
  constructs match.
- **Source positions cover block and inline nodes.** Columns count code points
  (1-based); offsets refer to the original source. Tabs expand for parsing
  logic only — in positions, each tab is one column.

## Security

The HTML renderer does **not** sanitize output. Raw HTML passes through
verbatim, and no output escaping replaces a sanitizer. If you expose untrusted
Markdown to the web, pass the resulting HTML through a separate sanitizer.
(URLs, titles, and code fence info strings are still escaped as required for
correct HTML.)

## Requirements

- **Zig 0.17.0** — stable releases only; nightly/master is not supported

## License

MIT
