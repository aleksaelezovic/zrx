const zrx = @import("zrx");

const Scale = struct { by: u32 };

fn ignore(_: Scale, _: u32) void {}

test "two defaults for one type" {
    const app = zrx.program(zrx.range(u32, 0, 3), .{zrx.forEach(ignore)}).provide(.{Scale{ .by = 1 }});
    _ = app.provide(.{Scale{ .by = 2 }});
}
