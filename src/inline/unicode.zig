const std = @import("std");

pub fn decodeBefore(text: []const u8, byte_pos: usize) ?u21 {
    if (byte_pos == 0 or byte_pos > text.len) return null;
    var i = byte_pos;
    while (i > 0) {
        i -= 1;
        if ((text[i] & 0xC0) != 0x80) break;
    }
    const len = std.unicode.utf8ByteSequenceLength(text[i]) catch return null;
    if (i + @as(usize, len) != byte_pos) return null;
    return std.unicode.utf8Decode(text[i .. i + @as(usize, len)]) catch null;
}

pub fn decodeAt(text: []const u8, byte_pos: usize) ?u21 {
    if (byte_pos >= text.len) return null;
    const len = std.unicode.utf8ByteSequenceLength(text[byte_pos]) catch return null;
    if (byte_pos + @as(usize, len) > text.len) return null;
    return std.unicode.utf8Decode(text[byte_pos .. byte_pos + @as(usize, len)]) catch null;
}

pub fn isUnicodeWhitespace(cp: u21) bool {
    if (cp < 0x80) {
        return switch (cp) {
            ' ', '\t', '\n', '\r', 0x0C, 0x0B => true,
            else => false,
        };
    }
    return switch (cp) {
        0x00A0, 0x1680, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000 => true,
        0x2000...0x200A => true,
        else => false,
    };
}

pub fn isUnicodePunctuation(cp: u21) bool {
    if (cp < 0x80) {
        return switch (cp) {
            '!'...'/', ':'...'@', '['...'`', '{'...'~' => true,
            else => false,
        };
    }
    return switch (cp) {
        0x00A1...0x00BF => true,
        0x00D7 => true,
        0x00F7 => true,
        0x037E => true,
        0x0387 => true,
        0x055A...0x055F => true,
        0x0589...0x058A => true,
        0x058F => true,
        0x05BE => true,
        0x05C0 => true,
        0x05C3 => true,
        0x05C6 => true,
        0x0606...0x060F => true,
        0x066A...0x066D => true,
        0x06D4 => true,
        0x0700...0x070D => true,
        0x07F7...0x07F9 => true,
        0x0830...0x083E => true,
        0x085E => true,
        0x0964...0x0965 => true,
        0x0970 => true,
        0x0DF4 => true,
        0x0E4F => true,
        0x0E5A...0x0E5B => true,
        0x0F04...0x0F12 => true,
        0x0F3A...0x0F3D => true,
        0x0F85 => true,
        0x104A...0x104F => true,
        0x10FB => true,
        0x1360...0x1368 => true,
        0x1400 => true,
        0x166D...0x166E => true,
        0x169B...0x169C => true,
        0x16EB...0x16ED => true,
        0x1735...0x1736 => true,
        0x17D4...0x17D6 => true,
        0x17D8...0x17DA => true,
        0x1800...0x180A => true,
        0x1944...0x1945 => true,
        0x19DE...0x19DF => true,
        0x1A1E...0x1A1F => true,
        0x1AA0...0x1AA6 => true,
        0x1AA8...0x1AAD => true,
        0x1B5A...0x1B60 => true,
        0x1BFC...0x1BFF => true,
        0x1C3B...0x1C3F => true,
        0x1C7E...0x1C7F => true,
        0x1CC0...0x1CC7 => true,
        0x1CD3 => true,
        0x2000...0x200A => true,
        0x2010...0x2027 => true,
        0x2030...0x2043 => true,
        0x2045...0x2051 => true,
        0x2053...0x205E => true,
        0x207A...0x207E => true,
        0x208A...0x208E => true,
        0x20A0...0x20BF => true,
        0x2100...0x2101 => true,
        0x2103...0x2104 => true,
        0x2107 => true,
        0x2113 => true,
        0x2116...0x2118 => true,
        0x211E...0x2123 => true,
        0x2125 => true,
        0x2127 => true,
        0x2129 => true,
        0x212E => true,
        0x213A...0x213B => true,
        0x2140...0x2144 => true,
        0x214A...0x214B => true,
        0x214C...0x214D => true,
        0x2150...0x215F => true,
        0x2189 => true,
        0x2190...0x21FF => true,
        0x2200...0x22FF => true,
        0x2300...0x237F => true,
        0x2394 => true,
        0x239B...0x23B1 => true,
        0x23B4...0x23DB => true,
        0x23DC...0x23E1 => true,
        0x2400...0x2426 => true,
        0x2440...0x244A => true,
        0x2500...0x25B6 => true,
        0x25B8...0x25C0 => true,
        0x25C2...0x25F7 => true,
        0x25FF => true,
        0x2600...0x266E => true,
        0x2670...0x2767 => true,
        0x2794...0x27BF => true,
        0x2800...0x28FF => true,
        0x2B00...0x2B2F => true,
        0x2B45...0x2B46 => true,
        0x2B4D...0x2B73 => true,
        0x2B76...0x2B95 => true,
        0x2B98...0x2BB9 => true,
        0x2BBD...0x2BC8 => true,
        0x2BCA...0x2BD1 => true,
        0x2BEC...0x2BEF => true,
        0x2CE5...0x2CEA => true,
        0x2CF9...0x2CFC => true,
        0x2CFE...0x2CFF => true,
        0x2E00...0x2E7F => true,
        0x3001...0x3003 => true,
        0x3008...0x3011 => true,
        0x3014...0x301F => true,
        0x3030 => true,
        0x303D => true,
        0x30A0 => true,
        0x30FB => true,
        0xA4FE...0xA4FF => true,
        0xA60D...0xA60F => true,
        0xA673 => true,
        0xA67E => true,
        0xA6F2...0xA6F7 => true,
        0xA874...0xA877 => true,
        0xA8CE...0xA8CF => true,
        0xA8F8...0xA8FA => true,
        0xA92E...0xA92F => true,
        0xA95F => true,
        0xA9C1...0xA9CD => true,
        0xA9DE...0xA9DF => true,
        0xAA5C...0xAA5F => true,
        0xAADE...0xAADF => true,
        0xAAF0...0xAAF1 => true,
        0xABEB => true,
        0xFD3E...0xFD3F => true,
        0xFE10...0xFE19 => true,
        0xFE30...0xFE52 => true,
        0xFE54...0xFE6F => true,
        0xFF01...0xFF0F => true,
        0xFF1A...0xFF20 => true,
        0xFF3B...0xFF40 => true,
        0xFF5B...0xFF65 => true,
        else => false,
    };
}

test "decodeBefore: multibyte" {
    const text = "aéb";
    try std.testing.expectEqual(@as(?u21, 0xE9), decodeBefore(text, 3));
    try std.testing.expectEqual(@as(?u21, 'a'), decodeBefore(text, 1));
}

test "decodeBefore: position zero returns null" {
    try std.testing.expectEqual(@as(?u21, null), decodeBefore("abc", 0));
}

test "decodeAt: ascii and multibyte" {
    const text = "aéb";
    try std.testing.expectEqual(@as(?u21, 'a'), decodeAt(text, 0));
    try std.testing.expectEqual(@as(?u21, 0xE9), decodeAt(text, 1));
    try std.testing.expectEqual(@as(?u21, 'b'), decodeAt(text, 3));
}

test "decodeAt: end of string returns null" {
    try std.testing.expectEqual(@as(?u21, null), decodeAt("abc", 3));
    try std.testing.expectEqual(@as(?u21, null), decodeAt("aéb", 4));
}

test "isUnicodeWhitespace" {
    try std.testing.expect(isUnicodeWhitespace(' '));
    try std.testing.expect(!isUnicodeWhitespace('a'));
    try std.testing.expect(isUnicodeWhitespace(0x00A0));
    try std.testing.expect(isUnicodeWhitespace(0x2003));
    try std.testing.expect(!isUnicodeWhitespace(0x0061));
}

test "isUnicodePunctuation" {
    try std.testing.expect(isUnicodePunctuation('*'));
    try std.testing.expect(!isUnicodePunctuation('a'));
    try std.testing.expect(isUnicodePunctuation(0x2014));
    try std.testing.expect(isUnicodePunctuation(0x2018));
    try std.testing.expect(!isUnicodePunctuation(0x2080));
}
