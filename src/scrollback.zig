const std = @import("std");

pub const LineEntry = struct {
    start: u32,
    len: u16,
};

pub const Scrollback = struct {
    buf: []u8,
    lines: []LineEntry,
    count: usize = 0,
    head: usize = 0,
    buf_pos: usize = 0,
    buf_used: usize = 0,
    max_lines: u16,
    max_bytes: usize,

    pub fn init(allocator: std.mem.Allocator, max_lines: u16, max_bytes: usize) !Scrollback {
        const buf = try allocator.alloc(u8, max_bytes);
        errdefer allocator.free(buf);
        const lines = try allocator.alloc(LineEntry, max_lines);
        return Scrollback{
            .buf = buf,
            .lines = lines,
            .max_lines = max_lines,
            .max_bytes = max_bytes,
        };
    }

    pub fn deinit(self: *Scrollback, allocator: std.mem.Allocator) void {
        allocator.free(self.buf);
        allocator.free(self.lines);
    }

    pub fn pushLine(self: *Scrollback, data: []const u8) void {
        // Truncate data to u16 max
        const max_len: usize = std.math.maxInt(u16);
        const len: u16 = @intCast(@min(data.len, max_len));
        const slice = data[0..len];

        // If the line is larger than the entire buffer, we can't store it
        if (len > self.max_bytes) return;

        // Evict oldest lines until we have enough space in buf
        while (self.buf_used + len > self.max_bytes and self.count > 0) {
            self.evictOldest();
        }

        // Write data to buf, handling wrap-around
        const start: u32 = @intCast(self.buf_pos);
        const remaining = self.max_bytes - self.buf_pos;
        if (len <= remaining) {
            @memcpy(self.buf[self.buf_pos .. self.buf_pos + len], slice);
        } else {
            // Split across boundary
            @memcpy(self.buf[self.buf_pos .. self.buf_pos + remaining], slice[0..remaining]);
            @memcpy(self.buf[0 .. len - remaining], slice[remaining..]);
        }
        self.buf_pos = (self.buf_pos + len) % self.max_bytes;
        self.buf_used += len;

        // Evict oldest if lines ring is full
        if (self.count >= self.max_lines) {
            self.evictOldestLine();
        }

        // Record LineEntry in lines ring
        self.lines[self.head] = LineEntry{ .start = start, .len = len };
        self.head = (self.head + 1) % self.max_lines;
        self.count += 1;
    }

    /// Evict the oldest line from the lines ring and account for its bytes.
    fn evictOldest(self: *Scrollback) void {
        if (self.count == 0) return;
        const tail = (self.head + self.max_lines - self.count) % self.max_lines;
        self.buf_used -= self.lines[tail].len;
        self.count -= 1;
    }

    /// Evict the oldest line from the lines ring (count >= max_lines case).
    /// Bytes are NOT subtracted here because the new line's bytes will overwrite them.
    fn evictOldestLine(self: *Scrollback) void {
        if (self.count == 0) return;
        const tail = (self.head + self.max_lines - self.count) % self.max_lines;
        self.buf_used -= self.lines[tail].len;
        self.count -= 1;
    }

    pub fn getLine(self: *const Scrollback, index: usize, out_buf: []u8) ?[]const u8 {
        if (index >= self.count) return null;

        const tail = (self.head + self.max_lines - self.count) % self.max_lines;
        const slot = (tail + index) % self.max_lines;
        const entry = self.lines[slot];
        const len: usize = entry.len;
        const start: usize = entry.start;

        if (len == 0) return self.buf[0..0];

        const end = start + len;
        if (end <= self.max_bytes) {
            // No wrap-around: return a slice directly into self.buf
            return self.buf[start..end];
        } else {
            // Wraps around buffer boundary: copy into out_buf
            if (out_buf.len < len) return null;
            const first_part = self.max_bytes - start;
            @memcpy(out_buf[0..first_part], self.buf[start..self.max_bytes]);
            @memcpy(out_buf[first_part..len], self.buf[0 .. len - first_part]);
            return out_buf[0..len];
        }
    }

    pub fn lineCount(self: *const Scrollback) usize {
        return self.count;
    }

    pub fn clear(self: *Scrollback) void {
        self.count = 0;
        self.head = 0;
        self.buf_pos = 0;
        self.buf_used = 0;
    }
};

test "push and retrieve lines" {
    const allocator = std.testing.allocator;
    var sb = try Scrollback.init(allocator, 10, 1024);
    defer sb.deinit(allocator);

    var tmp: [1024]u8 = undefined;

    sb.pushLine("hello");
    sb.pushLine("world");

    try std.testing.expectEqual(@as(usize, 2), sb.lineCount());

    const line0 = sb.getLine(0, &tmp).?;
    try std.testing.expectEqualStrings("hello", line0);

    const line1 = sb.getLine(1, &tmp).?;
    try std.testing.expectEqualStrings("world", line1);
}

test "eviction when max_lines exceeded" {
    const allocator = std.testing.allocator;
    var sb = try Scrollback.init(allocator, 3, 1024);
    defer sb.deinit(allocator);

    var tmp: [1024]u8 = undefined;

    sb.pushLine("line1");
    sb.pushLine("line2");
    sb.pushLine("line3");
    sb.pushLine("line4");

    try std.testing.expectEqual(@as(usize, 3), sb.lineCount());

    // Oldest ("line1") should have been evicted
    const line0 = sb.getLine(0, &tmp).?;
    try std.testing.expectEqualStrings("line2", line0);

    const line1 = sb.getLine(1, &tmp).?;
    try std.testing.expectEqualStrings("line3", line1);

    const line2 = sb.getLine(2, &tmp).?;
    try std.testing.expectEqualStrings("line4", line2);
}

test "eviction when max_bytes exceeded" {
    const allocator = std.testing.allocator;
    // 3x4-byte lines into 10-byte buf
    // After pushing "abcd"(4) + "efgh"(4) = 8 bytes used.
    // Pushing "ijkl"(4) requires 8+4=12 > 10, so evict "abcd" -> 4 bytes used, then fits.
    var sb = try Scrollback.init(allocator, 10, 10);
    defer sb.deinit(allocator);

    var tmp: [1024]u8 = undefined;

    sb.pushLine("abcd");
    sb.pushLine("efgh");
    sb.pushLine("ijkl");

    // "abcd" should have been evicted
    try std.testing.expectEqual(@as(usize, 2), sb.lineCount());

    const line0 = sb.getLine(0, &tmp).?;
    try std.testing.expectEqualStrings("efgh", line0);

    const line1 = sb.getLine(1, &tmp).?;
    try std.testing.expectEqualStrings("ijkl", line1);
}

test "clear resets state" {
    const allocator = std.testing.allocator;
    var sb = try Scrollback.init(allocator, 10, 1024);
    defer sb.deinit(allocator);

    var tmp: [1024]u8 = undefined;

    sb.pushLine("hello");
    sb.pushLine("world");
    try std.testing.expectEqual(@as(usize, 2), sb.lineCount());

    sb.clear();
    try std.testing.expectEqual(@as(usize, 0), sb.lineCount());
    try std.testing.expect(sb.getLine(0, &tmp) == null);
}

test "out of range returns null" {
    const allocator = std.testing.allocator;
    var sb = try Scrollback.init(allocator, 10, 1024);
    defer sb.deinit(allocator);

    var tmp: [1024]u8 = undefined;

    sb.pushLine("only");
    try std.testing.expect(sb.getLine(1, &tmp) == null);
    try std.testing.expect(sb.getLine(100, &tmp) == null);
}
