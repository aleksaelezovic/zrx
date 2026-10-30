const std = @import("std");
const zrx = @import("zrx");
const pipe = zrx.pipe;
const each = zrx.each;
const forEachWith = zrx.forEachWith;
const run = zrx.run;
const Stream = zrx.Stream;
const Emitter = zrx.Emitter;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var buffer: [64]u8 = undefined;
    var display: std.Io.Writer = .fixed(&buffer);

    const numbers: Stream(u32) = .fromProducer(1, produceNumbers);
    const displayFlow = pipe(&numbers, .{
        each(double),
        forEachWith(&display, writeNumber),
    });
    try run(allocator, io, .{displayFlow});

    if (!std.mem.eql(u8, display.buffered(), "2 4 6 ")) return error.UnexpectedResult;
    std.debug.print("Doubled numbers: {s}\n", .{display.buffered()});
}

fn produceNumbers(numbers: *Emitter(u32)) error{ Closed, Canceled }!void {
    for ([_]u32{ 1, 2, 3 }) |value| {
        try numbers.push(value);
    }
}

fn double(value: u32) u32 {
    return value * 2;
}

fn writeNumber(writer: *std.Io.Writer, value: u32) std.Io.Writer.Error!void {
    try writer.print("{d} ", .{value});
}
