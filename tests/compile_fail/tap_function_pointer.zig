const zrx = @import("zrx");

fn effect(_: u32) void {}

test {
    const pointer: *const fn (u32) void = &effect;
    _ = zrx.tap(pointer);
}
