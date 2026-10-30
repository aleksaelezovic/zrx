const zrx = @import("zrx");
const Input = struct {
    pub fn next(_: *@This(), _: anytype) ?u32 {
        return null;
    }
};
test {
    var input: Input = .{};
    _ = zrx.fromIterator(&input);
}
