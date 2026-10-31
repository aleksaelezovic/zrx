//! Archived transport regression, not a public API example.
const std = @import("std");
const zrx = @import("zrx");
const Stream = zrx.Stream;
const Emitter = zrx.Emitter;
const pipe = zrx.pipe;
const each = zrx.each;
const forEachWith = zrx.forEachWith;
const run = zrx.run;

const Number = struct { value: u32, evaluations: *usize };

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    var evaluations: usize = 0;
    var display_buffer: [64]u8 = undefined;
    var audit_buffer: [64]u8 = undefined;
    var display: std.Io.Writer = .fixed(&display_buffer);
    var audit: std.Io.Writer = .fixed(&audit_buffer);

    const numbers: Stream(Number) = .fromProducerWith(1, produceNumbers, &evaluations);
    const doubled = pipe(&numbers, .{each(doubleAndCount)});
    const displayFlow = pipe(&doubled, .{forEachWith(&display, writeNumber)});
    const auditFlow = pipe(&doubled, .{forEachWith(&audit, writeNumber)});

    try run(allocator, io, .{ displayFlow, auditFlow });

    if (evaluations != 3 or
        !std.mem.eql(u8, display.buffered(), "2 4 6 ") or
        !std.mem.eql(u8, audit.buffered(), "2 4 6 "))
        return error.UnexpectedResult;
    std.debug.print("Display: {s}\nAudit: {s}\nEvaluations: {d}\n", .{ display.buffered(), audit.buffered(), evaluations });
}

fn produceNumbers(evaluations: *usize, output: *Emitter(Number)) error{ Closed, Canceled }!void {
    for ([_]u32{ 1, 2, 3 }) |value| try output.push(.{ .value = value, .evaluations = evaluations });
}

fn doubleAndCount(number: Number) u32 {
    number.evaluations.* += 1;
    return number.value * 2;
}

fn writeNumber(writer: *std.Io.Writer, value: u32) std.Io.Writer.Error!void {
    try writer.print("{d} ", .{value});
}
