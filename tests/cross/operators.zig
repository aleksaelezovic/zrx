//! Runtime-input instantiation of bounds, retention and batching on the public API.
const std = @import("std");
const zrx = @import("zrx");
const Output = struct { total: *u64 };
fn save(output: Output, items: []const u32) void {
    for (items) |item| output.total.* +%= item;
}
export fn bounded_suffix(a: *const std.mem.Allocator, io: *const std.Io, input: [*]const u32, len: usize, limit: usize, output: *u64) bool {
    const flow = zrx.pipe(zrx.fromSlice(input[0..len]), .{
        zrx.take(limit), zrx.maxItems(limit), zrx.takeLast(limit), zrx.batchThen(2, save),
    });
    zrx.run(.{ a.*, io.*, Output{ .total = output } }, .{flow}) catch return false;
    return true;
}

fn saveItem(output: Output, item: u32) void {
    output.total.* +%= item;
}
export fn queue_prefix(a: *const std.mem.Allocator, io: *const std.Io, queue: *std.Io.Queue(u32), limit: usize, output: *u64) bool {
    const flow = zrx.pipe(zrx.readFrom(queue), .{ zrx.take(limit), zrx.forEach(saveItem) });
    zrx.run(.{ a.*, io.*, Output{ .total = output } }, .{flow}) catch return false;
    return true;
}

const Vector = @Vector(4, u32);
fn double(value: Vector) Vector {
    return value *% @as(Vector, @splat(2));
}
fn saveVector(output: *[4]u32, value: Vector) void {
    output.* = value;
}
export fn vector_item(a: *const std.mem.Allocator, io: *const std.Io, input: *const [4]u32, output: *[4]u32) bool {
    const value: Vector = input.*;
    const flow = zrx.pipe(zrx.fromValue(value), .{ zrx.map(double), zrx.forEach(saveVector) });
    zrx.run(.{ a.*, io.*, output }, .{flow}) catch return false;
    return true;
}
