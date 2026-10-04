#!/usr/bin/env python3
"""Convert a cmark spec-format .txt into the conformance JSON the Zig test
harness reads (SPEC §13.6, §16.2).

Usage:
    python3 tools/gen_spec_json.py test/fixtures/gfm-footnote.txt \
        "Footnotes (extension)" > test/fixtures/gfm-footnote.json

The spec format fences each example with a long run of backticks followed by
the word `example`; the markdown input and the expected HTML are separated by
a line holding only `.`, and `→` stands in for a tab.
"""
import json
import re
import sys

OPEN = re.compile(r"^`{32,}\s*example\s*$")
CLOSE = re.compile(r"^`{32,}\s*$")


def main() -> None:
    path, section = sys.argv[1], sys.argv[2]
    cases = []
    state = 0  # 0 = outside, 1 = markdown, 2 = html
    md: list[str] = []
    html: list[str] = []

    with open(path, encoding="utf-8") as fh:
        for raw in fh:
            line = raw.replace("\u2192", "\t")
            if state == 0:
                if OPEN.match(line):
                    state, md, html = 1, [], []
                continue
            if state == 1:
                if line.rstrip("\n") == ".":
                    state = 2
                else:
                    md.append(line)
                continue
            if CLOSE.match(line):
                cases.append(
                    {
                        "example": len(cases) + 1,
                        "section": section,
                        "markdown": "".join(md),
                        "html": "".join(html),
                    }
                )
                state = 0
            else:
                html.append(line)

    json.dump(cases, sys.stdout, indent=2, ensure_ascii=False)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
