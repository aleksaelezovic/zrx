const std = @import("std");
const zrx = @import("zrx");
const program = zrx.program;

// An `f32` does not hold this whole number: Zig refuses it as a literal,
// and so does the seed.
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
    program(zrx.fromSlice(&[_][2]f32{.{ 1, 2 }}), .{ zrx.map(zrx.reduce(16777217, total)), zrx.drain() }).run(.{});
}
