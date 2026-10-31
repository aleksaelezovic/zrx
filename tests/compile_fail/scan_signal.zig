const zrx = @import("zrx");
fn add(state: u32, value: u32) u32 {
    return state + value;
}
test {
    const signal = zrx.pipe(&[_]u32{1}, .{zrx.hold(0)});
    _ = zrx.pipe(&signal, .{zrx.scan(0, add)});
}
