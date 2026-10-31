const zrx = @import("zrx");
fn reduce(_: u64, _: u32) u32 {
    return 0;
}
test "reducer result must match the state parameter exactly" {
    _ = zrx.fold(0, reduce);
}
