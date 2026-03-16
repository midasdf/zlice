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
    pub fn spawn(shell: [:0]const u8, cols: u16, rows: u16) !Pty {
        // Open /dev/ptmx (PTY master multiplexer)
        const master_fd = try posix.openZ("/dev/ptmx", .{ .ACCMODE = .RDWR, .NOCTTY = true }, 0);
        errdefer posix.close(master_fd);

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

        const pid = try posix.fork();

        if (pid == 0) {
            // ---- Child process ----
            posix.close(master_fd);

            // Create a new session so we can have a controlling terminal
            const sid_result = linux.setsid();
            const sid_err = if (@TypeOf(sid_result) == usize)
                linux.E.init(sid_result)
            else if (sid_result == -1)
                linux.E.PERM // any non-SUCCESS value
            else
                linux.E.SUCCESS;
            if (sid_err != .SUCCESS) std.process.exit(1);

            // Open slave PTY as controlling terminal
            const slave_fd = posix.openZ(slave_path.ptr, .{ .ACCMODE = .RDWR }, 0) catch {
                std.process.exit(1);
            };

            // TIOCSCTTY: make this the controlling terminal (arg 0 = don't steal)
            _ = linux.ioctl(slave_fd, TIOCSCTTY, 0);

            // Redirect stdin/stdout/stderr to slave PTY
            posix.dup2(slave_fd, posix.STDIN_FILENO) catch std.process.exit(1);
            posix.dup2(slave_fd, posix.STDOUT_FILENO) catch std.process.exit(1);
            posix.dup2(slave_fd, posix.STDERR_FILENO) catch std.process.exit(1);

            // Close the slave fd if it's not one of the standard fds
            if (slave_fd > 2) posix.close(slave_fd);

            // Build argv and envp for execve
            const argv: [*:null]const ?[*:0]const u8 = &[_:null]?[*:0]const u8{shell};
            const envp: [*:null]const ?[*:0]const u8 = &[_:null]?[*:0]const u8{
                "TERM=xterm-256color",
            };

            posix.execveZ(shell, argv, envp) catch {};
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
        posix.close(self.master_fd);
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
        return posix.write(self.master_fd, data);
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
