const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;

pub const protocol = @import("protocol.zig");
pub const terminal = @import("terminal.zig");
pub const pty = @import("pty.zig");
pub const vt = @import("vt.zig");
pub const scrollback = @import("scrollback.zig");
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

// ─── Commands ─────────────────────────────────────────────────────────────────

/// Internal: run as the server process (foreground — caller forked us).
fn runServer(allocator: std.mem.Allocator, cfg: *const config.Config, name: []const u8) !void {
    const socket_path = try getSocketPath(allocator, cfg, name);
    defer allocator.free(socket_path);

    var srv = try server.Server.init(allocator, socket_path, cfg.*);
    defer srv.deinit();

    try srv.run();
}

/// Attach to an existing session by name.
fn attachSession(allocator: std.mem.Allocator, cfg: *const config.Config, name: []const u8) !void {
    const socket_path = try getSocketPath(allocator, cfg, name);
    defer allocator.free(socket_path);

    // Verify socket exists before trying to connect.
    std.fs.accessAbsolute(socket_path, .{}) catch {
        std.debug.print("No session named '{s}' found (socket not present).\n", .{name});
        return error.SessionNotFound;
    };

    try client.run(socket_path);
}

/// Check if a server is already running; if not, fork + exec self as --server,
/// wait for the socket to appear, then connect.
fn startNewSession(allocator: std.mem.Allocator, cfg: *const config.Config, name: []const u8) !void {
    const socket_path = try getSocketPath(allocator, cfg, name);
    defer allocator.free(socket_path);

    // If the socket already exists, just attach.
    if (std.fs.accessAbsolute(socket_path, .{})) {
        return client.run(socket_path);
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
        _ = linux.setsid();

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
    const dir_path = try getSocketDir(allocator, cfg);
    defer allocator.free(dir_path);

    var dir = std.fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound) {
            std.debug.print("No sessions found (socket directory does not exist).\n", .{});
            return;
        }
        return err;
    };
    defer dir.close();

    var found: u32 = 0;
    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file and entry.kind != .unix_domain_socket) continue;
        if (!std.mem.endsWith(u8, entry.name, ".sock")) continue;
        const session_name = entry.name[0 .. entry.name.len - ".sock".len];
        std.debug.print("{s}\n", .{session_name});
        found += 1;
    }

    if (found == 0) {
        std.debug.print("No active sessions.\n", .{});
    }
}

// ─── Usage ────────────────────────────────────────────────────────────────────

fn printUsage() void {
    std.debug.print(
        \\Usage: zlice [command] [args]
        \\
        \\Commands:
        \\  (none)              Start a new session (name "0")
        \\  attach <name>       Attach to an existing session
        \\  list                List active sessions
        \\
        \\Options:
        \\  --server <name>     Internal: start server process (used by auto-start)
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

    if (args.len < 2) {
        // Default: start (or attach to) session "0".
        return startNewSession(allocator, &cfg, "0");
    }

    const cmd = args[1];

    if (std.mem.eql(u8, cmd, "--server")) {
        const name = if (args.len > 2) args[2] else "0";
        return runServer(allocator, &cfg, name);
    } else if (std.mem.eql(u8, cmd, "attach")) {
        const name = if (args.len > 2) args[2] else "0";
        return attachSession(allocator, &cfg, name);
    } else if (std.mem.eql(u8, cmd, "list")) {
        return listSessions(allocator, &cfg);
    } else if (std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h")) {
        printUsage();
    } else if (std.mem.eql(u8, cmd, "--version") or std.mem.eql(u8, cmd, "-v")) {
        std.debug.print("zlice v0.1.0\n", .{});
    } else {
        std.debug.print("Unknown command: {s}\n\n", .{cmd});
        printUsage();
    }
}

// ─── Tests ────────────────────────────────────────────────────────────────────

test {
    _ = protocol;
    _ = terminal;
    _ = pty;
    _ = vt;
    _ = scrollback;
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
    // Default socket_dir is "/tmp/zlice-{uid}"
    const dir = try getSocketDir(allocator, &cfg);
    defer allocator.free(dir);

    // Should not contain the literal "{uid}" placeholder.
    try std.testing.expect(std.mem.indexOf(u8, dir, "{uid}") == null);
    // Should start with "/tmp/zlice-".
    try std.testing.expect(std.mem.startsWith(u8, dir, "/tmp/zlice-"));
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
        .socket_dir = "/run/zlice",
    };
    const path = try getSocketPath(allocator, &cfg, "test");
    defer allocator.free(path);

    try std.testing.expectEqualStrings("/run/zlice/test.sock", path);
}
