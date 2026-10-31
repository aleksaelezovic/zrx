const world = @import("zrx");
const Role = struct { first: u32, second: u32 };
fn acquire(value: u32) u32 {
    return value;
}
fn release(_: u32) void {}
test "role derivation is not arbitrary construction inference" {
    _ = world.deriveResource(Role, world.resource(@as(u32, 1), acquire, release));
}
