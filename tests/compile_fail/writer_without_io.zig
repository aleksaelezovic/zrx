const zrx = @import("zrx");

test "stdout needs std.Io" {
    zrx.program(zrx.range(u32, 0, 3), .{zrx.print(zrx.Stdout, "{d}\n")}).run(.{zrx.stdout(64)});
}
