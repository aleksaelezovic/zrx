const zrx = @import("zrx");

fn effect(_: error{Data}) error{Failed}!void {}

test {
    _ = zrx.tap(effect);
}
