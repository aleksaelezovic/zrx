//! Archived transport regression, not a public API example.
const std = @import("std");
const zrx = @import("zrx");
const Stream = zrx.Stream;
const Emitter = zrx.Emitter;
const pipe = zrx.pipe;
const each = zrx.each;
const forEachWith = zrx.forEachWith;
const run = zrx.run;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var original_buffer: [64]u8 = undefined;
    var doubled_buffer: [64]u8 = undefined;
    var original: std.Io.Writer = .fixed(&original_buffer);
    var doubled: std.Io.Writer = .fixed(&doubled_buffer);
    const numbers: Stream(u32) = .fromProducer(1, produceNumbers);
    const originalFlow = pipe(&numbers, .{forEachWith(&original, writeNumber)});
    const doubledFlow = pipe(&numbers, .{ each(double), forEachWith(&doubled, writeNumber) });
    try run(allocator, io, .{ originalFlow, doubledFlow });

    if (!std.mem.eql(u8, original.buffered(), "1 2 3 ") or
        !std.mem.eql(u8, doubled.buffered(), "2 4 6 "))
        return error.UnexpectedResult;
    std.debug.print("Original: {s}; doubled: {s}\n", .{ original.buffered(), doubled.buffered() });
}

fn produceNumbers(output: *Emitter(u32)) error{ Closed, Canceled }!void {
    for ([_]u32{ 1, 2, 3 }) |value| try output.push(value);
}

fn double(value: u32) u32 {
    return value * 2;
}

fn writeNumber(writer: *std.Io.Writer, value: u32) std.Io.Writer.Error!void {
    try writer.print("{d} ", .{value});
}
