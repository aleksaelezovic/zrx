const std = @import("std");
const zrx = @import("zrx");
const program = zrx.program;

// Not 0 where it is written, and 0 as the `f16` it would be.
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
    program(zrx.fromSlice(&[_]f16{1}), .{ zrx.scan(1e-10, total), zrx.drain() }).run(.{});
}
