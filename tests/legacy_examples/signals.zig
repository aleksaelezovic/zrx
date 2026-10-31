//! Archived signal lifecycle regression, not a public API example.
const std = @import("std");
const zrx = @import("zrx");
const Stream = zrx.Stream;
const Emitter = zrx.Emitter;
const pipe = zrx.pipe;
const map = zrx.map;
const hold = zrx.hold;
const values = zrx.values;
const forEachWith = zrx.forEachWith;
const run = zrx.run;
const Comfort = enum { cool, comfortable, warm };

pub fn main(init: std.process.Init) !void {
    var temperature_buffer: [64]u8 = undefined;
    var comfort_buffer: [64]u8 = undefined;
    var temperatures: std.Io.Writer = .fixed(&temperature_buffer);
    var descriptions: std.Io.Writer = .fixed(&comfort_buffer);
    const readings: Stream(i32) = .fromProducer(1, produceReadings);
    const current = pipe(&readings, .{hold(20)});
    const comfort = pipe(&current, .{map(classifyTemperature)});
    try run(init.gpa, init.io, .{
        pipe(values(&current), .{forEachWith(&temperatures, writeTemperature)}),
        pipe(values(&comfort), .{forEachWith(&descriptions, writeComfort)}),
    });
    if (!std.mem.eql(u8, temperatures.buffered(), "20 C 23 C 18 C ") or
        !std.mem.eql(u8, descriptions.buffered(), "comfortable warm cool "))
        return error.UnexpectedResult;
    std.debug.print("Temperature: {s}\nComfort:     {s}\n", .{ temperatures.buffered(), descriptions.buffered() });
}
fn produceReadings(output: *Emitter(i32)) error{ Closed, Canceled }!void {
    for ([_]i32{ 23, 18 }) |celsius| try output.push(celsius);
}
fn classifyTemperature(celsius: i32) Comfort {
    return if (celsius < 20) .cool else if (celsius < 23) .comfortable else .warm;
}
fn writeTemperature(writer: *std.Io.Writer, celsius: i32) std.Io.Writer.Error!void {
    try writer.print("{d} C ", .{celsius});
}
fn writeComfort(writer: *std.Io.Writer, comfort: Comfort) std.Io.Writer.Error!void {
    try writer.print("{s} ", .{@tagName(comfort)});
}
