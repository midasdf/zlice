const std = @import("std");
const protocol = @import("protocol.zig");

pub const Direction = protocol.Direction;

// ─── Types ────────────────────────────────────────────────────────────────────

pub const Region = struct {
    row: u16,
    col: u16,
    rows: u16,
    cols: u16,
};

pub const SplitDir = enum { horizontal, vertical };

pub const PaneId = u16;

pub const RegionEntry = struct {
    id: PaneId,
    region: Region,
};

// ─── LayoutNode ───────────────────────────────────────────────────────────────

pub const LayoutNode = union(enum) {
    leaf: LeafData,
    split: SplitData,

    pub const LeafData = struct {
        id: PaneId,
        pty_fd: i32, // -1 as placeholder when no real PTY
    };

    pub const SplitData = struct {
        dir: SplitDir,
        ratio: f32, // 0.0–1.0, where ratio is fraction given to `first`
        first: *LayoutNode,
        second: *LayoutNode,
    };
};

// ─── PaneTree ─────────────────────────────────────────────────────────────────

pub const PaneTree = struct {
    root: *LayoutNode,
    allocator: std.mem.Allocator,

    /// Create a tree with a single root leaf pane using `initial_id`.
    pub fn init(allocator: std.mem.Allocator, initial_id: PaneId) !PaneTree {
        const root = try allocator.create(LayoutNode);
        root.* = .{ .leaf = .{ .id = initial_id, .pty_fd = -1 } };
        return PaneTree{
            .root = root,
            .allocator = allocator,
        };
    }

    /// Free all nodes in the tree.
    pub fn deinit(self: *PaneTree) void {
        freeNode(self.allocator, self.root);
    }

    // ─── splitPane ────────────────────────────────────────────────────────────

    /// Split the leaf identified by `target_id`.  The leaf becomes `first`,
    /// a fresh leaf with `new_id` becomes `second`.  Returns `new_id`.
    pub fn splitPane(self: *PaneTree, target_id: PaneId, dir: SplitDir, new_id: PaneId) !PaneId {
        const new_leaf = try self.allocator.create(LayoutNode);
        new_leaf.* = .{ .leaf = .{ .id = new_id, .pty_fd = -1 } };
        errdefer self.allocator.destroy(new_leaf);

        // `out_split` is filled by replaceLeafWithSplit when the target is found.
        // It is heap-allocated so we can patch parent pointers.
        const out_split = try self.allocator.create(LayoutNode);
        errdefer self.allocator.destroy(out_split);

        // We need to find the target leaf and replace it in its parent.
        const found = replaceLeafWithSplit(
            self.allocator,
            self.root,
            null,
            false,
            target_id,
            dir,
            new_leaf,
            out_split,
        );

        if (!found) {
            return error.PaneNotFound;
        }

        // When the root itself was the target, replaceLeafWithSplit filled
        // `out_split` but had no parent to patch.  We fix this by overwriting
        // `self.root`'s value in place and then freeing the now-redundant
        // `out_split` shell (its children are already live in the tree).
        switch (self.root.*) {
            .leaf => {
                // Root is still a leaf → it was the target.  Copy split data in.
                self.root.* = out_split.*;
                self.allocator.destroy(out_split);
            },
            .split => {
                // Root was already replaced by a non-root path; `out_split` is
                // referenced from somewhere inside the tree — do NOT free it.
            },
        }

        return new_id;
    }

    // ─── closePane ────────────────────────────────────────────────────────────

    /// Remove the leaf `target_id`.  The sibling takes its parent's place.
    /// Returns the sibling pane ID, or null if target is the last pane (root leaf).
    pub fn closePane(self: *PaneTree, target_id: PaneId) ?PaneId {
        // If root is the only pane, can't close.
        switch (self.root.*) {
            .leaf => |l| {
                if (l.id == target_id) return null;
                return null; // target not found
            },
            .split => {},
        }

        var sibling_id: PaneId = 0;
        const found = removeLeaf(
            self.allocator,
            self.root,
            null,
            false,
            target_id,
            &sibling_id,
        );
        if (!found) return null;

        return sibling_id;
    }

    // ─── focusDirection ───────────────────────────────────────────────────────

    /// Find the nearest pane in `dir` relative to `from`, using region centres.
    pub fn focusDirection(
        self: *PaneTree,
        from: PaneId,
        dir: Direction,
        region_map: []const RegionEntry,
    ) ?PaneId {
        _ = self;

        // Find the source region.
        var src_opt: ?Region = null;
        for (region_map) |e| {
            if (e.id == from) {
                src_opt = e.region;
                break;
            }
        }
        const src = src_opt orelse return null;

        const src_center_row: i32 = @as(i32, src.row) + @divTrunc(@as(i32, src.rows), 2);
        const src_center_col: i32 = @as(i32, src.col) + @divTrunc(@as(i32, src.cols), 2);

        var best_id: ?PaneId = null;
        var best_dist: i32 = std.math.maxInt(i32);

        for (region_map) |e| {
            if (e.id == from) continue;

            const cand_center_row: i32 = @as(i32, e.region.row) + @divTrunc(@as(i32, e.region.rows), 2);
            const cand_center_col: i32 = @as(i32, e.region.col) + @divTrunc(@as(i32, e.region.cols), 2);

            const dr = cand_center_row - src_center_row;
            const dc = cand_center_col - src_center_col;

            const qualifies = switch (dir) {
                .left => dc < 0,
                .right => dc > 0,
                .up => dr < 0,
                .down => dr > 0,
            };
            if (!qualifies) continue;

            // Manhattan distance
            const dist: i32 = @intCast(@abs(dr) + @abs(dc));
            if (dist < best_dist) {
                best_dist = dist;
                best_id = e.id;
            }
        }

        return best_id;
    }

    // ─── resizePane ───────────────────────────────────────────────────────────

    /// Adjust the ratio of the split node that directly contains `target_id`.
    /// `delta_pct` is in integer percent steps (e.g. +5 means +0.05 to ratio).
    pub fn resizePane(self: *PaneTree, target_id: PaneId, dir: Direction, delta_pct: i16) void {
        adjustRatio(self.root, target_id, dir, delta_pct);
    }

    // ─── calculateRegions ─────────────────────────────────────────────────────

    /// Recursively divide `total` among leaves.  Caller owns returned slice.
    pub fn calculateRegions(self: *PaneTree, total: Region) ![]RegionEntry {
        var list: std.ArrayList(RegionEntry) = .{};
        errdefer list.deinit(self.allocator);
        try collectRegions(self.allocator, self.root, total, &list);
        return list.toOwnedSlice(self.allocator);
    }

    // ─── paneCount ────────────────────────────────────────────────────────────

    pub fn paneCount(self: *PaneTree) usize {
        return countLeaves(self.root);
    }
};

// ─── Internal helpers ─────────────────────────────────────────────────────────

fn freeNode(allocator: std.mem.Allocator, node: *LayoutNode) void {
    switch (node.*) {
        .leaf => {},
        .split => |s| {
            freeNode(allocator, s.first);
            freeNode(allocator, s.second);
        },
    }
    allocator.destroy(node);
}

fn countLeaves(node: *const LayoutNode) usize {
    return switch (node.*) {
        .leaf => 1,
        .split => |s| countLeaves(s.first) + countLeaves(s.second),
    };
}

/// Walk the tree looking for a leaf with `target_id`.
/// When found, allocate a new split node (stored in `out_split`) whose `first`
/// child is the original leaf and `second` is `new_leaf`.
/// The split node replaces the leaf in the parent.
/// Returns true on success.
fn replaceLeafWithSplit(
    allocator: std.mem.Allocator,
    node: *LayoutNode,
    parent: ?*LayoutNode,
    is_first_child: bool,
    target_id: PaneId,
    dir: SplitDir,
    new_leaf: *LayoutNode,
    out_split: *LayoutNode,
) bool {
    switch (node.*) {
        .leaf => |l| {
            if (l.id != target_id) return false;

            if (parent != null) {
                // Non-root case: `node` is already a heap-allocated child.
                // We can reuse it as `first` directly.
                out_split.* = .{ .split = .{
                    .dir = dir,
                    .ratio = 0.5,
                    .first = node,
                    .second = new_leaf,
                } };
                // Patch parent to point at out_split.
                if (parent) |p| {
                    switch (p.*) {
                        .split => |*s| {
                            if (is_first_child) {
                                s.first = out_split;
                            } else {
                                s.second = out_split;
                            }
                        },
                        .leaf => unreachable,
                    }
                }
            } else {
                // Root case: `node` is `self.root` — the caller will overwrite
                // `node.*` with `out_split.*` in place.  We need to preserve
                // the current leaf value as the `first` child.  Since caller
                // will copy out_split.* into node.*, we need a separate alloc
                // for the original leaf.
                const original_copy = allocator.create(LayoutNode) catch return false;
                original_copy.* = node.*;
                out_split.* = .{ .split = .{
                    .dir = dir,
                    .ratio = 0.5,
                    .first = original_copy,
                    .second = new_leaf,
                } };
                // No parent to patch — caller handles root in-place.
            }
            return true;
        },
        .split => |*s| {
            if (replaceLeafWithSplit(allocator, s.first, node, true, target_id, dir, new_leaf, out_split))
                return true;
            if (replaceLeafWithSplit(allocator, s.second, node, false, target_id, dir, new_leaf, out_split))
                return true;
            return false;
        },
    }
}

/// Remove the leaf `target_id` from the tree.
/// The sibling subtree takes the place of the parent split.
/// `out_sibling_id` is set to the leaf ID of the sibling (its leftmost leaf
/// if the sibling is itself a subtree — we take the first leaf).
/// Returns true on success.
fn removeLeaf(
    allocator: std.mem.Allocator,
    node: *LayoutNode,
    parent: ?*LayoutNode,
    is_first_child: bool,
    target_id: PaneId,
    out_sibling_id: *PaneId,
) bool {
    switch (node.*) {
        .leaf => |l| {
            if (l.id != target_id) return false;
            // A leaf has no parent split to act on here — the split case handles removal.
            // If the root itself is a leaf, caller already handles it.
            return false;
        },
        .split => |*s| {
            // Check if either direct child is the target leaf.
            const first_is_leaf = switch (s.first.*) {
                .leaf => |l| l.id == target_id,
                .split => false,
            };
            const second_is_leaf = switch (s.second.*) {
                .leaf => |l| l.id == target_id,
                .split => false,
            };

            if (first_is_leaf) {
                // Sibling is second subtree.
                out_sibling_id.* = firstLeafId(s.second);
                const sibling = s.second;
                const dead = s.first;
                if (parent != null) {
                    // Non-root: patch grandparent and free this split node.
                    replaceNodeInParent(node, sibling, parent, is_first_child);
                    allocator.destroy(dead);
                    allocator.destroy(node);
                } else {
                    // Root case: copy sibling into root node, free sibling shell.
                    allocator.destroy(dead);
                    node.* = sibling.*;
                    allocator.destroy(sibling);
                }
                return true;
            } else if (second_is_leaf) {
                out_sibling_id.* = firstLeafId(s.first);
                const sibling = s.first;
                const dead = s.second;
                if (parent != null) {
                    replaceNodeInParent(node, sibling, parent, is_first_child);
                    allocator.destroy(dead);
                    allocator.destroy(node);
                } else {
                    allocator.destroy(dead);
                    node.* = sibling.*;
                    allocator.destroy(sibling);
                }
                return true;
            }

            // Recurse.
            if (removeLeaf(allocator, s.first, node, true, target_id, out_sibling_id))
                return true;
            if (removeLeaf(allocator, s.second, node, false, target_id, out_sibling_id))
                return true;
            return false;
        },
    }
}

/// Patch `parent`'s appropriate child pointer to `replacement`.
/// If parent is null (i.e. we are operating on the root), this is a no-op —
/// the caller is responsible for updating `tree.root`.
fn replaceNodeInParent(
    old: *LayoutNode,
    replacement: *LayoutNode,
    parent: ?*LayoutNode,
    is_first_child: bool,
) void {
    _ = old;
    if (parent) |p| {
        switch (p.*) {
            .split => |*s| {
                if (is_first_child) {
                    s.first = replacement;
                } else {
                    s.second = replacement;
                }
            },
            .leaf => unreachable,
        }
    }
}

pub fn firstLeafId(node: *const LayoutNode) PaneId {
    return switch (node.*) {
        .leaf => |l| l.id,
        .split => |s| firstLeafId(s.first),
    };
}

fn collectRegions(
    allocator: std.mem.Allocator,
    node: *const LayoutNode,
    region: Region,
    list: *std.ArrayList(RegionEntry),
) !void {
    switch (node.*) {
        .leaf => |l| {
            try list.append(allocator, .{ .id = l.id, .region = region });
        },
        .split => |s| {
            const first_region, const second_region = splitRegion(region, s.dir, s.ratio);
            try collectRegions(allocator, s.first, first_region, list);
            try collectRegions(allocator, s.second, second_region, list);
        },
    }
}

/// Divide `region` by `ratio` (fraction for first) in `dir`.
/// Adjacent panes share their border: the second pane overlaps the first by
/// 1 column (horizontal) or 1 row (vertical), so a single border line
/// separates the two panes instead of a double border.
fn splitRegion(region: Region, dir: SplitDir, ratio: f32) struct { Region, Region } {
    switch (dir) {
        .horizontal => {
            // Split left/right: first gets `ratio` of cols.
            // Subtract 1 from total to account for the shared border column,
            // then distribute the remaining space by ratio.
            const available = region.cols -| 1; // space minus 1 shared border
            const first_content: u16 = @intFromFloat(@round(@as(f32, @floatFromInt(available)) * ratio));
            const clamped_first = @max(1, @min(first_content, available -| 1));
            // First pane includes left border + content + shared border
            const first_cols = clamped_first + 1;
            // Second pane starts at the shared border column (overlap by 1)
            const second_start = region.col + first_cols - 1;
            const second_cols = region.cols - first_cols + 1;
            const first = Region{
                .row = region.row,
                .col = region.col,
                .rows = region.rows,
                .cols = first_cols,
            };
            const second = Region{
                .row = region.row,
                .col = second_start,
                .rows = region.rows,
                .cols = second_cols,
            };
            return .{ first, second };
        },
        .vertical => {
            // Split top/bottom: first gets `ratio` of rows.
            // Same shared-border approach for rows.
            const available = region.rows -| 1;
            const first_content: u16 = @intFromFloat(@round(@as(f32, @floatFromInt(available)) * ratio));
            const clamped_first = @max(1, @min(first_content, available -| 1));
            const first_rows = clamped_first + 1;
            const second_start = region.row + first_rows - 1;
            const second_rows = region.rows - first_rows + 1;
            const first = Region{
                .row = region.row,
                .col = region.col,
                .rows = first_rows,
                .cols = region.cols,
            };
            const second = Region{
                .row = second_start,
                .col = region.col,
                .rows = second_rows,
                .cols = region.cols,
            };
            return .{ first, second };
        },
    }
}

/// Walk the tree and adjust the ratio of the split node that directly contains
/// `target_id` as one of its children.  `dir` determines the direction of the
/// resize relative to the pane — only splits whose direction matches the axis
/// of `dir` are adjusted.
fn adjustRatio(node: *LayoutNode, target_id: PaneId, dir: Direction, delta_pct: i16) void {
    switch (node.*) {
        .leaf => return,
        .split => |*s| {
            const first_has = subtreeContains(s.first, target_id);
            const second_has = subtreeContains(s.second, target_id);

            if (first_has or second_has) {
                // Check axis match.
                const axis_matches = switch (dir) {
                    .left, .right => s.dir == .horizontal,
                    .up, .down => s.dir == .vertical,
                };
                if (axis_matches) {
                    const delta: f32 = @as(f32, @floatFromInt(delta_pct)) / 100.0;
                    // If target is in `first`, growing rightward/downward expands first.
                    // If target is in `second`, growing leftward/upward (delta_pct<0 from caller's view)
                    // would expand second — let caller pass correct sign.
                    const new_ratio = s.ratio + delta;
                    s.ratio = @max(0.1, @min(0.9, new_ratio));
                    return;
                }
            }

            // Recurse to find the closer split.
            adjustRatio(s.first, target_id, dir, delta_pct);
            adjustRatio(s.second, target_id, dir, delta_pct);
        },
    }
}

fn subtreeContains(node: *const LayoutNode, id: PaneId) bool {
    return switch (node.*) {
        .leaf => |l| l.id == id,
        .split => |s| subtreeContains(s.first, id) or subtreeContains(s.second, id),
    };
}

// ─── PaneTree.splitPane / closePane need root-replacement support ─────────────
// The helpers above operate on children.  For the root-is-target case we need
// to mutate tree.root in place.  We do so by copying the out_split data back
// into the root node (pointer stays the same; the original leaf copy lives as
// a child).

// Re-export splitPane & closePane as methods on PaneTree using the helpers:

// Note: splitPane and closePane are already defined as methods above.
// We handle the root-replacement case inside them using the `parent == null`
// branch: when `parent` is null, `out_split` is heap-allocated but we need to
// copy its contents into `self.root` (which is the node we just walked into).
// Actually, the flow is:
//   replaceLeafWithSplit(root, null, ...) → finds root is the leaf → sets out_split,
//   but cannot patch the parent because parent is null.
//   We detect this by checking if root is still a leaf after the call.

// Let's re-examine: when the root IS the target leaf, after the call root still
// holds the old leaf data (we only patched parent if parent != null).
// We need to copy out_split into *root and free the no-longer-needed out_split node.
// But we've already written original copy of root → original_copy, so that is fine.
// We just copy out_split.* into root.* and then free out_split (shallow — don't
// recursively free its children, which are still live).

// This is handled in splitPane below with a post-call fixup.

// ─── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn makeTree(allocator: std.mem.Allocator) !PaneTree {
    return PaneTree.init(allocator, 0);
}

const full = Region{ .row = 0, .col = 0, .rows = 24, .cols = 80 };

test "init creates single pane" {
    var tree = try makeTree(testing.allocator);
    defer tree.deinit();

    try testing.expectEqual(@as(usize, 1), tree.paneCount());

    const regions = try tree.calculateRegions(full);
    defer testing.allocator.free(regions);

    try testing.expectEqual(@as(usize, 1), regions.len);
    try testing.expectEqual(@as(PaneId, 0), regions[0].id);
    try testing.expectEqual(full.row, regions[0].region.row);
    try testing.expectEqual(full.col, regions[0].region.col);
    try testing.expectEqual(full.rows, regions[0].region.rows);
    try testing.expectEqual(full.cols, regions[0].region.cols);
}

test "horizontal split" {
    var tree = try makeTree(testing.allocator);
    defer tree.deinit();

    const new_id = try tree.splitPane(0, .horizontal, 1);
    try testing.expectEqual(@as(PaneId, 1), new_id);
    try testing.expectEqual(@as(usize, 2), tree.paneCount());

    const regions = try tree.calculateRegions(full);
    defer testing.allocator.free(regions);

    try testing.expectEqual(@as(usize, 2), regions.len);

    // Find each region by pane ID.
    var r0: Region = undefined;
    var r1: Region = undefined;
    for (regions) |e| {
        if (e.id == 0) r0 = e.region else r1 = e.region;
    }

    // Both panes share the same rows.
    try testing.expectEqual(full.rows, r0.rows);
    try testing.expectEqual(full.rows, r1.rows);
    // Columns overlap by 1 (shared border) and together cover full.cols.
    try testing.expectEqual(full.col, r0.col);
    // Second pane starts 1 col before first pane ends (shared border).
    try testing.expectEqual(r0.col + r0.cols - 1, r1.col);
    // Total coverage: first.cols + second.cols - 1 (shared) == full.cols
    try testing.expectEqual(full.cols, r0.cols + r1.cols - 1);
}

test "vertical split" {
    var tree = try makeTree(testing.allocator);
    defer tree.deinit();

    const new_id = try tree.splitPane(0, .vertical, 1);
    try testing.expectEqual(@as(PaneId, 1), new_id);
    try testing.expectEqual(@as(usize, 2), tree.paneCount());

    const regions = try tree.calculateRegions(full);
    defer testing.allocator.free(regions);

    try testing.expectEqual(@as(usize, 2), regions.len);

    var r0: Region = undefined;
    var r1: Region = undefined;
    for (regions) |e| {
        if (e.id == 0) r0 = e.region else r1 = e.region;
    }

    // Both panes share the same cols.
    try testing.expectEqual(full.cols, r0.cols);
    try testing.expectEqual(full.cols, r1.cols);
    // Rows overlap by 1 (shared border).
    try testing.expectEqual(full.row, r0.row);
    try testing.expectEqual(r0.row + r0.rows - 1, r1.row);
    try testing.expectEqual(full.rows, r0.rows + r1.rows - 1);
}

test "nested split" {
    var tree = try makeTree(testing.allocator);
    defer tree.deinit();

    _ = try tree.splitPane(0, .horizontal, 1); // pane 0 and pane 1 side by side
    _ = try tree.splitPane(1, .vertical, 2); // pane 1 splits into 1 (top) and 2 (bottom)

    try testing.expectEqual(@as(usize, 3), tree.paneCount());

    const regions = try tree.calculateRegions(full);
    defer testing.allocator.free(regions);

    try testing.expectEqual(@as(usize, 3), regions.len);

    // All regions must be non-zero and fit within full.
    for (regions) |e| {
        try testing.expect(e.region.rows > 0);
        try testing.expect(e.region.cols > 0);
        try testing.expect(e.region.row + e.region.rows <= full.row + full.rows);
        try testing.expect(e.region.col + e.region.cols <= full.col + full.cols);
    }
}

test "close pane" {
    var tree = try makeTree(testing.allocator);
    defer tree.deinit();

    const new_id = try tree.splitPane(0, .horizontal, 1);
    try testing.expectEqual(@as(usize, 2), tree.paneCount());

    const sibling = tree.closePane(new_id);
    try testing.expect(sibling != null);
    try testing.expectEqual(@as(usize, 1), tree.paneCount());

    // The remaining pane should occupy the full region.
    const regions = try tree.calculateRegions(full);
    defer testing.allocator.free(regions);

    try testing.expectEqual(@as(usize, 1), regions.len);
    try testing.expectEqual(full.cols, regions[0].region.cols);
    try testing.expectEqual(full.rows, regions[0].region.rows);
}

test "focus direction" {
    var tree = try makeTree(testing.allocator);
    defer tree.deinit();

    _ = try tree.splitPane(0, .horizontal, 1); // pane 0 left, pane 1 right

    const regions = try tree.calculateRegions(full);
    defer testing.allocator.free(regions);

    // Focus right from pane 0 → should land on pane 1.
    const right = tree.focusDirection(0, .right, regions);
    try testing.expect(right != null);
    try testing.expectEqual(@as(PaneId, 1), right.?);

    // Focus left from pane 1 → should land on pane 0.
    const left = tree.focusDirection(1, .left, regions);
    try testing.expect(left != null);
    try testing.expectEqual(@as(PaneId, 0), left.?);

    // Focus up from pane 0 → nothing above (same row for both).
    const up = tree.focusDirection(0, .up, regions);
    try testing.expect(up == null);
}

test "resize pane" {
    var tree = try makeTree(testing.allocator);
    defer tree.deinit();

    _ = try tree.splitPane(0, .horizontal, 1);

    // Default ratio is 0.5.  Resize pane 0 rightward by +20%.
    tree.resizePane(0, .right, 20);

    const regions = try tree.calculateRegions(full);
    defer testing.allocator.free(regions);

    var r0: Region = undefined;
    var r1: Region = undefined;
    for (regions) |e| {
        if (e.id == 0) r0 = e.region else r1 = e.region;
    }

    // After +20%, pane 0 should be wider than pane 1.
    try testing.expect(r0.cols > r1.cols);
}

test "close last pane returns null" {
    var tree = try makeTree(testing.allocator);
    defer tree.deinit();

    const result = tree.closePane(0);
    try testing.expect(result == null);
    try testing.expectEqual(@as(usize, 1), tree.paneCount());
}
