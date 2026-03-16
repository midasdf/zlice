const std = @import("std");

pub const protocol = @import("protocol.zig");

pub fn main() !void {
    std.debug.print("zlice v0.1.0\n", .{});
}

test {
    _ = protocol;
}
