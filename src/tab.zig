const std = @import("std");
const pane = @import("pane.zig");

// ─── Constants ────────────────────────────────────────────────────────────────

pub const MAX_TABS: u8 = 10;

// ─── Tab ──────────────────────────────────────────────────────────────────────

pub const Tab = struct {
    name: [64]u8 = undefined,
    name_len: u8 = 0,
    pane_tree: pane.PaneTree,

    pub fn getName(self: *const Tab) []const u8 {
        return self.name[0..self.name_len];
    }

    pub fn setName(self: *Tab, new_name: []const u8) void {
        // Truncate at a valid UTF-8 boundary
        var len = @min(new_name.len, self.name.len);
        // Walk backwards to find a valid UTF-8 boundary
        while (len > 0 and (new_name[len - 1] & 0xC0) == 0x80) {
            // This is a continuation byte; check if the lead byte is included
            var start = len - 1;
            while (start > 0 and (new_name[start] & 0xC0) == 0x80) {
                start -= 1;
            }
            // Determine expected sequence length from lead byte
            const lead = new_name[start];
            const expected: usize = if (lead >= 0xF0) 4 else if (lead >= 0xE0) 3 else if (lead >= 0xC0) 2 else 1;
            if (start + expected <= len) break; // sequence is complete
            len = start; // truncate incomplete sequence
            break;
        }
        @memcpy(self.name[0..len], new_name[0..len]);
        self.name_len = @intCast(len);
    }
};

// ─── TabManager ───────────────────────────────────────────────────────────────

pub const TabManager = struct {
    tabs: [MAX_TABS]?Tab = [_]?Tab{null} ** MAX_TABS,
    count: u8 = 0,
    allocator: std.mem.Allocator,

    /// Create a TabManager with one initial tab named "Tab 1".
    pub fn init(allocator: std.mem.Allocator) !TabManager {
        var mgr = TabManager{ .allocator = allocator };
        const tree = try pane.PaneTree.init(allocator, 0);
        var tab: Tab = .{ .pane_tree = tree };
        tab.setName("Tab 1");
        mgr.tabs[0] = tab;
        mgr.count = 1;
        return mgr;
    }

    /// Deinit all tab pane trees.
    pub fn deinit(self: *TabManager) void {
        for (&self.tabs) |*slot| {
            if (slot.*) |*t| {
                t.pane_tree.deinit();
                slot.* = null;
            }
        }
        self.count = 0;
    }

    /// Create a new tab auto-named "Tab N". Returns the index of the new tab.
    /// `initial_pane_id` is the globally-unique ID assigned to the new tab's initial pane.
    /// Returns error.TabLimitReached if already at MAX_TABS.
    pub fn createTab(self: *TabManager, initial_pane_id: pane.PaneId) !u8 {
        if (self.count >= MAX_TABS) return error.TabLimitReached;

        // Find first empty slot.
        const idx = blk: {
            for (self.tabs, 0..) |slot, i| {
                if (slot == null) break :blk @as(u8, @intCast(i));
            }
            return error.TabLimitReached;
        };

        const tree = try pane.PaneTree.init(self.allocator, initial_pane_id);
        var tab: Tab = .{ .pane_tree = tree };

        // Auto-name: "Tab N" where N = count + 1 (next tab number).
        var buf: [64]u8 = undefined;
        const name = std.fmt.bufPrint(&buf, "Tab {d}", .{self.count + 1}) catch "Tab";
        tab.setName(name);

        self.tabs[idx] = tab;
        self.count += 1;
        return idx;
    }

    /// Close tab at `index`. Returns the nearest open tab index on success,
    /// or null if it's the last tab (can't close).
    pub fn closeTab(self: *TabManager, index: u8) ?u8 {
        if (self.count <= 1) return null;
        if (index >= MAX_TABS) return null;
        if (self.tabs[index] == null) return null;

        self.tabs[index].?.pane_tree.deinit();
        self.tabs[index] = null;
        self.count -= 1;

        // Find nearest: backward first, then forward.
        var i: i16 = @as(i16, @intCast(index)) - 1;
        while (i >= 0) : (i -= 1) {
            if (self.tabs[@intCast(i)] != null) return @intCast(i);
        }
        var j: u8 = index + 1;
        while (j < MAX_TABS) : (j += 1) {
            if (self.tabs[j] != null) return j;
        }
        return 0; // shouldn't reach here since count > 0
    }

    /// Return the next existing tab index from `current` (wraps around).
    pub fn nextTab(self: *TabManager, current: u8) u8 {
        if (self.count <= 1) return current;
        var i: u8 = (current + 1) % MAX_TABS;
        var steps: u8 = 0;
        while (steps < MAX_TABS) : (steps += 1) {
            if (self.tabs[i] != null) return i;
            i = (i + 1) % MAX_TABS;
        }
        return current;
    }

    /// Return the previous existing tab index from `current` (wraps around).
    pub fn prevTab(self: *TabManager, current: u8) u8 {
        if (self.count <= 1) return current;
        var i: u8 = if (current == 0) MAX_TABS - 1 else current - 1;
        var steps: u8 = 0;
        while (steps < MAX_TABS) : (steps += 1) {
            if (self.tabs[i] != null) return i;
            i = if (i == 0) MAX_TABS - 1 else i - 1;
        }
        return current;
    }

    /// Return a pointer to the tab at the given index.
    pub fn activeTab(self: *TabManager, active: u8) *Tab {
        return &self.tabs[active].?;
    }

    /// Return the number of open tabs.
    pub fn tabCount(self: *TabManager) u8 {
        return self.count;
    }
};

// ─── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "init creates one tab" {
    var mgr = try TabManager.init(testing.allocator);
    defer mgr.deinit();

    try testing.expectEqual(@as(u8, 1), mgr.tabCount());
    try testing.expectEqualStrings("Tab 1", mgr.activeTab(0).getName());
}

test "create multiple tabs" {
    var mgr = try TabManager.init(testing.allocator);
    defer mgr.deinit();

    _ = try mgr.createTab(1);
    _ = try mgr.createTab(2);

    try testing.expectEqual(@as(u8, 3), mgr.tabCount());
}

test "close tab" {
    var mgr = try TabManager.init(testing.allocator);
    defer mgr.deinit();

    _ = try mgr.createTab(1); // index 1

    // Close the first tab (index 0).
    const result = mgr.closeTab(0);
    try testing.expect(result != null);
    try testing.expectEqual(@as(u8, 1), mgr.tabCount());
    // The nearest tab should be valid.
    try testing.expect(mgr.tabs[result.?] != null);
}

test "cannot close last tab" {
    var mgr = try TabManager.init(testing.allocator);
    defer mgr.deinit();

    const result = mgr.closeTab(0);
    try testing.expect(result == null);
    try testing.expectEqual(@as(u8, 1), mgr.tabCount());
}

test "next/prev tab wraps" {
    var mgr = try TabManager.init(testing.allocator);
    defer mgr.deinit();

    _ = try mgr.createTab(1); // index 1
    _ = try mgr.createTab(2); // index 2

    // Tabs are at indices 0, 1, 2 (count == 3).

    // next from index 2 should wrap to index 0.
    const next = mgr.nextTab(2);
    try testing.expectEqual(@as(u8, 0), next);

    // prev from index 0 should wrap to index 2.
    const prev = mgr.prevTab(0);
    try testing.expectEqual(@as(u8, 2), prev);
}

test "rename tab" {
    var mgr = try TabManager.init(testing.allocator);
    defer mgr.deinit();

    mgr.activeTab(0).setName("my-session");
    try testing.expectEqualStrings("my-session", mgr.activeTab(0).getName());
}
