const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const protocol = @import("protocol.zig");
const terminal = @import("terminal.zig");
const input_mod = @import("input.zig");
const mode_mod = @import("mode.zig");

// ─── Debug ────────────────────────────────────────────────────────────────────

var debug_fd: ?posix.fd_t = null;

fn debugInit() void {
    const fd_or_err = posix.open("/tmp/zlice-debug.log", .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
    debug_fd = fd_or_err catch null;
}

fn debugLog(comptime fmt: []const u8, args: anytype) void {
    const fd = debug_fd orelse return;
    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    _ = posix.write(fd, msg) catch {};
}

// ─── Constants ────────────────────────────────────────────────────────────────

/// epoll user-data tags stored in the .u64 field.
const FD_STDIN: u64 = 0;
const FD_SOCKET: u64 = 1;
const FD_SIGNAL: u64 = 2;

/// Size of the receive buffer for frames arriving from the server.
const RECV_BUF_SIZE: usize = 65536 + protocol.HEADER_SIZE;

// ─── Client struct ────────────────────────────────────────────────────────────

pub const Client = struct {
    socket_fd: posix.fd_t,
    raw_mode: terminal.RawMode,
    input_parser: input_mod.InputParser,
    mode_state: mode_mod.ModeState,
    running: bool,
};

// ─── connect ──────────────────────────────────────────────────────────────────

/// Create a Unix-domain stream socket and connect it to `socket_path`.
/// Returns the connected file descriptor on success.
pub fn connect(socket_path: [:0]const u8) !posix.fd_t {
    const fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    errdefer posix.close(fd);

    var addr = posix.sockaddr.un{ .path = [_]u8{0} ** 108 };
    if (socket_path.len >= addr.path.len) return error.NameTooLong;
    @memcpy(addr.path[0..socket_path.len], socket_path);

    try posix.connect(
        fd,
        @ptrCast(&addr),
        @sizeOf(posix.sockaddr.un),
    );
    return fd;
}

// ─── sendFrame ────────────────────────────────────────────────────────────────

/// Encode a frame and write it entirely to `fd`.
pub fn sendFrame(
    fd: posix.fd_t,
    msg_type: protocol.MessageType,
    payload: []const u8,
) !void {
    var buf: [protocol.HEADER_SIZE + protocol.MAX_PAYLOAD_LEN]u8 = undefined;
    const n = try protocol.encodeFrame(&buf, msg_type, payload);
    var sent: usize = 0;
    while (sent < n) {
        const w = try posix.write(fd, buf[sent..n]);
        if (w == 0) return error.BrokenPipe;
        sent += w;
    }
}

// ─── run ──────────────────────────────────────────────────────────────────────

/// Full client event loop.
///
/// 1. Connect to the multiplexer socket.
/// 2. Enter terminal raw mode.
/// 3. Send a `hello` message with the current terminal geometry.
/// 4. Use epoll to multiplex stdin, the socket, and SIGWINCH (signalfd).
/// 5. Dispatch events until the server sends `exit` or a fatal error occurs.
/// 6. Restore the terminal and close resources on exit.
pub fn run(socket_path: [:0]const u8) !void {
    debugInit();
    debugLog("client starting\n", .{});

    // ── Connect ──────────────────────────────────────────────────────────────
    const sock_fd = try connect(socket_path);
    defer posix.close(sock_fd);

    // ── Raw mode ─────────────────────────────────────────────────────────────
    var raw = try terminal.RawMode.enter(posix.STDIN_FILENO);
    defer raw.leave();

    // ── Switch to alternate screen and clear ────────────────────────────────
    const stdout_fd = posix.STDOUT_FILENO;
    _ = posix.write(stdout_fd, "\x1b[?1049h\x1b[2J\x1b[H") catch {};
    defer {
        // Restore main screen on exit
        _ = posix.write(stdout_fd, "\x1b[?1049l") catch {};
    }

    // ── Hello ─────────────────────────────────────────────────────────────────
    const term_size = terminal.getSize(posix.STDOUT_FILENO) catch terminal.TerminalSize{ .cols = 80, .rows = 24 };
    const term_env = std.posix.getenv("TERM") orelse "xterm-256color";

    var hello_payload: [256]u8 = undefined;
    const hello_len = try protocol.encodeHello(&hello_payload, .{
        .client_version = protocol.PROTOCOL_VERSION,
        .term = term_env,
        .cols = term_size.cols,
        .rows = term_size.rows,
    });
    try sendFrame(sock_fd, .hello, hello_payload[0..hello_len]);

    // ── SIGWINCH via signalfd ─────────────────────────────────────────────────
    var sigwinch_mask = linux.sigemptyset();
    linux.sigaddset(&sigwinch_mask, linux.SIG.WINCH);
    // Block normal delivery of SIGWINCH so signalfd can consume it.
    _ = linux.sigprocmask(linux.SIG.BLOCK, &sigwinch_mask, null);
    const sig_rc = linux.signalfd(-1, &sigwinch_mask, linux.SFD.CLOEXEC);
    if (linux.E.init(sig_rc) != .SUCCESS) return error.SignalFdFailed;
    const sig_fd: posix.fd_t = @intCast(sig_rc);
    defer posix.close(sig_fd);

    // ── epoll ─────────────────────────────────────────────────────────────────
    const epfd_rc = linux.epoll_create1(linux.EPOLL.CLOEXEC);
    if (linux.E.init(epfd_rc) != .SUCCESS) return error.EpollCreateFailed;
    const epfd: i32 = @intCast(epfd_rc);
    defer posix.close(epfd);

    // Register stdin
    {
        var ev = linux.epoll_event{
            .events = linux.EPOLL.IN | linux.EPOLL.ERR | linux.EPOLL.HUP,
            .data = .{ .u64 = FD_STDIN },
        };
        const r = linux.epoll_ctl(epfd, linux.EPOLL.CTL_ADD, posix.STDIN_FILENO, &ev);
        if (linux.E.init(r) != .SUCCESS) return error.EpollCtlFailed;
    }
    // Register socket
    {
        var ev = linux.epoll_event{
            .events = linux.EPOLL.IN | linux.EPOLL.ERR | linux.EPOLL.HUP,
            .data = .{ .u64 = FD_SOCKET },
        };
        const r = linux.epoll_ctl(epfd, linux.EPOLL.CTL_ADD, sock_fd, &ev);
        if (linux.E.init(r) != .SUCCESS) return error.EpollCtlFailed;
    }
    // Register signalfd
    {
        var ev = linux.epoll_event{
            .events = linux.EPOLL.IN | linux.EPOLL.ERR,
            .data = .{ .u64 = FD_SIGNAL },
        };
        const r = linux.epoll_ctl(epfd, linux.EPOLL.CTL_ADD, sig_fd, &ev);
        if (linux.E.init(r) != .SUCCESS) return error.EpollCtlFailed;
    }

    // ── State ─────────────────────────────────────────────────────────────────
    var input_parser = input_mod.InputParser{};
    var mode_state = mode_mod.ModeState{};
    var running = true;

    // Receive buffer (frame reassembly)
    var recv_buf: [RECV_BUF_SIZE]u8 = undefined;
    var recv_len: usize = 0;

    const stdout = std.fs.File.stdout();

    // ── Event loop ────────────────────────────────────────────────────────────
    while (running) {
        var events: [16]linux.epoll_event = undefined;
        const n_events_rc = linux.epoll_wait(epfd, &events, events.len, -1);
        const n_events = switch (linux.E.init(n_events_rc)) {
            .SUCCESS => n_events_rc,
            .INTR => continue, // interrupted by another signal
            else => return error.EpollWaitFailed,
        };

        debugLog("epoll: {} events\n", .{n_events});
        for (events[0..n_events]) |ev| {
            debugLog("  event tag={}\n", .{ev.data.u64});
            switch (ev.data.u64) {
                FD_STDIN => {
                    var input_buf: [256]u8 = undefined;
                    const n_read = posix.read(posix.STDIN_FILENO, &input_buf) catch |err| {
                        debugLog("stdin read error: {}\n", .{err});
                        break;
                    };
                    debugLog("stdin: {} bytes\n", .{n_read});
                    if (n_read == 0) {
                        debugLog("stdin EOF\n", .{});
                        running = false;
                        break;
                    }
                    handleStdinBytes(
                        input_buf[0..n_read],
                        &input_parser,
                        &mode_state,
                        sock_fd,
                    ) catch |err| {
                        debugLog("handleStdinBytes error: {}\n", .{err});
                    };
                },

                FD_SOCKET => {
                    // Append into recv_buf
                    const space = recv_buf.len - recv_len;
                    if (space == 0) return error.ReceiveBufferFull;
                    const n_read = posix.read(sock_fd, recv_buf[recv_len..]) catch {
                        running = false;
                        break;
                    };
                    if (n_read == 0) {
                        running = false;
                        break;
                    }
                    recv_len += n_read;

                    // Drain complete frames
                    var consumed: usize = 0;
                    while (recv_len - consumed >= protocol.HEADER_SIZE) {
                        const hdr_slice: *const [protocol.HEADER_SIZE]u8 =
                            recv_buf[consumed..][0..protocol.HEADER_SIZE];
                        const hdr = protocol.decodeHeader(hdr_slice) catch break;
                        const frame_end = consumed + protocol.HEADER_SIZE + hdr.payload_len;
                        if (recv_len < frame_end) break; // need more data

                        const payload = recv_buf[consumed + protocol.HEADER_SIZE .. frame_end];
                        const keep = try handleServerFrame(
                            hdr.msg_type,
                            payload,
                            stdout,
                        );
                        if (!keep) {
                            running = false;
                            break;
                        }
                        consumed = frame_end;
                    }
                    // Shift unconsumed bytes to front
                    if (consumed > 0 and consumed < recv_len) {
                        std.mem.copyForwards(u8, recv_buf[0..], recv_buf[consumed..recv_len]);
                    }
                    recv_len -= consumed;
                },

                FD_SIGNAL => {
                    // Drain the signalfd (one signalfd_siginfo per event)
                    var ssi: linux.signalfd_siginfo = undefined;
                    _ = posix.read(sig_fd, std.mem.asBytes(&ssi)) catch {};
                    // Re-query terminal size and notify the server
                    const new_size = terminal.getSize(posix.STDOUT_FILENO) catch
                        terminal.TerminalSize{ .cols = 80, .rows = 24 };
                    var resize_payload: [4]u8 = undefined;
                    _ = try protocol.encodeResize(&resize_payload, .{
                        .cols = new_size.cols,
                        .rows = new_size.rows,
                    });
                    try sendFrame(sock_fd, .resize, &resize_payload);
                },

                else => {},
            }
        }
    }
}

// ─── handleStdinBytes ─────────────────────────────────────────────────────────

/// Parse raw bytes from stdin through the InputParser, then dispatch each
/// recognized Key via the ModeState.  Send the appropriate protocol message
/// for each action.
fn handleStdinBytes(
    bytes: []const u8,
    input_parser: *input_mod.InputParser,
    mode_state: *mode_mod.ModeState,
    sock_fd: posix.fd_t,
) !void {
    for (bytes) |byte| {
        const maybe_key = input_parser.feed(byte);
        const key = maybe_key orelse continue;

        const action = mode_state.handleKey(key);
        try dispatchAction(action, input_parser.lastSequence(), sock_fd);
    }
    // Flush any pending ESC that wasn't followed by '['
    if (input_parser.flush()) |key| {
        const action = mode_state.handleKey(key);
        try dispatchAction(action, input_parser.lastSequence(), sock_fd);
    }
}

// ─── dispatchAction ──────────────────────────────────────────────────────────

fn dispatchAction(
    action: mode_mod.Action,
    raw_bytes: []const u8,
    sock_fd: posix.fd_t,
) !void {
    switch (action) {
        .forward_to_pty => {
            try sendFrame(sock_fd, .input, raw_bytes);
        },
        .send_command => |cmd_id| {
            const payload = [_]u8{@intFromEnum(cmd_id)};
            try sendFrame(sock_fd, .command, &payload);
        },
        .send_direction_command => |v| {
            const payload = [_]u8{ @intFromEnum(v.cmd), @intFromEnum(v.dir) };
            try sendFrame(sock_fd, .command, &payload);
        },
        .send_resize => |v| {
            // Encode as: cmd(1) dir(1) delta_hi(1) delta_lo(1)
            const delta_u: u16 = @bitCast(v.delta);
            const payload = [_]u8{
                @intFromEnum(protocol.CommandId.resize_pane),
                @intFromEnum(v.dir),
                @intCast(delta_u >> 8),
                @intCast(delta_u & 0xFF),
            };
            try sendFrame(sock_fd, .command, &payload);
        },
        .switch_mode => |new_mode| {
            // Notify server so it can update the status bar display
            const payload = [_]u8{@intFromEnum(new_mode)};
            try sendFrame(sock_fd, .state, &payload);
        },
        .start_rename_tab => {
            // Tab rename requires interactive input — not yet implemented.
            // Send the command so the server can at least acknowledge it.
            const payload = [_]u8{@intFromEnum(protocol.CommandId.rename_tab)};
            try sendFrame(sock_fd, .command, &payload);
        },
        .none => {},
    }
}

// ─── handleServerFrame ───────────────────────────────────────────────────────

/// Dispatch a frame received from the server.
/// Returns `true` to keep running, `false` to exit the event loop.
fn handleServerFrame(
    msg_type: protocol.MessageType,
    payload: []const u8,
    stdout: std.fs.File,
) !bool {
    switch (msg_type) {
        .hello_ack => {
            // Server acknowledged our hello; nothing to do.
        },

        .render => {
            // Write the render payload directly to stdout — the server has
            // already formatted it as terminal escape sequences.
            var written: usize = 0;
            while (written < payload.len) {
                const n = try stdout.write(payload[written..]);
                if (n == 0) return error.StdoutClosed;
                written += n;
            }
        },

        .state => {
            // State update — could update a local status bar overlay.
            // For now just consume it silently.
            _ = protocol.decodeState(payload) catch {};
        },

        .exit => {
            return false;
        },

        .err => {
            const err_info = protocol.decodeError(payload) catch return true;
            // Display the error message in the terminal (best effort).
            var err_buf: [256]u8 = undefined;
            const err_msg = std.fmt.bufPrint(&err_buf, "\r\n[zlice error {d}]: {s}\r\n", .{ err_info.code, err_info.msg }) catch &err_buf;
            _ = posix.write(posix.STDERR_FILENO, err_msg) catch {};
        },

        // Client-bound only; ignore if server mistakenly sends client→server types.
        else => {},
    }
    return true;
}

// ─── Tests ────────────────────────────────────────────────────────────────────

test "Client struct layout" {
    // Verify that the struct compiles and has the expected fields.
    const c: Client = .{
        .socket_fd = 0,
        .raw_mode = undefined,
        .input_parser = .{},
        .mode_state = .{},
        .running = true,
    };
    try std.testing.expect(c.running);
    try std.testing.expectEqual(@as(posix.fd_t, 0), c.socket_fd);
}

test "sendFrame encoding via socketpair" {
    // Create a connected socket pair so we can test the full encode+write path.
    var fds: [2]i32 = undefined;
    const rc = linux.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds);
    if (linux.E.init(rc) != .SUCCESS) return error.SocketpairFailed;
    defer posix.close(fds[0]);
    defer posix.close(fds[1]);

    const payload = "hello";
    try sendFrame(fds[0], .input, payload);

    // Read back the raw bytes on the other end.
    var buf: [64]u8 = undefined;
    const n = try posix.read(fds[1], &buf);
    try std.testing.expectEqual(protocol.HEADER_SIZE + payload.len, n);

    // Verify the header fields.
    const hdr = try protocol.decodeHeader(buf[0..protocol.HEADER_SIZE]);
    try std.testing.expectEqual(protocol.MessageType.input, hdr.msg_type);
    try std.testing.expectEqual(@as(u32, payload.len), hdr.payload_len);

    // Verify the payload is preserved.
    try std.testing.expectEqualStrings(payload, buf[protocol.HEADER_SIZE .. protocol.HEADER_SIZE + payload.len]);
}

test "sendFrame empty payload" {
    var fds: [2]i32 = undefined;
    const rc = linux.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, &fds);
    if (linux.E.init(rc) != .SUCCESS) return error.SocketpairFailed;
    defer posix.close(fds[0]);
    defer posix.close(fds[1]);

    try sendFrame(fds[0], .command, &.{});

    var buf: [16]u8 = undefined;
    const n = try posix.read(fds[1], &buf);
    try std.testing.expectEqual(protocol.HEADER_SIZE, n);

    const hdr = try protocol.decodeHeader(buf[0..protocol.HEADER_SIZE]);
    try std.testing.expectEqual(protocol.MessageType.command, hdr.msg_type);
    try std.testing.expectEqual(@as(u32, 0), hdr.payload_len);
}
