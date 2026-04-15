const std = @import("std");
const tab_mod = @import("tab.zig");
const pane_mod = @import("pane.zig");

// ─── Data Types ───────────────────────────────────────────────────────────────

pub const SavedPane = struct {
    cwd: []const u8,
};

pub const SavedSplit = struct {
    direction: []const u8, // "horizontal" or "vertical"
    ratio: f32,
};

pub const SavedTab = struct {
    name: []const u8,
    pane_count: u8,
};

pub const SavedSession = struct {
    tab_count: u8,
    tabs: []SavedTab,

    /// Free memory allocated during loadSession.
    pub fn deinit(self: *SavedSession, allocator: std.mem.Allocator) void {
        for (self.tabs) |t| {
            allocator.free(t.name);
        }
        allocator.free(self.tabs);
    }
};

// ─── Path Helpers ─────────────────────────────────────────────────────────────

/// Returns the data directory path `~/.local/share/zplit/`.
/// Caller owns the returned slice.
pub fn getDataDir(allocator: std.mem.Allocator, environ: std.process.Environ) ![]const u8 {
    const home = std.process.Environ.getPosix(environ, "HOME") orelse return error.HomeNotSet;
    return std.fmt.allocPrint(allocator, "{s}/.local/share/zplit", .{home});
}

/// Build the full path for a session file.
/// Caller owns the returned slice.
/// Returns error.InvalidSessionName if name contains path separators or ".."
fn getSessionPath(allocator: std.mem.Allocator, environ: std.process.Environ, name: []const u8) ![]const u8 {
    // Reject path traversal attempts
    if (name.len == 0) return error.InvalidSessionName;
    if (std.mem.indexOf(u8, name, "/") != null) return error.InvalidSessionName;
    if (std.mem.indexOf(u8, name, "\\") != null) return error.InvalidSessionName;
    if (std.mem.indexOf(u8, name, "..") != null) return error.InvalidSessionName;

    const dir = try getDataDir(allocator, environ);
    defer allocator.free(dir);
    return std.fmt.allocPrint(allocator, "{s}/{s}.json", .{ dir, name });
}

// ─── Count Leaves ─────────────────────────────────────────────────────────────

/// Count the number of leaf nodes in a pane tree recursively.
fn countLeaves(node: *const pane_mod.LayoutNode) u8 {
    return switch (node.*) {
        .leaf => 1,
        .split => |s| countLeaves(s.first) + countLeaves(s.second),
    };
}

// ─── JSON Builder ─────────────────────────────────────────────────────────────

/// Serialise a TabManager to a JSON string.  Caller owns the returned slice.
fn buildJson(allocator: std.mem.Allocator, tab_manager: *tab_mod.TabManager) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, "{\"tabs\":[");

    var first = true;
    for (tab_manager.tabs) |slot| {
        const t = slot orelse continue;
        if (!first) try buf.append(allocator, ',');
        first = false;

        try buf.appendSlice(allocator, "{\"name\":\"");
        const tab_name = t.getName();
        for (tab_name) |ch| {
            switch (ch) {
                '"' => try buf.appendSlice(allocator, "\\\""),
                '\\' => try buf.appendSlice(allocator, "\\\\"),
                else => try buf.append(allocator, ch),
            }
        }
        const pc = countLeaves(t.pane_tree.root);
        const tail = try std.fmt.allocPrint(allocator, "\",\"pane_count\":{d}}}", .{pc});
        defer allocator.free(tail);
        try buf.appendSlice(allocator, tail);
    }

    try buf.appendSlice(allocator, "]}");
    return buf.toOwnedSlice(allocator);
}

// ─── Save ─────────────────────────────────────────────────────────────────────

/// Save a session layout to `~/.local/share/zplit/{name}.json`.
pub fn saveSession(allocator: std.mem.Allocator, io: std.Io, environ: std.process.Environ, name: []const u8, tab_manager: *tab_mod.TabManager) !void {
    const data_dir = try getDataDir(allocator, environ);
    defer allocator.free(data_dir);

    // Create the data directory if it does not exist.
    std.Io.Dir.createDirAbsolute(io, data_dir, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    const session_path = try getSessionPath(allocator, environ, name);
    defer allocator.free(session_path);

    const json = try buildJson(allocator, tab_manager);
    defer allocator.free(json);

    const file = try std.Io.Dir.createFileAbsolute(io, session_path, .{ .truncate = true });
    defer file.close(io);
    var write_buf: [4096]u8 = undefined;
    var file_writer = file.writer(io, &write_buf);
    try file_writer.interface.writeAll(json);
    try file_writer.interface.flush();
}

// ─── Load ─────────────────────────────────────────────────────────────────────

/// Load a session from `~/.local/share/zplit/{name}.json`.
/// Returns null if the file does not exist.
/// Caller must call `SavedSession.deinit()` on the returned value.
pub fn loadSession(allocator: std.mem.Allocator, io: std.Io, environ: std.process.Environ, name: []const u8) !?SavedSession {
    const session_path = try getSessionPath(allocator, environ, name);
    defer allocator.free(session_path);

    const file = std.Io.Dir.openFileAbsolute(io, session_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close(io);

    var read_buf: [4096]u8 = undefined;
    var file_reader = file.reader(io, &read_buf);
    const contents = try file_reader.interface.allocRemaining(allocator, .limited(1024 * 64));
    defer allocator.free(contents);

    return try parseSession(allocator, contents);
}

// ─── Minimal JSON Parser ──────────────────────────────────────────────────────
//
// Parses the specific format produced by buildJson:
//   {"tabs":[{"name":"...","pane_count":N},...]}
//
// Handles escaped \" and \\ inside names.

fn parseSession(allocator: std.mem.Allocator, json: []const u8) !SavedSession {
    // Find the "tabs" array.
    const tabs_key = "\"tabs\":[";
    const tabs_start_pos = std.mem.indexOf(u8, json, tabs_key) orelse return error.InvalidSessionFile;
    var pos: usize = tabs_start_pos + tabs_key.len;

    var tabs: std.ArrayListUnmanaged(SavedTab) = .{ .items = &.{}, .capacity = 0 };
    errdefer {
        for (tabs.items) |t| allocator.free(t.name);
        tabs.deinit(allocator);
    }

    // Iterate over objects inside the array.
    while (pos < json.len) {
        // Skip whitespace.
        while (pos < json.len and isWhitespace(json[pos])) pos += 1;
        if (pos >= json.len) break;

        // End of array.
        if (json[pos] == ']') break;

        // Expect '{'.
        if (json[pos] != '{') return error.InvalidSessionFile;
        pos += 1;

        var tab_name: ?[]u8 = null;
        var tab_pane_count: u8 = 0;
        errdefer if (tab_name) |n| allocator.free(n);

        // Parse key-value pairs.
        while (pos < json.len) {
            while (pos < json.len and isWhitespace(json[pos])) pos += 1;
            if (pos >= json.len) return error.InvalidSessionFile;
            if (json[pos] == '}') { pos += 1; break; }
            if (json[pos] == ',') { pos += 1; continue; }

            // Expect '"key"'.
            if (json[pos] != '"') return error.InvalidSessionFile;
            pos += 1;
            const key_start = pos;
            while (pos < json.len and json[pos] != '"') pos += 1;
            const key = json[key_start..pos];
            pos += 1; // skip closing '"'

            // Skip ':'.
            while (pos < json.len and isWhitespace(json[pos])) pos += 1;
            if (pos >= json.len or json[pos] != ':') return error.InvalidSessionFile;
            pos += 1;
            while (pos < json.len and isWhitespace(json[pos])) pos += 1;

            if (std.mem.eql(u8, key, "name")) {
                // String value with escape support.
                if (pos >= json.len or json[pos] != '"') return error.InvalidSessionFile;
                pos += 1;
                var name_buf: std.ArrayListUnmanaged(u8) = .{ .items = &.{}, .capacity = 0 };
                errdefer name_buf.deinit(allocator);
                while (pos < json.len and json[pos] != '"') {
                    if (json[pos] == '\\') {
                        pos += 1;
                        if (pos >= json.len) return error.InvalidSessionFile;
                        switch (json[pos]) {
                            '"' => try name_buf.append(allocator, '"'),
                            '\\' => try name_buf.append(allocator, '\\'),
                            'n' => try name_buf.append(allocator, '\n'),
                            't' => try name_buf.append(allocator, '\t'),
                            else => try name_buf.append(allocator, json[pos]),
                        }
                    } else {
                        try name_buf.append(allocator, json[pos]);
                    }
                    pos += 1;
                }
                pos += 1; // skip closing '"'
                tab_name = try name_buf.toOwnedSlice(allocator);
            } else if (std.mem.eql(u8, key, "pane_count")) {
                // Integer value.
                const num_start = pos;
                while (pos < json.len and json[pos] >= '0' and json[pos] <= '9') pos += 1;
                const num_str = json[num_start..pos];
                tab_pane_count = std.fmt.parseInt(u8, num_str, 10) catch return error.InvalidSessionFile;
            } else {
                // Unknown key: skip value (string or number only for this format).
                if (json[pos] == '"') {
                    pos += 1;
                    while (pos < json.len and json[pos] != '"') {
                        if (json[pos] == '\\') pos += 1;
                        pos += 1;
                    }
                    pos += 1;
                } else {
                    while (pos < json.len and json[pos] != ',' and json[pos] != '}') pos += 1;
                }
            }
        }

        const owned_name = tab_name orelse return error.InvalidSessionFile;
        try tabs.append(allocator, .{ .name = owned_name, .pane_count = tab_pane_count });

        // Skip ',' between objects.
        while (pos < json.len and isWhitespace(json[pos])) pos += 1;
        if (pos < json.len and json[pos] == ',') pos += 1;
    }

    const tabs_slice = try tabs.toOwnedSlice(allocator);
    return SavedSession{
        .tab_count = @intCast(tabs_slice.len),
        .tabs = tabs_slice,
    };
}

fn isWhitespace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

// ─── Delete ───────────────────────────────────────────────────────────────────

/// Remove a session file. Silently ignores if the file does not exist.
pub fn deleteSession(allocator: std.mem.Allocator, io: std.Io, environ: std.process.Environ, name: []const u8) void {
    const session_path = getSessionPath(allocator, environ, name) catch return;
    defer allocator.free(session_path);
    std.Io.Dir.deleteFileAbsolute(io, session_path) catch {};
}

// ─── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

/// Save using a direct file path (bypasses HOME; for tests only).
fn saveSessionToPath(allocator: std.mem.Allocator, io: std.Io, path: []const u8, tab_manager: *tab_mod.TabManager) !void {
    const json = try buildJson(allocator, tab_manager);
    defer allocator.free(json);
    const file = try std.Io.Dir.createFileAbsolute(io, path, .{ .truncate = true });
    defer file.close(io);
    var write_buf: [4096]u8 = undefined;
    var file_writer = file.writer(io, &write_buf);
    try file_writer.interface.writeAll(json);
    try file_writer.interface.flush();
}

/// Load from a direct file path (bypasses HOME; for tests only).
fn loadSessionFromPath(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !?SavedSession {
    const file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close(io);
    var read_buf: [4096]u8 = undefined;
    var file_reader = file.reader(io, &read_buf);
    const contents = try file_reader.interface.allocRemaining(allocator, .limited(1024 * 64));
    defer allocator.free(contents);
    return try parseSession(allocator, contents);
}

test "save and load round-trip" {
    const allocator = testing.allocator;
    const io = std.testing.io;

    // Use a fixed path in /tmp that we can clean up.
    const file_path = "/tmp/zplit-test-roundtrip.json";
    defer std.Io.Dir.deleteFileAbsolute(io, file_path) catch {};

    // Build a tab manager with 2 tabs.
    var mgr = try tab_mod.TabManager.init(allocator);
    defer mgr.deinit();
    mgr.activeTab(0).setName("dev");
    const tab2_idx = try mgr.createTab(1);
    mgr.activeTab(tab2_idx).setName("logs");

    try saveSessionToPath(allocator, io, file_path, &mgr);

    var loaded = (try loadSessionFromPath(allocator, io, file_path)) orelse return error.ExpectedSession;
    defer loaded.deinit(allocator);

    try testing.expectEqual(@as(u8, 2), loaded.tab_count);
    try testing.expectEqualStrings("dev", loaded.tabs[0].name);
    try testing.expectEqualStrings("logs", loaded.tabs[1].name);
}

test "load nonexistent returns null" {
    const allocator = testing.allocator;
    const io = std.testing.io;
    const result = try loadSessionFromPath(allocator, io, "/tmp/zplit-test-nonexistent-99999.json");
    try testing.expectEqual(@as(?SavedSession, null), result);
}

test "delete removes file" {
    const io = std.testing.io;

    const file_path = "/tmp/zplit-del-test.json";

    // Create a dummy file.
    const f = try std.Io.Dir.createFileAbsolute(io, file_path, .{});
    f.close(io);

    // Verify it exists.
    try std.Io.Dir.accessAbsolute(io, file_path, .{});

    // Delete it.
    std.Io.Dir.deleteFileAbsolute(io, file_path) catch {};

    // Should no longer exist.
    const err = std.Io.Dir.accessAbsolute(io, file_path, .{});
    try testing.expectError(error.FileNotFound, err);
}
