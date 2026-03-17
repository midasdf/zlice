const std = @import("std");
const vt = @import("vt.zig");
const Cell = vt.Cell;

// ─── Row ─────────────────────────────────────────────────────────────────────

pub const Row = struct {
    cells: []Cell,
    is_canonical: bool, // true = real newline / first row, false = soft-wrapped continuation

    pub fn init(allocator: std.mem.Allocator, cols: u16, canonical: bool) !Row {
        const cells = try allocator.alloc(Cell, cols);
        @memset(cells, Cell{});
        return Row{
            .cells = cells,
            .is_canonical = canonical,
        };
    }

    pub fn deinit(self: *Row, allocator: std.mem.Allocator) void {
        if (self.cells.len > 0) {
            allocator.free(self.cells);
        }
        self.cells = &.{};
    }

    /// Return index of last non-space cell + 1 (content length without trailing spaces).
    pub fn contentLen(self: *const Row) usize {
        var i: usize = self.cells.len;
        while (i > 0) {
            if (self.cells[i - 1].char != ' ' or
                !std.meta.eql(self.cells[i - 1].fg, vt.Color.default) or
                !std.meta.eql(self.cells[i - 1].bg, vt.Color.default) or
                @as(u8, @bitCast(self.cells[i - 1].attr)) != 0)
            {
                break;
            }
            i -= 1;
        }
        return i;
    }
};

// ─── Grid ────────────────────────────────────────────────────────────────────

pub const Grid = struct {
    allocator: std.mem.Allocator,
    rows: std.ArrayListUnmanaged(Row),
    cols: u16,
    viewport_rows: u16,
    cursor_row: u16 = 0,
    cursor_col: u16 = 0,

    // Current drawing pen
    pen_fg: vt.Color = .default,
    pen_bg: vt.Color = .default,
    pen_attr: vt.Attr = .{},

    // Alternate screen support
    saved_main_rows: ?[]Row = null,
    saved_cursor_row: u16 = 0,
    saved_cursor_col: u16 = 0,
    in_alt_screen: bool = false,

    pub fn init(allocator: std.mem.Allocator, cols: u16, viewport_rows: u16) !Grid {
        var rows: std.ArrayListUnmanaged(Row) = .{};
        errdefer {
            for (rows.items) |*r| r.deinit(allocator);
            rows.deinit(allocator);
        }
        // Initialize with viewport_rows canonical rows
        var i: u16 = 0;
        while (i < viewport_rows) : (i += 1) {
            try rows.append(allocator, try Row.init(allocator, cols, true));
        }
        return Grid{
            .allocator = allocator,
            .rows = rows,
            .cols = cols,
            .viewport_rows = viewport_rows,
        };
    }

    pub fn deinit(self: *Grid) void {
        for (self.rows.items) |*r| r.deinit(self.allocator);
        self.rows.deinit(self.allocator);
        if (self.saved_main_rows) |saved| {
            for (saved) |*r| {
                var row = r.*;
                row.deinit(self.allocator);
            }
            self.allocator.free(saved);
        }
    }

    /// Get a cell at a specific viewport position. Returns blank cell if out of bounds.
    /// Get a cell from the visible viewport. Row 0 is the top of the viewport.
    /// When rows.len > viewport_rows, the viewport is the last viewport_rows rows.
    pub fn getCell(self: *const Grid, row: u16, col: u16) Cell {
        const total: usize = self.rows.items.len;
        const viewport_start: usize = if (total > self.viewport_rows) total - self.viewport_rows else 0;
        const actual_row: usize = viewport_start + row;
        if (actual_row >= total or col >= self.cols) return Cell{};
        const r = self.rows.items[actual_row];
        if (col >= r.cells.len) return Cell{};
        return r.cells[col];
    }

    pub fn getCols(self: *const Grid) u16 {
        return self.cols;
    }

    pub fn getRows(self: *const Grid) u16 {
        return self.viewport_rows;
    }

    // ── Apply VT Event ───────────────────────────────────────────────────────

    /// Apply a VT event. Returns an optional CPR response to write to the PTY.
    pub fn applyEvent(self: *Grid, ev: vt.Event) ?CprResponse {
        switch (ev) {
            .print => |ch| {
                if (self.cursor_row >= self.rows.items.len) return null;
                // Auto-wrap: if cursor is at right margin, wrap to next line
                if (self.cursor_col >= self.cols) {
                    self.cursor_col = 0;
                    self.cursor_row +|= 1;
                    if (self.cursor_row >= self.rows.items.len) {
                        self.cursor_row = @intCast(self.rows.items.len - 1);
                        self.scrollUp(1);
                    }
                    // Mark this new row as wrapped (non-canonical)
                    if (self.cursor_row < self.rows.items.len) {
                        self.rows.items[self.cursor_row].is_canonical = false;
                    }
                }
                const r = &self.rows.items[self.cursor_row];
                if (self.cursor_col < r.cells.len) {
                    r.cells[self.cursor_col] = .{
                        .char = ch,
                        .fg = self.pen_fg,
                        .bg = self.pen_bg,
                        .attr = self.pen_attr,
                    };
                }
                self.cursor_col += 1;
            },
            .cursor_pos => |cp| {
                self.cursor_row = @min(cp.row, @as(u16, @intCast(self.rows.items.len)) -| 1);
                self.cursor_col = @min(cp.col, self.cols -| 1);
            },
            .cursor_move => |cm| {
                const new_row: i32 = @as(i32, self.cursor_row) + cm.row;
                const new_col: i32 = @as(i32, self.cursor_col) + cm.col;
                self.cursor_row = @intCast(@max(0, @min(new_row, @as(i32, @intCast(self.rows.items.len)) - 1)));
                self.cursor_col = @intCast(@max(0, @min(new_col, @as(i32, self.cols) - 1)));
            },
            .linefeed => {
                self.cursor_row +|= 1;
                if (self.cursor_row >= self.rows.items.len) {
                    self.cursor_row = @intCast(self.rows.items.len - 1);
                    self.scrollUp(1);
                }
                // The row we landed on after a linefeed is canonical
                if (self.cursor_row < self.rows.items.len) {
                    self.rows.items[self.cursor_row].is_canonical = true;
                }
            },
            .carriage_return => {
                self.cursor_col = 0;
            },
            .backspace => {
                if (self.cursor_col > 0) self.cursor_col -= 1;
            },
            .erase_display => |mode| {
                switch (mode) {
                    0 => {
                        if (self.cursor_row < self.rows.items.len) {
                            const r = &self.rows.items[self.cursor_row];
                            if (self.cursor_col < r.cells.len) {
                                @memset(r.cells[self.cursor_col..], Cell{});
                            }
                        }
                        var i: usize = self.cursor_row + 1;
                        while (i < self.rows.items.len) : (i += 1) {
                            @memset(self.rows.items[i].cells, Cell{});
                        }
                    },
                    1 => {
                        var i: usize = 0;
                        while (i < self.cursor_row) : (i += 1) {
                            @memset(self.rows.items[i].cells, Cell{});
                        }
                        if (self.cursor_row < self.rows.items.len) {
                            const r = &self.rows.items[self.cursor_row];
                            const end = @min(@as(usize, self.cursor_col) + 1, r.cells.len);
                            @memset(r.cells[0..end], Cell{});
                        }
                    },
                    2 => {
                        for (self.rows.items) |*r| {
                            @memset(r.cells, Cell{});
                        }
                    },
                    else => {},
                }
            },
            .erase_line => |mode| {
                if (self.cursor_row >= self.rows.items.len) return null;
                const r = &self.rows.items[self.cursor_row];
                switch (mode) {
                    0 => {
                        if (self.cursor_col < r.cells.len) {
                            @memset(r.cells[self.cursor_col..], Cell{});
                        }
                    },
                    1 => {
                        const end = @min(@as(usize, self.cursor_col) + 1, r.cells.len);
                        @memset(r.cells[0..end], Cell{});
                    },
                    2 => {
                        @memset(r.cells, Cell{});
                    },
                    else => {},
                }
            },
            .scroll_up => |n| self.scrollUp(n),
            .scroll_down => |n| self.scrollDown(n),
            .insert_lines => |n| {
                const max_row: u16 = @intCast(self.rows.items.len);
                const count = @min(n, max_row - self.cursor_row);
                if (count == 0) return null;
                var dst_row_i: isize = @as(isize, max_row) - 1;
                const count_i: isize = @intCast(count);
                while (dst_row_i >= @as(isize, self.cursor_row) + count_i) : (dst_row_i -= 1) {
                    const src_idx: usize = @intCast(dst_row_i - count_i);
                    const dst_idx: usize = @intCast(dst_row_i);
                    const tmp = self.rows.items[dst_idx].cells;
                    self.rows.items[dst_idx].cells = self.rows.items[src_idx].cells;
                    self.rows.items[src_idx].cells = tmp;
                    self.rows.items[dst_idx].is_canonical = self.rows.items[src_idx].is_canonical;
                }
                var i: u16 = 0;
                while (i < count) : (i += 1) {
                    const idx = self.cursor_row + i;
                    if (idx < self.rows.items.len) {
                        @memset(self.rows.items[idx].cells, Cell{});
                        self.rows.items[idx].is_canonical = true;
                    }
                }
            },
            .delete_lines => |n| {
                const max_row: u16 = @intCast(self.rows.items.len);
                const count = @min(n, max_row - self.cursor_row);
                if (count == 0) return null;
                const move_rows = max_row - self.cursor_row - count;
                if (move_rows > 0) {
                    var i: u16 = 0;
                    while (i < move_rows) : (i += 1) {
                        const src_idx: usize = self.cursor_row + count + i;
                        const dst_idx: usize = self.cursor_row + i;
                        const tmp = self.rows.items[dst_idx].cells;
                        self.rows.items[dst_idx].cells = self.rows.items[src_idx].cells;
                        self.rows.items[src_idx].cells = tmp;
                        self.rows.items[dst_idx].is_canonical = self.rows.items[src_idx].is_canonical;
                    }
                }
                var i: u16 = max_row - count;
                while (i < max_row) : (i += 1) {
                    @memset(self.rows.items[i].cells, Cell{});
                    self.rows.items[i].is_canonical = true;
                }
            },
            .sgr => |params| {
                if (params.reset) {
                    self.pen_fg = .default;
                    self.pen_bg = .default;
                    self.pen_attr = .{};
                }
                if (params.fg) |fg| self.pen_fg = fg;
                if (params.bg) |bg| self.pen_bg = bg;
                if (params.attr) |attr| {
                    if (attr.bold) self.pen_attr.bold = true;
                    if (attr.dim) self.pen_attr.dim = true;
                    if (attr.italic) self.pen_attr.italic = true;
                    if (attr.underline) self.pen_attr.underline = true;
                    if (attr.blink) self.pen_attr.blink = true;
                    if (attr.inverse) self.pen_attr.inverse = true;
                    if (attr.hidden) self.pen_attr.hidden = true;
                    if (attr.strikethrough) self.pen_attr.strikethrough = true;
                }
            },
            .alt_screen => |enter| {
                if (enter and !self.in_alt_screen) {
                    self.saved_cursor_row = self.cursor_row;
                    self.saved_cursor_col = self.cursor_col;
                    const saved = self.allocator.alloc(Row, self.rows.items.len) catch return null;
                    for (self.rows.items, 0..) |r, i| {
                        const new_cells = self.allocator.alloc(Cell, r.cells.len) catch {
                            var j: usize = 0;
                            while (j < i) : (j += 1) {
                                self.allocator.free(saved[j].cells);
                            }
                            self.allocator.free(saved);
                            return null;
                        };
                        @memcpy(new_cells, r.cells);
                        saved[i] = Row{ .cells = new_cells, .is_canonical = r.is_canonical };
                    }
                    if (self.saved_main_rows) |old_saved| {
                        for (old_saved) |*r| {
                            var row = r.*;
                            row.deinit(self.allocator);
                        }
                        self.allocator.free(old_saved);
                    }
                    self.saved_main_rows = saved;
                    for (self.rows.items) |*r| {
                        @memset(r.cells, Cell{});
                        r.is_canonical = true;
                    }
                    self.cursor_row = 0;
                    self.cursor_col = 0;
                    self.in_alt_screen = true;
                } else if (!enter and self.in_alt_screen) {
                    if (self.saved_main_rows) |saved| {
                        for (self.rows.items) |*r| r.deinit(self.allocator);
                        self.rows.clearRetainingCapacity();
                        var restore_failed = false;
                        for (saved, 0..) |r, idx| {
                            self.rows.append(self.allocator, r) catch {
                                // OOM: deinit this row and all remaining saved rows
                                var rr = r;
                                rr.deinit(self.allocator);
                                var j = idx + 1;
                                while (j < saved.len) : (j += 1) {
                                    var rem = saved[j];
                                    rem.deinit(self.allocator);
                                }
                                restore_failed = true;
                                break;
                            };
                        }
                        self.allocator.free(saved);
                        self.saved_main_rows = null;
                        if (restore_failed) {
                            // Ensure at least one row exists
                            if (self.rows.items.len == 0) {
                                const blank = Row.init(self.allocator, self.cols, true) catch return null;
                                self.rows.append(self.allocator, blank) catch return null;
                            }
                        }
                    }
                    self.cursor_row = self.saved_cursor_row;
                    self.cursor_col = self.saved_cursor_col;
                    self.in_alt_screen = false;
                    self.pen_fg = .default;
                    self.pen_bg = .default;
                    self.pen_attr = .{};
                }
            },
            .cursor_position_report => {
                return CprResponse{
                    .row = self.cursor_row + 1,
                    .col = self.cursor_col + 1,
                };
            },
            .set_title => return null, // handled externally
            else => {},
        }
        return null;
    }

    // ── Scroll helpers ───────────────────────────────────────────────────────

    fn scrollUp(self: *Grid, n: u16) void {
        const total: u16 = @intCast(self.rows.items.len);
        const count = @min(n, total);
        if (count == 0) return;

        var i: u16 = 0;
        while (i < count) : (i += 1) {
            self.rows.items[i].deinit(self.allocator);
        }

        const remaining = total - count;
        if (remaining > 0) {
            std.mem.copyForwards(Row, self.rows.items[0..remaining], self.rows.items[count..total]);
        }

        i = 0;
        while (i < count) : (i += 1) {
            self.rows.items[remaining + i] = Row.init(self.allocator, self.cols, true) catch {
                // On OOM, reuse the slot with a zero-width placeholder that won't be indexed
                // This is a best-effort scenario under extreme memory pressure
                self.rows.items.len = remaining + i;
                return;
            };
        }
    }

    fn scrollDown(self: *Grid, n: u16) void {
        const total: u16 = @intCast(self.rows.items.len);
        const count = @min(n, total);
        if (count == 0) return;

        var i: u16 = 0;
        while (i < count) : (i += 1) {
            self.rows.items[total - 1 - i].deinit(self.allocator);
        }

        const remaining = total - count;
        if (remaining > 0) {
            var j: isize = @as(isize, remaining) - 1;
            while (j >= 0) : (j -= 1) {
                const src: usize = @intCast(j);
                const dst: usize = @intCast(j + @as(isize, count));
                self.rows.items[dst] = self.rows.items[src];
            }
        }

        i = 0;
        while (i < count) : (i += 1) {
            self.rows.items[i] = Row.init(self.allocator, self.cols, true) catch Row{
                .cells = &.{},
                .is_canonical = true,
            };
        }
    }

    // ── Resize with Reflow ───────────────────────────────────────────────────

    pub fn resize(self: *Grid, new_cols: u16, new_rows: u16) !void {
        if (self.cols == new_cols and self.viewport_rows == new_rows and self.rows.items.len == new_rows) return;

        if (self.in_alt_screen) {
            try self.resizeSimple(new_cols, new_rows);
            return;
        }

        if (self.cols != new_cols) {
            try self.reflow(new_cols, new_rows);
        } else {
            try self.resizeHeight(new_rows);
        }
    }

    fn reflow(self: *Grid, new_cols: u16, new_rows: u16) !void {
        const alloc = self.allocator;

        // Phase 1: Compute cursor's linear position
        var cursor_linear: usize = 0;
        {
            var canonical_idx: usize = 0;
            var char_in_canonical: usize = 0;

            for (self.rows.items, 0..) |r, row_idx| {
                if (r.is_canonical and row_idx > 0) {
                    canonical_idx += 1;
                    char_in_canonical = 0;
                }
                if (row_idx == self.cursor_row) {
                    cursor_linear = canonical_idx * 1_000_000 + char_in_canonical + self.cursor_col;
                    break;
                }
                char_in_canonical += r.cells.len;
            }
        }

        // Phase 2: Merge wrapped rows back into canonical lines
        // Use a simple dynamic array of dynamic arrays
        var canonical_count: usize = 0;
        // First pass: count canonical lines
        for (self.rows.items, 0..) |r, idx| {
            if (r.is_canonical or idx == 0) canonical_count += 1;
        }

        // Collect canonical lines as slices of cells
        var line_cells_list: std.ArrayListUnmanaged(std.ArrayListUnmanaged(Cell)) = .{};
        defer {
            for (line_cells_list.items) |*cl| cl.deinit(alloc);
            line_cells_list.deinit(alloc);
        }

        for (self.rows.items, 0..) |r, idx| {
            if (r.is_canonical or idx == 0 or line_cells_list.items.len == 0) {
                var new_line: std.ArrayListUnmanaged(Cell) = .{};
                const content_len = r.contentLen();
                try new_line.appendSlice(alloc, r.cells[0..content_len]);
                try line_cells_list.append(alloc, new_line);
            } else {
                var last = &line_cells_list.items[line_cells_list.items.len - 1];
                const content_len = r.contentLen();
                if (content_len > 0) {
                    try last.appendSlice(alloc, r.cells[0..content_len]);
                }
            }
        }

        // Phase 3: Free old rows
        for (self.rows.items) |*r| r.deinit(alloc);
        self.rows.clearRetainingCapacity();

        // Phase 4: Re-split each canonical line to new width
        var new_cursor_row: u16 = 0;
        var new_cursor_col: u16 = 0;
        var current_canonical: usize = 0;

        for (line_cells_list.items) |cl| {
            const line_cells = cl.items;

            if (line_cells.len == 0) {
                try self.rows.append(alloc, try Row.init(alloc, new_cols, true));
                const cursor_canonical_idx = cursor_linear / 1_000_000;
                if (cursor_canonical_idx == current_canonical) {
                    new_cursor_row = @intCast(self.rows.items.len - 1);
                    new_cursor_col = 0;
                }
            } else {
                var offset: usize = 0;
                var first_chunk = true;
                while (offset < line_cells.len) {
                    const chunk_end = @min(offset + new_cols, line_cells.len);
                    const chunk = line_cells[offset..chunk_end];

                    var new_row = try Row.init(alloc, new_cols, first_chunk);
                    @memcpy(new_row.cells[0..chunk.len], chunk);

                    try self.rows.append(alloc, new_row);

                    const cursor_in_canonical = cursor_linear % 1_000_000;
                    const cursor_canonical_idx = cursor_linear / 1_000_000;
                    if (cursor_canonical_idx == current_canonical and
                        cursor_in_canonical >= offset and
                        cursor_in_canonical <= chunk_end)
                    {
                        // Cursor at chunk_end means it's at the right edge;
                        // if it's exactly at the boundary and there's more content,
                        // let the next chunk claim it instead.
                        if (cursor_in_canonical < chunk_end or offset + new_cols >= line_cells.len) {
                            new_cursor_row = @intCast(self.rows.items.len - 1);
                            new_cursor_col = @intCast(cursor_in_canonical - offset);
                        }
                    }

                    offset = chunk_end;
                    first_chunk = false;
                }
            }
            current_canonical += 1;
        }

        // Phase 5: Adjust to viewport height
        while (self.rows.items.len < new_rows) {
            try self.rows.append(alloc, try Row.init(alloc, new_cols, true));
        }

        if (self.rows.items.len > new_rows) {
            // First, remove empty trailing rows
            while (self.rows.items.len > new_rows) {
                const last = &self.rows.items[self.rows.items.len - 1];
                if (last.contentLen() == 0 and self.rows.items.len - 1 > new_cursor_row) {
                    var removed = self.rows.pop().?;
                    removed.deinit(alloc);
                } else {
                    break;
                }
            }
            // If still too many rows, keep them but adjust viewport
            // The viewport shows the last new_rows rows (where cursor is)
            if (self.rows.items.len > new_rows) {
                // Ensure cursor is within the visible viewport at the bottom
                const total: u16 = @intCast(self.rows.items.len);
                const viewport_start = total -| new_rows;
                if (new_cursor_row < viewport_start) {
                    new_cursor_row = viewport_start;
                }
            }
        }

        self.cols = new_cols;
        self.viewport_rows = new_rows;
        self.cursor_row = @min(new_cursor_row, @as(u16, @intCast(self.rows.items.len)) -| 1);
        self.cursor_col = @min(new_cursor_col, new_cols -| 1);
    }

    fn resizeHeight(self: *Grid, new_rows: u16) !void {
        while (self.rows.items.len < new_rows) {
            try self.rows.append(self.allocator, try Row.init(self.allocator, self.cols, true));
        }
        while (self.rows.items.len > new_rows) {
            if (self.rows.pop()) |*r_ptr| {
                var r = r_ptr.*;
                r.deinit(self.allocator);
            }
        }
        self.viewport_rows = new_rows;
        self.cursor_row = @min(self.cursor_row, @as(u16, @intCast(self.rows.items.len)) -| 1);
    }

    fn resizeSimple(self: *Grid, new_cols: u16, new_rows: u16) !void {
        const alloc = self.allocator;
        var new_row_list: std.ArrayListUnmanaged(Row) = .{};
        errdefer {
            for (new_row_list.items) |*r| r.deinit(alloc);
            new_row_list.deinit(alloc);
        }

        const copy_rows = @min(self.rows.items.len, @as(usize, new_rows));
        const copy_cols = @min(self.cols, new_cols);

        var i: usize = 0;
        while (i < copy_rows) : (i += 1) {
            var new_row = try Row.init(alloc, new_cols, self.rows.items[i].is_canonical);
            @memcpy(new_row.cells[0..copy_cols], self.rows.items[i].cells[0..copy_cols]);
            try new_row_list.append(alloc, new_row);
        }
        while (new_row_list.items.len < new_rows) {
            try new_row_list.append(alloc, try Row.init(alloc, new_cols, true));
        }

        for (self.rows.items) |*r| r.deinit(alloc);
        self.rows.deinit(alloc);
        self.rows = new_row_list;
        self.cols = new_cols;
        self.viewport_rows = new_rows;
        self.cursor_row = @min(self.cursor_row, new_rows -| 1);
        self.cursor_col = @min(self.cursor_col, new_cols -| 1);
    }
};

/// CPR response data -- caller formats and writes to PTY.
pub const CprResponse = struct {
    row: u16,
    col: u16,
};

// ─── Tests ───────────────────────────────────────────────────────────────────

test "reflow wraps long line to narrower width" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 10, 3);
    defer grid.deinit();

    const text = "ABCDEFGHIJ";
    for (text) |ch| {
        _ = grid.applyEvent(.{ .print = ch });
    }

    try grid.resize(5, 3);

    try std.testing.expectEqual(@as(u16, 5), grid.cols);
    try std.testing.expect(grid.rows.items[0].is_canonical);
    try std.testing.expectEqual(@as(u21, 'A'), grid.rows.items[0].cells[0].char);
    try std.testing.expectEqual(@as(u21, 'E'), grid.rows.items[0].cells[4].char);
    try std.testing.expect(!grid.rows.items[1].is_canonical);
    try std.testing.expectEqual(@as(u21, 'F'), grid.rows.items[1].cells[0].char);
    try std.testing.expectEqual(@as(u21, 'J'), grid.rows.items[1].cells[4].char);
}

test "reflow unwraps when width increases" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 5, 4);
    defer grid.deinit();

    for ("ABCDE") |ch| _ = grid.applyEvent(.{ .print = ch });
    for ("FGH") |ch| _ = grid.applyEvent(.{ .print = ch });

    try std.testing.expect(grid.rows.items[0].is_canonical);
    try std.testing.expect(!grid.rows.items[1].is_canonical);

    try grid.resize(10, 4);

    try std.testing.expect(grid.rows.items[0].is_canonical);
    try std.testing.expectEqual(@as(u21, 'A'), grid.rows.items[0].cells[0].char);
    try std.testing.expectEqual(@as(u21, 'H'), grid.rows.items[0].cells[7].char);
    try std.testing.expectEqual(@as(u21, ' '), grid.rows.items[0].cells[8].char);
}

test "canonical line boundary preserved" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 10, 5);
    defer grid.deinit();

    for ("Hello") |ch| _ = grid.applyEvent(.{ .print = ch });
    _ = grid.applyEvent(.linefeed);
    _ = grid.applyEvent(.carriage_return);
    for ("World") |ch| _ = grid.applyEvent(.{ .print = ch });

    try grid.resize(5, 5);

    try std.testing.expect(grid.rows.items[0].is_canonical);
    try std.testing.expectEqual(@as(u21, 'H'), grid.rows.items[0].cells[0].char);
    try std.testing.expect(grid.rows.items[1].is_canonical);
    try std.testing.expectEqual(@as(u21, 'W'), grid.rows.items[1].cells[0].char);
}

test "cursor position correct after reflow" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 10, 3);
    defer grid.deinit();

    for ("ABCDEFGH") |ch| _ = grid.applyEvent(.{ .print = ch });
    try std.testing.expectEqual(@as(u16, 0), grid.cursor_row);

    try grid.resize(5, 3);

    try std.testing.expectEqual(@as(u16, 1), grid.cursor_row);
    try std.testing.expectEqual(@as(u16, 3), grid.cursor_col);
}

test "print with auto-wrap creates non-canonical row" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 5, 3);
    defer grid.deinit();

    for ("ABCDEF") |ch| _ = grid.applyEvent(.{ .print = ch });

    try std.testing.expect(grid.rows.items[0].is_canonical);
    try std.testing.expect(!grid.rows.items[1].is_canonical);
    try std.testing.expectEqual(@as(u21, 'F'), grid.rows.items[1].cells[0].char);
    try std.testing.expectEqual(@as(u16, 1), grid.cursor_row);
    try std.testing.expectEqual(@as(u16, 1), grid.cursor_col);
}

test "getCell returns blank for out of bounds" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 5, 3);
    defer grid.deinit();

    const cell = grid.getCell(100, 100);
    try std.testing.expectEqual(@as(u21, ' '), cell.char);
}

test "resize height only adds rows" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 10, 3);
    defer grid.deinit();

    for ("ABC") |ch| _ = grid.applyEvent(.{ .print = ch });

    try grid.resize(10, 5);
    try std.testing.expectEqual(@as(usize, 5), grid.rows.items.len);
    try std.testing.expectEqual(@as(u21, 'A'), grid.rows.items[0].cells[0].char);
}

test "resize height only removes rows" {
    const allocator = std.testing.allocator;
    var grid = try Grid.init(allocator, 10, 5);
    defer grid.deinit();

    try grid.resize(10, 3);
    try std.testing.expectEqual(@as(usize, 3), grid.rows.items.len);
}
