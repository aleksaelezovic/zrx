//! One run, separate success/report sinks. No retry boundary is needed to route
//! an ordinary map failure; errors skip success stages until whenError.
const std = @import("std");
const zrx = @import("zrx");
const fromSlice = zrx.fromSlice;
const pipe = zrx.pipe;
const map = zrx.map;
const branch = zrx.branch;
const whenError = zrx.whenError;
const otherwise = zrx.otherwise;
const stdoutLines = zrx.stdoutLines;
const stderrLines = zrx.stderrLines;
const line = zrx.line;
const run = zrx.run;
const Text = zrx.Line(64);
const AppError = error{ Invalid, Unavailable };

fn process(value: u32) AppError!u32 {
    return switch (value) {
        0 => error.Invalid,
        1 => error.Unavailable,
        else => value * 2,
    };
}
fn formatResult(value: u32) Text {
    var bytes: [64]u8 = undefined;
    const text = std.fmt.bufPrint(&bytes, "result: {d}", .{value}) catch unreachable;
    return line(64, text) catch unreachable;
}
fn formatFailure(failure: zrx.Failure(AppError)) Text {
    var bytes: [64]u8 = undefined;
    const text = std.fmt.bufPrint(&bytes, "error: {s}", .{@errorName(failure.err)}) catch unreachable;
    return line(64, text) catch unreachable;
}

pub fn program(source: anytype, success: anytype, errors: anytype) @TypeOf(pipe(source, .{
    map(process), map(formatResult),
    branch(.{
        whenError(AppError, .{ map(formatFailure), errors }),
        otherwise(success),
    }),
})) {
    return pipe(source, .{
        map(process), map(formatResult),
        branch(.{
            whenError(AppError, .{ map(formatFailure), errors }),
            otherwise(success),
        }),
    });
}

pub fn main(init: std.process.Init) !void {
    const input = [_]u32{ 2, 0, 1, 3 };
    try run(.{ init.gpa, init.io }, .{
        program(fromSlice(&input), stdoutLines(), stderrLines()),
    });
}
