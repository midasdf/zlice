const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const protocol = @import("protocol.zig");
const pty_mod = @import("pty.zig");
const vt_mod = @import("vt.zig");
const scrollback_mod = @import("scrollback.zig");
const pane_mod = @import("pane.zig");
const tab_mod = @import("tab.zig");
const render_mod = @import("render.zig");
const status_bar_mod = @import("status_bar.zig");
const config_mod = @import("config.zig");
const mode_mod = @import("mode.zig");

// ─── Constants ────────────────────────────────────────────────────────────────

/// epoll data tag for the listen socket
const TAG_LISTEN: u64 = 0xFFFF_FFFF_FFFF_0000;
/// epoll data tag for the connected client socket
const TAG_CLIENT: u64 = 0xFFFF_FFFF_FFFF_0001;
/// epoll data tag for the signal fd
const TAG_SIGNAL: u64 = 0xFFFF_FFFF_FFFF_0002;
/// epoll data tags for PTY fds are encoded as: TAG_PTY_BASE | pane_id
const TAG_PTY_BASE: u64 = 0x0001_0000_0000_0000;

fn ptyTag(pane_id: pane_mod.PaneId) u64 {
    return TAG_PTY_BASE | @as(u64, pane_id);
}

fn isPtyTag(tag: u64) bool {
    return (tag & TAG_PTY_BASE) != 0 and
        tag != TAG_LISTEN and
        tag != TAG_CLIENT and
        tag != TAG_SIGNAL;
}

fn paneIdFromTag(tag: u64) pane_mod.PaneId {
    return @intCast(tag & 0xFFFF);
}

const DEFAULT_COLS: u16 = 80;
const DEFAULT_ROWS: u16 = 24;

// ─── PaneState ────────────────────────────────────────────────────────────────

/// Per-pane runtime state (PTY + VT parser + scrollback + virtual screen).
pub const PaneState = struct {
    allocator: std.mem.Allocator,
    pty: pty_mod.Pty,
    vt_parser: vt_mod.Parser,
    scrollback: scrollback_mod.Scrollback,
    /// Pane's virtual screen buffer: rows * cols cells (what the PTY has drawn).
    screen: []vt_mod.Cell,
    cursor_row: u16 = 0,
    cursor_col: u16 = 0,
    cols: u16,
    rows: u16,
    scroll_offset: u16 = 0, // lines scrolled back from live view
    /// Pane title (set by OSC set_title VT sequence or defaulted to "Pane N").
    title: [64]u8 = [_]u8{0} ** 64,
    title_len: u8 = 0,
    /// Current drawing pen (SGR state)
    pen_fg: vt_mod.Color = .default,
    pen_bg: vt_mod.Color = .default,
    pen_attr: vt_mod.Attr = .{},
    /// Alternate screen buffer support
    alt_screen_buf: ?[]vt_mod.Cell = null,
    saved_cursor_row: u16 = 0,
    saved_cursor_col: u16 = 0,
    in_alt_screen: bool = false,

    /// Apply a VT event to this pane's screen buffer.
    pub fn applyEvent(self: *PaneState, ev: vt_mod.Event) void {
        switch (ev) {
            .print => |ch| {
                if (self.cursor_row >= self.rows or self.cursor_col >= self.cols) return;
                const idx = @as(usize, self.cursor_row) * self.cols + self.cursor_col;
                self.screen[idx] = .{
                    .char = ch,
                    .fg = self.pen_fg,
                    .bg = self.pen_bg,
                    .attr = self.pen_attr,
                };
                self.cursor_col += 1;
                if (self.cursor_col >= self.cols) {
                    self.cursor_col = 0;
                    self.cursor_row +|= 1;
                    if (self.cursor_row >= self.rows) {
                        self.cursor_row = self.rows - 1;
                        self.scrollScreenUp(1);
                    }
                }
            },
            .cursor_pos => |cp| {
                self.cursor_row = @min(cp.row, self.rows -| 1);
                self.cursor_col = @min(cp.col, self.cols -| 1);
            },
            .cursor_move => |cm| {
                const new_row: i32 = @as(i32, self.cursor_row) + cm.row;
                const new_col: i32 = @as(i32, self.cursor_col) + cm.col;
                self.cursor_row = @intCast(@max(0, @min(new_row, @as(i32, self.rows) - 1)));
                self.cursor_col = @intCast(@max(0, @min(new_col, @as(i32, self.cols) - 1)));
            },
            .linefeed => {
                self.cursor_row +|= 1;
                if (self.cursor_row >= self.rows) {
                    self.cursor_row = self.rows - 1;
                    self.scrollScreenUp(1);
                }
            },
            .carriage_return => {
                self.cursor_col = 0;
            },
            .backspace => {
                if (self.cursor_col > 0) self.cursor_col -= 1;
            },
            .erase_display => |mode| {
                switch (mode) {
                    0 => { // erase from cursor to end
                        const start = @as(usize, self.cursor_row) * self.cols + self.cursor_col;
                        @memset(self.screen[start..], vt_mod.Cell{});
                    },
                    1 => { // erase from start to cursor
                        const end = @as(usize, self.cursor_row) * self.cols + self.cursor_col + 1;
                        @memset(self.screen[0..@min(end, self.screen.len)], vt_mod.Cell{});
                    },
                    2 => { // erase all
                        @memset(self.screen, vt_mod.Cell{});
                    },
                    else => {},
                }
            },
            .erase_line => |mode| {
                const row_start = @as(usize, self.cursor_row) * self.cols;
                switch (mode) {
                    0 => { // erase from cursor to end of line
                        const start = row_start + self.cursor_col;
                        const end = row_start + self.cols;
                        if (start < self.screen.len) {
                            @memset(self.screen[start..@min(end, self.screen.len)], vt_mod.Cell{});
                        }
                    },
                    1 => { // erase from start of line to cursor
                        const end = row_start + self.cursor_col + 1;
                        @memset(self.screen[row_start..@min(end, self.screen.len)], vt_mod.Cell{});
                    },
                    2 => { // erase entire line
                        const end = row_start + self.cols;
                        @memset(self.screen[row_start..@min(end, self.screen.len)], vt_mod.Cell{});
                    },
                    else => {},
                }
            },
            .scroll_up => |n| self.scrollScreenUp(n),
            .scroll_down => |n| self.scrollScreenDown(n),
            .sgr => |params| {
                if (params.reset) {
                    self.pen_fg = .default;
                    self.pen_bg = .default;
                    self.pen_attr = .{};
                }
                if (params.fg) |fg| self.pen_fg = fg;
                if (params.bg) |bg| self.pen_bg = bg;
                if (params.attr) |attr| {
                    // Merge attribute bits (SGR sets individual flags)
                    if (attr.bold) self.pen_attr.bold = true;
                    if (attr.dim) self.pen_attr.dim = true;
                    if (attr.italic) self.pen_attr.italic = true;
                    if (attr.underline) self.pen_attr.underline = true;
                    if (attr.blink) self.pen_attr.blink = true;
                    if (attr.inverse) self.pen_attr.inverse = true;
                    if (attr.hidden) self.pen_attr.hidden = true;
                    if (attr.strikethrough) self.pen_attr.strikethrough = true;
                }
            },
            .set_title => |t| {
                const len: u8 = @intCast(@min(t.len, self.title.len));
                @memcpy(self.title[0..len], t[0..len]);
                self.title_len = len;
            },
            .alt_screen => |enter| {
                if (enter and !self.in_alt_screen) {
                    // Enter alternate screen: save main buffer and cursor
                    self.saved_cursor_row = self.cursor_row;
                    self.saved_cursor_col = self.cursor_col;
                    // Save main screen into alt_screen_buf
                    if (self.alt_screen_buf == null) {
                        self.alt_screen_buf = self.allocator.alloc(vt_mod.Cell, self.screen.len) catch null;
                    }
                    if (self.alt_screen_buf) |buf| {
                        if (buf.len == self.screen.len) {
                            @memcpy(buf, self.screen);
                        }
                    }
                    // Clear screen for alt screen apps
                    @memset(self.screen, vt_mod.Cell{});
                    self.cursor_row = 0;
                    self.cursor_col = 0;
                    self.in_alt_screen = true;
                } else if (!enter and self.in_alt_screen) {
                    // Leave alternate screen: restore saved main buffer
                    if (self.alt_screen_buf) |buf| {
                        if (buf.len == self.screen.len) {
                            @memcpy(self.screen, buf);
                        }
                    }
                    self.cursor_row = self.saved_cursor_row;
                    self.cursor_col = self.saved_cursor_col;
                    self.in_alt_screen = false;
                    // Reset pen
                    self.pen_fg = .default;
                    self.pen_bg = .default;
                    self.pen_attr = .{};
                }
            },
            else => {}, // bell, tab, cursor_visible, scroll_region etc.
        }
    }

    fn scrollScreenUp(self: *PaneState, n: u16) void {
        const rows_to_scroll = @min(n, self.rows);
        const move_rows = self.rows - rows_to_scroll;
        if (move_rows > 0) {
            const src_start = @as(usize, rows_to_scroll) * self.cols;
            const dst_start: usize = 0;
            const len = @as(usize, move_rows) * self.cols;
            std.mem.copyForwards(vt_mod.Cell, self.screen[dst_start .. dst_start + len], self.screen[src_start .. src_start + len]);
        }
        // Clear the vacated bottom rows
        const clear_start = @as(usize, move_rows) * self.cols;
        @memset(self.screen[clear_start..], vt_mod.Cell{});
    }

    fn scrollScreenDown(self: *PaneState, n: u16) void {
        const rows_to_scroll = @min(n, self.rows);
        const move_rows = self.rows - rows_to_scroll;
        if (move_rows > 0) {
            // Move rows downward — must copy backwards to avoid overlap.
            // Use signed arithmetic to avoid unsigned underflow.
            var dst_row_i: isize = @as(isize, self.rows) - 1;
            const scroll_i: isize = @intCast(rows_to_scroll);
            while (dst_row_i >= scroll_i) : (dst_row_i -= 1) {
                const src_row: usize = @intCast(dst_row_i - scroll_i);
                const dst_row: usize = @intCast(dst_row_i);
                const src = src_row * self.cols;
                const dst = dst_row * self.cols;
                @memcpy(self.screen[dst .. dst + self.cols], self.screen[src .. src + self.cols]);
            }
        }
        // Clear the vacated top rows
        const clear_end = @as(usize, rows_to_scroll) * self.cols;
        @memset(self.screen[0..clear_end], vt_mod.Cell{});
    }
};

// ─── Server struct ────────────────────────────────────────────────────────────

pub const Server = struct {
    allocator: std.mem.Allocator,
    config: config_mod.Config,
    tab_manager: tab_mod.TabManager,
    pane_states: std.AutoHashMap(pane_mod.PaneId, *PaneState),
    listen_fd: posix.fd_t,
    client_fd: ?posix.fd_t,
    epoll_fd: posix.fd_t,
    screen: render_mod.Screen,
    client_cols: u16,
    client_rows: u16,
    running: bool,
    current_mode: mode_mod.Mode,
    socket_path: []const u8, // owned, for cleanup

    // ── init ──────────────────────────────────────────────────────────────────

    pub fn init(
        allocator: std.mem.Allocator,
        socket_path: [:0]const u8,
        config: config_mod.Config,
    ) !Server {
        // Ensure parent directory exists with mode 0o700
        if (std.fs.path.dirname(socket_path)) |dir_path| {
            std.fs.makeDirAbsolute(dir_path) catch |err| {
                if (err != error.PathAlreadyExists) return err;
            };
            // chmod the directory to 0700
            const dir_cstr = try allocator.dupeZ(u8, dir_path);
            defer allocator.free(dir_cstr);
            _ = linux.chmod(dir_cstr.ptr, 0o700);
        }

        // Remove stale socket file if present
        posix.unlink(socket_path) catch {};

        // Create + bind listen socket
        const listen_fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0);
        errdefer posix.close(listen_fd);

        var addr = posix.sockaddr.un{ .path = [_]u8{0} ** 108 };
        if (socket_path.len >= addr.path.len) return error.NameTooLong;
        @memcpy(addr.path[0..socket_path.len], socket_path);
        try posix.bind(listen_fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un));
        try posix.listen(listen_fd, 1);

        // Create epoll instance
        const epoll_fd_rc = linux.epoll_create1(linux.EPOLL.CLOEXEC);
        if (linux.E.init(epoll_fd_rc) != .SUCCESS) return error.EpollCreateFailed;
        const epoll_fd: posix.fd_t = @intCast(epoll_fd_rc);
        errdefer posix.close(epoll_fd);

        // Register listen_fd on epoll
        {
            var ev = linux.epoll_event{
                .events = linux.EPOLL.IN | linux.EPOLL.ERR,
                .data = .{ .u64 = TAG_LISTEN },
            };
            const r = linux.epoll_ctl(epoll_fd, linux.EPOLL.CTL_ADD, listen_fd, &ev);
            if (linux.E.init(r) != .SUCCESS) return error.EpollCtlFailed;
        }

        // Initialize TabManager (creates first tab with one pane, id=0)
        var tab_manager = try tab_mod.TabManager.init(allocator);
        errdefer tab_manager.deinit();

        // Create screen with default size
        var screen = try render_mod.Screen.init(allocator, DEFAULT_COLS, DEFAULT_ROWS);
        errdefer screen.deinit();

        const path_copy = try allocator.dupe(u8, socket_path);
        errdefer allocator.free(path_copy);

        var srv = Server{
            .allocator = allocator,
            .config = config,
            .tab_manager = tab_manager,
            .pane_states = std.AutoHashMap(pane_mod.PaneId, *PaneState).init(allocator),
            .listen_fd = listen_fd,
            .client_fd = null,
            .epoll_fd = epoll_fd,
            .screen = screen,
            .client_cols = DEFAULT_COLS,
            .client_rows = DEFAULT_ROWS,
            .running = true,
            .current_mode = .normal,
            .socket_path = path_copy,
        };

        // Spawn PTY for the initial pane (id=0)
        try srv.spawnPaneState(0);

        return srv;
    }

    // ── deinit ────────────────────────────────────────────────────────────────

    pub fn deinit(self: *Server) void {
        // Close all PTYs and free pane states
        var it = self.pane_states.iterator();
        while (it.next()) |entry| {
            const state = entry.value_ptr.*;
            state.pty.close();
            state.scrollback.deinit(self.allocator);
            self.allocator.free(state.screen);
            self.allocator.destroy(state);
        }
        self.pane_states.deinit();

        if (self.client_fd) |fd| posix.close(fd);
        posix.close(self.listen_fd);
        posix.close(self.epoll_fd);

        // Remove socket file
        const socket_pathZ = self.allocator.dupeZ(u8, self.socket_path) catch null;
        if (socket_pathZ) |p| {
            posix.unlink(p) catch {};
            self.allocator.free(p);
        }
        self.allocator.free(self.socket_path);

        self.tab_manager.deinit();
        self.screen.deinit();
    }

    // ── run ───────────────────────────────────────────────────────────────────

    pub fn run(self: *Server) !void {
        // Register SIGTERM + SIGINT via signalfd
        var sig_mask = linux.sigemptyset();
        linux.sigaddset(&sig_mask, linux.SIG.TERM);
        linux.sigaddset(&sig_mask, linux.SIG.INT);
        _ = linux.sigprocmask(linux.SIG.BLOCK, &sig_mask, null);

        const sig_fd_rc = linux.signalfd(-1, &sig_mask, linux.SFD.CLOEXEC);
        if (linux.E.init(sig_fd_rc) != .SUCCESS) return error.SignalFdFailed;
        const sig_fd: posix.fd_t = @intCast(sig_fd_rc);
        defer posix.close(sig_fd);

        {
            var ev = linux.epoll_event{
                .events = linux.EPOLL.IN | linux.EPOLL.ERR,
                .data = .{ .u64 = TAG_SIGNAL },
            };
            const r = linux.epoll_ctl(self.epoll_fd, linux.EPOLL.CTL_ADD, sig_fd, &ev);
            if (linux.E.init(r) != .SUCCESS) return error.EpollCtlFailed;
        }

        // Receive buffer for client frames
        var recv_buf: [protocol.HEADER_SIZE + protocol.MAX_PAYLOAD_LEN]u8 = undefined;
        var recv_len: usize = 0;

        while (self.running) {
            var events: [32]linux.epoll_event = undefined;
            const n_rc = linux.epoll_wait(self.epoll_fd, &events, events.len, -1);
            const n_events = switch (linux.E.init(n_rc)) {
                .SUCCESS => n_rc,
                .INTR => continue,
                else => return error.EpollWaitFailed,
            };

            for (events[0..n_events]) |ev| {
                const tag = ev.data.u64;

                if (tag == TAG_LISTEN) {
                    // Accept a new client (single-client: close previous if any)
                    const new_client = posix.accept(self.listen_fd, null, null, posix.SOCK.CLOEXEC) catch continue;
                    if (self.client_fd) |old| {
                        const r2 = linux.epoll_ctl(self.epoll_fd, linux.EPOLL.CTL_DEL, old, null);
                        _ = r2;
                        posix.close(old);
                    }
                    self.client_fd = new_client;
                    {
                        var client_ev = linux.epoll_event{
                            .events = linux.EPOLL.IN | linux.EPOLL.ERR | linux.EPOLL.HUP,
                            .data = .{ .u64 = TAG_CLIENT },
                        };
                        const r2 = linux.epoll_ctl(self.epoll_fd, linux.EPOLL.CTL_ADD, new_client, &client_ev);
                        if (linux.E.init(r2) != .SUCCESS) {
                            posix.close(new_client);
                            self.client_fd = null;
                            continue;
                        }
                    }
                    recv_len = 0;
                    // Send hello_ack with empty payload
                    self.sendFrame(.hello_ack, &.{}) catch {};
                    // Hide cursor and force full redraw
                    self.sendFrame(.render, "\x1b[?25l") catch {};

                } else if (tag == TAG_CLIENT) {
                    // Read from client
                    const cfd = self.client_fd orelse continue;
                    const space = recv_buf.len - recv_len;
                    if (space == 0) {
                        // Buffer full with no complete frame — protocol error, disconnect
                        self.disconnectClient();
                        recv_len = 0;
                        continue;
                    }
                    const n_read = posix.read(cfd, recv_buf[recv_len..]) catch {
                        self.disconnectClient();
                        recv_len = 0;
                        continue;
                    };
                    if (n_read == 0) {
                        self.disconnectClient();
                        recv_len = 0;
                        continue;
                    }
                    recv_len += n_read;

                    // Drain complete frames
                    var consumed: usize = 0;
                    while (recv_len - consumed >= protocol.HEADER_SIZE) {
                        const hdr_slice: *const [protocol.HEADER_SIZE]u8 =
                            recv_buf[consumed..][0..protocol.HEADER_SIZE];
                        const hdr = protocol.decodeHeader(hdr_slice) catch {
                            consumed += 1;
                            continue;
                        };
                        const frame_end = consumed + protocol.HEADER_SIZE + hdr.payload_len;
                        if (recv_len < frame_end) break;
                        const payload = recv_buf[consumed + protocol.HEADER_SIZE .. frame_end];
                        self.handleClientFrame(hdr.msg_type, payload);
                        consumed = frame_end;
                    }
                    if (consumed > 0 and consumed < recv_len) {
                        std.mem.copyForwards(u8, recv_buf[0..], recv_buf[consumed..recv_len]);
                    }
                    if (consumed > recv_len) {
                        recv_len = 0;
                    } else {
                        recv_len -= consumed;
                    }

                } else if (tag == TAG_SIGNAL) {
                    // SIGTERM or SIGINT
                    var ssi: linux.signalfd_siginfo = undefined;
                    _ = posix.read(sig_fd, std.mem.asBytes(&ssi)) catch {};
                    self.running = false;

                } else if (isPtyTag(tag)) {
                    // PTY output for a pane
                    const pane_id = paneIdFromTag(tag);
                    self.handlePtyOutput(pane_id);
                }
            }
        }
    }

    // ── handleClientFrame ─────────────────────────────────────────────────────

    fn handleClientFrame(self: *Server, msg_type: protocol.MessageType, payload: []const u8) void {
        switch (msg_type) {
            .hello => {
                const hp = protocol.decodeHello(payload) catch return;
                self.client_cols = hp.cols;
                self.client_rows = hp.rows;
                self.screen.resize(hp.cols, hp.rows) catch {};
                self.resizeAllPanes();
                self.compose();
            },
            .input => {
                // Write to active pane's PTY
                const active_tab = self.tab_manager.activeTab();
                const active_id = active_tab.pane_tree.active_pane;
                if (self.pane_states.get(active_id)) |state| {
                    _ = state.pty.write(payload) catch {};
                }
            },
            .command => {
                if (payload.len < 1) return;
                const cmd_raw = payload[0];
                const cmd = std.meta.intToEnum(protocol.CommandId, cmd_raw) catch return;
                self.handleCommand(cmd, payload[1..]);
            },
            .resize => {
                const rp = protocol.decodeResize(payload) catch return;
                self.client_cols = rp.cols;
                self.client_rows = rp.rows;
                self.screen.resize(rp.cols, rp.rows) catch {};
                self.resizeAllPanes();
                self.compose();
            },
            .state => {
                // Client mode changed — update server-side mode for status bar
                if (payload.len >= 1) {
                    self.current_mode = std.meta.intToEnum(mode_mod.Mode, payload[0]) catch .normal;
                    self.compose();
                }
            },
            else => {},
        }
    }

    // ── handleCommand ─────────────────────────────────────────────────────────

    pub fn handleCommand(self: *Server, cmd_id: protocol.CommandId, payload: []const u8) void {
        const active_tab = self.tab_manager.activeTab();
        const active_id = active_tab.pane_tree.active_pane;

        switch (cmd_id) {
            .split_horizontal => {
                const new_id = active_tab.pane_tree.splitPane(active_id, .horizontal) catch return;
                self.spawnPaneState(new_id) catch return;
                active_tab.pane_tree.active_pane = new_id;
                self.compose();
            },
            .split_vertical => {
                const new_id = active_tab.pane_tree.splitPane(active_id, .vertical) catch return;
                self.spawnPaneState(new_id) catch return;
                active_tab.pane_tree.active_pane = new_id;
                self.compose();
            },
            .close_pane => {
                const sibling = active_tab.pane_tree.closePane(active_id) orelse return;
                self.destroyPaneState(active_id);
                active_tab.pane_tree.active_pane = sibling;
                self.compose();
            },
            .focus_pane => {
                if (payload.len < 1) return;
                const dir_raw = payload[0];
                const dir = std.meta.intToEnum(protocol.Direction, dir_raw) catch return;
                // Content area: row 1 (tab bar) to client_rows-2 (status bar)
                const status_bar_rows: u16 = if (self.config.status_bar and self.client_rows > 0) 1 else 0;
                const tab_bar_rows: u16 = if (self.client_rows > 0) 1 else 0;
                const reserved = tab_bar_rows + status_bar_rows;
                const content_rows = if (self.client_rows > reserved) self.client_rows - reserved else self.client_rows;
                const total_region = pane_mod.Region{
                    .row = tab_bar_rows,
                    .col = 0,
                    .rows = content_rows,
                    .cols = self.client_cols,
                };
                const regions = active_tab.pane_tree.calculateRegions(total_region) catch return;
                defer self.allocator.free(regions);
                if (active_tab.pane_tree.focusDirection(active_id, dir, regions)) |new_id| {
                    active_tab.pane_tree.active_pane = new_id;
                    self.compose();
                }
            },
            .resize_pane => {
                if (payload.len < 3) return;
                const dir_raw = payload[0];
                const dir = std.meta.intToEnum(protocol.Direction, dir_raw) catch return;
                const delta_hi = payload[1];
                const delta_lo = payload[2];
                const delta_u: u16 = (@as(u16, delta_hi) << 8) | delta_lo;
                const delta: i16 = @bitCast(delta_u);
                active_tab.pane_tree.resizePane(active_id, dir, delta);
                self.compose();
            },
            .toggle_fullscreen => {
                // Stub: no-op for now
                self.compose();
            },
            .new_tab => {
                const new_tab_idx = self.tab_manager.createTab() catch return;
                _ = new_tab_idx;
                // Spawn PTY for the new tab's initial pane (id = next_id - 1 in the new tree)
                const new_active_tab = self.tab_manager.activeTab();
                const new_pane_id = new_active_tab.pane_tree.active_pane;
                self.spawnPaneState(new_pane_id) catch return;
                self.compose();
            },
            .close_tab => {
                // Destroy all pane states for this tab before closing
                self.destroyAllPanesInCurrentTab();
                _ = self.tab_manager.closeTab(self.tab_manager.active);
                self.compose();
            },
            .next_tab => {
                self.tab_manager.nextTab();
                self.compose();
            },
            .prev_tab => {
                self.tab_manager.prevTab();
                self.compose();
            },
            .switch_tab => {
                if (payload.len < 1) return;
                const target = payload[0];
                if (target < tab_mod.MAX_TABS and self.tab_manager.tabs[target] != null) {
                    self.tab_manager.active = target;
                    self.compose();
                }
            },
            .rename_tab => {
                if (payload.len > 0) {
                    self.tab_manager.activeTab().setName(payload);
                    self.compose();
                }
            },
            .scroll_up_lines => {
                if (self.pane_states.get(active_id)) |state| {
                    state.scroll_offset +|= 3;
                    self.compose();
                }
            },
            .scroll_down_lines => {
                if (self.pane_states.get(active_id)) |state| {
                    state.scroll_offset -|= 3;
                    self.compose();
                }
            },
            .scroll_half_page_up => {
                if (self.pane_states.get(active_id)) |state| {
                    state.scroll_offset +|= state.rows / 2;
                    self.compose();
                }
            },
            .scroll_half_page_down => {
                if (self.pane_states.get(active_id)) |state| {
                    state.scroll_offset -|= state.rows / 2;
                    self.compose();
                }
            },
            .detach => {
                // Disconnect client but keep server running
                self.disconnectClient();
            },
            .quit => {
                self.running = false;
            },
        }
    }

    // ── spawnPaneState ────────────────────────────────────────────────────────

    pub fn spawnPaneState(self: *Server, pane_id: pane_mod.PaneId) !void {
        // Use $SHELL if available, otherwise fall back to config default
        const shell = std.posix.getenv("SHELL") orelse self.config.default_shell;
        const shell_z = try self.allocator.dupeZ(u8, shell);
        defer self.allocator.free(shell_z);

        const inner = self.innerPaneSize();
        const pty = try pty_mod.Pty.spawn(shell_z, inner.cols, inner.rows);

        const screen_len = @as(usize, inner.cols) * @as(usize, inner.rows);
        const screen = try self.allocator.alloc(vt_mod.Cell, screen_len);
        errdefer self.allocator.free(screen);
        @memset(screen, vt_mod.Cell{});

        const sb_lines = self.config.scrollback_lines;
        const sb_bytes = self.config.scrollback_max_bytes;
        const sb = try scrollback_mod.Scrollback.init(self.allocator, sb_lines, sb_bytes);

        const state = try self.allocator.create(PaneState);
        errdefer self.allocator.destroy(state);
        state.* = PaneState{
            .allocator = self.allocator,
            .pty = pty,
            .vt_parser = vt_mod.Parser.init(),
            .scrollback = sb,
            .screen = screen,
            .cols = inner.cols,
            .rows = inner.rows,
        };

        try self.pane_states.put(pane_id, state);

        // Register PTY master fd on epoll
        var ev = linux.epoll_event{
            .events = linux.EPOLL.IN | linux.EPOLL.HUP | linux.EPOLL.ERR,
            .data = .{ .u64 = ptyTag(pane_id) },
        };
        const r = linux.epoll_ctl(self.epoll_fd, linux.EPOLL.CTL_ADD, pty.master_fd, &ev);
        if (linux.E.init(r) != .SUCCESS) {
            _ = self.pane_states.remove(pane_id);
            state.pty.close();
            state.scrollback.deinit(self.allocator);
            self.allocator.free(screen);
            self.allocator.destroy(state);
            return error.EpollCtlFailed;
        }
    }

    // ── destroyPaneState ─────────────────────────────────────────────────────

    pub fn destroyPaneState(self: *Server, pane_id: pane_mod.PaneId) void {
        const state = self.pane_states.fetchRemove(pane_id) orelse return;
        const s = state.value;
        // Remove from epoll before closing
        const r = linux.epoll_ctl(self.epoll_fd, linux.EPOLL.CTL_DEL, s.pty.master_fd, null);
        _ = r;
        s.pty.close();
        s.scrollback.deinit(self.allocator);
        if (s.alt_screen_buf) |buf| self.allocator.free(buf);
        self.allocator.free(s.screen);
        self.allocator.destroy(s);
    }

    // ── handlePtyOutput ───────────────────────────────────────────────────────

    fn handlePtyOutput(self: *Server, pane_id: pane_mod.PaneId) void {
        const state = self.pane_states.get(pane_id) orelse return;
        var buf: [4096]u8 = undefined;
        const n = state.pty.read(&buf) catch return;
        if (n == 0) return;

        // Debug: dump first PTY output
        {
            const log_fd = std.posix.open("/tmp/zlice-pty-dump.bin", .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true }, 0o644) catch null;
            if (log_fd) |fd| {
                defer std.posix.close(fd);
                _ = std.posix.write(fd, buf[0..n]) catch {};
            }
        }

        // Feed bytes through VT parser and update pane screen buffer
        for (buf[0..n]) |byte| {
            if (state.vt_parser.feed(byte)) |event| {
                state.applyEvent(event);
            }
        }

        // Only re-render if this pane is in the active tab
        const active_tab = self.tab_manager.activeTab();
        if (self.isPaneInTree(active_tab.pane_tree.root, pane_id)) {
            self.compose();
        }
    }

    // ── compose ───────────────────────────────────────────────────────────────

    /// Composite all pane screen buffers onto the Screen, draw borders,
    /// render the tab bar and status bar, send dirty regions to the client.
    pub fn compose(self: *Server) void {
        // Clear back buffer
        self.screen.clear();

        const status_bar_rows: u16 = if (self.config.status_bar and self.client_rows > 0) 1 else 0;
        // Row 0 is reserved for the tab bar; last row for the status bar.
        const tab_bar_rows: u16 = if (self.client_rows > 0) 1 else 0;
        const reserved_rows = tab_bar_rows + status_bar_rows;
        const content_rows = self.client_rows -| reserved_rows;
        const content_start_row = tab_bar_rows;

        const total_region = pane_mod.Region{
            .row = content_start_row,
            .col = 0,
            .rows = content_rows,
            .cols = self.client_cols,
        };

        // Collect tab names (used by both tab bar and status bar)
        var tab_names_buf: [tab_mod.MAX_TABS][]const u8 = undefined;
        var tab_names_len: usize = 0;
        for (&self.tab_manager.tabs) |*slot| {
            if (slot.*) |*t| {
                tab_names_buf[tab_names_len] = t.getName();
                tab_names_len += 1;
            }
        }
        const tab_names = tab_names_buf[0..tab_names_len];

        // Render tab bar in row 0
        if (tab_bar_rows > 0 and self.screen.rows > 0) {
            const tab_bar_start: usize = 0;
            const tab_bar_end = @as(usize, self.screen.cols);
            if (tab_bar_end <= self.screen.back.len) {
                const tab_bar_cells = self.screen.back[tab_bar_start..tab_bar_end];
                status_bar_mod.renderTabBar(
                    tab_bar_cells,
                    self.screen.cols,
                    tab_names,
                    self.tab_manager.active,
                );
            }
        }

        // Calculate pane regions for the active tab
        const active_tab = self.tab_manager.activeTab();
        const regions = active_tab.pane_tree.calculateRegions(total_region) catch return;
        defer self.allocator.free(regions);

        // Resize each pane's PTY and screen buffer to match its actual region
        for (regions) |entry| {
            const pane_state = self.pane_states.get(entry.id) orelse continue;
            const rgn = entry.region;
            // Inner content area (minus border)
            const new_cols = if (rgn.cols > 2) rgn.cols - 2 else 1;
            const new_rows = if (rgn.rows > 2) rgn.rows - 2 else 1;
            if (pane_state.cols != new_cols or pane_state.rows != new_rows) {
                pane_state.pty.setSize(new_cols, new_rows) catch {};
                const new_len = @as(usize, new_cols) * @as(usize, new_rows);
                const new_screen = self.allocator.alloc(vt_mod.Cell, new_len) catch continue;
                // Clear — the shell will redraw after receiving SIGWINCH
                @memset(new_screen, vt_mod.Cell{});
                // Free old alt screen buf if size changed
                if (pane_state.alt_screen_buf) |buf| {
                    self.allocator.free(buf);
                    pane_state.alt_screen_buf = null;
                }
                self.allocator.free(pane_state.screen);
                pane_state.screen = new_screen;
                pane_state.cols = new_cols;
                pane_state.rows = new_rows;
                pane_state.cursor_row = 0;
                pane_state.cursor_col = 0;
                // Reset pen state for clean redraw
                pane_state.pen_fg = .default;
                pane_state.pen_bg = .default;
                pane_state.pen_attr = .{};
            }
        }

        // For each pane region, draw border with title and copy pane content inset by 1
        for (regions) |entry| {
            const pane_state = self.pane_states.get(entry.id) orelse continue;
            const region = entry.region;
            const is_active = (entry.id == active_tab.pane_tree.active_pane);

            // Use pane title if set, otherwise generate a default "Pane N" label.
            var default_title_buf: [16]u8 = undefined;
            const title: []const u8 = if (pane_state.title_len > 0)
                pane_state.title[0..pane_state.title_len]
            else blk: {
                const s = std.fmt.bufPrint(&default_title_buf, "Pane {d}", .{entry.id + 1}) catch "Pane";
                break :blk s;
            };

            // Debug: log sizes
            {
                const log_fd = std.posix.open("/tmp/zlice-server-debug.log", .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true }, 0o644) catch null;
                if (log_fd) |fd| {
                    defer std.posix.close(fd);
                    var dbuf: [256]u8 = undefined;
                    const msg = std.fmt.bufPrint(&dbuf, "region: row={} col={} rows={} cols={} | pane: cols={} rows={} | screen: {}x{}\n", .{ region.row, region.col, region.rows, region.cols, pane_state.cols, pane_state.rows, self.screen.cols, self.screen.rows }) catch "";
                    _ = std.posix.write(fd, msg) catch {};
                }
            }

            // Draw zellij-style border with title in top frame line
            self.screen.drawBorderWithTitle(region, title, is_active);

            // Content area is inset by 1 on each side for the border
            const inner_row = region.row + 1;
            const inner_col = region.col + 1;
            const inner_rows = if (region.rows > 2) region.rows - 2 else 0;
            const inner_cols = if (region.cols > 2) region.cols - 2 else 0;

            // Copy rows from pane screen into compositor screen
            var r: u16 = 0;
            while (r < inner_rows) : (r += 1) {
                if (r >= pane_state.rows) break;
                const screen_row = inner_row + r;
                if (screen_row >= self.screen.rows) break;

                var c: u16 = 0;
                while (c < inner_cols) : (c += 1) {
                    if (c >= pane_state.cols) break;
                    const screen_col = inner_col + c;
                    if (screen_col >= self.screen.cols) break;

                    const pane_idx = @as(usize, r) * pane_state.cols + c;
                    const vt_cell = pane_state.screen[pane_idx];

                    const screen_cell = self.screen.cellAt(screen_row, screen_col);
                    screen_cell.* = render_mod.Cell{
                        .char = vt_cell.char,
                        .fg = vt_cell.fg,
                        .bg = vt_cell.bg,
                        .attr = vt_cell.attr,
                    };
                }
            }
        }

        // Render status bar in the bottom row if enabled
        if (status_bar_rows > 0 and self.client_rows > 0) {
            const bar_row = self.client_rows - 1;
            if (bar_row < self.screen.rows) {
                const bar_start = @as(usize, bar_row) * self.screen.cols;
                const bar_end = bar_start + self.screen.cols;
                if (bar_end <= self.screen.back.len) {
                    const bar_cells = self.screen.back[bar_start..bar_end];
                    status_bar_mod.renderStatusBar(
                        bar_cells,
                        self.screen.cols,
                        self.current_mode,
                    );
                }
            }
        }

        // Send dirty regions to client
        self.sendDirtyRegions();

        // Swap buffers
        self.screen.swapBuffers();
    }

    // ── sendDirtyRegions ──────────────────────────────────────────────────────

    fn sendDirtyRegions(self: *Server) void {
        const cfd = self.client_fd orelse return;

        const dirty = self.screen.getDirtyRegions(self.allocator) catch return;
        defer {
            for (dirty) |dr| self.allocator.free(dr.cells);
            self.allocator.free(dirty);
        }
        if (dirty.len == 0) return;

        // Encode all dirty regions into a single render payload using escape sequences.
        // Format: for each region, emit CUP + cell SGR+char sequences.
        var payload_list = std.array_list.Managed(u8).init(self.allocator);
        defer payload_list.deinit();
        const writer = payload_list.writer();

        for (dirty) |dr| {
            for (dr.cells, 0..) |cell, col_offset| {
                const abs_col = dr.col + @as(u16, @intCast(col_offset));
                // CUP: ESC[row+1;col+1H (1-based)
                writer.print("\x1b[{d};{d}H", .{ dr.row + 1, abs_col + 1 }) catch continue;
                render_mod.serializeCell(cell, writer) catch continue;
            }
        }

        if (payload_list.items.len == 0) return;
        // Break into MAX_PAYLOAD_LEN chunks if needed
        var offset: usize = 0;
        while (offset < payload_list.items.len) {
            const chunk_end = @min(offset + protocol.MAX_PAYLOAD_LEN, payload_list.items.len);
            const chunk = payload_list.items[offset..chunk_end];

            var frame_buf: [protocol.HEADER_SIZE + protocol.MAX_PAYLOAD_LEN]u8 = undefined;
            const frame_len = protocol.encodeFrame(&frame_buf, .render, chunk) catch break;
            var sent: usize = 0;
            while (sent < frame_len) {
                const w = posix.write(cfd, frame_buf[sent..frame_len]) catch break;
                if (w == 0) break;
                sent += w;
            }
            offset = chunk_end;
        }
    }

    // ── sendFrame ─────────────────────────────────────────────────────────────

    fn sendFrame(self: *Server, msg_type: protocol.MessageType, payload: []const u8) !void {
        const cfd = self.client_fd orelse return;
        var buf: [protocol.HEADER_SIZE + protocol.MAX_PAYLOAD_LEN]u8 = undefined;
        const n = try protocol.encodeFrame(&buf, msg_type, payload);
        var sent: usize = 0;
        while (sent < n) {
            const w = try posix.write(cfd, buf[sent..n]);
            if (w == 0) return error.BrokenPipe;
            sent += w;
        }
    }

    // ── disconnectClient ──────────────────────────────────────────────────────

    fn disconnectClient(self: *Server) void {
        if (self.client_fd) |fd| {
            const r = linux.epoll_ctl(self.epoll_fd, linux.EPOLL.CTL_DEL, fd, null);
            _ = r;
            posix.close(fd);
            self.client_fd = null;
        }
    }

    // ── resizeAllPanes ────────────────────────────────────────────────────────

    /// Compute the inner content size for a single pane (frame border inset + tab/status bar).
    fn innerPaneSize(self: *Server) struct { cols: u16, rows: u16 } {
        // 2 rows reserved (tab bar top + status bar bottom) + 2 for border top/bottom
        const reserved_rows: u16 = 2 + 2;
        // 2 cols for border left/right
        const reserved_cols: u16 = 2;
        return .{
            .cols = if (self.client_cols > reserved_cols) self.client_cols - reserved_cols else 1,
            .rows = if (self.client_rows > reserved_rows) self.client_rows - reserved_rows else 1,
        };
    }

    fn resizeAllPanes(self: *Server) void {
        const inner = self.innerPaneSize();
        var it = self.pane_states.iterator();
        while (it.next()) |entry| {
            const state = entry.value_ptr.*;
            state.pty.setSize(inner.cols, inner.rows) catch {};
            const new_len = @as(usize, inner.cols) * @as(usize, inner.rows);
            if (state.cols != inner.cols or state.rows != inner.rows) {
                const new_screen = self.allocator.alloc(vt_mod.Cell, new_len) catch continue;
                self.allocator.free(state.screen);
                state.screen = new_screen;
                state.cols = inner.cols;
                state.rows = inner.rows;
                @memset(state.screen, vt_mod.Cell{});
                state.cursor_row = 0;
                state.cursor_col = 0;
            }
        }
    }

    // ── destroyAllPanesInCurrentTab ───────────────────────────────────────────

    fn destroyAllPanesInCurrentTab(self: *Server) void {
        const active_tab = self.tab_manager.activeTab();
        self.destroyPanesInNode(active_tab.pane_tree.root);
    }

    fn destroyPanesInNode(self: *Server, node: *pane_mod.LayoutNode) void {
        switch (node.*) {
            .leaf => |l| self.destroyPaneState(l.id),
            .split => |s| {
                self.destroyPanesInNode(s.first);
                self.destroyPanesInNode(s.second);
            },
        }
    }

    // ── isPaneInTree ──────────────────────────────────────────────────────────

    fn isPaneInTree(self: *Server, node: *pane_mod.LayoutNode, pane_id: pane_mod.PaneId) bool {
        switch (node.*) {
            .leaf => |l| return l.id == pane_id,
            .split => |s| return self.isPaneInTree(s.first, pane_id) or
                self.isPaneInTree(s.second, pane_id),
        }
    }
};

// ─── Tests ────────────────────────────────────────────────────────────────────

test "Server struct compiles" {
    // Ensure the Server type is valid and fields are accessible.
    const info = @typeInfo(Server);
    comptime std.debug.assert(info == .@"struct");
}

test "PaneState applyEvent print" {
    const allocator = std.testing.allocator;

    const cols: u16 = 10;
    const rows: u16 = 5;
    const screen = try allocator.alloc(vt_mod.Cell, @as(usize, cols) * rows);
    defer allocator.free(screen);
    @memset(screen, vt_mod.Cell{});

    var sb = try scrollback_mod.Scrollback.init(allocator, 100, 4096);
    defer sb.deinit(allocator);

    var state = PaneState{
        .allocator = allocator,
        .pty = undefined, // not used in this test
        .vt_parser = vt_mod.Parser.init(),
        .scrollback = sb,
        .screen = screen,
        .cols = cols,
        .rows = rows,
    };
    // Detach scrollback ownership so deinit isn't called twice
    state.scrollback.count = 0;

    state.applyEvent(.{ .print = 'A' });
    try std.testing.expectEqual(@as(u21, 'A'), state.screen[0].char);
    try std.testing.expectEqual(@as(u16, 1), state.cursor_col);
}

test "PaneState applyEvent cursor_pos" {
    const allocator = std.testing.allocator;

    const cols: u16 = 80;
    const rows: u16 = 24;
    const screen = try allocator.alloc(vt_mod.Cell, @as(usize, cols) * rows);
    defer allocator.free(screen);
    @memset(screen, vt_mod.Cell{});

    var sb = try scrollback_mod.Scrollback.init(allocator, 100, 4096);
    defer sb.deinit(allocator);

    var state = PaneState{
        .allocator = allocator,
        .pty = undefined,
        .vt_parser = vt_mod.Parser.init(),
        .scrollback = sb,
        .screen = screen,
        .cols = cols,
        .rows = rows,
    };

    state.applyEvent(.{ .cursor_pos = .{ .row = 5, .col = 10 } });
    try std.testing.expectEqual(@as(u16, 5), state.cursor_row);
    try std.testing.expectEqual(@as(u16, 10), state.cursor_col);

    // Free the scrollback that was moved into state
    // (it will be freed by the defers above since `sb` still owns the memory)
}

test "PaneState applyEvent erase_display 2" {
    const allocator = std.testing.allocator;

    const cols: u16 = 10;
    const rows: u16 = 5;
    const screen = try allocator.alloc(vt_mod.Cell, @as(usize, cols) * rows);
    defer allocator.free(screen);

    // Fill with non-blank cells
    for (screen) |*c| c.* = vt_mod.Cell{ .char = 'X' };

    var sb = try scrollback_mod.Scrollback.init(allocator, 100, 4096);
    defer sb.deinit(allocator);

    var state = PaneState{
        .allocator = allocator,
        .pty = undefined,
        .vt_parser = vt_mod.Parser.init(),
        .scrollback = sb,
        .screen = screen,
        .cols = cols,
        .rows = rows,
    };

    state.applyEvent(.{ .erase_display = 2 });

    for (state.screen) |c| {
        try std.testing.expectEqual(@as(u21, ' '), c.char);
    }
}

test "ptyTag and isPtyTag" {
    const id: pane_mod.PaneId = 3;
    const tag = ptyTag(id);
    try std.testing.expect(isPtyTag(tag));
    try std.testing.expect(!isPtyTag(TAG_LISTEN));
    try std.testing.expect(!isPtyTag(TAG_CLIENT));
    try std.testing.expect(!isPtyTag(TAG_SIGNAL));
    try std.testing.expectEqual(id, paneIdFromTag(tag));
}

test "handleCommand dispatch (unit smoke)" {
    // Verify that command ID integer encoding matches what the client sends.
    // Client sends: [cmd_byte] [optional payload...]
    // Server receives payload[0] as CommandId raw byte.
    try std.testing.expectEqual(@as(u8, 0x01), @intFromEnum(protocol.CommandId.split_horizontal));
    try std.testing.expectEqual(@as(u8, 0x02), @intFromEnum(protocol.CommandId.split_vertical));
    try std.testing.expectEqual(@as(u8, 0x03), @intFromEnum(protocol.CommandId.close_pane));
    try std.testing.expectEqual(@as(u8, 0x20), @intFromEnum(protocol.CommandId.detach));
    try std.testing.expectEqual(@as(u8, 0x21), @intFromEnum(protocol.CommandId.quit));
}
