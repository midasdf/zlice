const std = @import("std");

pub const protocol = @import("protocol.zig");
pub const terminal = @import("terminal.zig");
pub const pty = @import("pty.zig");
pub const vt = @import("vt.zig");
pub const scrollback = @import("scrollback.zig");
pub const mode = @import("mode.zig");
pub const input = @import("input.zig");
pub const config = @import("config.zig");
pub const pane = @import("pane.zig");
pub const tab = @import("tab.zig");
pub const render = @import("render.zig");
pub const status_bar = @import("status_bar.zig");

pub fn main() !void {
    std.debug.print("zlice v0.1.0\n", .{});
}

test {
    _ = protocol;
    _ = terminal;
    _ = pty;
    _ = vt;
    _ = scrollback;
    _ = mode;
    _ = input;
    _ = config;
    _ = pane;
    _ = tab;
    _ = render;
    _ = status_bar;
}
