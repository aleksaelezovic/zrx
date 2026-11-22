const std = @import("std");
const zrx = @import("zrx");
const program = zrx.program;
const range = zrx.range;

// The reducer accumulates `u32` items in a `u32`, and `-1` is none.
const total = struct {
    pub const zrx_handler = {};

    pub fn State(comptime Item: type) type {
        return Item;
    }

    pub fn requires(comptime _: usize) []const type {
        return &.{};
    }

    pub fn call(_: anytype, args: anytype) @TypeOf(args[0]) {
        return args[0] + args[1];
    }
};

test {
    program(range(u32, 0, 3), .{ zrx.scan(-1, total), zrx.drain() }).run(.{});
}
