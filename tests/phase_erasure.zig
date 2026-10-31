//! Native LLVM inspection fixture. No equality rule added to the codegen catalog.
const std = @import("std");
const api = @import("api");
const zrx = api.current;
const Empty = struct {
    pub fn mark(_: @This(), comptime _: api.Phase) void {}
};
const Input = struct { count: usize };
fn transform(value: u64) u64 {
    return value *% 3 +% 1;
}
fn accept(total: *u64, value: u64) void {
    total.* +%= value;
}
fn produce(input: Input, output: *zrx.Emitter(u64)) !void {
    for (0..input.count) |i| try output.push(@intCast(i));
}
const Iterator = struct {
    count: usize,
    index: usize = 0,
    pub fn next(self: *@This()) ?u64 {
        if (self.index == self.count) return null;
        defer self.index += 1;
        return @intCast(self.index);
    }
};
fn execute(comptime graph: bool, comptime observed: bool, io: std.Io, count: usize, total: *u64) bool {
    var cursor: Iterator = .{ .count = count };
    const source = if (graph) zrx.Stream(u64).fromProducer(16, produce) else zrx.fromIterator(&cursor);
    const flow = zrx.pipe(source, .{ zrx.each(transform), zrx.forEach(accept) });
    const bindings = .{ std.heap.smp_allocator, io, Input{ .count = count }, total };
    if (observed) api.runObserved(bindings, .{flow}, Empty{}) catch return false else zrx.run(bindings, .{flow}) catch return false;
    return true;
}
pub export fn finite_default(io: *const std.Io, count: usize, total: *u64) bool {
    return execute(false, false, io.*, count, total);
}
pub export fn finite_empty(io: *const std.Io, count: usize, total: *u64) bool {
    return execute(false, true, io.*, count, total);
}
pub export fn graph_default(io: *const std.Io, count: usize, total: *u64) bool {
    return execute(true, false, io.*, count, total);
}
pub export fn graph_empty(io: *const std.Io, count: usize, total: *u64) bool {
    return execute(true, true, io.*, count, total);
}
