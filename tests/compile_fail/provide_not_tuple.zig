const zrx = @import("zrx");

test "provide needs a tuple" {
    const app = zrx.program(zrx.range(u32, 0, 3), zrx.pipe(.{zrx.drain()}));
    _ = app.provide(@as(u32, 1));
}
