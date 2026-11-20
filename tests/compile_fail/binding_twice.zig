const zrx = @import("zrx");

const Connection = struct { id: u32 };

fn connect() Connection {
    return .{ .id = 1 };
}
fn ignore(_: Connection, _: u32) void {}

test "a value and a resource in one tuple provide the same type" {
    zrx.program(zrx.range(u32, 0, 3), .{zrx.forEach(ignore)}).run(.{ zrx.resource(connect, null), Connection{ .id = 2 } });
}
