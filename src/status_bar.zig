const std = @import("std");
const render = @import("render.zig");
const mode_mod = @import("mode.zig");
const vt = @import("vt.zig");

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

// Default status bar background (dark grey / colour 0 for contrast).
const BAR_BG: vt.Color = .{ .idx = 0 };
// Dimmed hint text — bright black / dark grey foreground.
const HINT_FG: vt.Color = .{ .idx = 8 };
// Active tab highlight — white foreground, slightly lighter background.
const TAB_ACTIVE_FG: vt.Color = .{ .idx = 15 };
const TAB_ACTIVE_BG: vt.Color = .{ .idx = 8 };
const TAB_INACTIVE_FG: vt.Color = .{ .idx = 7 };

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
            .hint = "Ctrl+p:PANE | Ctrl+t:TAB | Ctrl+s:SCROLL | Ctrl+o:SESSION",
        },
        .pane => .{
            .label = " PANE ",
            .fg = COLOR_BLACK,
            .bg = COLOR_BLUE,
            .hint = "h/j/k/l:focus | H/J/K/L:resize | n:split-h | v:split-v | x:close",
        },
        .tab => .{
            .label = " TAB ",
            .fg = COLOR_BLACK,
            .bg = COLOR_MAGENTA,
            .hint = "h/l:switch | n:new | x:close | r:rename",
        },
        .scroll => .{
            .label = " SCROLL ",
            .fg = COLOR_BLACK,
            .bg = COLOR_YELLOW,
            .hint = "j/k:line | u/d:page",
        },
        .session => .{
            .label = " SESSION ",
            .fg = COLOR_BLACK,
            .bg = COLOR_RED,
            .hint = "d:detach | q:quit",
        },
        .locked => .{
            .label = " LOCKED ",
            .fg = COLOR_BLACK,
            .bg = COLOR_DARK_GREY,
            .hint = "Ctrl+g to unlock",
        },
    };
}

// ─── writeString ─────────────────────────────────────────────────────────────

/// Write ASCII text into `cells` starting at `offset.*`, advancing offset.
/// Stops when the text is exhausted or when the cells slice is full.
pub fn writeString(
    cells: []render.Cell,
    offset: *u16,
    text: []const u8,
    fg: vt.Color,
    bg: vt.Color,
) void {
    for (text) |ch| {
        if (offset.* >= cells.len) break;
        cells[offset.*] = render.Cell{
            .char = ch,
            .fg = fg,
            .bg = bg,
        };
        offset.* += 1;
    }
}

// ─── renderStatusBar ─────────────────────────────────────────────────────────

/// Fill `cells` (one row, length == cols) with the status bar layout:
///   [mode label] [key hints (dimmed)] ... [tab list (right)]
pub fn renderStatusBar(
    cells: []render.Cell,
    cols: u16,
    current_mode: mode_mod.Mode,
    tab_names: []const []const u8,
    active_tab: u8,
) void {
    // Fill entire row with background first.
    for (cells[0..cols]) |*c| {
        c.* = render.Cell{ .char = ' ', .fg = .default, .bg = BAR_BG };
    }

    const info = modeInfo(current_mode);

    var offset: u16 = 0;

    // ── Left: mode label ─────────────────────────────────────────────────────
    writeString(cells, &offset, info.label, info.fg, info.bg);

    // ── Middle: key hints ─────────────────────────────────────────────────────
    // One space separator, then the hint string.
    writeString(cells, &offset, " ", HINT_FG, BAR_BG);
    writeString(cells, &offset, info.hint, HINT_FG, BAR_BG);

    // ── Right: tab list ───────────────────────────────────────────────────────
    // Build the tab list string length to figure out where to start.
    // Each tab: "[name]" with a space between tabs and one trailing space.
    // We write it right-aligned by computing total width first.

    // Compute right-section width.
    var right_width: u16 = 0;
    for (tab_names, 0..) |name, i| {
        right_width += 1; // '['
        right_width += @intCast(name.len);
        right_width += 1; // ']'
        if (i + 1 < tab_names.len) right_width += 1; // space between
    }
    if (right_width > 0) right_width += 1; // leading space margin

    // Only render tabs if they fit.
    if (right_width > 0 and right_width <= cols) {
        var tab_offset: u16 = cols - right_width;
        // Leading margin space.
        writeString(cells, &tab_offset, " ", .default, BAR_BG);
        for (tab_names, 0..) |name, i| {
            const is_active = (i == @as(usize, active_tab));
            const tab_fg = if (is_active) TAB_ACTIVE_FG else TAB_INACTIVE_FG;
            const tab_bg = if (is_active) TAB_ACTIVE_BG else BAR_BG;
            writeString(cells, &tab_offset, "[", tab_fg, tab_bg);
            writeString(cells, &tab_offset, name, tab_fg, tab_bg);
            writeString(cells, &tab_offset, "]", tab_fg, tab_bg);
            if (i + 1 < tab_names.len) {
                writeString(cells, &tab_offset, " ", .default, BAR_BG);
            }
        }
    }
}

// ─── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "renders mode indicator" {
    var cells: [80]render.Cell = undefined;
    renderStatusBar(&cells, 80, .normal, &[_][]const u8{}, 0);

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

    renderStatusBar(&cells_normal, 120, .normal, &[_][]const u8{}, 0);
    renderStatusBar(&cells_pane, 120, .pane, &[_][]const u8{}, 0);

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

test "tab list rendered" {
    var cells: [80]render.Cell = undefined;
    const tab_names = [_][]const u8{ "alpha", "beta" };
    renderStatusBar(&cells, 80, .normal, &tab_names, 0);

    // Scan cells for '[' characters that begin a tab entry.
    var found_alpha = false;
    var found_beta = false;
    var i: usize = 0;
    while (i < 80) : (i += 1) {
        if (cells[i].char == '[') {
            // Check if next chars spell a known tab name.
            if (i + 5 < 80 and
                cells[i + 1].char == 'a' and
                cells[i + 2].char == 'l' and
                cells[i + 3].char == 'p' and
                cells[i + 4].char == 'h' and
                cells[i + 5].char == 'a')
            {
                found_alpha = true;
            }
            if (i + 4 < 80 and
                cells[i + 1].char == 'b' and
                cells[i + 2].char == 'e' and
                cells[i + 3].char == 't' and
                cells[i + 4].char == 'a')
            {
                found_beta = true;
            }
        }
    }

    try testing.expect(found_alpha);
    try testing.expect(found_beta);

    // Active tab (index 0 = "alpha") should use the active highlight bg.
    // Find the '[' before "alpha" and check its bg.
    var alpha_bracket_idx: usize = 0;
    i = 0;
    while (i < 80) : (i += 1) {
        if (cells[i].char == '[' and i + 5 < 80 and
            cells[i + 1].char == 'a' and cells[i + 2].char == 'l')
        {
            alpha_bracket_idx = i;
            break;
        }
    }
    switch (cells[alpha_bracket_idx].bg) {
        .idx => |idx_val| try testing.expectEqual(@as(u8, 8), idx_val), // TAB_ACTIVE_BG
        else => return error.WrongActiveTabColor,
    }
}
