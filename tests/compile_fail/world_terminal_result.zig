const world = @import("zrx");
fn effect(value: u32) u32 {
    return value;
}
test "terminal cannot leak a result" {
    _ = world.forEach(effect);
}
