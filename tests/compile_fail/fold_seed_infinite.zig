const std = @import("std");
const zrx = @import("zrx");
const program = zrx.program;

// The reducer accumulates `f32` items in an `f32`, and as one `1e300` is
// infinite: the seed is judged as the state it becomes.
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
    program(zrx.fromSlice(&[_]f32{1}), .{ zrx.fold(1e300, total), zrx.drain() }).run(.{});
}
