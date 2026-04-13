const std = @import("std");

// ─── East Asian display width ─────────────────────────────────────────────────

/// Terminal cell width (1 or 2) for a Unicode scalar value.
/// Matches `grid` wide-character rules: CJK, fullwidth forms, etc. are 2 cells.
/// Returns 0 only for `cp == 0` (spacer / unset).
pub fn eastAsianDisplayWidth(cp: u21) u8 {
    if (cp == 0) return 0;
    // CJK Unified Ideographs
    if (cp >= 0x4E00 and cp <= 0x9FFF) return 2;
    // CJK Unified Ideographs Extension A
    if (cp >= 0x3400 and cp <= 0x4DBF) return 2;
    // CJK Compatibility Ideographs
    if (cp >= 0xF900 and cp <= 0xFAFF) return 2;
    // Hiragana
    if (cp >= 0x3040 and cp <= 0x309F) return 2;
    // Katakana
    if (cp >= 0x30A0 and cp <= 0x30FF) return 2;
    // Fullwidth Forms
    if (cp >= 0xFF01 and cp <= 0xFF60) return 2;
    if (cp >= 0xFFE0 and cp <= 0xFFE6) return 2;
    // Halfwidth Katakana (1-wide)
    if (cp >= 0xFF65 and cp <= 0xFF9F) return 1;
    // CJK Symbols and Punctuation
    if (cp >= 0x3000 and cp <= 0x303F) return 2;
    // Hangul Syllables
    if (cp >= 0xAC00 and cp <= 0xD7AF) return 2;
    // Enclosed CJK Letters
    if (cp >= 0x3200 and cp <= 0x32FF) return 2;
    // CJK Compatibility
    if (cp >= 0x3300 and cp <= 0x33FF) return 2;
    // Bopomofo
    if (cp >= 0x3100 and cp <= 0x312F) return 2;
    // CJK Extension B+
    if (cp >= 0x20000 and cp <= 0x2FA1F) return 2;
    return 1;
}

// ─── Tests ───────────────────────────────────────────────────────────────────

test "ASCII width 1" {
    try std.testing.expectEqual(@as(u8, 1), eastAsianDisplayWidth('A'));
    try std.testing.expectEqual(@as(u8, 1), eastAsianDisplayWidth('z'));
}

test "CJK width 2" {
    try std.testing.expectEqual(@as(u8, 2), eastAsianDisplayWidth(0x3042)); // あ
    try std.testing.expectEqual(@as(u8, 2), eastAsianDisplayWidth(0x6F22)); // 漢
}

test "spacer width 0" {
    try std.testing.expectEqual(@as(u8, 0), eastAsianDisplayWidth(0));
}
