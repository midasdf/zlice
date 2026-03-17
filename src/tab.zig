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
        const len = @min(new_name.len, self.name.len);
        @memcpy(self.name[0..len], new_name[0..len]);
        self.name_len = @intCast(len);
    }
};

// ─── TabManager ───────────────────────────────────────────────────────────────

pub const TabManager = struct {
    tabs: [MAX_TABS]?Tab = [_]?Tab{null} ** MAX_TABS,
    count: u8 = 0,
    active: u8 = 0,
    allocator: std.mem.Allocator,

    /// Create a TabManager with one initial tab named "Tab 1".
    pub fn init(allocator: std.mem.Allocator) !TabManager {
        var mgr = TabManager{ .allocator = allocator };
        const tree = try pane.PaneTree.init(allocator, 0);
        var tab: Tab = .{ .pane_tree = tree };
        tab.setName("Tab 1");
        mgr.tabs[0] = tab;
        mgr.count = 1;
        mgr.active = 0;
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
        self.active = idx;
        return idx;
    }

    /// Close tab at `index`. Returns false if it would close the last tab.
    /// Adjusts active index if the closed tab was active.
    pub fn closeTab(self: *TabManager, index: u8) bool {
        if (self.count <= 1) return false;
        if (index >= MAX_TABS) return false;
        if (self.tabs[index] == null) return false;

        self.tabs[index].?.pane_tree.deinit();
        self.tabs[index] = null;
        self.count -= 1;

        // If the closed tab was active, move active to the nearest existing tab.
        if (self.active == index) {
            // Search backward first, then forward.
            var found = false;
            var i: i16 = @as(i16, @intCast(index)) - 1;
            while (i >= 0) : (i -= 1) {
                if (self.tabs[@intCast(i)] != null) {
                    self.active = @intCast(i);
                    found = true;
                    break;
                }
            }
            if (!found) {
                var j: u8 = index + 1;
                while (j < MAX_TABS) : (j += 1) {
                    if (self.tabs[j] != null) {
                        self.active = j;
                        break;
                    }
                }
            }
        }
        return true;
    }

    /// Switch to the next existing tab (wraps around).
    pub fn nextTab(self: *TabManager) void {
        if (self.count <= 1) return;
        var i: u8 = (self.active + 1) % MAX_TABS;
        var steps: u8 = 0;
        while (steps < MAX_TABS) : (steps += 1) {
            if (self.tabs[i] != null) {
                self.active = i;
                return;
            }
            i = (i + 1) % MAX_TABS;
        }
    }

    /// Switch to the previous existing tab (wraps around).
    pub fn prevTab(self: *TabManager) void {
        if (self.count <= 1) return;
        var i: u8 = if (self.active == 0) MAX_TABS - 1 else self.active - 1;
        var steps: u8 = 0;
        while (steps < MAX_TABS) : (steps += 1) {
            if (self.tabs[i] != null) {
                self.active = i;
                return;
            }
            i = if (i == 0) MAX_TABS - 1 else i - 1;
        }
    }

    /// Return a pointer to the active tab.
    pub fn activeTab(self: *TabManager) *Tab {
        return &self.tabs[self.active].?;
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
    try testing.expectEqualStrings("Tab 1", mgr.activeTab().getName());
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
    try testing.expect(result);
    try testing.expectEqual(@as(u8, 1), mgr.tabCount());
    // Active should have shifted away from closed index.
    try testing.expect(mgr.active != 0 or mgr.tabs[mgr.active] != null);
}

test "cannot close last tab" {
    var mgr = try TabManager.init(testing.allocator);
    defer mgr.deinit();

    const result = mgr.closeTab(0);
    try testing.expect(!result);
    try testing.expectEqual(@as(u8, 1), mgr.tabCount());
}

test "next/prev tab wraps" {
    var mgr = try TabManager.init(testing.allocator);
    defer mgr.deinit();

    _ = try mgr.createTab(1); // index 1
    _ = try mgr.createTab(2); // index 2

    // Set active to the last occupied slot.
    // Tabs are at indices 0, 1, 2 (count == 3).
    // createTab sets active to the new index each time, so active == 2.
    try testing.expectEqual(@as(u8, 2), mgr.active);

    // next from index 2 should wrap to index 0.
    mgr.nextTab();
    try testing.expectEqual(@as(u8, 0), mgr.active);

    // prev from index 0 should wrap to index 2.
    mgr.prevTab();
    try testing.expectEqual(@as(u8, 2), mgr.active);
}

test "rename tab" {
    var mgr = try TabManager.init(testing.allocator);
    defer mgr.deinit();

    mgr.activeTab().setName("my-session");
    try testing.expectEqualStrings("my-session", mgr.activeTab().getName());
}
