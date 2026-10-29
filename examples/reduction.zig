const zrx = @import("zrx");
const pipe = zrx.pipe;
const tryPipe = zrx.tryPipe;
const map = zrx.map;
const filter = zrx.filter;
const fold = zrx.fold;
const tryFold = zrx.tryFold;

fn isEven(value: u32) bool {
    return value % 2 == 0;
}

fn add(total: u64, value: u32) u64 {
    return total +% value;
}

fn checkedAdd(total: u64, value: u32) error{Zero}!u64 {
    if (value == 0) return error.Zero;
    return add(total, value);
}

fn totalEven(values: []const u32, initial: u64) u64 {
    return pipe(values, .{
        filter(isEven),
        fold(initial, add),
    });
}

fn recover(value: error{Zero}!u64) u64 {
    return value catch 99;
}

pub fn main() !void {
    const items = [_]u32{ 1, 2, 3, 4 };
    if (totalEven(&items, 10) != 16) return error.UnexpectedResult;
    if (try pipe(&items, .{tryFold(10, checkedAdd)}) != 20) return error.UnexpectedResult;

    const with_zero = [_]u32{ 1, 0, 3 };
    // tryFold stops the loop; pipe still runs the explicit recovery stage.
    const recovered = pipe(&with_zero, .{ tryFold(0, checkedAdd), map(recover) });
    if (recovered != 99) return error.UnexpectedResult;
    // tryPipe also stops the surrounding pipeline.
    const result = tryPipe(&with_zero, .{tryFold(0, checkedAdd)});
    if (result) |_| {
        return error.UnexpectedResult;
    } else |err| {
        if (err != error.Zero) return error.UnexpectedResult;
    }
    const empty = [_]u32{};
    if (try pipe(&empty, .{tryFold(7, checkedAdd)}) != 7) return error.UnexpectedResult;
}
