const std = @import("std");
const zrx = @import("zrx");
const program = zrx.program;
const range = zrx.range;
const map = zrx.map;
const forEach = zrx.forEach;
const rescue = zrx.rescue;

fn evenOnly(value: u32) error{Odd}!u32 {
    if (value % 2 == 1) return error.Odd;
    return value;
}
fn ignore(_: anytype) void {}
const failing = program(range(u32, 0, 3), .{ map(evenOnly), forEach(ignore) });
/// A run that cannot fail: its rescue is never called.
const steady = program(range(u32, 0, 3), .{forEach(ignore)});

const Log = struct { lines: u32 };
fn openLog() error{NoDisk}!Log {
    return error.NoDisk;
}
// What a rescue is given for itself has to be there when it is called.
fn note(_: Log, _: anyerror) void {}
test {
    failing.run(.{rescue(note).provide(.{zrx.resource(openLog, null)})});
}
