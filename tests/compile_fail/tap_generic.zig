const zrx = @import("zrx");

fn invalid(_: anytype) void {}

test {
    _ = zrx.tap(invalid);
}
