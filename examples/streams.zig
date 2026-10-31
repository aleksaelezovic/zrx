const std = @import("std");
const zrx = @import("zrx");
const pipe = zrx.pipe;
const each = zrx.each;
const filter = zrx.filter;
const fold = zrx.fold;
const stderrLines = zrx.stderrLines;
const run = zrx.run;

const Scale = struct { value: u32 };
fn produce(output: *zrx.Emitter(u32)) !void {
    for ([_]u32{ 1, 2, 3, 4 }) |value| try output.push(value);
}
fn scale(factor: Scale, value: u32) u32 {
    return value * factor.value;
}
fn large(value: u32) bool {
    return value >= 6;
}
fn add(sum: u64, value: u32) u64 {
    return sum + value;
}
fn format(value: u64) !zrx.Line(64) {
    var buffer: [64]u8 = undefined;
    const text = try std.fmt.bufPrint(&buffer, "Stream total: {d}", .{value});
    return zrx.line(64, text);
}
pub fn main(init: std.process.Init) !void {
    const source = zrx.Stream(u32).fromProducer(1, produce);
    try run(.{ init.gpa, init.io, Scale{ .value = 2 } }, .{
        pipe(&source, .{ each(scale), filter(large), fold(@as(u64, 0), add), each(format), stderrLines() }),
    });
}
