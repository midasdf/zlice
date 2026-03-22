const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;

pub const protocol = @import("protocol.zig");
pub const terminal = @import("terminal.zig");
pub const pty = @import("pty.zig");
pub const vt = @import("vt.zig");
pub const scrollback = @import("scrollback.zig");
pub const grid = @import("grid.zig");
pub const mode = @import("mode.zig");
pub const input = @import("input.zig");
pub const config = @import("config.zig");
pub const pane = @import("pane.zig");
pub const tab = @import("tab.zig");
pub const render = @import("render.zig");
pub const status_bar = @import("status_bar.zig");
pub const client = @import("client.zig");
pub const server = @import("server.zig");
pub const session = @import("session.zig");

// ─── Socket path helpers ──────────────────────────────────────────────────────

/// Resolve `socket_dir` from config, replacing `{uid}` with the real UID.
/// Returns a sentinel-terminated string owned by the caller.
fn getSocketDir(allocator: std.mem.Allocator, cfg: *const config.Config) ![:0]u8 {
    const uid = linux.getuid();
    const uid_str = try std.fmt.allocPrint(allocator, "{d}", .{uid});
    defer allocator.free(uid_str);

    // Replace `{uid}` in socket_dir
    const template = cfg.socket_dir;
    const placeholder = "{uid}";
    const resolved = if (std.mem.indexOf(u8, template, placeholder)) |pos| blk: {
        const before = template[0..pos];
        const after = template[pos + placeholder.len ..];
        break :blk try std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ before, uid_str, after });
    } else blk: {
        break :blk try allocator.dupe(u8, template);
    };
    defer allocator.free(resolved);
    return allocator.dupeZ(u8, resolved);
}

/// Build the full UNIX socket path: `{socket_dir}/{name}.sock`.
/// Returns a sentinel-terminated string owned by the caller.
fn getSocketPath(allocator: std.mem.Allocator, cfg: *const config.Config, name: []const u8) ![:0]u8 {
    const dir = try getSocketDir(allocator, cfg);
    defer allocator.free(dir);
    const s = try std.fmt.allocPrint(allocator, "{s}/{s}.sock", .{ dir, name });
    defer allocator.free(s);
    return allocator.dupeZ(u8, s);
}

// ─── Session discovery ────────────────────────────────────────────────────────

/// Check if a session server is alive by attempting a connection.
/// Returns true if the server accepted the connection (alive).
/// Returns false if connection failed (stale socket).
fn isSessionAlive(socket_path: [:0]const u8) bool {
    const fd = client.connect(socket_path) catch return false;
    posix.close(fd);
    return true;
}

/// Find the lowest unused numeric session name (0, 1, 2, ...).
/// Stale sockets (dead server) are cleaned up and their names reused.
/// Caller owns the returned string.
fn findNextSessionName(allocator: std.mem.Allocator, cfg: *const config.Config) ![]const u8 {
    var num: u32 = 0;
    while (num < 1000) : (num += 1) {
        const name = try std.fmt.allocPrint(allocator, "{d}", .{num});
        const socket_path = try getSocketPath(allocator, cfg, name);
        defer allocator.free(socket_path);

        if (std.fs.accessAbsolute(socket_path, .{})) {
            // Socket exists — check if server is alive.
            if (isSessionAlive(socket_path)) {
                // Session alive, try next number.
                allocator.free(name);
            } else {
                // Stale socket — clean up and reuse this name.
                posix.unlink(socket_path) catch {};
                return name;
            }
        } else |_| {
            // Socket doesn't exist — name is free.
            return name;
        }
    }
    // Fallback (shouldn't reach with 1000 slots).
    return try std.fmt.allocPrint(allocator, "{d}", .{@as(u32, 0)});
}

/// Find an existing session to attach to.
/// Returns the name of the first (lowest-numbered) live session.
/// Cleans up stale sockets encountered during scan.
/// Caller owns the returned string.
fn findFirstSession(allocator: std.mem.Allocator, cfg: *const config.Config) ![]const u8 {
    const dir_path = try getSocketDir(allocator, cfg);
    defer allocator.free(dir_path);

    var dir = std.fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch {
        return error.NoActiveSessions;
    };
    defer dir.close();

    var best: ?[]const u8 = null;
    var best_num: ?u32 = null;

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file and entry.kind != .unix_domain_socket) continue;
        if (!std.mem.endsWith(u8, entry.name, ".sock")) continue;
        const name = entry.name[0 .. entry.name.len - ".sock".len];

        // Verify liveness.
        const socket_path = try getSocketPath(allocator, cfg, name);
        defer allocator.free(socket_path);

        if (!isSessionAlive(socket_path)) {
            posix.unlink(socket_path) catch {};
            continue;
        }

        const num = std.fmt.parseInt(u32, name, 10) catch null;
        const should_update = if (best == null)
            true
        else if (num != null and (best_num == null or num.? < best_num.?))
            true
        else
            false;

        if (should_update) {
            if (best) |b| allocator.free(b);
            best = try allocator.dupe(u8, name);
            best_num = num;
        }
    }

    return best orelse error.NoActiveSessions;
}

/// Count live sessions. Returns count and a list of names.
/// Caller owns the returned names slice and each string within.
fn countSessions(allocator: std.mem.Allocator, cfg: *const config.Config) !struct { count: u32, names: [][]const u8 } {
    const dir_path = try getSocketDir(allocator, cfg);
    defer allocator.free(dir_path);

    var dir = std.fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch {
        const empty = try allocator.alloc([]const u8, 0);
        return .{ .count = 0, .names = empty };
    };
    defer dir.close();

    var names: std.ArrayListUnmanaged([]const u8) = .{};

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file and entry.kind != .unix_domain_socket) continue;
        if (!std.mem.endsWith(u8, entry.name, ".sock")) continue;
        const name = entry.name[0 .. entry.name.len - ".sock".len];

        const socket_path = try getSocketPath(allocator, cfg, name);
        defer allocator.free(socket_path);

        if (isSessionAlive(socket_path)) {
            try names.append(allocator, try allocator.dupe(u8, name));
        } else {
            posix.unlink(socket_path) catch {};
        }
    }

    const owned = try names.toOwnedSlice(allocator);
    return .{ .count = @intCast(owned.len), .names = owned };
}

// ─── Commands ─────────────────────────────────────────────────────────────────

/// Internal: run as the server process (foreground — caller forked us).
fn runServer(allocator: std.mem.Allocator, cfg: *const config.Config, name: []const u8) !void {
    const socket_path = try getSocketPath(allocator, cfg, name);
    defer allocator.free(socket_path);

    var srv = try server.Server.init(allocator, socket_path, name, cfg.*);
    defer srv.deinit();

    try srv.run();
}

/// Attach to an existing session by name.
fn attachSession(allocator: std.mem.Allocator, cfg: *const config.Config, name: []const u8) !void {
    const socket_path = try getSocketPath(allocator, cfg, name);
    defer allocator.free(socket_path);

    // Verify socket exists before trying to connect.
    std.fs.accessAbsolute(socket_path, .{}) catch {
        std.debug.print("No session named '{s}' found.\n", .{name});
        return error.SessionNotFound;
    };

    // Verify server is alive (clean up stale socket if not).
    if (!isSessionAlive(socket_path)) {
        posix.unlink(socket_path) catch {};
        std.debug.print("Session '{s}' is dead (stale socket removed).\n", .{name});
        return error.SessionNotFound;
    }

    try client.run(socket_path);
}

/// Attach without a name: auto-select if only one session, prompt if multiple.
fn attachAuto(allocator: std.mem.Allocator, cfg: *const config.Config) !void {
    const result = try countSessions(allocator, cfg);
    defer {
        for (result.names) |n| allocator.free(n);
        allocator.free(result.names);
    }

    switch (result.count) {
        0 => {
            std.debug.print("No active sessions. Run 'zplit' to create one.\n", .{});
        },
        1 => {
            // Single session — attach directly.
            try attachSession(allocator, cfg, result.names[0]);
        },
        else => {
            // Multiple sessions — list them and ask user to specify.
            std.debug.print("Multiple sessions active. Please specify a name:\n\n", .{});
            for (result.names) |name| {
                std.debug.print("  {s}\n", .{name});
            }
            std.debug.print("\nUsage: zplit attach <name>\n", .{});
        },
    }
}

/// Create a new session. Errors if the session name is already in use.
/// Stale sockets are cleaned up transparently.
fn startNewSession(allocator: std.mem.Allocator, cfg: *const config.Config, name: []const u8) !void {
    const socket_path = try getSocketPath(allocator, cfg, name);
    defer allocator.free(socket_path);

    // If socket exists, check liveness.
    if (std.fs.accessAbsolute(socket_path, .{})) {
        if (isSessionAlive(socket_path)) {
            std.debug.print("Session '{s}' already exists. Use 'zplit attach {s}' to connect.\n", .{ name, name });
            return;
        }
        // Stale socket — clean up and proceed with creating a new session.
        posix.unlink(socket_path) catch {};
    } else |_| {}

    // Fork + exec self with `--server <name>`.
    const self_exe = try std.fs.selfExePathAlloc(allocator);
    defer allocator.free(self_exe);

    const self_exe_z = try allocator.dupeZ(u8, self_exe);
    defer allocator.free(self_exe_z);

    const name_z = try allocator.dupeZ(u8, name);
    defer allocator.free(name_z);

    // Build a null-terminated envp from the current environment (no libc).
    // std.os.environ is [][*:0]u8; we need [*:null]const ?[*:0]const u8.
    const env_slice = std.os.environ;
    const envp_buf = try allocator.alloc(?[*:0]const u8, env_slice.len + 1);
    defer allocator.free(envp_buf);
    for (env_slice, 0..) |ptr, i| {
        envp_buf[i] = @ptrCast(ptr);
    }
    envp_buf[env_slice.len] = null;
    const envp: [*:null]const ?[*:0]const u8 = @ptrCast(envp_buf.ptr);

    const pid = try posix.fork();
    if (pid == 0) {
        // Child: exec self as server.
        // Detach from the parent's session/process group so it survives.
        const sid_result = linux.setsid();
        const sid_err = if (@TypeOf(sid_result) == usize)
            linux.E.init(sid_result)
        else if (sid_result == -1)
            linux.E.PERM
        else
            linux.E.SUCCESS;
        if (sid_err != .SUCCESS) std.process.exit(1);

        const argv = [_:null]?[*:0]const u8{
            self_exe_z.ptr,
            "--server",
            name_z.ptr,
            null,
        };
        const err = posix.execveZ(self_exe_z, &argv, envp);
        // If execve returns, something went wrong.
        std.debug.print("execve failed: {s}\n", .{@errorName(err)});
        posix.exit(1);
    }

    // Parent: poll for the socket file, up to ~1 second (100 × 10 ms).
    var attempts: u32 = 0;
    while (attempts < 100) : (attempts += 1) {
        std.Thread.sleep(10 * std.time.ns_per_ms);
        if (std.fs.accessAbsolute(socket_path, .{})) {
            break;
        } else |_| {}
    }

    try client.run(socket_path);
}

/// List all active sessions by scanning the socket directory for .sock files.
fn listSessions(allocator: std.mem.Allocator, cfg: *const config.Config) !void {
    const result = try countSessions(allocator, cfg);
    defer {
        for (result.names) |n| allocator.free(n);
        allocator.free(result.names);
    }

    if (result.count == 0) {
        std.debug.print("No active sessions.\n", .{});
        return;
    }

    for (result.names) |name| {
        std.debug.print("{s}\n", .{name});
    }
}

/// Kill a session by name. Connects and immediately disconnects, relying on
/// server cleanup. If the server is already dead, removes the stale socket.
fn killSession(allocator: std.mem.Allocator, cfg: *const config.Config, name: []const u8) !void {
    const socket_path = try getSocketPath(allocator, cfg, name);
    defer allocator.free(socket_path);

    std.fs.accessAbsolute(socket_path, .{}) catch {
        std.debug.print("No session named '{s}' found.\n", .{name});
        return;
    };

    if (!isSessionAlive(socket_path)) {
        posix.unlink(socket_path) catch {};
        std.debug.print("Removed stale session '{s}'.\n", .{name});
        return;
    }

    // Send a kill signal: connect, send a quit command, disconnect.
    // For now, just unlink the socket — the server will notice on next epoll
    // and shut down when it can no longer accept new connections.
    posix.unlink(socket_path) catch {};
    std.debug.print("Killed session '{s}'.\n", .{name});
}

/// Kill all sessions.
fn killAllSessions(allocator: std.mem.Allocator, cfg: *const config.Config) !void {
    const result = try countSessions(allocator, cfg);
    defer {
        for (result.names) |n| allocator.free(n);
        allocator.free(result.names);
    }

    if (result.count == 0) {
        std.debug.print("No active sessions.\n", .{});
        return;
    }

    for (result.names) |name| {
        try killSession(allocator, cfg, name);
    }
}

// ─── Usage ────────────────────────────────────────────────────────────────────

fn printUsage() void {
    std.debug.print(
        \\Usage: zplit [command] [options]
        \\
        \\Commands:
        \\  (none)                Create a new session (auto-named)
        \\  attach [name]    (a)  Attach to an existing session
        \\  list-sessions    (ls) List active sessions
        \\  kill-session <name>(k) Kill a session
        \\  kill-all-sessions (ka) Kill all sessions
        \\
        \\Options:
        \\  -s <name>           Set session name for new session
        \\  --server <name>     Internal: start server process
        \\  --help, -h          Show this help message
        \\  --version, -v       Show version information
        \\
    , .{});
}

// ─── Entry point ──────────────────────────────────────────────────────────────

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Load config (falls back to defaults if the file doesn't exist).
    var cfg = try config.loadFromFile(allocator);
    defer cfg.deinit();

    // Parse args.
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // Scan for -s <name> flag anywhere in args.
    var session_name: ?[]const u8 = null;
    var filtered_args: std.ArrayListUnmanaged([]const u8) = .{};
    defer filtered_args.deinit(allocator);

    for (args, 0..) |arg, i| {
        if (std.mem.eql(u8, arg, "-s") and i + 1 < args.len) {
            session_name = args[i + 1];
        } else if (i > 0 and i < args.len) {
            // Check if this arg is the value for -s (skip it).
            if (i >= 2 and std.mem.eql(u8, args[i - 1], "-s")) continue;
            try filtered_args.append(allocator, arg);
        }
    }

    const has_subcmd = filtered_args.items.len > 0;
    const subcmd = if (has_subcmd) filtered_args.items[0] else "";

    // No subcommand: create a new session.
    if (!has_subcmd) {
        const name = if (session_name) |s|
            try allocator.dupe(u8, s)
        else
            try findNextSessionName(allocator, &cfg);
        defer allocator.free(name);
        return startNewSession(allocator, &cfg, name);
    }

    // ── Internal ──
    if (std.mem.eql(u8, subcmd, "--server")) {
        const name = if (filtered_args.items.len > 1) filtered_args.items[1] else "0";
        return runServer(allocator, &cfg, name);
    }

    // ── attach / a ──
    if (std.mem.eql(u8, subcmd, "attach") or std.mem.eql(u8, subcmd, "a")) {
        if (filtered_args.items.len > 1) {
            return attachSession(allocator, &cfg, filtered_args.items[1]);
        }
        return attachAuto(allocator, &cfg);
    }

    // ── list-sessions / ls / list (backward compat) ──
    if (std.mem.eql(u8, subcmd, "list-sessions") or
        std.mem.eql(u8, subcmd, "ls") or
        std.mem.eql(u8, subcmd, "list"))
    {
        return listSessions(allocator, &cfg);
    }

    // ── kill-session / k ──
    if (std.mem.eql(u8, subcmd, "kill-session") or std.mem.eql(u8, subcmd, "k")) {
        if (filtered_args.items.len > 1) {
            return killSession(allocator, &cfg, filtered_args.items[1]);
        }
        std.debug.print("Usage: zplit kill-session <name>\n", .{});
        return;
    }

    // ── kill-all-sessions / ka ──
    if (std.mem.eql(u8, subcmd, "kill-all-sessions") or std.mem.eql(u8, subcmd, "ka")) {
        return killAllSessions(allocator, &cfg);
    }

    // ── help / version ──
    if (std.mem.eql(u8, subcmd, "--help") or std.mem.eql(u8, subcmd, "-h")) {
        printUsage();
        return;
    }
    if (std.mem.eql(u8, subcmd, "--version") or std.mem.eql(u8, subcmd, "-v")) {
        std.debug.print("zplit v0.1.0\n", .{});
        return;
    }

    std.debug.print("Unknown command: {s}\n\n", .{subcmd});
    printUsage();
}

// ─── Tests ────────────────────────────────────────────────────────────────────

test {
    _ = protocol;
    _ = terminal;
    _ = pty;
    _ = vt;
    _ = scrollback;
    _ = grid;
    _ = mode;
    _ = input;
    _ = config;
    _ = pane;
    _ = tab;
    _ = render;
    _ = status_bar;
    _ = client;
    _ = server;
    _ = session;
}

test "getSocketDir replaces {uid}" {
    const allocator = std.testing.allocator;
    var cfg = config.Config{};
    // Default socket_dir is "/tmp/zplit-{uid}"
    const dir = try getSocketDir(allocator, &cfg);
    defer allocator.free(dir);

    // Should not contain the literal "{uid}" placeholder.
    try std.testing.expect(std.mem.indexOf(u8, dir, "{uid}") == null);
    // Should start with "/tmp/zplit-".
    try std.testing.expect(std.mem.startsWith(u8, dir, "/tmp/zplit-"));
}

test "getSocketPath builds correct path" {
    const allocator = std.testing.allocator;
    var cfg = config.Config{};
    const path = try getSocketPath(allocator, &cfg, "mysession");
    defer allocator.free(path);

    // Should end with "/mysession.sock".
    try std.testing.expect(std.mem.endsWith(u8, path, "/mysession.sock"));
    // Should not contain placeholder.
    try std.testing.expect(std.mem.indexOf(u8, path, "{uid}") == null);
}

test "getSocketPath no {uid} in template" {
    const allocator = std.testing.allocator;
    var cfg = config.Config{
        .socket_dir = "/run/zplit",
    };
    const path = try getSocketPath(allocator, &cfg, "test");
    defer allocator.free(path);

    try std.testing.expectEqualStrings("/run/zplit/test.sock", path);
}

test "findNextSessionName returns 0 when no sockets exist" {
    const allocator = std.testing.allocator;
    // Use a temporary directory that definitely doesn't exist.
    var cfg = config.Config{
        .socket_dir = "/tmp/zplit-test-nonexistent-999999",
    };
    const name = try findNextSessionName(allocator, &cfg);
    defer allocator.free(name);

    try std.testing.expectEqualStrings("0", name);
}
