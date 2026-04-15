const std = @import("std");
const render = @import("render.zig");
const mode_mod = @import("mode.zig");
const vt = @import("vt.zig");
const unicode_width = @import("unicode_width.zig");

// ─── Color constants ──────────────────────────────────────────────────────────

// ANSI 256-colour palette indices used for mode indicators.
// idx 2 = green, 4 = blue, 5 = magenta, 3 = yellow, 1 = red, 8 = dark grey
const COLOR_BLACK: vt.Color = .{ .idx = 0 };
const COLOR_GREEN: vt.Color = .{ .idx = 2 };
const COLOR_YELLOW: vt.Color = .{ .idx = 3 };
const COLOR_BLUE: vt.Color = .{ .idx = 4 };
const COLOR_MAGENTA: vt.Color = .{ .idx = 5 };
const COLOR_RED: vt.Color = .{ .idx = 1 };
const COLOR_DARK_GREY: vt.Color = .{ .idx = 8 };
const COLOR_WHITE: vt.Color = .{ .idx = 7 };
const COLOR_BRIGHT_WHITE: vt.Color = .{ .idx = 15 };

// Default status bar background (dark grey / colour 0 for contrast).
const BAR_BG: vt.Color = .{ .idx = 0 };
// Dimmed hint text — bright black / dark grey foreground.
const HINT_FG: vt.Color = .{ .idx = 8 };

// Tab bar colors
// Active tab: green background (idx 2), black text
const TAB_ACTIVE_FG: vt.Color = .{ .idx = 0 };
const TAB_ACTIVE_BG: vt.Color = .{ .idx = 2 };
// Inactive tab: dark grey background, white text
const TAB_INACTIVE_FG: vt.Color = .{ .idx = 7 };
const TAB_INACTIVE_BG: vt.Color = .{ .idx = 8 };
// Tab bar background (fills spaces between/around tabs)
const TAB_BAR_BG: vt.Color = .{ .idx = 0 };

// Separator between mode label and hints
const SEP_FG: vt.Color = .{ .idx = 8 };

// ─── ModeInfo ─────────────────────────────────────────────────────────────────

const ModeInfo = struct {
    label: []const u8,
    fg: vt.Color,
    bg: vt.Color,
    hint: []const u8,
};

fn modeInfo(m: mode_mod.Mode) ModeInfo {
    return switch (m) {
        .normal => .{
            .label = " NORMAL ",
            .fg = COLOR_BLACK,
            .bg = COLOR_GREEN,
            .hint = "Ctrl+p Pane\xe2\x94\x82Ctrl+t Tab\xe2\x94\x82Ctrl+s Scroll\xe2\x94\x82Ctrl+o Session\xe2\x94\x82Ctrl+g Lock",
        },
        .pane => .{
            .label = " PANE ",
            .fg = COLOR_BLACK,
            .bg = COLOR_BLUE,
            .hint = "\xe2\x86\x90 \xe2\x86\x93 \xe2\x86\x91 \xe2\x86\x92 Move\xe2\x94\x82n New\xe2\x94\x82v VSplit\xe2\x94\x82x Close\xe2\x94\x82Esc Normal",
        },
        .tab => .{
            .label = " TAB ",
            .fg = COLOR_BLACK,
            .bg = COLOR_MAGENTA,
            .hint = "\xe2\x86\x90 \xe2\x86\x92 Switch\xe2\x94\x82n New\xe2\x94\x82x Close\xe2\x94\x82r Rename\xe2\x94\x82Esc Normal",
        },
        .scroll => .{
            .label = " SCROLL ",
            .fg = COLOR_BLACK,
            .bg = COLOR_YELLOW,
            .hint = "\xe2\x86\x91 \xe2\x86\x93 Line\xe2\x94\x82u d Page\xe2\x94\x82Esc Normal",
        },
        .session => .{
            .label = " SESSION ",
            .fg = COLOR_BLACK,
            .bg = COLOR_RED,
            .hint = "d Detach\xe2\x94\x82q Quit\xe2\x94\x82Esc Normal",
        },
        .locked => .{
            .label = " LOCKED ",
            .fg = COLOR_BLACK,
            .bg = COLOR_DARK_GREY,
            .hint = "Ctrl+g Unlock",
        },
    };
}

// ─── writeString ─────────────────────────────────────────────────────────────

/// Write UTF-8 text into `cells` starting at `offset.*`, advancing offset.
/// Each Unicode codepoint occupies one cell. Stops when text is exhausted
/// or when the cells slice is full. Invalid UTF-8 bytes are skipped.
pub fn writeString(
    cells: []render.Cell,
    offset: *u16,
    text: []const u8,
    fg: vt.Color,
    bg: vt.Color,
) void {
    var i: usize = 0;
    while (i < text.len) {
        if (offset.* >= cells.len) break;
        const cp_len = std.unicode.utf8ByteSequenceLength(text[i]) catch {
            i += 1;
            continue;
        };
        if (i + cp_len > text.len) break;
        const cp = std.unicode.utf8Decode(text[i .. i + cp_len]) catch {
            i += 1;
            continue;
        };
        const w = unicode_width.terminalDisplayWidth(cp);
        if (w == 0) {
            // Combining / VS / ZWJ — no cell in our model; skip (same as grid .print).
            i += cp_len;
            continue;
        }
        cells[offset.*] = render.Cell{
            .char = cp,
            .fg = fg,
            .bg = bg,
        };
        offset.* += 1;
        if (w == 2 and offset.* < cells.len) {
            cells[offset.*] = render.Cell{
                .char = 0,
                .fg = fg,
                .bg = bg,
            };
            offset.* += 1;
        }
        i += cp_len;
    }
}

// ─── renderStatusBar ─────────────────────────────────────────────────────────

/// Fill `cells` (one row, length == cols) with the status bar layout:
///   [mode label] [│] [key hints (dimmed)]
pub fn renderStatusBar(
    cells: []render.Cell,
    cols: u16,
    current_mode: mode_mod.Mode,
) void {
    // Fill entire row with background first.
    const safe_cols = @min(cols, @as(u16, @intCast(cells.len)));
    for (cells[0..safe_cols]) |*c| {
        c.* = render.Cell{ .char = ' ', .fg = .default, .bg = BAR_BG };
    }

    const info = modeInfo(current_mode);

    var offset: u16 = 0;

    // ── Left: mode label ─────────────────────────────────────────────────────
    writeString(cells, &offset, info.label, info.fg, info.bg);

    // ── Separator ─────────────────────────────────────────────────────────────
    writeString(cells, &offset, "\xe2\x94\x82", SEP_FG, BAR_BG);

    // ── Middle: key hints ─────────────────────────────────────────────────────
    writeString(cells, &offset, info.hint, HINT_FG, BAR_BG);
}

// ─── renderTabBar ─────────────────────────────────────────────────────────────

/// Fill `cells` (one row, length == cols) with the zellij-style tab bar:
///   Dark background, each tab as a "ribbon": ` TabName `
///   Active tab: green bg (idx 2) + black text
///   Inactive tab: dark grey bg (idx 8) + white text
pub fn renderTabBar(
    cells: []render.Cell,
    cols: u16,
    tab_names: []const []const u8,
    active_tab: u8,
) void {
    // Fill entire row with tab bar background first.
    const safe_cols = @min(cols, @as(u16, @intCast(cells.len)));
    for (cells[0..safe_cols]) |*c| {
        c.* = render.Cell{ .char = ' ', .fg = .default, .bg = TAB_BAR_BG };
    }

    var offset: u16 = 0;

    for (tab_names, 0..) |name, i| {
        const is_active = (i == @as(usize, active_tab));
        const tab_fg = if (is_active) TAB_ACTIVE_FG else TAB_INACTIVE_FG;
        const tab_bg = if (is_active) TAB_ACTIVE_BG else TAB_INACTIVE_BG;

        // Each tab: " name " with padding
        writeString(cells, &offset, " ", tab_fg, tab_bg);
        writeString(cells, &offset, name, tab_fg, tab_bg);
        writeString(cells, &offset, " ", tab_fg, tab_bg);

        // One space gap between tabs (on bar background)
        if (i + 1 < tab_names.len) {
            writeString(cells, &offset, " ", .default, TAB_BAR_BG);
        }

        if (offset >= safe_cols) break;
    }
}

// ─── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "renders mode indicator" {
    var cells: [80]render.Cell = undefined;
    renderStatusBar(&cells, 80, .normal);

    // First cell of NORMAL label should be ' ' with green background.
    const first = cells[0];
    try testing.expectEqual(@as(u21, ' '), first.char);
    switch (first.bg) {
        .idx => |i| try testing.expectEqual(@as(u8, 2), i), // green
        else => return error.WrongColor,
    }

    // Cells at positions 1..6 should spell "NORMAL".
    const expected = " NORMAL ";
    for (expected, 0..) |ch, idx| {
        try testing.expectEqual(@as(u21, ch), cells[idx].char);
        // All mode label cells share the same bg.
        switch (cells[idx].bg) {
            .idx => |i| try testing.expectEqual(@as(u8, 2), i),
            else => return error.WrongColor,
        }
    }
}

test "different modes have different hints" {
    var cells_normal: [120]render.Cell = undefined;
    var cells_pane: [120]render.Cell = undefined;

    renderStatusBar(&cells_normal, 120, .normal);
    renderStatusBar(&cells_pane, 120, .pane);

    // The hint text starts somewhere after the label.  Find the first cell
    // where the two renders differ — that position should be within the label
    // area (different label lengths → different backgrounds / text).
    // More robustly: check that the full rendered rows are not identical.
    var identical = true;
    for (cells_normal, 0..) |cn, idx| {
        if (!render.Cell.eql(cn, cells_pane[idx])) {
            identical = false;
            break;
        }
    }
    try testing.expect(!identical);

    // Also verify PANE-mode label contains 'P' somewhere in the label area.
    // PANE label: " PANE " — check for 'P' at offset 1.
    try testing.expectEqual(@as(u21, 'P'), cells_pane[1].char);
    // NORMAL label should have 'N' at offset 1.
    try testing.expectEqual(@as(u21, 'N'), cells_normal[1].char);
}

test "renderTabBar renders tab names" {
    var cells: [80]render.Cell = undefined;
    const tab_names = [_][]const u8{ "alpha", "beta" };
    renderTabBar(&cells, 80, &tab_names, 0);

    // Tab bar format: " alpha " " beta " with spaces between
    // Offset 0: ' ' (padding before alpha), offset 1-5: 'alpha', offset 6: ' '
    try testing.expectEqual(@as(u21, ' '), cells[0].char);
    try testing.expectEqual(@as(u21, 'a'), cells[1].char);
    try testing.expectEqual(@as(u21, 'l'), cells[2].char);
    try testing.expectEqual(@as(u21, 'p'), cells[3].char);
    try testing.expectEqual(@as(u21, 'h'), cells[4].char);
    try testing.expectEqual(@as(u21, 'a'), cells[5].char);
    try testing.expectEqual(@as(u21, ' '), cells[6].char);

    // Active tab (index 0 = "alpha") should use green background (idx 2).
    switch (cells[1].bg) {
        .idx => |i| try testing.expectEqual(@as(u8, 2), i), // TAB_ACTIVE_BG = green
        else => return error.WrongActiveTabColor,
    }
    // Active tab text should be black (idx 0).
    switch (cells[1].fg) {
        .idx => |i| try testing.expectEqual(@as(u8, 0), i),
        else => return error.WrongActiveTabFg,
    }

    // beta tab (inactive) should have dark grey background (idx 8).
    // beta starts at offset 8 (' ' gap at 7, then ' beta ')
    // Layout: " alpha " + " " + " beta "
    // 0: ' ', 1-5: alpha, 6: ' ', 7: gap-space, 8: ' ', 9-12: beta, 13: ' '
    switch (cells[9].bg) {
        .idx => |i| try testing.expectEqual(@as(u8, 8), i), // TAB_INACTIVE_BG
        else => return error.WrongInactiveTabColor,
    }
}

test "writeString wide CJK uses spacer cell" {
    var cells: [8]render.Cell = undefined;
    var off: u16 = 0;
    writeString(&cells, &off, "漢", COLOR_WHITE, BAR_BG);
    try testing.expectEqual(@as(u16, 2), off);
    try testing.expectEqual(@as(u21, 0x6F22), cells[0].char);
    try testing.expectEqual(@as(u21, 0), cells[1].char);
}

test "renderTabBar single tab" {
    var cells: [40]render.Cell = undefined;
    const tab_names = [_][]const u8{"Tab 1"};
    renderTabBar(&cells, 40, &tab_names, 0);

    // Single tab: " Tab 1 " starting at offset 0
    try testing.expectEqual(@as(u21, ' '), cells[0].char);
    try testing.expectEqual(@as(u21, 'T'), cells[1].char);
    try testing.expectEqual(@as(u21, 'a'), cells[2].char);
    try testing.expectEqual(@as(u21, 'b'), cells[3].char);
    // Active tab green background
    switch (cells[1].bg) {
        .idx => |i| try testing.expectEqual(@as(u8, 2), i),
        else => return error.WrongColor,
    }
}
