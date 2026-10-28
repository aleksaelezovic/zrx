const std = @import("std");
const zrx = @import("zrx");
const pipe = zrx.pipe;
const tryPipe = zrx.tryPipe;
const map = zrx.map;
const tap = zrx.tap;
const tapWith = zrx.tapWith;

fn positive(value: u32) error{Zero}!u32 {
    return if (value == 0) error.Zero else value;
}

fn double(value: u32) u32 {
    return value * 2;
}

fn record(destination: *u32, value: u32) void {
    destination.* = value;
}

fn validate(value: u32) error{TooLarge}!void {
    if (value > 100) return error.TooLarge;
}

fn write(writer: *std.Io.Writer, value: u32) std.Io.Writer.Error!void {
    try writer.print("{d}", .{value});
}

pub fn main() !void {
    var recorded: u32 = 0;
    var buffer: [16]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    const result = try tryPipe(3, .{
        map(.{ positive, double }),
        tap(validate),
        tapWith(&recorded, record),
        tapWith(&writer, write),
    });
    if (result != 6 or recorded != 6 or !std.mem.eql(u8, writer.buffered(), "6")) {
        return error.UnexpectedResult;
    }

    // Ordinary pipe deliberately returns the error value rather than handling it.
    const checked = pipe(101, .{tap(validate)});
    if (checked) |_| return error.ExpectedFailure else |err| {
        if (err != error.TooLarge) return err;
    }
}
