const zrx = @import("zrx");
test "empty callbacks are not identity" {
    _ = zrx.map(.{});
}
