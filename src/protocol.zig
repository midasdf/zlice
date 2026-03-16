const std = @import("std");

// ─── Constants ────────────────────────────────────────────────────────────────

pub const PROTOCOL_VERSION: u8 = 0x01;
pub const MAX_PAYLOAD_LEN: u32 = 65536;
pub const HEADER_SIZE: usize = 6; // ver(1) + type(1) + len(4)

// ─── Enums ────────────────────────────────────────────────────────────────────

pub const MessageType = enum(u8) {
    // Client → Server
    hello = 0x00,
    input = 0x01,
    resize = 0x02,
    command = 0x03,
    // Server → Client
    hello_ack = 0x80,
    render = 0x81,
    state = 0x82,
    exit = 0x83,
    err = 0x84,
};

pub const CommandId = enum(u8) {
    split_horizontal = 0x01,
    split_vertical = 0x02,
    close_pane = 0x03,
    focus_pane = 0x04,
    resize_pane = 0x05,
    toggle_fullscreen = 0x06,
    scroll_up_lines = 0x07,
    scroll_down_lines = 0x08,
    scroll_half_page_up = 0x09,
    scroll_half_page_down = 0x0A,
    new_tab = 0x10,
    close_tab = 0x11,
    switch_tab = 0x12,
    rename_tab = 0x13,
    next_tab = 0x14,
    prev_tab = 0x15,
    detach = 0x20,
    quit = 0x21,
};

pub const Direction = enum(u8) {
    left = 0,
    down = 1,
    up = 2,
    right = 3,
};

// ─── Frame ────────────────────────────────────────────────────────────────────

/// A parsed protocol frame. `payload` is a slice into caller-owned memory.
pub const Frame = struct {
    version: u8,
    msg_type: MessageType,
    payload: []const u8,
};

// ─── Wire encoding ────────────────────────────────────────────────────────────

/// Encode a frame header + payload into `out`.
/// `out` must be at least HEADER_SIZE + payload.len bytes.
/// Returns the number of bytes written.
pub fn encodeFrame(
    out: []u8,
    msg_type: MessageType,
    payload: []const u8,
) error{BufferTooSmall}!usize {
    const total = HEADER_SIZE + payload.len;
    if (out.len < total) return error.BufferTooSmall;
    if (payload.len > MAX_PAYLOAD_LEN) return error.BufferTooSmall;

    out[0] = PROTOCOL_VERSION;
    out[1] = @intFromEnum(msg_type);
    const len: u32 = @intCast(payload.len);
    std.mem.writeInt(u32, out[2..6], len, .big);
    @memcpy(out[HEADER_SIZE .. HEADER_SIZE + payload.len], payload);
    return total;
}

/// Decode only the 6-byte header. Returns a partial Frame with an empty payload slice.
/// The caller is responsible for reading exactly `frame.payload` more bytes
/// (the length is encoded in the header — use `decodeHeader` then read that many bytes).
pub const HeaderResult = struct {
    version: u8,
    msg_type: MessageType,
    payload_len: u32,
};

pub fn decodeHeader(buf: *const [HEADER_SIZE]u8) error{UnknownMessageType}!HeaderResult {
    const version = buf[0];
    const raw_type = buf[1];
    const mt = switch (raw_type) {
        0x00 => MessageType.hello,
        0x01 => MessageType.input,
        0x02 => MessageType.resize,
        0x03 => MessageType.command,
        0x80 => MessageType.hello_ack,
        0x81 => MessageType.render,
        0x82 => MessageType.state,
        0x83 => MessageType.exit,
        0x84 => MessageType.err,
        else => return error.UnknownMessageType,
    };
    const payload_len = std.mem.readInt(u32, buf[2..6], .big);
    return .{ .version = version, .msg_type = mt, .payload_len = payload_len };
}

// ─── Payload helpers ──────────────────────────────────────────────────────────

// Hello  ──────────────────────────────────────────────────────────────────────
// Layout: [client_version(1)] [term_len(1)] [term(N)] [cols(2,be)] [rows(2,be)]

pub const HelloPayload = struct {
    client_version: u8,
    term: []const u8, // e.g. "xterm-256color"
    cols: u16,
    rows: u16,
};

pub fn encodeHello(out: []u8, p: HelloPayload) error{BufferTooSmall}!usize {
    const term_len = p.term.len;
    const needed = 1 + 1 + term_len + 2 + 2;
    if (out.len < needed) return error.BufferTooSmall;
    out[0] = p.client_version;
    out[1] = @intCast(term_len);
    @memcpy(out[2 .. 2 + term_len], p.term);
    const off = 2 + term_len;
    std.mem.writeInt(u16, out[off..][0..2], p.cols, .big);
    std.mem.writeInt(u16, out[off + 2 ..][0..2], p.rows, .big);
    return needed;
}

pub fn decodeHello(payload: []const u8) error{Truncated}!HelloPayload {
    if (payload.len < 2) return error.Truncated;
    const client_version = payload[0];
    const term_len: usize = payload[1];
    if (payload.len < 2 + term_len + 4) return error.Truncated;
    const term = payload[2 .. 2 + term_len];
    const off = 2 + term_len;
    const cols = std.mem.readInt(u16, payload[off..][0..2], .big);
    const rows = std.mem.readInt(u16, payload[off + 2 ..][0..2], .big);
    return .{ .client_version = client_version, .term = term, .cols = cols, .rows = rows };
}

// Resize  ─────────────────────────────────────────────────────────────────────
// Layout: [cols(2,be)] [rows(2,be)]

pub const ResizePayload = struct {
    cols: u16,
    rows: u16,
};

pub fn encodeResize(out: []u8, p: ResizePayload) error{BufferTooSmall}!usize {
    if (out.len < 4) return error.BufferTooSmall;
    std.mem.writeInt(u16, out[0..2], p.cols, .big);
    std.mem.writeInt(u16, out[2..4], p.rows, .big);
    return 4;
}

pub fn decodeResize(payload: []const u8) error{Truncated}!ResizePayload {
    if (payload.len < 4) return error.Truncated;
    const cols = std.mem.readInt(u16, payload[0..2], .big);
    const rows = std.mem.readInt(u16, payload[2..4], .big);
    return .{ .cols = cols, .rows = rows };
}

// Error  ──────────────────────────────────────────────────────────────────────
// Layout: [code(2,be)] [msg_len(2,be)] [msg(N)]

pub const ErrorPayload = struct {
    code: u16,
    msg: []const u8,
};

pub fn encodeError(out: []u8, p: ErrorPayload) error{BufferTooSmall}!usize {
    const needed = 2 + 2 + p.msg.len;
    if (out.len < needed) return error.BufferTooSmall;
    std.mem.writeInt(u16, out[0..2], p.code, .big);
    std.mem.writeInt(u16, out[2..4], @intCast(p.msg.len), .big);
    @memcpy(out[4 .. 4 + p.msg.len], p.msg);
    return needed;
}

pub fn decodeError(payload: []const u8) error{Truncated}!ErrorPayload {
    if (payload.len < 4) return error.Truncated;
    const code = std.mem.readInt(u16, payload[0..2], .big);
    const msg_len: usize = std.mem.readInt(u16, payload[2..4], .big);
    if (payload.len < 4 + msg_len) return error.Truncated;
    return .{ .code = code, .msg = payload[4 .. 4 + msg_len] };
}

// State  ──────────────────────────────────────────────────────────────────────
// Layout: [session_id(4,be)] [num_panes(2,be)] [active_pane(2,be)] [num_tabs(2,be)] [active_tab(2,be)]

pub const StatePayload = struct {
    session_id: u32,
    num_panes: u16,
    active_pane: u16,
    num_tabs: u16,
    active_tab: u16,
};

pub fn encodeState(out: []u8, p: StatePayload) error{BufferTooSmall}!usize {
    if (out.len < 12) return error.BufferTooSmall;
    std.mem.writeInt(u32, out[0..4], p.session_id, .big);
    std.mem.writeInt(u16, out[4..6], p.num_panes, .big);
    std.mem.writeInt(u16, out[6..8], p.active_pane, .big);
    std.mem.writeInt(u16, out[8..10], p.num_tabs, .big);
    std.mem.writeInt(u16, out[10..12], p.active_tab, .big);
    return 12;
}

pub fn decodeState(payload: []const u8) error{Truncated}!StatePayload {
    if (payload.len < 12) return error.Truncated;
    return .{
        .session_id = std.mem.readInt(u32, payload[0..4], .big),
        .num_panes = std.mem.readInt(u16, payload[4..6], .big),
        .active_pane = std.mem.readInt(u16, payload[6..8], .big),
        .num_tabs = std.mem.readInt(u16, payload[8..10], .big),
        .active_tab = std.mem.readInt(u16, payload[10..12], .big),
    };
}

// DirtyHeader  ────────────────────────────────────────────────────────────────
// Used as a sub-header inside render payloads to mark dirty cell regions.
// Layout: [pane_id(2,be)] [x(2,be)] [y(2,be)] [width(2,be)] [height(2,be)]

pub const DirtyHeader = struct {
    pane_id: u16,
    x: u16,
    y: u16,
    width: u16,
    height: u16,
};

pub const DIRTY_HEADER_SIZE: usize = 10;

pub fn encodeDirtyHeader(out: []u8, h: DirtyHeader) error{BufferTooSmall}!usize {
    if (out.len < DIRTY_HEADER_SIZE) return error.BufferTooSmall;
    std.mem.writeInt(u16, out[0..2], h.pane_id, .big);
    std.mem.writeInt(u16, out[2..4], h.x, .big);
    std.mem.writeInt(u16, out[4..6], h.y, .big);
    std.mem.writeInt(u16, out[6..8], h.width, .big);
    std.mem.writeInt(u16, out[8..10], h.height, .big);
    return DIRTY_HEADER_SIZE;
}

pub fn decodeDirtyHeader(payload: []const u8) error{Truncated}!DirtyHeader {
    if (payload.len < DIRTY_HEADER_SIZE) return error.Truncated;
    return .{
        .pane_id = std.mem.readInt(u16, payload[0..2], .big),
        .x = std.mem.readInt(u16, payload[2..4], .big),
        .y = std.mem.readInt(u16, payload[4..6], .big),
        .width = std.mem.readInt(u16, payload[6..8], .big),
        .height = std.mem.readInt(u16, payload[8..10], .big),
    };
}

// ─── Tests ────────────────────────────────────────────────────────────────────

test "constants" {
    try std.testing.expectEqual(@as(u8, 0x01), PROTOCOL_VERSION);
    try std.testing.expectEqual(@as(u32, 65536), MAX_PAYLOAD_LEN);
    try std.testing.expectEqual(@as(usize, 6), HEADER_SIZE);
}

test "MessageType enum values" {
    try std.testing.expectEqual(@as(u8, 0x00), @intFromEnum(MessageType.hello));
    try std.testing.expectEqual(@as(u8, 0x01), @intFromEnum(MessageType.input));
    try std.testing.expectEqual(@as(u8, 0x80), @intFromEnum(MessageType.hello_ack));
    try std.testing.expectEqual(@as(u8, 0x84), @intFromEnum(MessageType.err));
}

test "CommandId enum values" {
    try std.testing.expectEqual(@as(u8, 0x01), @intFromEnum(CommandId.split_horizontal));
    try std.testing.expectEqual(@as(u8, 0x20), @intFromEnum(CommandId.detach));
    try std.testing.expectEqual(@as(u8, 0x21), @intFromEnum(CommandId.quit));
}

test "Direction enum values" {
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(Direction.left));
    try std.testing.expectEqual(@as(u8, 3), @intFromEnum(Direction.right));
}

test "encodeFrame / decodeHeader round-trip" {
    var buf: [256]u8 = undefined;
    const payload = "hello world";
    const written = try encodeFrame(&buf, .input, payload);
    try std.testing.expectEqual(HEADER_SIZE + payload.len, written);
    try std.testing.expectEqual(PROTOCOL_VERSION, buf[0]);
    try std.testing.expectEqual(@as(u8, 0x01), buf[1]);
    const hdr = try decodeHeader(buf[0..HEADER_SIZE]);
    try std.testing.expectEqual(PROTOCOL_VERSION, hdr.version);
    try std.testing.expectEqual(MessageType.input, hdr.msg_type);
    try std.testing.expectEqual(@as(u32, payload.len), hdr.payload_len);
}

test "encodeFrame buffer too small" {
    var buf: [4]u8 = undefined;
    try std.testing.expectError(error.BufferTooSmall, encodeFrame(&buf, .hello, "abc"));
}

test "decodeHeader unknown message type" {
    var buf = [_]u8{ PROTOCOL_VERSION, 0xFF, 0, 0, 0, 0 };
    try std.testing.expectError(error.UnknownMessageType, decodeHeader(&buf));
}

test "encodeFrame all message types" {
    var buf: [32]u8 = undefined;
    const types = [_]MessageType{ .hello, .input, .resize, .command, .hello_ack, .render, .state, .exit, .err };
    for (types) |mt| {
        const n = try encodeFrame(&buf, mt, "x");
        try std.testing.expectEqual(HEADER_SIZE + 1, n);
        const hdr = try decodeHeader(buf[0..HEADER_SIZE]);
        try std.testing.expectEqual(mt, hdr.msg_type);
    }
}

test "hello payload round-trip" {
    var buf: [64]u8 = undefined;
    const p = HelloPayload{
        .client_version = PROTOCOL_VERSION,
        .term = "xterm-256color",
        .cols = 220,
        .rows = 50,
    };
    const n = try encodeHello(&buf, p);
    const decoded = try decodeHello(buf[0..n]);
    try std.testing.expectEqual(p.client_version, decoded.client_version);
    try std.testing.expectEqualStrings(p.term, decoded.term);
    try std.testing.expectEqual(p.cols, decoded.cols);
    try std.testing.expectEqual(p.rows, decoded.rows);
}

test "hello payload truncated" {
    try std.testing.expectError(error.Truncated, decodeHello(&.{0x01}));
    // term_len says 10 but only 3 bytes follow
    const bad = [_]u8{ 0x01, 0x0A, 'a', 'b', 'c' };
    try std.testing.expectError(error.Truncated, decodeHello(&bad));
}

test "resize payload round-trip" {
    var buf: [4]u8 = undefined;
    const p = ResizePayload{ .cols = 132, .rows = 43 };
    const n = try encodeResize(&buf, p);
    try std.testing.expectEqual(@as(usize, 4), n);
    const decoded = try decodeResize(buf[0..n]);
    try std.testing.expectEqual(p.cols, decoded.cols);
    try std.testing.expectEqual(p.rows, decoded.rows);
}

test "resize payload truncated" {
    try std.testing.expectError(error.Truncated, decodeResize(&.{ 0, 1, 2 }));
}

test "error payload round-trip" {
    var buf: [64]u8 = undefined;
    const p = ErrorPayload{ .code = 404, .msg = "pane not found" };
    const n = try encodeError(&buf, p);
    const decoded = try decodeError(buf[0..n]);
    try std.testing.expectEqual(p.code, decoded.code);
    try std.testing.expectEqualStrings(p.msg, decoded.msg);
}

test "error payload truncated" {
    try std.testing.expectError(error.Truncated, decodeError(&.{ 0, 1 }));
    // msg_len says 100 but buffer is only 5 bytes total
    const bad = [_]u8{ 0x00, 0x01, 0x00, 0x64, 'x' };
    try std.testing.expectError(error.Truncated, decodeError(&bad));
}

test "state payload round-trip" {
    var buf: [12]u8 = undefined;
    const p = StatePayload{
        .session_id = 0xDEADBEEF,
        .num_panes = 4,
        .active_pane = 2,
        .num_tabs = 3,
        .active_tab = 1,
    };
    const n = try encodeState(&buf, p);
    try std.testing.expectEqual(@as(usize, 12), n);
    const decoded = try decodeState(buf[0..n]);
    try std.testing.expectEqual(p.session_id, decoded.session_id);
    try std.testing.expectEqual(p.num_panes, decoded.num_panes);
    try std.testing.expectEqual(p.active_pane, decoded.active_pane);
    try std.testing.expectEqual(p.num_tabs, decoded.num_tabs);
    try std.testing.expectEqual(p.active_tab, decoded.active_tab);
}

test "state payload truncated" {
    try std.testing.expectError(error.Truncated, decodeState(&.{ 0, 1, 2, 3, 4 }));
}

test "dirty header round-trip" {
    var buf: [DIRTY_HEADER_SIZE]u8 = undefined;
    const h = DirtyHeader{ .pane_id = 7, .x = 10, .y = 20, .width = 80, .height = 24 };
    const n = try encodeDirtyHeader(&buf, h);
    try std.testing.expectEqual(DIRTY_HEADER_SIZE, n);
    const decoded = try decodeDirtyHeader(buf[0..n]);
    try std.testing.expectEqual(h.pane_id, decoded.pane_id);
    try std.testing.expectEqual(h.x, decoded.x);
    try std.testing.expectEqual(h.y, decoded.y);
    try std.testing.expectEqual(h.width, decoded.width);
    try std.testing.expectEqual(h.height, decoded.height);
}

test "dirty header truncated" {
    try std.testing.expectError(error.Truncated, decodeDirtyHeader(&.{ 0, 1, 2, 3 }));
}

test "encodeFrame big-endian length bytes" {
    // payload of exactly 256 bytes would set bytes [2..6] = 0x00_00_01_00
    // use a smaller payload: 0x0102 = 258 bytes
    var payload: [258]u8 = undefined;
    @memset(&payload, 0xAB);
    var big_buf: [264]u8 = undefined;
    const n = try encodeFrame(&big_buf, .render, &payload);
    try std.testing.expectEqual(@as(usize, HEADER_SIZE + 258), n);
    try std.testing.expectEqual(@as(u8, 0x00), big_buf[2]);
    try std.testing.expectEqual(@as(u8, 0x00), big_buf[3]);
    try std.testing.expectEqual(@as(u8, 0x01), big_buf[4]);
    try std.testing.expectEqual(@as(u8, 0x02), big_buf[5]);
}
