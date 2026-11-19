const zrx = @import("zrx");

test "two writers for one role" {
    const app = zrx.program(zrx.range(u32, 0, 3), .{zrx.print(zrx.Stdout, "{d}\n")}).provide(.{
        zrx.stdout(64),
        zrx.fileWriter(zrx.Stdout, "out.txt", 64, .{}),
    });
    _ = app;
}
