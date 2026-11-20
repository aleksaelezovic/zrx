const std = @import("std");
const zrx = @import("zrx");
const program = zrx.program;
const range = zrx.range;
const map = zrx.map;
const forEach = zrx.forEach;
const rescue = zrx.rescue;

fn evenOnly(value: u32) error{Odd}!u32 {
    if (value % 2 == 1) return error.Odd;
    return value;
}
fn ignore(_: anytype) void {}
const failing = program(range(u32, 0, 3), .{ map(evenOnly), forEach(ignore) });

// Named like what this library hands its own programs. It is not that.
const Lookalike = struct {
    env: struct { u32 },

    pub const zrx_resolved = {};
    pub const rescued = false;
};
test {
    failing.run(Lookalike{ .env = .{1} });
}
