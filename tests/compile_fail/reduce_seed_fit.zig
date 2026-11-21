const std = @import("std");
const zrx = @import("zrx");
const program = zrx.program;
const range = zrx.range;

// The reducer accumulates `u32` elements in a `u32`, and `0.5` is none.
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
    const rows = [_][2]u32{.{ 1, 2 }};
    program(zrx.fromSlice(&rows), .{ zrx.map(zrx.reduce(0.5, total)), zrx.drain() }).run(.{});
}
