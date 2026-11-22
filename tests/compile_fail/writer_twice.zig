const zrx = @import("zrx");

test "two writers for one role" {
    const app = zrx.program(zrx.range(u32, 0, 3), .{zrx.print(zrx.ext.process.Stdout, "{d}\n")}).provide(.{
        zrx.ext.process.stdout(zrx.ext.process.Stdout, 64),
        zrx.ext.fs.fileWriter(zrx.ext.process.Stdout, "out.txt", 64, .{}),
    });
    _ = app;
}
