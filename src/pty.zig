const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;

// Raw ioctl constants for PTY management (x86_64 / arm64 / riscv64)
// These are the standard Linux values for non-MIPS, non-SPARC arches.
const TIOCGPTN: u32 = linux.T.IOCGPTN;
const TIOCSPTLCK: u32 = linux.T.IOCSPTLCK;
const TIOCSCTTY: u32 = linux.T.IOCSCTTY;
const TIOCSWINSZ: u32 = linux.T.IOCSWINSZ;

pub const Pty = struct {
    master_fd: posix.fd_t,
    pid: posix.pid_t,

    /// Spawn a new PTY with the given shell and terminal dimensions.
    pub fn spawn(shell: [:0]const u8, cols: u16, rows: u16, environ: std.process.Environ) !Pty {
        // Open /dev/ptmx (PTY master multiplexer)
        const ptmx_rc = linux.open("/dev/ptmx", .{ .ACCMODE = .RDWR, .NOCTTY = true, .CLOEXEC = true }, 0);
        if (linux.errno(ptmx_rc) != .SUCCESS) return error.OpenPtmxFailed;
        const master_fd: posix.fd_t = @intCast(ptmx_rc);
        errdefer _ = linux.close(master_fd);

        // Unlock the PTY slave (TIOCSPTLCK = 0)
        var lock: c_int = 0;
        if (linux.ioctl(master_fd, TIOCSPTLCK, @intFromPtr(&lock)) != 0) {
            return error.IoctlFailed;
        }

        // Get the PTY slave number (TIOCGPTN)
        var pty_num: c_uint = 0;
        if (linux.ioctl(master_fd, TIOCGPTN, @intFromPtr(&pty_num)) != 0) {
            return error.IoctlFailed;
        }

        // Build slave path "/dev/pts/{n}"
        var slave_path_buf: [32:0]u8 = undefined;
        const slave_path = try std.fmt.bufPrintZ(&slave_path_buf, "/dev/pts/{d}", .{pty_num});

        // Set window size on master before fork
        var ws = posix.winsize{
            .row = rows,
            .col = cols,
            .xpixel = 0,
            .ypixel = 0,
        };
        if (linux.ioctl(master_fd, TIOCSWINSZ, @intFromPtr(&ws)) != 0) {
            return error.IoctlFailed;
        }

        const fork_rc = linux.fork();
        if (linux.errno(fork_rc) != .SUCCESS) return error.ForkFailed;
        const pid: posix.pid_t = @intCast(fork_rc);

        if (pid == 0) {
            // ---- Child process ----
            _ = linux.close(master_fd);

            // Create a new session so we can have a controlling terminal
            const sid_result = linux.setsid();
            const sid_err = if (@TypeOf(sid_result) == usize)
                linux.errno(sid_result)
            else if (sid_result == -1)
                linux.E.PERM // any non-SUCCESS value
            else
                linux.E.SUCCESS;
            if (sid_err != .SUCCESS) std.process.exit(1);

            // Open slave PTY as controlling terminal
            const slave_rc = linux.open(slave_path.ptr, .{ .ACCMODE = .RDWR }, 0);
            if (linux.errno(slave_rc) != .SUCCESS) {
                std.process.exit(1);
            }
            const slave_fd: posix.fd_t = @intCast(slave_rc);

            // TIOCSCTTY: make this the controlling terminal (arg 0 = don't steal)
            _ = linux.ioctl(slave_fd, TIOCSCTTY, 0);

            // Redirect stdin/stdout/stderr to slave PTY
            if (linux.errno(linux.dup2(slave_fd, posix.STDIN_FILENO)) != .SUCCESS) std.process.exit(1);
            if (linux.errno(linux.dup2(slave_fd, posix.STDOUT_FILENO)) != .SUCCESS) std.process.exit(1);
            if (linux.errno(linux.dup2(slave_fd, posix.STDERR_FILENO)) != .SUCCESS) std.process.exit(1);

            // Close the slave fd if it's not one of the standard fds
            if (slave_fd > 2) _ = linux.close(slave_fd);

            // Build argv for execve
            const argv: [*:null]const ?[*:0]const u8 = &[_:null]?[*:0]const u8{shell};

            // Build envp with essential variables from parent + TERM override
            const home = std.process.Environ.getPosix(environ, "HOME") orelse "/";
            const user = std.process.Environ.getPosix(environ, "USER") orelse "user";
            const path = std.process.Environ.getPosix(environ, "PATH") orelse "/usr/local/bin:/usr/bin:/bin";
            const lang = std.process.Environ.getPosix(environ, "LANG") orelse "C.UTF-8";
            const shell_env = std.process.Environ.getPosix(environ, "SHELL") orelse "/bin/sh";

            // Inherit TERM from parent (e.g. st-256color) instead of forcing xterm-256color
            const term_val = std.process.Environ.getPosix(environ, "TERM") orelse "xterm-256color";
            var term_buf: [64]u8 = undefined;
            const term_str = std.fmt.bufPrintZ(&term_buf, "TERM={s}", .{term_val}) catch "TERM=xterm-256color";
            var home_buf: [256]u8 = undefined;
            const home_str = std.fmt.bufPrintZ(&home_buf, "HOME={s}", .{home}) catch "HOME=/";
            var user_buf: [128]u8 = undefined;
            const user_str = std.fmt.bufPrintZ(&user_buf, "USER={s}", .{user}) catch "USER=user";
            var path_buf: [1024]u8 = undefined;
            const path_str = std.fmt.bufPrintZ(&path_buf, "PATH={s}", .{path}) catch "PATH=/usr/bin:/bin";
            var lang_buf: [64]u8 = undefined;
            const lang_str = std.fmt.bufPrintZ(&lang_buf, "LANG={s}", .{lang}) catch "LANG=C.UTF-8";
            var shell_buf: [256]u8 = undefined;
            const shell_str = std.fmt.bufPrintZ(&shell_buf, "SHELL={s}", .{shell_env}) catch "SHELL=/bin/sh";

            // Optional env vars from parent
            const display = std.process.Environ.getPosix(environ, "DISPLAY");
            var display_buf: [128]u8 = undefined;
            const display_str: ?[:0]const u8 = if (display) |d|
                (std.fmt.bufPrintZ(&display_buf, "DISPLAY={s}", .{d}) catch null)
            else
                null;

            const xdg_rt = std.process.Environ.getPosix(environ, "XDG_RUNTIME_DIR");
            var xdg_buf: [256]u8 = undefined;
            const xdg_str: ?[:0]const u8 = if (xdg_rt) |x|
                (std.fmt.bufPrintZ(&xdg_buf, "XDG_RUNTIME_DIR={s}", .{x}) catch null)
            else
                null;

            // Build envp — up to 13 entries + null sentinel
            var env_entries: [15]?[*:0]const u8 = [_]?[*:0]const u8{null} ** 15;
            var env_idx: usize = 0;
            env_entries[env_idx] = term_str; env_idx += 1;
            env_entries[env_idx] = home_str; env_idx += 1;
            env_entries[env_idx] = user_str; env_idx += 1;
            env_entries[env_idx] = path_str; env_idx += 1;
            env_entries[env_idx] = lang_str; env_idx += 1;
            env_entries[env_idx] = shell_str; env_idx += 1;
            env_entries[env_idx] = "TERM_PROGRAM=zplit"; env_idx += 1;
            env_entries[env_idx] = "ZELLIJ=0"; env_idx += 1;
            env_entries[env_idx] = "ZPLIT=1"; env_idx += 1; // Prevent zplit auto-start nesting
            env_entries[env_idx] = "fish_greeting="; env_idx += 1; // Suppress fish welcome message
            if (display_str) |s| { env_entries[env_idx] = s; env_idx += 1; }
            if (xdg_str) |s| { env_entries[env_idx] = s; env_idx += 1; }
            env_entries[env_idx] = null;

            const envp: [*:null]const ?[*:0]const u8 = @ptrCast(&env_entries);

            _ = linux.execve(shell, argv, envp);
            std.process.exit(1);
        }

        // ---- Parent process ----
        return Pty{
            .master_fd = master_fd,
            .pid = pid,
        };
    }

    /// Resize the PTY window.
    pub fn setSize(self: *Pty, cols: u16, rows: u16) !void {
        var ws = posix.winsize{
            .row = rows,
            .col = cols,
            .xpixel = 0,
            .ypixel = 0,
        };
        if (linux.ioctl(self.master_fd, TIOCSWINSZ, @intFromPtr(&ws)) != 0) {
            return error.IoctlFailed;
        }
    }

    /// Close the PTY and send SIGHUP to the child process.
    pub fn close(self: *Pty) void {
        _ = linux.close(self.master_fd);
        posix.kill(self.pid, posix.SIG.HUP) catch {};
    }

    /// Read data from the PTY master. Returns the number of bytes read.
    /// Returns 0 on WouldBlock (non-blocking scenario).
    pub fn read(self: *Pty, buf: []u8) !usize {
        return posix.read(self.master_fd, buf) catch |err| switch (err) {
            error.WouldBlock => return 0,
            else => return err,
        };
    }

    /// Write data to the PTY master. Returns the number of bytes written.
    pub fn write(self: *Pty, data: []const u8) !usize {
        while (true) {
            const w_rc = linux.write(self.master_fd, data.ptr, data.len);
            switch (linux.errno(w_rc)) {
                .SUCCESS => return w_rc,
                .INTR => continue,
                else => return error.WriteFailed,
            }
        }
    }
};

test "Pty struct layout" {
    // Verify the struct has the expected fields and types without forking.
    // Field introspection must be done at comptime.
    const info = @typeInfo(Pty).@"struct";
    comptime std.debug.assert(info.fields.len == 2);

    comptime {
        var found_master_fd = false;
        var found_pid = false;
        for (info.fields) |f| {
            if (std.mem.eql(u8, f.name, "master_fd")) {
                std.debug.assert(f.type == posix.fd_t);
                found_master_fd = true;
            } else if (std.mem.eql(u8, f.name, "pid")) {
                std.debug.assert(f.type == posix.pid_t);
                found_pid = true;
            }
        }
        std.debug.assert(found_master_fd);
        std.debug.assert(found_pid);
    }
}
