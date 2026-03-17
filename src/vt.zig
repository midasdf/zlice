const std = @import("std");

// ─────────────────────────────────────────────────────────────
// Types
// ─────────────────────────────────────────────────────────────

pub const Color = union(enum) {
    default,
    idx: u8,
    rgb: struct { r: u8, g: u8, b: u8 },
};

pub const Attr = packed struct {
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    underline: bool = false,
    blink: bool = false,
    inverse: bool = false,
    hidden: bool = false,
    strikethrough: bool = false,
};

pub const Cell = struct {
    char: u21 = ' ',
    fg: Color = .default,
    bg: Color = .default,
    attr: Attr = .{},
};

pub const SgrParams = struct {
    reset: bool = false,
    attr: ?Attr = null,
    fg: ?Color = null,
    bg: ?Color = null,
};

pub const Event = union(enum) {
    print: u21,
    cursor_move: struct { row: i16, col: i16 },
    cursor_pos: struct { row: u16, col: u16 },
    erase_display: u8,
    erase_line: u8,
    sgr: SgrParams,
    scroll_region: struct { top: u16, bottom: u16 },
    scroll_up: u16,
    scroll_down: u16,
    insert_lines: u16,
    delete_lines: u16,
    cursor_position_report, // DSR: app requests cursor position (CSI 6n)
    device_attributes_request, // DA1: app requests terminal identity (CSI c / CSI 0c)
    linefeed,
    carriage_return,
    backspace,
    tab,
    bell,
    set_title: []const u8,
    alt_screen: bool,
    cursor_visible: bool,
};

// ─────────────────────────────────────────────────────────────
// Parser
// ─────────────────────────────────────────────────────────────

const State = enum {
    ground,
    escape,
    escape_intermediate,
    csi_entry,
    csi_param,
    csi_intermediate,
    osc_string,
    dcs_passthrough, // Consume DCS sequences until ST
};

const MAX_PARAMS = 16;
const OSC_BUF_LEN = 256;

pub const Parser = struct {
    state: State = .ground,

    // CSI parameter accumulator
    params: [MAX_PARAMS]u16 = [_]u16{0} ** MAX_PARAMS,
    param_idx: usize = 0,
    has_param: bool = false, // at least one digit seen for current param
    private: bool = false, // '?' or '>' prefix seen

    // OSC accumulator
    osc_buf: [OSC_BUF_LEN]u8 = undefined,
    osc_len: usize = 0,

    // UTF-8 multibyte accumulator
    utf8_buf: [4]u8 = undefined,
    utf8_len: u3 = 0,
    utf8_expected: u3 = 0,

    pub fn init() Parser {
        return .{};
    }

    fn resetCsi(self: *Parser) void {
        self.params = [_]u16{0} ** MAX_PARAMS;
        self.param_idx = 0;
        self.has_param = false;
        self.private = false;
    }

    fn getParam(self: *const Parser, idx: usize, default: u16) u16 {
        if (idx > self.param_idx) return default;
        const v = self.params[idx];
        return if (v == 0 and !self.has_param) default else v;
    }

    // Returns the actual stored param value (0 means not set / literal 0).
    fn rawParam(self: *const Parser, idx: usize) u16 {
        if (idx > self.param_idx) return 0;
        return self.params[idx];
    }

    pub fn feed(self: *Parser, byte: u8) ?Event {
        switch (self.state) {
            // ── Ground ───────────────────────────────────────
            .ground => {
                switch (byte) {
                    0x1b => {
                        self.state = .escape;
                        return null;
                    },
                    '\n' => return .linefeed,
                    '\r' => return .carriage_return,
                    0x08 => return .backspace,
                    '\t' => return .tab,
                    0x07 => return .bell,
                    0x20...0x7e => return .{ .print = byte },
                    // UTF-8 multibyte start bytes
                    0xc0...0xdf => {
                        self.utf8_buf[0] = byte;
                        self.utf8_len = 1;
                        self.utf8_expected = 2;
                        return null;
                    },
                    0xe0...0xef => {
                        self.utf8_buf[0] = byte;
                        self.utf8_len = 1;
                        self.utf8_expected = 3;
                        return null;
                    },
                    0xf0...0xf7 => {
                        self.utf8_buf[0] = byte;
                        self.utf8_len = 1;
                        self.utf8_expected = 4;
                        return null;
                    },
                    // UTF-8 continuation bytes (when accumulating)
                    0x80...0xbf => {
                        if (self.utf8_len > 0 and self.utf8_len < self.utf8_expected) {
                            self.utf8_buf[self.utf8_len] = byte;
                            self.utf8_len += 1;
                            if (self.utf8_len == self.utf8_expected) {
                                // Decode complete UTF-8 sequence
                                const cp = decodeUtf8(self.utf8_buf[0..self.utf8_len]);
                                self.utf8_len = 0;
                                self.utf8_expected = 0;
                                return if (cp) |c| .{ .print = c } else null;
                            }
                            return null;
                        }
                        return null; // stray continuation byte
                    },
                    else => return null,
                }
            },

            // ── Escape ───────────────────────────────────────
            .escape => {
                switch (byte) {
                    '[' => {
                        self.state = .csi_entry;
                        self.resetCsi();
                        return null;
                    },
                    ']' => {
                        self.state = .osc_string;
                        self.osc_len = 0;
                        return null;
                    },
                    'M' => {
                        self.state = .ground;
                        return .{ .scroll_down = 1 };
                    },
                    'P' => {
                        // DCS (Device Control String) — consume until ST
                        self.state = .dcs_passthrough;
                        return null;
                    },
                    0x20...0x2f => {
                        // intermediate bytes
                        self.state = .escape_intermediate;
                        return null;
                    },
                    else => {
                        self.state = .ground;
                        return null;
                    },
                }
            },

            // ── Escape intermediate ──────────────────────────
            .escape_intermediate => {
                if (byte >= 0x30 and byte <= 0x7e) {
                    self.state = .ground;
                }
                return null;
            },

            // ── CSI Entry ────────────────────────────────────
            .csi_entry => {
                switch (byte) {
                    '?' , '>' => {
                        self.private = true;
                        self.state = .csi_param;
                        return null;
                    },
                    '0'...'9' => {
                        self.state = .csi_param;
                        self.params[0] = byte - '0';
                        self.has_param = true;
                        return null;
                    },
                    ';' => {
                        self.state = .csi_param;
                        self.param_idx += 1;
                        return null;
                    },
                    0x20...0x2f => {
                        self.state = .csi_intermediate;
                        return null;
                    },
                    0x40...0x7e => {
                        // Final byte with no params
                        self.state = .ground;
                        return self.dispatchCsi(byte);
                    },
                    else => {
                        self.state = .ground;
                        return null;
                    },
                }
            },

            // ── CSI Param ────────────────────────────────────
            .csi_param => {
                switch (byte) {
                    '0'...'9' => {
                        const digit = byte - '0';
                        const cur = self.params[self.param_idx];
                        self.params[self.param_idx] = cur *% 10 +% digit;
                        self.has_param = true;
                        return null;
                    },
                    ';' => {
                        if (self.param_idx + 1 < MAX_PARAMS) {
                            self.param_idx += 1;
                        }
                        // has_param tracks per-param; reset tracking for new param
                        return null;
                    },
                    0x20...0x2f => {
                        self.state = .csi_intermediate;
                        return null;
                    },
                    0x40...0x7e => {
                        self.state = .ground;
                        return self.dispatchCsi(byte);
                    },
                    else => {
                        self.state = .ground;
                        return null;
                    },
                }
            },

            // ── CSI Intermediate ─────────────────────────────
            .csi_intermediate => {
                if (byte >= 0x40 and byte <= 0x7e) {
                    self.state = .ground;
                    // dispatch ignored for now (rare sequences)
                } else if (byte == 0x1b) {
                    self.state = .ground;
                }
                return null;
            },

            // ── OSC String ───────────────────────────────────
            .osc_string => {
                switch (byte) {
                    0x07 => {
                        // BEL terminates OSC
                        self.state = .ground;
                        return self.dispatchOsc();
                    },
                    0x1b => {
                        // ESC starts ST (string terminator); next byte should be '\\'
                        // We treat ESC here as terminator (peek-free state machine)
                        self.state = .ground;
                        return self.dispatchOsc();
                    },
                    else => {
                        if (self.osc_len < OSC_BUF_LEN) {
                            self.osc_buf[self.osc_len] = byte;
                            self.osc_len += 1;
                        }
                        return null;
                    },
                }
            },

            // ── DCS passthrough ──────────────────────────────────
            // Consume all bytes until ST (ESC \) or BEL
            .dcs_passthrough => {
                switch (byte) {
                    0x1b => {
                        // ESC — next byte should be '\' for ST. Go to ground.
                        self.state = .ground;
                        return null;
                    },
                    0x07 => {
                        // BEL also terminates
                        self.state = .ground;
                        return null;
                    },
                    else => return null, // consume silently
                }
            },
        }
    }

    // ─────────────────────────────────────────────────────────
    // CSI dispatch
    // ─────────────────────────────────────────────────────────

    fn dispatchCsi(self: *Parser, final: u8) ?Event {
        if (self.private) {
            return self.dispatchCsiPrivate(final);
        }
        switch (final) {
            // Cursor up
            'A' => return .{ .cursor_move = .{
                .row = -@as(i16, @intCast(self.getParam(0, 1))),
                .col = 0,
            }},
            // Cursor down
            'B' => return .{ .cursor_move = .{
                .row = @as(i16, @intCast(self.getParam(0, 1))),
                .col = 0,
            }},
            // Cursor right / forward
            'C' => return .{ .cursor_move = .{
                .row = 0,
                .col = @as(i16, @intCast(self.getParam(0, 1))),
            }},
            // Cursor left / backward
            'D' => return .{ .cursor_move = .{
                .row = 0,
                .col = -@as(i16, @intCast(self.getParam(0, 1))),
            }},
            // Cursor position (CUP) — 1-based → 0-based
            'H', 'f' => {
                const row = self.getParam(0, 1);
                const col = self.getParam(1, 1);
                return .{ .cursor_pos = .{
                    .row = if (row > 0) row - 1 else 0,
                    .col = if (col > 0) col - 1 else 0,
                }};
            },
            // Erase in display
            'J' => return .{ .erase_display = @intCast(self.rawParam(0)) },
            // Erase in line
            'K' => return .{ .erase_line = @intCast(self.rawParam(0)) },
            // Insert lines
            'L' => return .{ .insert_lines = self.getParam(0, 1) },
            // Delete lines
            'M' => return .{ .delete_lines = self.getParam(0, 1) },
            // Scroll up
            'S' => return .{ .scroll_up = self.getParam(0, 1) },
            // Scroll down
            'T' => return .{ .scroll_down = self.getParam(0, 1) },
            // Set scrolling region
            'r' => {
                const top = self.getParam(0, 1);
                const bot = self.getParam(1, 1);
                return .{ .scroll_region = .{
                    .top = if (top > 0) top - 1 else 0,
                    .bottom = if (bot > 0) bot - 1 else 0,
                }};
            },
            // SGR
            'm' => return .{ .sgr = self.parseSgr() },
            // DSR (Device Status Report) — CSI 6 n = request cursor position
            'n' => {
                if (self.rawParam(0) == 6) return .cursor_position_report;
                return null;
            },
            // DA1 (Device Attributes) — CSI c or CSI 0 c
            'c' => {
                const p = self.rawParam(0);
                if (p == 0) return .device_attributes_request;
                return null;
            },
            else => return null,
        }
    }

    fn dispatchCsiPrivate(self: *Parser, final: u8) ?Event {
        const p = self.rawParam(0);
        switch (final) {
            'h' => switch (p) {
                1049, 47 => return .{ .alt_screen = true },
                25 => return .{ .cursor_visible = true },
                else => return null,
            },
            'l' => switch (p) {
                1049, 47 => return .{ .alt_screen = false },
                25 => return .{ .cursor_visible = false },
                else => return null,
            },
            else => return null,
        }
    }

    // ─────────────────────────────────────────────────────────
    // SGR parsing
    // ─────────────────────────────────────────────────────────

    fn parseSgr(self: *const Parser) SgrParams {
        var result = SgrParams{};
        var attr = Attr{};
        var has_attr = false;

        var i: usize = 0;
        const count = self.param_idx + 1;

        while (i < count) : (i += 1) {
            const p = self.params[i];
            switch (p) {
                0 => {
                    result.reset = true;
                    attr = .{};
                    has_attr = true;
                    result.fg = null;
                    result.bg = null;
                },
                1 => { attr.bold = true; has_attr = true; },
                2 => { attr.dim = true; has_attr = true; },
                3 => { attr.italic = true; has_attr = true; },
                4 => { attr.underline = true; has_attr = true; },
                5 => { attr.blink = true; has_attr = true; },
                7 => { attr.inverse = true; has_attr = true; },
                8 => { attr.hidden = true; has_attr = true; },
                9 => { attr.strikethrough = true; has_attr = true; },
                // Foreground colors
                30...37 => result.fg = .{ .idx = @intCast(p - 30) },
                38 => {
                    // 38;5;N or 38;2;R;G;B
                    if (i + 2 < count and self.params[i + 1] == 5) {
                        result.fg = .{ .idx = @intCast(self.params[i + 2]) };
                        i += 2;
                    } else if (i + 4 < count and self.params[i + 1] == 2) {
                        result.fg = .{ .rgb = .{
                            .r = @intCast(self.params[i + 2]),
                            .g = @intCast(self.params[i + 3]),
                            .b = @intCast(self.params[i + 4]),
                        }};
                        i += 4;
                    }
                },
                39 => result.fg = .default,
                // Background colors
                40...47 => result.bg = .{ .idx = @intCast(p - 40) },
                48 => {
                    if (i + 2 < count and self.params[i + 1] == 5) {
                        result.bg = .{ .idx = @intCast(self.params[i + 2]) };
                        i += 2;
                    } else if (i + 4 < count and self.params[i + 1] == 2) {
                        result.bg = .{ .rgb = .{
                            .r = @intCast(self.params[i + 2]),
                            .g = @intCast(self.params[i + 3]),
                            .b = @intCast(self.params[i + 4]),
                        }};
                        i += 4;
                    }
                },
                49 => result.bg = .default,
                // Bright foreground (90-97)
                90...97 => result.fg = .{ .idx = @intCast(p - 90 + 8) },
                // Bright background (100-107)
                100...107 => result.bg = .{ .idx = @intCast(p - 100 + 8) },
                else => {},
            }
        }

        if (has_attr) result.attr = attr;
        return result;
    }

    // ─────────────────────────────────────────────────────────
    // OSC dispatch
    // ─────────────────────────────────────────────────────────

    fn decodeUtf8(bytes: []const u8) ?u21 {
        if (bytes.len == 2) {
            const c0: u21 = bytes[0] & 0x1f;
            const c1: u21 = bytes[1] & 0x3f;
            return (c0 << 6) | c1;
        } else if (bytes.len == 3) {
            const c0: u21 = bytes[0] & 0x0f;
            const c1: u21 = bytes[1] & 0x3f;
            const c2: u21 = bytes[2] & 0x3f;
            return (c0 << 12) | (c1 << 6) | c2;
        } else if (bytes.len == 4) {
            const c0: u21 = bytes[0] & 0x07;
            const c1: u21 = bytes[1] & 0x3f;
            const c2: u21 = bytes[2] & 0x3f;
            const c3: u21 = bytes[3] & 0x3f;
            return (c0 << 18) | (c1 << 12) | (c2 << 6) | c3;
        }
        return null;
    }

    fn dispatchOsc(self: *Parser) ?Event {
        const buf = self.osc_buf[0..self.osc_len];
        // Expect "0;" or "2;" prefix
        if (buf.len < 2) return null;
        if ((buf[0] == '0' or buf[0] == '2') and buf[1] == ';') {
            return .{ .set_title = buf[2..] };
        }
        return null;
    }
};

// ─────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────

fn feedAll(p: *Parser, seq: []const u8) ?Event {
    var last: ?Event = null;
    for (seq) |b| {
        if (p.feed(b)) |ev| last = ev;
    }
    return last;
}

test "parse printable ASCII" {
    var p = Parser.init();
    const ev = p.feed('A');
    try std.testing.expect(ev != null);
    try std.testing.expectEqual(Event{ .print = 'A' }, ev.?);
}

test "parse space character" {
    var p = Parser.init();
    const ev = p.feed(' ');
    try std.testing.expect(ev != null);
    try std.testing.expectEqual(Event{ .print = ' ' }, ev.?);
}

test "parse cursor up CSI A" {
    var p = Parser.init();
    // ESC [ A  (1 row up, default param)
    _ = p.feed(0x1b);
    _ = p.feed('[');
    const ev = p.feed('A');
    try std.testing.expect(ev != null);
    switch (ev.?) {
        .cursor_move => |cm| {
            try std.testing.expectEqual(@as(i16, -1), cm.row);
            try std.testing.expectEqual(@as(i16, 0), cm.col);
        },
        else => return error.WrongEvent,
    }
}

test "parse cursor up CSI 3A" {
    var p = Parser.init();
    _ = p.feed(0x1b);
    _ = p.feed('[');
    _ = p.feed('3');
    const ev = p.feed('A');
    try std.testing.expect(ev != null);
    switch (ev.?) {
        .cursor_move => |cm| {
            try std.testing.expectEqual(@as(i16, -3), cm.row);
            try std.testing.expectEqual(@as(i16, 0), cm.col);
        },
        else => return error.WrongEvent,
    }
}

test "parse CUP with params CSI 10;20H" {
    var p = Parser.init();
    _ = p.feed(0x1b);
    _ = p.feed('[');
    _ = p.feed('1');
    _ = p.feed('0');
    _ = p.feed(';');
    _ = p.feed('2');
    _ = p.feed('0');
    const ev = p.feed('H');
    try std.testing.expect(ev != null);
    switch (ev.?) {
        .cursor_pos => |cp| {
            // 1-based → 0-based
            try std.testing.expectEqual(@as(u16, 9), cp.row);
            try std.testing.expectEqual(@as(u16, 19), cp.col);
        },
        else => return error.WrongEvent,
    }
}

test "parse CUP default params CSI H" {
    var p = Parser.init();
    _ = p.feed(0x1b);
    _ = p.feed('[');
    const ev = p.feed('H');
    try std.testing.expect(ev != null);
    switch (ev.?) {
        .cursor_pos => |cp| {
            try std.testing.expectEqual(@as(u16, 0), cp.row);
            try std.testing.expectEqual(@as(u16, 0), cp.col);
        },
        else => return error.WrongEvent,
    }
}

test "parse SGR bold CSI 1m" {
    var p = Parser.init();
    _ = p.feed(0x1b);
    _ = p.feed('[');
    _ = p.feed('1');
    const ev = p.feed('m');
    try std.testing.expect(ev != null);
    switch (ev.?) {
        .sgr => |s| {
            try std.testing.expect(!s.reset);
            try std.testing.expect(s.attr != null);
            try std.testing.expect(s.attr.?.bold);
        },
        else => return error.WrongEvent,
    }
}

test "parse SGR reset CSI m (no params)" {
    var p = Parser.init();
    _ = p.feed(0x1b);
    _ = p.feed('[');
    const ev = p.feed('m');
    try std.testing.expect(ev != null);
    switch (ev.?) {
        .sgr => |s| {
            try std.testing.expect(s.reset);
        },
        else => return error.WrongEvent,
    }
}

test "parse erase display CSI 2J" {
    var p = Parser.init();
    _ = p.feed(0x1b);
    _ = p.feed('[');
    _ = p.feed('2');
    const ev = p.feed('J');
    try std.testing.expect(ev != null);
    switch (ev.?) {
        .erase_display => |n| try std.testing.expectEqual(@as(u8, 2), n),
        else => return error.WrongEvent,
    }
}

test "parse alt screen on CSI ?1049h" {
    var p = Parser.init();
    _ = p.feed(0x1b);
    _ = p.feed('[');
    _ = p.feed('?');
    _ = p.feed('1');
    _ = p.feed('0');
    _ = p.feed('4');
    _ = p.feed('9');
    const ev = p.feed('h');
    try std.testing.expect(ev != null);
    switch (ev.?) {
        .alt_screen => |on| try std.testing.expect(on),
        else => return error.WrongEvent,
    }
}

test "parse alt screen off CSI ?1049l" {
    var p = Parser.init();
    _ = p.feed(0x1b);
    _ = p.feed('[');
    _ = p.feed('?');
    _ = p.feed('1');
    _ = p.feed('0');
    _ = p.feed('4');
    _ = p.feed('9');
    const ev = p.feed('l');
    try std.testing.expect(ev != null);
    switch (ev.?) {
        .alt_screen => |on| try std.testing.expect(!on),
        else => return error.WrongEvent,
    }
}

test "parse newline" {
    var p = Parser.init();
    const ev = p.feed('\n');
    try std.testing.expect(ev != null);
    switch (ev.?) {
        .linefeed => {},
        else => return error.WrongEvent,
    }
}

test "parse carriage return" {
    var p = Parser.init();
    const ev = p.feed('\r');
    try std.testing.expect(ev != null);
    switch (ev.?) {
        .carriage_return => {},
        else => return error.WrongEvent,
    }
}

test "parse backspace" {
    var p = Parser.init();
    const ev = p.feed(0x08);
    try std.testing.expect(ev != null);
    switch (ev.?) {
        .backspace => {},
        else => return error.WrongEvent,
    }
}

test "parse OSC set title" {
    var p = Parser.init();
    // ESC ] 0 ; H e l l o BEL
    _ = p.feed(0x1b);
    _ = p.feed(']');
    _ = p.feed('0');
    _ = p.feed(';');
    _ = p.feed('H');
    _ = p.feed('e');
    _ = p.feed('l');
    _ = p.feed('l');
    _ = p.feed('o');
    const ev = p.feed(0x07);
    try std.testing.expect(ev != null);
    switch (ev.?) {
        .set_title => |t| try std.testing.expectEqualStrings("Hello", t),
        else => return error.WrongEvent,
    }
}

test "parse SGR fg color 31 (red)" {
    var p = Parser.init();
    _ = p.feed(0x1b);
    _ = p.feed('[');
    _ = p.feed('3');
    _ = p.feed('1');
    const ev = p.feed('m');
    try std.testing.expect(ev != null);
    switch (ev.?) {
        .sgr => |s| {
            try std.testing.expect(s.fg != null);
            switch (s.fg.?) {
                .idx => |i| try std.testing.expectEqual(@as(u8, 1), i),
                else => return error.WrongColor,
            }
        },
        else => return error.WrongEvent,
    }
}

test "parse SGR 256-color fg 38;5;200" {
    var p = Parser.init();
    _ = feedAll(&p, "\x1b[38;5;200m");
    var p2 = Parser.init();
    _ = p2.feed(0x1b);
    _ = p2.feed('[');
    _ = p2.feed('3');
    _ = p2.feed('8');
    _ = p2.feed(';');
    _ = p2.feed('5');
    _ = p2.feed(';');
    _ = p2.feed('2');
    _ = p2.feed('0');
    _ = p2.feed('0');
    const ev = p2.feed('m');
    try std.testing.expect(ev != null);
    switch (ev.?) {
        .sgr => |s| {
            try std.testing.expect(s.fg != null);
            switch (s.fg.?) {
                .idx => |i| try std.testing.expectEqual(@as(u8, 200), i),
                else => return error.WrongColor,
            }
        },
        else => return error.WrongEvent,
    }
}

test "parse reverse index ESC M" {
    var p = Parser.init();
    _ = p.feed(0x1b);
    const ev = p.feed('M');
    try std.testing.expect(ev != null);
    switch (ev.?) {
        .scroll_down => |n| try std.testing.expectEqual(@as(u16, 1), n),
        else => return error.WrongEvent,
    }
}

test "parse cursor visible CSI ?25h" {
    var p = Parser.init();
    _ = p.feed(0x1b);
    _ = p.feed('[');
    _ = p.feed('?');
    _ = p.feed('2');
    _ = p.feed('5');
    const ev = p.feed('h');
    try std.testing.expect(ev != null);
    switch (ev.?) {
        .cursor_visible => |v| try std.testing.expect(v),
        else => return error.WrongEvent,
    }
}

test "parse cursor hidden CSI ?25l" {
    var p = Parser.init();
    _ = p.feed(0x1b);
    _ = p.feed('[');
    _ = p.feed('?');
    _ = p.feed('2');
    _ = p.feed('5');
    const ev = p.feed('l');
    try std.testing.expect(ev != null);
    switch (ev.?) {
        .cursor_visible => |v| try std.testing.expect(!v),
        else => return error.WrongEvent,
    }
}

test "parser returns to ground after sequence" {
    var p = Parser.init();
    // After a full CSI sequence, next byte should be treated as ground
    _ = p.feed(0x1b);
    _ = p.feed('[');
    _ = p.feed('A'); // cursor up
    const ev = p.feed('X');
    try std.testing.expect(ev != null);
    switch (ev.?) {
        .print => |c| try std.testing.expectEqual(@as(u21, 'X'), c),
        else => return error.WrongEvent,
    }
}
