const std = @import("std");
const protocol = @import("protocol.zig");

// ─── Key enum ─────────────────────────────────────────────────────────────────

pub const Key = enum {
    h, j, k, l, n, v, x, f, r, d, q, u,
    H, J, K, L,
    ctrl_g, ctrl_p, ctrl_t, ctrl_s, ctrl_o,
    escape, enter, tab,
    arrow_up, arrow_down, arrow_left, arrow_right,
    page_up, page_down,
    other,
};

// ─── Mode enum ────────────────────────────────────────────────────────────────

pub const Mode = enum {
    normal,
    pane,
    tab,
    scroll,
    session,
    locked,
};

// ─── Action union ─────────────────────────────────────────────────────────────

pub const Action = union(enum) {
    /// Raw bytes should go to the active pane unchanged.
    forward_to_pty,
    /// Send a command with no additional data.
    send_command: protocol.CommandId,
    /// Send a command that targets a direction (e.g. focus_pane left).
    send_direction_command: struct { cmd: protocol.CommandId, dir: protocol.Direction },
    /// Resize the active pane by delta in the given direction.
    send_resize: struct { dir: protocol.Direction, delta: i16 },
    /// Enter tab-rename input mode.
    start_rename_tab,
    /// Transition to a new mode.
    switch_mode: Mode,
    /// Key was consumed but nothing should happen.
    none,
};

// ─── ModeState ────────────────────────────────────────────────────────────────

pub const ModeState = struct {
    current: Mode = .normal,

    pub fn handleKey(self: *ModeState, key: Key) Action {
        return switch (self.current) {
            .normal => handleNormal(self, key),
            .pane => handlePane(self, key),
            .tab => handleTab(self, key),
            .scroll => handleScroll(self, key),
            .session => handleSession(self, key),
            .locked => handleLocked(self, key),
        };
    }

    // ── Normal ───────────────────────────────────────────────────────────────

    fn handleNormal(self: *ModeState, key: Key) Action {
        switch (key) {
            .ctrl_p => {
                self.current = .pane;
                return .{ .switch_mode = .pane };
            },
            .ctrl_t => {
                self.current = .tab;
                return .{ .switch_mode = .tab };
            },
            .ctrl_s => {
                self.current = .scroll;
                return .{ .switch_mode = .scroll };
            },
            .ctrl_o => {
                self.current = .session;
                return .{ .switch_mode = .session };
            },
            .ctrl_g => {
                self.current = .locked;
                return .{ .switch_mode = .locked };
            },
            else => return .forward_to_pty,
        }
    }

    // ── Pane ─────────────────────────────────────────────────────────────────

    fn handlePane(self: *ModeState, key: Key) Action {
        switch (key) {
            // Focus: h/j/k/l and arrow keys
            .h, .arrow_left => return .{ .send_direction_command = .{ .cmd = .focus_pane, .dir = .left } },
            .j, .arrow_down => return .{ .send_direction_command = .{ .cmd = .focus_pane, .dir = .down } },
            .k, .arrow_up => return .{ .send_direction_command = .{ .cmd = .focus_pane, .dir = .up } },
            .l, .arrow_right => return .{ .send_direction_command = .{ .cmd = .focus_pane, .dir = .right } },
            // Resize: H/J/K/L
            .H => return .{ .send_resize = .{ .dir = .left, .delta = 10 } },
            .J => return .{ .send_resize = .{ .dir = .down, .delta = 10 } },
            .K => return .{ .send_resize = .{ .dir = .up, .delta = 10 } },
            .L => return .{ .send_resize = .{ .dir = .right, .delta = 10 } },
            // Splits
            .n => return .{ .send_command = .split_horizontal },
            .v => return .{ .send_command = .split_vertical },
            // Pane management
            .x => return .{ .send_command = .close_pane },
            .f => return .{ .send_command = .toggle_fullscreen },
            // Return to normal (Ctrl+P also exits pane mode, like zellij)
            .escape, .enter, .ctrl_p => {
                self.current = .normal;
                return .{ .switch_mode = .normal };
            },
            else => return .none,
        }
    }

    // ── Tab ──────────────────────────────────────────────────────────────────

    fn handleTab(self: *ModeState, key: Key) Action {
        switch (key) {
            .h, .arrow_left => return .{ .send_command = .prev_tab },
            .l, .arrow_right => return .{ .send_command = .next_tab },
            .n => return .{ .send_command = .new_tab },
            .x => return .{ .send_command = .close_tab },
            .r => return .start_rename_tab,
            .escape, .enter, .ctrl_t => {
                self.current = .normal;
                return .{ .switch_mode = .normal };
            },
            else => return .none,
        }
    }

    // ── Scroll ───────────────────────────────────────────────────────────────

    fn handleScroll(self: *ModeState, key: Key) Action {
        switch (key) {
            .j, .arrow_down => return .{ .send_command = .scroll_down_lines },
            .k, .arrow_up => return .{ .send_command = .scroll_up_lines },
            .d, .page_down => return .{ .send_command = .scroll_half_page_down },
            .u, .page_up => return .{ .send_command = .scroll_half_page_up },
            .escape, .enter, .ctrl_s => {
                self.current = .normal;
                return .{ .switch_mode = .normal };
            },
            else => return .none,
        }
    }

    // ── Session ──────────────────────────────────────────────────────────────

    fn handleSession(self: *ModeState, key: Key) Action {
        switch (key) {
            .d => return .{ .send_command = .detach },
            .q => return .{ .send_command = .quit },
            .escape, .enter, .ctrl_o => {
                self.current = .normal;
                return .{ .switch_mode = .normal };
            },
            else => return .none,
        }
    }

    // ── Locked ───────────────────────────────────────────────────────────────

    fn handleLocked(self: *ModeState, key: Key) Action {
        switch (key) {
            .ctrl_g => {
                self.current = .normal;
                return .{ .switch_mode = .normal };
            },
            else => return .forward_to_pty,
        }
    }
};

// ─── Tests ────────────────────────────────────────────────────────────────────

test "normal mode transitions" {
    var ms = ModeState{};
    // ctrl_p → pane
    var action = ms.handleKey(.ctrl_p);
    try std.testing.expectEqual(Mode.pane, ms.current);
    try std.testing.expectEqual(Action{ .switch_mode = .pane }, action);

    // reset
    ms = ModeState{};
    action = ms.handleKey(.ctrl_t);
    try std.testing.expectEqual(Mode.tab, ms.current);

    ms = ModeState{};
    action = ms.handleKey(.ctrl_s);
    try std.testing.expectEqual(Mode.scroll, ms.current);

    ms = ModeState{};
    action = ms.handleKey(.ctrl_o);
    try std.testing.expectEqual(Mode.session, ms.current);

    ms = ModeState{};
    _ = ms.handleKey(.ctrl_g);
    try std.testing.expectEqual(Mode.locked, ms.current);
}

test "pane mode focus h -> send_direction_command focus_pane left" {
    var ms = ModeState{ .current = .pane };
    const action = ms.handleKey(.h);
    switch (action) {
        .send_direction_command => |v| {
            try std.testing.expectEqual(protocol.CommandId.focus_pane, v.cmd);
            try std.testing.expectEqual(protocol.Direction.left, v.dir);
        },
        else => return error.WrongActionTag,
    }
}

test "pane mode resize H -> send_resize left delta=10" {
    var ms = ModeState{ .current = .pane };
    const action = ms.handleKey(.H);
    switch (action) {
        .send_resize => |v| {
            try std.testing.expectEqual(protocol.Direction.left, v.dir);
            try std.testing.expectEqual(@as(i16, 10), v.delta);
        },
        else => return error.WrongActionTag,
    }
}

test "pane mode escape returns to normal" {
    var ms = ModeState{ .current = .pane };
    const action = ms.handleKey(.escape);
    try std.testing.expectEqual(Mode.normal, ms.current);
    try std.testing.expectEqual(Action{ .switch_mode = .normal }, action);
}

test "session detach" {
    var ms = ModeState{ .current = .session };
    const action = ms.handleKey(.d);
    try std.testing.expectEqual(Action{ .send_command = .detach }, action);
}

test "locked mode forwards keys to pty" {
    var ms = ModeState{ .current = .locked };

    var action = ms.handleKey(.h);
    try std.testing.expectEqual(Action.forward_to_pty, action);
    try std.testing.expectEqual(Mode.locked, ms.current);

    action = ms.handleKey(.ctrl_p);
    try std.testing.expectEqual(Action.forward_to_pty, action);
    try std.testing.expectEqual(Mode.locked, ms.current);
}

test "locked mode ctrl_g exits to normal" {
    var ms = ModeState{ .current = .locked };
    const action = ms.handleKey(.ctrl_g);
    try std.testing.expectEqual(Mode.normal, ms.current);
    try std.testing.expectEqual(Action{ .switch_mode = .normal }, action);
}

test "scroll mode keys" {
    var ms = ModeState{ .current = .scroll };

    var action = ms.handleKey(.j);
    try std.testing.expectEqual(Action{ .send_command = .scroll_down_lines }, action);

    action = ms.handleKey(.arrow_up);
    try std.testing.expectEqual(Action{ .send_command = .scroll_up_lines }, action);

    action = ms.handleKey(.d);
    try std.testing.expectEqual(Action{ .send_command = .scroll_half_page_down }, action);

    action = ms.handleKey(.page_up);
    try std.testing.expectEqual(Action{ .send_command = .scroll_half_page_up }, action);
}

test "normal mode non-mode keys forward to pty" {
    var ms = ModeState{};

    var action = ms.handleKey(.h);
    try std.testing.expectEqual(Action.forward_to_pty, action);
    try std.testing.expectEqual(Mode.normal, ms.current);

    action = ms.handleKey(.other);
    try std.testing.expectEqual(Action.forward_to_pty, action);

    action = ms.handleKey(.enter);
    try std.testing.expectEqual(Action.forward_to_pty, action);
}
