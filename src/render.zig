const std = @import("std");
const vt = @import("vt.zig");
const pane_mod = @import("pane.zig");

// ─── Cell ─────────────────────────────────────────────────────────────────────

pub const Cell = struct {
    char: u21 = ' ',
    fg: vt.Color = .default,
    bg: vt.Color = .default,
    attr: vt.Attr = .{},

    pub fn eql(a: Cell, b: Cell) bool {
        return a.char == b.char and
            std.meta.eql(a.fg, b.fg) and
            std.meta.eql(a.bg, b.bg) and
            @as(u8, @bitCast(a.attr)) == @as(u8, @bitCast(b.attr));
    }
};

// ─── DirtyRegion ──────────────────────────────────────────────────────────────

pub const DirtyRegion = struct {
    row: u16,
    col: u16,
    cells: []const Cell,
};

// ─── Screen ───────────────────────────────────────────────────────────────────

pub const Screen = struct {
    front: []Cell,
    back: []Cell,
    cols: u16,
    rows: u16,
    allocator: std.mem.Allocator,

    /// Allocate front and back buffers, fill with blank cells.
    pub fn init(allocator: std.mem.Allocator, cols: u16, rows: u16) !Screen {
        const len = @as(usize, cols) * @as(usize, rows);
        const front = try allocator.alloc(Cell, len);
        errdefer allocator.free(front);
        const back = try allocator.alloc(Cell, len);
        errdefer allocator.free(back);

        const blank = Cell{};
        @memset(front, blank);
        @memset(back, blank);

        return Screen{
            .front = front,
            .back = back,
            .cols = cols,
            .rows = rows,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Screen) void {
        self.allocator.free(self.front);
        self.allocator.free(self.back);
    }

    /// Reallocate both buffers for new dimensions.  Content is cleared.
    pub fn resize(self: *Screen, cols: u16, rows: u16) !void {
        const len = @as(usize, cols) * @as(usize, rows);
        const new_front = try self.allocator.alloc(Cell, len);
        errdefer self.allocator.free(new_front);
        const new_back = try self.allocator.alloc(Cell, len);

        const blank = Cell{};
        @memset(new_front, blank);
        @memset(new_back, blank);

        self.allocator.free(self.front);
        self.allocator.free(self.back);
        self.front = new_front;
        self.back = new_back;
        self.cols = cols;
        self.rows = rows;
    }

    /// Get a pointer to a mutable cell in the back buffer.
    pub fn cellAt(self: *Screen, row: u16, col: u16) *Cell {
        return &self.back[@as(usize, row) * @as(usize, self.cols) + @as(usize, col)];
    }

    /// Fill the back buffer with blank cells.
    pub fn clear(self: *Screen) void {
        @memset(self.back, Cell{});
    }

    /// Draw a box border around `region` using box-drawing characters.
    /// Active pane border is rendered with a brighter/colored style.
    pub fn drawBorder(self: *Screen, region: pane_mod.Region, is_active: bool) void {
        self.drawBorderWithTitle(region, "", is_active);
    }

    /// Draw a zellij-style pane frame with a title in the top line.
    /// Top line: ┌ Title ──────────┐
    /// Sides:    │                 │
    /// Bottom:   └─────────────────┘
    /// Active pane border is green (idx 2), inactive is dark grey (idx 8).
    pub fn drawBorderWithTitle(self: *Screen, region: pane_mod.Region, title: []const u8, is_active: bool) void {
        // Nothing to draw if the region has no border space.
        if (region.rows < 2 or region.cols < 2) return;

        const border_fg: vt.Color = if (is_active)
            vt.Color{ .idx = 2 } // green for active (zellij style)
        else
            vt.Color{ .idx = 8 }; // dark grey for inactive

        const title_fg: vt.Color = if (is_active)
            vt.Color{ .idx = 15 } // bright white for active title
        else
            vt.Color{ .idx = 7 }; // white for inactive title

        const attr = vt.Attr{};

        const r_top = region.row;
        const r_bot = region.row + region.rows - 1;
        const c_left = region.col;
        const c_right = region.col + region.cols - 1;

        // Guard: ensure coordinates are within screen bounds.
        if (r_bot >= self.rows or c_right >= self.cols) return;

        // Corners
        self.cellAt(r_top, c_left).* = Cell{ .char = '┌', .fg = border_fg, .attr = attr };
        self.cellAt(r_top, c_right).* = Cell{ .char = '┐', .fg = border_fg, .attr = attr };
        self.cellAt(r_bot, c_left).* = Cell{ .char = '└', .fg = border_fg, .attr = attr };
        self.cellAt(r_bot, c_right).* = Cell{ .char = '┘', .fg = border_fg, .attr = attr };

        // Top edge: ┌ Title ──────────┐
        // Layout: c_left+1 = ' ', c_left+2 = title chars, then ' ', then '─' fill
        const inner_width: u16 = if (c_right > c_left + 1) c_right - c_left - 1 else 0;

        if (inner_width > 0 and title.len > 0) {
            // Write: space + title + space + dashes to fill
            var c: u16 = c_left + 1;

            // Leading space before title
            if (c < c_right) {
                self.cellAt(r_top, c).* = Cell{ .char = ' ', .fg = border_fg, .attr = attr };
                c += 1;
            }

            // Title text (truncated to fit, leaving room for trailing space + at least one dash)
            const max_title = if (inner_width > 3) inner_width - 3 else 0;
            const title_len: u16 = @intCast(@min(title.len, max_title));
            var ti: u16 = 0;
            while (ti < title_len and c < c_right) : (ti += 1) {
                self.cellAt(r_top, c).* = Cell{ .char = title[ti], .fg = title_fg, .attr = attr };
                c += 1;
            }

            // Trailing space after title (only if title was written)
            if (title_len > 0 and c < c_right) {
                self.cellAt(r_top, c).* = Cell{ .char = ' ', .fg = border_fg, .attr = attr };
                c += 1;
            }

            // Fill remainder with dashes
            while (c < c_right) : (c += 1) {
                self.cellAt(r_top, c).* = Cell{ .char = '─', .fg = border_fg, .attr = attr };
            }
        } else {
            // No title: just dashes
            var c: u16 = c_left + 1;
            while (c < c_right) : (c += 1) {
                self.cellAt(r_top, c).* = Cell{ .char = '─', .fg = border_fg, .attr = attr };
            }
        }

        // Bottom edge: all dashes
        var c: u16 = c_left + 1;
        while (c < c_right) : (c += 1) {
            self.cellAt(r_bot, c).* = Cell{ .char = '─', .fg = border_fg, .attr = attr };
        }

        // Left and right edges
        var r: u16 = r_top + 1;
        while (r < r_bot) : (r += 1) {
            self.cellAt(r, c_left).* = Cell{ .char = '│', .fg = border_fg, .attr = attr };
            self.cellAt(r, c_right).* = Cell{ .char = '│', .fg = border_fg, .attr = attr };
        }
    }

    /// Copy back buffer to front buffer (call after dirty regions have been sent).
    pub fn swapBuffers(self: *Screen) void {
        @memcpy(self.front, self.back);
    }

    /// Compare front and back buffers row by row.
    /// Returns a slice of DirtyRegion for each contiguous run of changed cells.
    /// Caller owns the returned slice AND each region's cells slice.
    pub fn getDirtyRegions(self: *Screen, allocator: std.mem.Allocator) ![]DirtyRegion {
        var regions: std.ArrayList(DirtyRegion) = .{};
        errdefer {
            for (regions.items) |dr| allocator.free(dr.cells);
            regions.deinit(allocator);
        }

        var row: u16 = 0;
        while (row < self.rows) : (row += 1) {
            const row_offset = @as(usize, row) * @as(usize, self.cols);

            var col: u16 = 0;
            while (col < self.cols) {
                // Find start of a dirty run.
                if (Cell.eql(
                    self.front[row_offset + col],
                    self.back[row_offset + col],
                )) {
                    col += 1;
                    continue;
                }

                // Start of a dirty run at `col`.
                const run_start = col;
                col += 1;

                // Extend the run as far as cells differ.
                while (col < self.cols and !Cell.eql(
                    self.front[row_offset + col],
                    self.back[row_offset + col],
                )) : (col += 1) {}

                // `col` is now one past the last dirty cell.
                const run_len = col - run_start;
                const cells_copy = try allocator.dupe(
                    Cell,
                    self.back[row_offset + run_start .. row_offset + run_start + run_len],
                );
                try regions.append(allocator, .{
                    .row = row,
                    .col = run_start,
                    .cells = cells_copy,
                });
            }
        }

        return regions.toOwnedSlice(allocator);
    }
};

// ─── serializeCell ────────────────────────────────────────────────────────────

/// Write a single Cell as terminal escape sequences (SGR + UTF-8 codepoint).
pub fn serializeCell(cell: Cell, writer: anytype) !void {
    // Build SGR: reset, then apply fg, bg, attr.
    try writer.writeAll("\x1b[0");

    // Foreground
    switch (cell.fg) {
        .default => {},
        .idx => |i| {
            if (i < 8) {
                try writer.print(";{d}", .{30 + i});
            } else if (i < 16) {
                try writer.print(";{d}", .{90 + (i - 8)});
            } else {
                try writer.print(";38;5;{d}", .{i});
            }
        },
        .rgb => |c| try writer.print(";38;2;{d};{d};{d}", .{ c.r, c.g, c.b }),
    }

    // Background
    switch (cell.bg) {
        .default => {},
        .idx => |i| {
            if (i < 8) {
                try writer.print(";{d}", .{40 + i});
            } else if (i < 16) {
                try writer.print(";{d}", .{100 + (i - 8)});
            } else {
                try writer.print(";48;5;{d}", .{i});
            }
        },
        .rgb => |c| try writer.print(";48;2;{d};{d};{d}", .{ c.r, c.g, c.b }),
    }

    // Attributes
    const a = cell.attr;
    if (a.bold) try writer.writeAll(";1");
    if (a.dim) try writer.writeAll(";2");
    if (a.italic) try writer.writeAll(";3");
    if (a.underline) try writer.writeAll(";4");
    if (a.blink) try writer.writeAll(";5");
    if (a.inverse) try writer.writeAll(";7");
    if (a.hidden) try writer.writeAll(";8");
    if (a.strikethrough) try writer.writeAll(";9");

    try writer.writeByte('m');

    // UTF-8 encode the codepoint.
    var buf: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(cell.char, &buf) catch {
        // Fallback to replacement character on encode failure.
        try writer.writeAll("\xef\xbf\xbd");
        return;
    };
    try writer.writeAll(buf[0..len]);
}

// ─── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "init creates blank screen" {
    var screen = try Screen.init(testing.allocator, 80, 24);
    defer screen.deinit();

    // Every cell in both buffers should be the default blank cell.
    const blank = Cell{};
    for (screen.back) |c| {
        try testing.expect(Cell.eql(c, blank));
    }
    for (screen.front) |c| {
        try testing.expect(Cell.eql(c, blank));
    }
}

test "cellAt and modification" {
    var screen = try Screen.init(testing.allocator, 80, 24);
    defer screen.deinit();

    const cell_ptr = screen.cellAt(5, 10);
    cell_ptr.* = Cell{ .char = 'X', .fg = .{ .idx = 1 } };

    const got = screen.cellAt(5, 10).*;
    try testing.expectEqual(@as(u21, 'X'), got.char);
    switch (got.fg) {
        .idx => |i| try testing.expectEqual(@as(u8, 1), i),
        else => return error.WrongColor,
    }

    // Other cells remain blank.
    try testing.expect(Cell.eql(screen.cellAt(0, 0).*, Cell{}));
}

test "dirty region detection" {
    var screen = try Screen.init(testing.allocator, 80, 24);
    defer screen.deinit();

    // Modify cells at row 3, cols 5..7 (inclusive) in back buffer.
    screen.cellAt(3, 5).* = Cell{ .char = 'A' };
    screen.cellAt(3, 6).* = Cell{ .char = 'B' };
    screen.cellAt(3, 7).* = Cell{ .char = 'C' };

    const regions = try screen.getDirtyRegions(testing.allocator);
    defer {
        for (regions) |dr| testing.allocator.free(dr.cells);
        testing.allocator.free(regions);
    }

    try testing.expectEqual(@as(usize, 1), regions.len);
    try testing.expectEqual(@as(u16, 3), regions[0].row);
    try testing.expectEqual(@as(u16, 5), regions[0].col);
    try testing.expectEqual(@as(usize, 3), regions[0].cells.len);
    try testing.expectEqual(@as(u21, 'A'), regions[0].cells[0].char);
    try testing.expectEqual(@as(u21, 'B'), regions[0].cells[1].char);
    try testing.expectEqual(@as(u21, 'C'), regions[0].cells[2].char);
}

test "no dirty regions when buffers match" {
    var screen = try Screen.init(testing.allocator, 80, 24);
    defer screen.deinit();

    // Modify back buffer, then swap so they match.
    screen.cellAt(0, 0).* = Cell{ .char = 'Z' };
    screen.swapBuffers();

    const regions = try screen.getDirtyRegions(testing.allocator);
    defer {
        for (regions) |dr| testing.allocator.free(dr.cells);
        testing.allocator.free(regions);
    }

    try testing.expectEqual(@as(usize, 0), regions.len);
}

test "drawBorder" {
    // Screen big enough to hold a border + interior.
    var screen = try Screen.init(testing.allocator, 20, 10);
    defer screen.deinit();

    const region = pane_mod.Region{ .row = 1, .col = 2, .rows = 5, .cols = 8 };
    screen.drawBorder(region, false);

    const r_top = region.row;
    const r_bot = region.row + region.rows - 1;
    const c_left = region.col;
    const c_right = region.col + region.cols - 1;

    // Corners
    try testing.expectEqual(@as(u21, '┌'), screen.cellAt(r_top, c_left).char);
    try testing.expectEqual(@as(u21, '┐'), screen.cellAt(r_top, c_right).char);
    try testing.expectEqual(@as(u21, '└'), screen.cellAt(r_bot, c_left).char);
    try testing.expectEqual(@as(u21, '┘'), screen.cellAt(r_bot, c_right).char);

    // Top edge (not corners) — no title so all dashes
    try testing.expectEqual(@as(u21, '─'), screen.cellAt(r_top, c_left + 1).char);
    try testing.expectEqual(@as(u21, '─'), screen.cellAt(r_top, c_right - 1).char);

    // Left and right edges (not corners)
    try testing.expectEqual(@as(u21, '│'), screen.cellAt(r_top + 1, c_left).char);
    try testing.expectEqual(@as(u21, '│'), screen.cellAt(r_top + 1, c_right).char);

    // Interior cell is untouched.
    try testing.expect(Cell.eql(screen.cellAt(r_top + 1, c_left + 1).*, Cell{}));
}

test "drawBorderWithTitle" {
    // Screen big enough for a titled border.
    var screen = try Screen.init(testing.allocator, 30, 10);
    defer screen.deinit();

    // region cols=16: inner_width=14, title "fish" len=4
    // Layout: ┌ fish ──────┐
    const region = pane_mod.Region{ .row = 0, .col = 0, .rows = 5, .cols = 16 };
    screen.drawBorderWithTitle(region, "fish", true);

    const r_top = region.row;
    const r_bot = region.row + region.rows - 1;
    const c_left = region.col;
    const c_right = region.col + region.cols - 1;

    // Corners
    try testing.expectEqual(@as(u21, '┌'), screen.cellAt(r_top, c_left).char);
    try testing.expectEqual(@as(u21, '┐'), screen.cellAt(r_top, c_right).char);
    try testing.expectEqual(@as(u21, '└'), screen.cellAt(r_bot, c_left).char);
    try testing.expectEqual(@as(u21, '┘'), screen.cellAt(r_bot, c_right).char);

    // After ┌: space, then 'f','i','s','h', then space, then dashes
    try testing.expectEqual(@as(u21, ' '), screen.cellAt(r_top, c_left + 1).char);
    try testing.expectEqual(@as(u21, 'f'), screen.cellAt(r_top, c_left + 2).char);
    try testing.expectEqual(@as(u21, 'i'), screen.cellAt(r_top, c_left + 3).char);
    try testing.expectEqual(@as(u21, 's'), screen.cellAt(r_top, c_left + 4).char);
    try testing.expectEqual(@as(u21, 'h'), screen.cellAt(r_top, c_left + 5).char);
    try testing.expectEqual(@as(u21, ' '), screen.cellAt(r_top, c_left + 6).char);
    // After the title+space, rest should be dashes up to corner
    try testing.expectEqual(@as(u21, '─'), screen.cellAt(r_top, c_right - 1).char);

    // Active border should be green (idx 2)
    switch (screen.cellAt(r_top, c_left).fg) {
        .idx => |i| try testing.expectEqual(@as(u8, 2), i),
        else => return error.WrongActiveColor,
    }

    // Left/right side edges
    try testing.expectEqual(@as(u21, '│'), screen.cellAt(r_top + 1, c_left).char);
    try testing.expectEqual(@as(u21, '│'), screen.cellAt(r_top + 1, c_right).char);

    // Interior untouched
    try testing.expect(Cell.eql(screen.cellAt(r_top + 1, c_left + 1).*, Cell{}));
}
