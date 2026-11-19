const std = @import("std");
const zrx = @import("zrx");
const program = zrx.program;
const range = zrx.range;
const map = zrx.map;
const forEach = zrx.forEach;
const resource = zrx.resource;
const using = zrx.using;

const Handle = struct { id: u32 };

fn open(id: u32) Handle {
    return .{ .id = id };
}
fn close(_: Handle) void {}
fn plus(handle: Handle, value: u32) u32 {
    return value + handle.id;
}
fn ignore(_: u32) void {}

// The value is released when the push of the item returns: no task can keep it.
test {
    try program(range(u32, 0, 3), .{ using(resource(open, close), .{ zrx.queue(2), map(plus) }), forEach(ignore) }).run(.{std.testing.io});
}
