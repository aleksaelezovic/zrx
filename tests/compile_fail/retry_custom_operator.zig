const zrx = @import("zrx");
fn identity(item: u32) u32 {
    return item;
}
const Custom = struct {
    pub fn Output(comptime Source: type) type {
        return @TypeOf(zrx.map(identity)).Output(Source);
    }
    pub fn apply(_: @This(), source: anytype) Output(@TypeOf(source)) {
        return zrx.map(identity).apply(source);
    }
};
test {
    _ = zrx.retryPipe(zrx.fromValue(@as(u32, 1)), .{Custom{}}, .{ .max_attempts = 1 });
}
