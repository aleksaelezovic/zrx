const zrx = @import("zrx");
const Input = struct {
    pub fn next(_: *@This()) ?u32 {
        return null;
    }
};
test {
    const input: Input = .{};
    _ = zrx.fromIterator(&input);
}
