const std = @import("std");

pub const Config = struct {
    // [general]
    default_shell: []const u8 = "/bin/sh",
    scrollback_lines: u16 = 1000,
    scrollback_max_bytes: u32 = 1048576,
    max_panes: u8 = 8,
    // [keybinds]
    pane_mode_key: []const u8 = "ctrl+p",
    tab_mode_key: []const u8 = "ctrl+t",
    scroll_mode_key: []const u8 = "ctrl+s",
    session_mode_key: []const u8 = "ctrl+o",
    lock_mode_key: []const u8 = "ctrl+g",
    // [appearance]
    status_bar: bool = true,
    status_bar_position: []const u8 = "bottom",
    pane_border_style: []const u8 = "single",
    // [session]
    socket_dir: []const u8 = "/tmp/zlice-{uid}",
    auto_save_layout: bool = true,
};

/// Parse a minimal TOML subset into a Config.
/// String fields that are overridden by the file are allocated with `allocator`.
/// Callers must free those strings. Default string literals are not heap-allocated.
pub fn parse(allocator: std.mem.Allocator, content: []const u8) !Config {
    var cfg = Config{};

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw_line| {
        // Strip trailing \r
        var line = raw_line;
        if (line.len > 0 and line[line.len - 1] == '\r') {
            line = line[0 .. line.len - 1];
        }

        // Strip leading/trailing whitespace
        line = std.mem.trim(u8, line, " \t");

        // Skip blank lines and comments
        if (line.len == 0 or line[0] == '#') continue;

        // Skip table headers
        if (line[0] == '[') continue;

        // Parse key = value
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        var val = std.mem.trim(u8, line[eq + 1 ..], " \t");

        // Strip inline comment from value (only for non-string values)
        // For string values we handle comments after unquoting.
        const is_quoted = val.len >= 2 and val[0] == '"';

        if (!is_quoted) {
            // Strip trailing comment
            if (std.mem.indexOfScalar(u8, val, '#')) |hash| {
                val = std.mem.trim(u8, val[0..hash], " \t");
            }
        }

        if (is_quoted) {
            // Find closing quote (handle escaped quotes is out of scope for minimal TOML)
            const close = std.mem.indexOfScalarPos(u8, val, 1, '"') orelse continue;
            const str_val = val[1..close];

            if (std.mem.eql(u8, key, "default_shell")) {
                cfg.default_shell = try allocator.dupe(u8, str_val);
            } else if (std.mem.eql(u8, key, "pane_mode_key")) {
                cfg.pane_mode_key = try allocator.dupe(u8, str_val);
            } else if (std.mem.eql(u8, key, "tab_mode_key")) {
                cfg.tab_mode_key = try allocator.dupe(u8, str_val);
            } else if (std.mem.eql(u8, key, "scroll_mode_key")) {
                cfg.scroll_mode_key = try allocator.dupe(u8, str_val);
            } else if (std.mem.eql(u8, key, "session_mode_key")) {
                cfg.session_mode_key = try allocator.dupe(u8, str_val);
            } else if (std.mem.eql(u8, key, "lock_mode_key")) {
                cfg.lock_mode_key = try allocator.dupe(u8, str_val);
            } else if (std.mem.eql(u8, key, "status_bar_position")) {
                cfg.status_bar_position = try allocator.dupe(u8, str_val);
            } else if (std.mem.eql(u8, key, "pane_border_style")) {
                cfg.pane_border_style = try allocator.dupe(u8, str_val);
            } else if (std.mem.eql(u8, key, "socket_dir")) {
                cfg.socket_dir = try allocator.dupe(u8, str_val);
            }
        } else if (std.mem.eql(u8, val, "true")) {
            if (std.mem.eql(u8, key, "status_bar")) {
                cfg.status_bar = true;
            } else if (std.mem.eql(u8, key, "auto_save_layout")) {
                cfg.auto_save_layout = true;
            }
        } else if (std.mem.eql(u8, val, "false")) {
            if (std.mem.eql(u8, key, "status_bar")) {
                cfg.status_bar = false;
            } else if (std.mem.eql(u8, key, "auto_save_layout")) {
                cfg.auto_save_layout = false;
            }
        } else {
            // Integer
            if (std.mem.eql(u8, key, "scrollback_lines")) {
                cfg.scrollback_lines = std.fmt.parseInt(u16, val, 10) catch continue;
            } else if (std.mem.eql(u8, key, "scrollback_max_bytes")) {
                cfg.scrollback_max_bytes = std.fmt.parseInt(u32, val, 10) catch continue;
            } else if (std.mem.eql(u8, key, "max_panes")) {
                cfg.max_panes = std.fmt.parseInt(u8, val, 10) catch continue;
            }
        }
    }

    return cfg;
}

/// Load config from ~/.config/zlice/config.toml.
/// Returns defaults if the file does not exist.
/// All heap-allocated string fields must be freed by the caller.
pub fn loadFromFile(allocator: std.mem.Allocator) !Config {
    const home = std.posix.getenv("HOME") orelse "/root";
    const path = try std.fmt.allocPrint(allocator, "{s}/.config/zlice/config.toml", .{home});
    defer allocator.free(path);

    const file = std.fs.openFileAbsolute(path, .{}) catch |err| {
        if (err == error.FileNotFound) return Config{};
        return err;
    };
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(content);

    return parse(allocator, content);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "parse basic config" {
    const allocator = std.testing.allocator;

    const toml =
        \\[general]
        \\default_shell = "/bin/bash"
        \\scrollback_lines = 2000
        \\scrollback_max_bytes = 2097152
        \\max_panes = 16
        \\
        \\[keybinds]
        \\pane_mode_key = "ctrl+a"
        \\tab_mode_key = "ctrl+b"
        \\scroll_mode_key = "ctrl+x"
        \\session_mode_key = "ctrl+e"
        \\lock_mode_key = "ctrl+l"
        \\
        \\[appearance]
        \\status_bar = false
        \\status_bar_position = "top"
        \\pane_border_style = "double"
        \\
        \\[session]
        \\socket_dir = "/run/user/1000/zlice"
        \\auto_save_layout = false
    ;

    const cfg = try parse(allocator, toml);

    // Free all heap-allocated string fields
    defer allocator.free(cfg.default_shell);
    defer allocator.free(cfg.pane_mode_key);
    defer allocator.free(cfg.tab_mode_key);
    defer allocator.free(cfg.scroll_mode_key);
    defer allocator.free(cfg.session_mode_key);
    defer allocator.free(cfg.lock_mode_key);
    defer allocator.free(cfg.status_bar_position);
    defer allocator.free(cfg.pane_border_style);
    defer allocator.free(cfg.socket_dir);

    try std.testing.expectEqualStrings("/bin/bash", cfg.default_shell);
    try std.testing.expectEqual(@as(u16, 2000), cfg.scrollback_lines);
    try std.testing.expectEqual(@as(u32, 2097152), cfg.scrollback_max_bytes);
    try std.testing.expectEqual(@as(u8, 16), cfg.max_panes);
    try std.testing.expectEqualStrings("ctrl+a", cfg.pane_mode_key);
    try std.testing.expectEqualStrings("ctrl+b", cfg.tab_mode_key);
    try std.testing.expectEqualStrings("ctrl+x", cfg.scroll_mode_key);
    try std.testing.expectEqualStrings("ctrl+e", cfg.session_mode_key);
    try std.testing.expectEqualStrings("ctrl+l", cfg.lock_mode_key);
    try std.testing.expectEqual(false, cfg.status_bar);
    try std.testing.expectEqualStrings("top", cfg.status_bar_position);
    try std.testing.expectEqualStrings("double", cfg.pane_border_style);
    try std.testing.expectEqualStrings("/run/user/1000/zlice", cfg.socket_dir);
    try std.testing.expectEqual(false, cfg.auto_save_layout);
}

test "defaults when empty" {
    const allocator = std.testing.allocator;

    const cfg = try parse(allocator, "");
    // No heap allocations for default values — nothing to free.

    try std.testing.expectEqualStrings("/bin/sh", cfg.default_shell);
    try std.testing.expectEqual(@as(u16, 1000), cfg.scrollback_lines);
    try std.testing.expectEqual(@as(u32, 1048576), cfg.scrollback_max_bytes);
    try std.testing.expectEqual(@as(u8, 8), cfg.max_panes);
    try std.testing.expectEqualStrings("ctrl+p", cfg.pane_mode_key);
    try std.testing.expectEqualStrings("ctrl+t", cfg.tab_mode_key);
    try std.testing.expectEqualStrings("ctrl+s", cfg.scroll_mode_key);
    try std.testing.expectEqualStrings("ctrl+o", cfg.session_mode_key);
    try std.testing.expectEqualStrings("ctrl+g", cfg.lock_mode_key);
    try std.testing.expectEqual(true, cfg.status_bar);
    try std.testing.expectEqualStrings("bottom", cfg.status_bar_position);
    try std.testing.expectEqualStrings("single", cfg.pane_border_style);
    try std.testing.expectEqualStrings("/tmp/zlice-{uid}", cfg.socket_dir);
    try std.testing.expectEqual(true, cfg.auto_save_layout);
}

test "comments and blank lines ignored" {
    const allocator = std.testing.allocator;

    const toml =
        \\# This is a top-level comment
        \\
        \\[general]
        \\# Shell to use
        \\default_shell = "/bin/zsh"
        \\
        \\# scrollback_lines = 9999   <- this line should be ignored
        \\
        \\[appearance]
        \\status_bar = true  # inline comment
    ;

    const cfg = try parse(allocator, toml);
    defer allocator.free(cfg.default_shell);

    try std.testing.expectEqualStrings("/bin/zsh", cfg.default_shell);
    // scrollback_lines commented out — should remain default
    try std.testing.expectEqual(@as(u16, 1000), cfg.scrollback_lines);
    try std.testing.expectEqual(true, cfg.status_bar);
}
