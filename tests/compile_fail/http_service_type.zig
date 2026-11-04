const zrx = @import("zrx");
test {
    _ = zrx.httpRequests(struct { not_a_server: usize });
}
