const std = @import("std");
const zrx = @import("zrx");
const Budget = struct { count: usize };
fn identity(item: u32) error{Failed}!u32 {
    return item;
}
fn policy(_: Budget, _: error{Failed}, _: usize) zrx.RetryDecision {
    return .stop;
}
fn ignore(_: error{Failed}!u32) void {}
test {
    const retried = zrx.retryPipe(zrx.fromValue(@as(u32, 1)), .{zrx.map(identity)}, policy);
    try zrx.run(.{ std.testing.allocator, std.testing.io }, .{zrx.pipe(retried, .{zrx.forEach(ignore)})});
}
