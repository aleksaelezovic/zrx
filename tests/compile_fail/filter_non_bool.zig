const zrx = @import("zrx");

fn invalid(_: u32) error{Failed}!bool {
    return true;
}

test {
    _ = zrx.filter(invalid);
}
