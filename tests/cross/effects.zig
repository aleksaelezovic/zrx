const std = @import("std");
const zrx = @import("zrx");
const pipe = zrx.pipe;
const tryPipe = zrx.tryPipe;
const map = zrx.map;
const tap = zrx.tap;
const tapWith = zrx.tapWith;

fn checked(value: u32) error{Zero}!u32 {
    return if (value == 0) error.Zero else value;
}

fn double(value: u32) u32 {
    return value *% 2;
}

fn record(destination: *u32, value: u32) void {
    destination.* = value;
}

fn validate(value: u32) error{TooLarge}!void {
    if (value > 100) return error.TooLarge;
}

fn recover(value: error{TooLarge}!u32) u32 {
    return value catch 0;
}

fn write(writer: *std.Io.Writer, value: u32) std.Io.Writer.Error!void {
    try writer.print("{d}", .{value});
}

export fn effect_value_coverage(value: u32) u32 {
    return pipe(value, .{ tap(validate), map(recover) });
}

export fn effect_state_coverage(value: u32, destination: *u32) u32 {
    return tryPipe(value, .{
        map(.{ checked, double }),
        tapWith(destination, record),
        tap(validate),
    }) catch 0;
}

export fn effect_writer_coverage(value: u32, writer: *std.Io.Writer) u32 {
    return tryPipe(value, .{tapWith(writer, write)}) catch 0;
}
