//! Runtime inputs instantiate recovery, selective error lanes and explicit sinks.
const std = @import("std");
const zrx = @import("zrx");
const E = error{Bad};
const Service = struct { replacement: u64 };
fn transform(value: u32) E!u64 {
    return if (value == 0) error.Bad else @as(u64, value) * 2;
}
fn replace(service: Service, _: E) u64 {
    return service.replacement;
}
fn report(service: Service, _: zrx.Failure(E)) u64 {
    return service.replacement;
}
fn save(output: *u64, value: u64) void {
    output.* +%= value;
}
export fn recover_items(a: *const std.mem.Allocator, io: *const std.Io, items: [*]const u32, len: usize, replacement: u64, output: *u64) bool {
    zrx.run(.{ a.*, io.*, Service{ .replacement = replacement }, output }, .{
        zrx.pipe(zrx.fromSlice(items[0..len]), .{ zrx.map(transform), zrx.recover(replace), zrx.forEach(save) }),
    }) catch return false;
    return true;
}
export fn route_errors(a: *const std.mem.Allocator, io: *const std.Io, items: [*]const u32, len: usize, replacement: u64, output: *u64) bool {
    zrx.run(.{ a.*, io.*, Service{ .replacement = replacement }, output }, .{
        zrx.pipe(zrx.fromSlice(items[0..len]), .{ zrx.map(transform), zrx.branch(.{
            zrx.whenError(E, zrx.map(report)),
            zrx.otherwise(zrx.map(struct {
                fn same(value: u64) u64 {
                    return value;
                }
            }.same)),
        }), zrx.forEach(save) }),
    }) catch return false;
    return true;
}
