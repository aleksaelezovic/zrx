const std = @import("std");
const sequences = @import("../data/sequences.zig");
const queueNext = @import("../internal/queue.zig").next;

/// Borrow a mutable std.Io.Queue(T) with explicit waiting capability. The queue
/// and captured Io must outlive traversal and be compatible with run's Io.
/// Empty open input waits; closed-and-drained input ends normally; cancellation
/// is an outer cursor error. Optional/error-valued items remain data.
///
/// Copies compete for the same input, never broadcast or rewind. Reference one
/// stable adapter by pointer for run-owned sharing. No new queue storage is
/// allocated here; the standard queue retains its borrowed fixed-capacity buffer.
pub fn readFrom(io: std.Io, source: anytype) sequences.PullView(QueueCursor(QueueItem(@TypeOf(source)))) {
    return .{ .input = .{ .io = io, .queue = source } };
}

fn QueueItem(comptime Pointer: type) type {
    const contract = "readFrom: expected a mutable pointer to std.Io.Queue(T); declare stream flows directly";
    if (@typeInfo(Pointer) != .pointer or @typeInfo(Pointer).pointer.size != .one or
        @typeInfo(Pointer).pointer.attrs.@"const")
        @compileError(contract);
    const Source = @typeInfo(Pointer).pointer.child;
    if (@typeInfo(Source) != .@"struct") @compileError(contract);
    if (!@hasDecl(Source, "putOne")) @compileError(contract);
    const info = switch (@typeInfo(@TypeOf(Source.putOne))) {
        .@"fn" => |info| info,
        else => @compileError(contract),
    };
    if (info.param_types.len != 3 or info.param_types[2] == null) @compileError(contract);
    const T = info.param_types[2].?;
    if (Source != std.Io.Queue(T)) @compileError(contract);
    if (@sizeOf(T) == 0) @compileError("readFrom: zero-sized queue elements are not supported");
    return T;
}

fn QueueCursor(comptime T: type) type {
    return struct {
        io: std.Io,
        queue: *std.Io.Queue(T),

        pub fn next(self: *@This()) std.Io.Cancelable!?T {
            return queueNext(T, self.io, self.queue);
        }
    };
}
