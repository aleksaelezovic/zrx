const std = @import("std");
const zrx = @import("zrx");
const pipe = zrx.pipe;
const fromSlice = zrx.fromSlice;
const hold = zrx.hold;
const map = zrx.map;
const values = zrx.values;
const each = zrx.each;
const stderrLines = zrx.stderrLines;
const run = zrx.run;

const Offset = struct { value: i32 };
fn convert(offset: Offset, value: i32) i32 {
    return value + offset.value;
}
fn format(value: i32) !zrx.Line(64) {
    var buffer: [64]u8 = undefined;
    const text = try std.fmt.bufPrint(&buffer, "Signal state: {d}", .{value});
    return zrx.line(64, text);
}
pub fn main(init: std.process.Init) !void {
    const updates = fromSlice(&[_]i32{ 23, 18 });
    const temperature = pipe(&updates, .{ hold(@as(i32, 20)), map(convert) });
    try run(.{ init.gpa, init.io, Offset{ .value = 1 } }, .{
        pipe(values(&temperature), .{ each(format), stderrLines() }),
    });
}
