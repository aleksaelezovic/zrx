const zrx = @import("zrx");

fn constant() u32 {
    return 42;
}

test {
    _ = zrx.map(constant);
}
