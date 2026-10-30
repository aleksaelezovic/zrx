const zrx = @import("zrx");
const Input = struct {
    pub fn next(_: *@This()) u32 {
        return 0;
    }
};
test {
    var input: Input = .{};
    _ = zrx.fromIterator(&input);
}
