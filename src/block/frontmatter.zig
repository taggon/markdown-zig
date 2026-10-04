const std = @import("std");
const testing = std.testing;

pub const FrontmatterFence = enum { yaml, toml };

/// Whether a line is a valid frontmatter opening fence at column 0.
/// Returns the fence type, or null if the line is not an opening fence.
///
/// A valid opening fence is exactly three marker bytes (`---` or `+++`) at
/// column 0, with only trailing whitespace after (SPEC §9.3).
pub fn openingFence(line: []const u8) ?FrontmatterFence {
    if (line.len >= 3 and line[0] == '-' and line[1] == '-' and line[2] == '-') {
        return if (onlyWsAfter(line, 3)) .yaml else null;
    }
    if (line.len >= 3 and line[0] == '+' and line[1] == '+' and line[2] == '+') {
        return if (onlyWsAfter(line, 3)) .toml else null;
    }
    return null;
}

/// Whether a line is a valid closing fence for the given fence type.
/// The marker must match the opening fence, be at column 0, and have only
/// trailing whitespace after the three marker bytes (SPEC §9.3).
pub fn closingFence(line: []const u8, fence: FrontmatterFence) bool {
    const marker: u8 = switch (fence) {
        .yaml => '-',
        .toml => '+',
    };
    if (line.len < 3 or line[0] != marker or line[1] != marker or line[2] != marker) return false;
    return onlyWsAfter(line, 3);
}

/// True when every byte from `start` onward is a space or tab.
fn onlyWsAfter(line: []const u8, start: usize) bool {
    var i = start;
    while (i < line.len) : (i += 1) {
        if (line[i] != ' ' and line[i] != '\t') return false;
    }
    return true;
}

// ── Tests ──────────────────────────────────────────────────────────

test "opening fence: YAML ---" {
    try testing.expectEqual(@as(?FrontmatterFence, .yaml), openingFence("---"));
    try testing.expectEqual(@as(?FrontmatterFence, .yaml), openingFence("---  "));
    try testing.expectEqual(@as(?FrontmatterFence, .yaml), openingFence("---\t"));
}

test "opening fence: TOML +++" {
    try testing.expectEqual(@as(?FrontmatterFence, .toml), openingFence("+++"));
    try testing.expectEqual(@as(?FrontmatterFence, .toml), openingFence("+++ "));
}

test "opening fence: rejects wrong length" {
    try testing.expect(openingFence("--") == null);
    try testing.expect(openingFence("----") == null);
    try testing.expect(openingFence("++") == null);
    try testing.expect(openingFence("++++") == null);
}

test "opening fence: rejects leading whitespace" {
    try testing.expect(openingFence(" ---") == null);
    try testing.expect(openingFence("\t---") == null);
    try testing.expect(openingFence(" +++") == null);
}

test "opening fence: rejects trailing content" {
    try testing.expect(openingFence("---x") == null);
    try testing.expect(openingFence("--- -") == null);
    try testing.expect(openingFence("+++foo") == null);
}

test "opening fence: rejects empty and unrelated lines" {
    try testing.expect(openingFence("") == null);
    try testing.expect(openingFence("hello") == null);
    try testing.expect(openingFence("- - -") == null);
}

test "closing fence: matches opening type" {
    try testing.expect(closingFence("---", .yaml));
    try testing.expect(closingFence("--- ", .yaml));
    try testing.expect(closingFence("+++", .toml));
    try testing.expect(closingFence("+++\t", .toml));
}

test "closing fence: rejects mismatched marker" {
    try testing.expect(!closingFence("---", .toml));
    try testing.expect(!closingFence("+++", .yaml));
}

test "closing fence: rejects wrong length and content" {
    try testing.expect(!closingFence("--", .yaml));
    try testing.expect(!closingFence("----", .yaml));
    try testing.expect(!closingFence("---x", .yaml));
    try testing.expect(!closingFence(" ---", .yaml));
}
