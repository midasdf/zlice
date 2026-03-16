const std = @import("std");

pub const protocol = @import("protocol.zig");
pub const terminal = @import("terminal.zig");
pub const pty = @import("pty.zig");
pub const vt = @import("vt.zig");
pub const scrollback = @import("scrollback.zig");

pub fn main() !void {
    std.debug.print("zlice v0.1.0\n", .{});
}

test {
    _ = protocol;
    _ = terminal;
    _ = pty;
    _ = vt;
    _ = scrollback;
}
