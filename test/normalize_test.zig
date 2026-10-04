const std = @import("std");
const normalize = @import("normalize");

test "collapse whitespace outside pre; leave pre intact" {
    const a = std.testing.allocator;
    {
        const out = try normalize.normalize(a, "<p>a   b\n c</p>");
        defer a.free(out);
        try std.testing.expectEqualStrings("<p>a b c</p>", out);
    }
    {
        const out = try normalize.normalize(a, "<pre><code>a   b</code></pre>");
        defer a.free(out);
        try std.testing.expectEqualStrings("<pre><code>a   b</code></pre>", out);
    }
}

test "attribute sorting and lowercasing" {
    const a = std.testing.allocator;
    const out = try normalize.normalize(a, "<a title=\"x\" href=\"y\">z</a>");
    defer a.free(out);
    try std.testing.expectEqualStrings("<a href=\"y\" title=\"x\">z</a>", out);
}

test "self-closing normalization" {
    const a = std.testing.allocator;
    const out = try normalize.normalize(a, "<br/>");
    defer a.free(out);
    try std.testing.expectEqualStrings("<br />", out);
}

test "entity normalization in text" {
    const a = std.testing.allocator;
    const out = try normalize.normalize(a, "<p>&amp; &lt; &gt;</p>");
    defer a.free(out);
    try std.testing.expectEqualStrings("<p>&amp; &lt; &gt;</p>", out);
}

test "block tags separate lines" {
    const a = std.testing.allocator;
    const out = try normalize.normalize(a, "<ul><li>a</li><li>b</li></ul>");
    defer a.free(out);
    try std.testing.expectEqualStrings("<ul><li>a</li><li>b</li></ul>", out);
}
