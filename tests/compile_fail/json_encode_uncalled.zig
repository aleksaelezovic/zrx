const std = @import("std");
const zrx = @import("zrx");
const pipe = zrx.pipe;
const program = zrx.program;
const range = zrx.range;
const map = zrx.map;
const write = zrx.write;
const json = zrx.ext.json;

test {
    var buffer: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    program(range(u32, 0, 3), pipe(.{ map(json.encode), write(*std.Io.Writer, "{f}\n") })).run(.{&writer});
}
