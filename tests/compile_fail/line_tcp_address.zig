const zrx = @import("zrx");
test {
    _ = zrx.tcpLines(@as(u16, 8080), 32, 1);
}
