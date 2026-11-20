const zrx = @import("zrx");
const Named = struct { sink: @TypeOf(zrx.drain()) };

test {
    zrx.program(zrx.range(u32, 0, 3), Named{ .sink = zrx.drain() }).run(.{});
}
