//! Current public API, runtime inputs. Object coverage, not foreign execution or
//! a direct/grouped/separate codegen equality claim.
const std = @import("std");
const zrx = @import("zrx");
const Factor = struct { value: u32 };
fn acquire(value: u32) Factor {
    return .{ .value = value };
}
fn serviceValue(factor: Factor) u64 {
    return factor.value;
}
export fn declarative_service(gpa: *const std.mem.Allocator, io: *const std.Io, factor: u32, output: *u64) bool {
    const flow = zrx.pipe(zrx.fromService(Factor), .{ zrx.map(serviceValue), zrx.forEach(save) });
    zrx.run(.{ gpa.*, io.*, zrx.resource(factor, acquire, null), output }, .{flow}) catch return false;
    return true;
}
fn scale(factor: Factor, value: u32) u64 {
    return @as(u64, value) * factor.value;
}
fn sum(state: u64, value: u64) u64 {
    return state +% value;
}
fn save(output: *u64, value: u64) void {
    output.* = value;
}
export fn declarative_finite(gpa: *const std.mem.Allocator, io: *const std.Io, input: [*]const u32, len: usize, factor: u32, output: *u64) bool {
    const flow = zrx.pipe(zrx.fromSlice(input[0..len]), .{
        zrx.map(scale),
        zrx.fold(@as(u64, 0), sum),
        zrx.forEach(save),
    });
    zrx.run(.{ gpa.*, io.*, zrx.resource(factor, acquire, null), output }, .{flow}) catch return false;
    return true;
}
const Span = struct { values: []const u32 };
fn expand(span: Span) @TypeOf(zrx.fromSlice(@as([]const u32, undefined))) {
    return zrx.fromSlice(span.values);
}
export fn declarative_flat_map(gpa: *const std.mem.Allocator, io: *const std.Io, input: [*]const u32, len: usize, factor: u32, output: *u64) bool {
    const flow = zrx.pipe(zrx.fromValue(Span{ .values = input[0..len] }), .{
        zrx.flatMap(expand),
        zrx.map(scale),
        zrx.fold(@as(u64, 0), sum),
        zrx.forEach(save),
    });
    zrx.run(.{ gpa.*, io.*, Factor{ .value = factor }, output }, .{flow}) catch return false;
    return true;
}
fn produce(output: *zrx.Emitter(u32)) !void {
    try output.push(1);
    try output.push(2);
}
export fn declarative_producer(gpa: *const std.mem.Allocator, io: *const std.Io, output: *u64) bool {
    const source = zrx.Stream(u32).fromProducer(1, produce);
    const flow = zrx.pipe(&source, .{ zrx.map(scale), zrx.fold(@as(u64, 0), sum), zrx.forEach(save) });
    zrx.run(.{ gpa.*, io.*, Factor{ .value = 2 }, output }, .{flow}) catch return false;
    return true;
}
fn identity(value: u32) u32 {
    return value;
}
fn saveCurrent(output: *u32, value: u32) void {
    output.* = value;
}
export fn declarative_signal(gpa: *const std.mem.Allocator, io: *const std.Io, input: [*]const u32, len: usize, output: *u32) bool {
    const updates = zrx.fromSlice(input[0..len]);
    const state = zrx.pipe(&updates, .{ zrx.hold(@as(u32, 0)), zrx.map(identity) });
    const flow = zrx.pipe(zrx.values(&state), .{zrx.forEach(saveCurrent)});
    zrx.run(.{ gpa.*, io.*, output }, .{flow}) catch return false;
    return true;
}

fn wordSize(value: zrx.Chunk(u8, 80)) u64 {
    return value.len;
}
export fn declarative_words(gpa: *const std.mem.Allocator, io: *const std.Io, input: [*]const u8, len: usize, output: *u64) bool {
    const flow = zrx.pipe(zrx.fromValue(input[0..len]), .{
        zrx.splitBy(std.ascii.isWhitespace, .{ .max_items = 80, .empty = .skip }),
        zrx.map(wordSize),
        zrx.fold(@as(u64, 0), sum),
        zrx.forEach(save),
    });
    zrx.run(.{ gpa.*, io.*, output }, .{flow}) catch return false;
    return true;
}

fn adjacent(value: u32) [2]u32 {
    return .{ value, value +% 1 };
}
export fn declarative_flatten(gpa: *const std.mem.Allocator, io: *const std.Io, input: [*]const u32, len: usize, output: *u64) bool {
    const flow = zrx.pipe(zrx.fromSlice(input[0..len]), .{
        zrx.map(adjacent),
        zrx.flatten(),
        zrx.map(scale),
        zrx.fold(@as(u64, 0), sum),
        zrx.forEach(save),
    });
    zrx.run(.{ gpa.*, io.*, Factor{ .value = 1 }, output }, .{flow}) catch return false;
    return true;
}
