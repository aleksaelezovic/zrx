const zrx = @import("zrx");

test {
    const Invalid = struct {
        pub fn Output(comptime _: type) type {
            return bool;
        }
        pub fn apply(_: @This(), value: u32) u32 {
            return value;
        }
    };
    _ = zrx.pipe(@as(u32, 1), .{Invalid{}});
}
