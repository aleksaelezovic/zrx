const zrx = @import("zrx");
fn add(state: u32, value: u32) u32 {
    return state + value;
}
test {
    _ = zrx.pipe([_]u32{1}, .{zrx.scan(0, add)});
}
