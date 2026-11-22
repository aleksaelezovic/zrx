const zrx = @import("zrx");

test "stdout needs std.Io" {
    zrx.program(zrx.range(u32, 0, 3), .{zrx.print(zrx.ext.process.Stdout, "{d}\n")}).run(.{zrx.ext.process.stdout(zrx.ext.process.Stdout, 64)});
}
