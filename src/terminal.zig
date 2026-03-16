const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;

pub const TerminalSize = struct {
    cols: u16,
    rows: u16,
};

pub const RawMode = struct {
    original: posix.termios,
    fd: posix.fd_t,

    pub fn enter(fd: posix.fd_t) !RawMode {
        const original = try posix.tcgetattr(fd);
        var raw = original;

        // iflag: disable BRKINT, ICRNL, INPCK, ISTRIP, IXON
        raw.iflag.BRKINT = false;
        raw.iflag.ICRNL = false;
        raw.iflag.INPCK = false;
        raw.iflag.ISTRIP = false;
        raw.iflag.IXON = false;

        // oflag: disable OPOST
        raw.oflag.OPOST = false;

        // cflag: set CS8
        raw.cflag.CSIZE = .CS8;

        // lflag: disable ECHO, ICANON, ISIG, IEXTEN
        raw.lflag.ECHO = false;
        raw.lflag.ICANON = false;
        raw.lflag.ISIG = false;
        raw.lflag.IEXTEN = false;

        // cc: VMIN=1 VTIME=0 (block until at least 1 byte available)
        // Works with epoll: epoll only signals EPOLLIN when data is ready.
        raw.cc[@intFromEnum(linux.V.MIN)] = 1;
        raw.cc[@intFromEnum(linux.V.TIME)] = 0;

        try posix.tcsetattr(fd, .NOW, raw);

        return RawMode{ .original = original, .fd = fd };
    }

    pub fn leave(self: *RawMode) void {
        posix.tcsetattr(self.fd, .NOW, self.original) catch {};
    }
};

pub fn getSize(fd: posix.fd_t) !TerminalSize {
    var wsz: posix.winsize = undefined;
    const fd_usize: usize = @bitCast(@as(isize, fd));
    const rc = linux.syscall3(.ioctl, fd_usize, linux.T.IOCGWINSZ, @intFromPtr(&wsz));
    switch (linux.E.init(rc)) {
        .SUCCESS => {},
        else => return error.IoctlFailed,
    }
    return TerminalSize{
        .cols = wsz.col,
        .rows = wsz.row,
    };
}

test "getSize returns nonzero on TTY" {
    const fd = posix.STDOUT_FILENO;
    if (!posix.isatty(fd)) {
        return error.SkipZigTest;
    }
    const size = try getSize(fd);
    try std.testing.expect(size.cols > 0);
    try std.testing.expect(size.rows > 0);
}
