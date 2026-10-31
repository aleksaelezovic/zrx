const world = @import("zrx");
fn transform(_: bool) u32 {
    return 1;
}
test "source and callback input must match even before run" {
    _ = world.pipe(world.fromSlice(&[_]u32{1}), .{world.each(transform)});
}
