const std = @import("std");
const mode = @import("mode.zig");
const Key = mode.Key;

// ─── InputParser ──────────────────────────────────────────────────────────────

const State = enum { ground, escape, csi };

pub const InputParser = struct {
    state: State = .ground,
    buf: [8]u8 = undefined,
    buf_len: u8 = 0,
    /// Tracks the raw bytes that produced the last emitted Key.
    seq_buf: [16]u8 = undefined,
    seq_len: u8 = 0,

    fn trackByte(self: *InputParser, byte: u8) void {
        if (self.seq_len < self.seq_buf.len) {
            self.seq_buf[self.seq_len] = byte;
            self.seq_len += 1;
        }
    }

    /// Returns the raw bytes that produced the last emitted Key.
    pub fn lastSequence(self: *const InputParser) []const u8 {
        return self.seq_buf[0..self.seq_len];
    }

    /// Feed one raw byte. Returns a Key if one can be emitted now.
    pub fn feed(self: *InputParser, byte: u8) ?Key {
        switch (self.state) {
            .ground => {
                if (byte == 0x1b) {
                    self.state = .escape;
                    self.seq_len = 0;
                    self.trackByte(byte);
                    return null;
                }
                self.seq_len = 0;
                self.trackByte(byte);
                return mapByte(byte);
            },

            .escape => {
                self.trackByte(byte);
                if (byte == '[') {
                    self.state = .csi;
                    self.buf_len = 0;
                    return null;
                }
                self.state = .ground;
                return .escape;
            },

            .csi => {
                self.trackByte(byte);
                if ((byte >= '0' and byte <= '9') or byte == ';') {
                    if (self.buf_len < self.buf.len) {
                        self.buf[self.buf_len] = byte;
                        self.buf_len += 1;
                    }
                    return null;
                }
                if (byte >= 0x40 and byte <= 0x7e) {
                    self.state = .ground;
                    return mapCsi(byte, self.buf[0..self.buf_len]);
                }
                self.state = .ground;
                return .other;
            },
        }
    }

    /// Call after the byte stream ends (or on timeout) to drain pending state.
    pub fn flush(self: *InputParser) ?Key {
        if (self.state == .escape) {
            self.state = .ground;
            // seq_buf already has 0x1b from the initial ESC
            return .escape;
        }
        return null;
    }
};

// ─── mapByte ─────────────────────────────────────────────────────────────────

fn mapByte(byte: u8) Key {
    return switch (byte) {
        0x07 => .ctrl_g,
        0x09 => .tab,
        0x0d => .enter,
        0x0f => .ctrl_o,
        0x10 => .ctrl_p,
        0x13 => .ctrl_s,
        0x14 => .ctrl_t,
        'h'  => .h,
        'j'  => .j,
        'k'  => .k,
        'l'  => .l,
        'n'  => .n,
        'v'  => .v,
        'x'  => .x,
        'f'  => .f,
        'r'  => .r,
        'd'  => .d,
        'q'  => .q,
        'u'  => .u,
        'H'  => .H,
        'J'  => .J,
        'K'  => .K,
        'L'  => .L,
        else => .other,
    };
}

// ─── mapCsi ──────────────────────────────────────────────────────────────────

fn mapCsi(final: u8, params: []const u8) Key {
    return switch (final) {
        'A' => .arrow_up,
        'B' => .arrow_down,
        'C' => .arrow_right,
        'D' => .arrow_left,
        '~' => blk: {
            // params should be a single digit: '5' = page_up, '6' = page_down
            if (params.len == 1) {
                break :blk switch (params[0]) {
                    '5' => .page_up,
                    '6' => .page_down,
                    else => .other,
                };
            }
            break :blk .other;
        },
        else => .other,
    };
}

// ─── Tests ───────────────────────────────────────────────────────────────────

test "parse simple keys" {
    var p = InputParser{};

    // 'h' in ground state
    try std.testing.expectEqual(Key.h, p.feed('h'));

    // ctrl_p (0x10)
    try std.testing.expectEqual(Key.ctrl_p, p.feed(0x10));

    // enter (0x0d)
    try std.testing.expectEqual(Key.enter, p.feed(0x0d));
}

test "parse arrow keys" {
    var p = InputParser{};

    // ESC [ A → arrow_up
    try std.testing.expectEqual(@as(?Key, null), p.feed(0x1b));
    try std.testing.expectEqual(@as(?Key, null), p.feed('['));
    try std.testing.expectEqual(@as(?Key, Key.arrow_up), p.feed('A'));
}

test "bare escape" {
    var p = InputParser{};

    // Feed ESC, then flush (no '[' follows)
    try std.testing.expectEqual(@as(?Key, null), p.feed(0x1b));
    try std.testing.expectEqual(@as(?Key, Key.escape), p.flush());

    // Parser should be back in ground state
    try std.testing.expectEqual(Key.h, p.feed('h'));
}

test "ctrl_g" {
    var p = InputParser{};
    try std.testing.expectEqual(Key.ctrl_g, p.feed(0x07));
}

test "page up and page down" {
    var p = InputParser{};

    // ESC [ 5 ~ → page_up
    try std.testing.expectEqual(@as(?Key, null), p.feed(0x1b));
    try std.testing.expectEqual(@as(?Key, null), p.feed('['));
    try std.testing.expectEqual(@as(?Key, null), p.feed('5'));
    try std.testing.expectEqual(@as(?Key, Key.page_up), p.feed('~'));

    // ESC [ 6 ~ → page_down
    try std.testing.expectEqual(@as(?Key, null), p.feed(0x1b));
    try std.testing.expectEqual(@as(?Key, null), p.feed('['));
    try std.testing.expectEqual(@as(?Key, null), p.feed('6'));
    try std.testing.expectEqual(@as(?Key, Key.page_down), p.feed('~'));
}
