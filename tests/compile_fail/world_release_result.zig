const world = @import("zrx");
fn acquire(value: u32) u32 {
    return value;
}
fn release(_: u32) !void {}
test "release must be infallible" {
    _ = world.resource(@as(u32, 1), acquire, release);
}
