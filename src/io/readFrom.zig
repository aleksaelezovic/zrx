const std = @import("std");
const sequences = @import("../data/sequences.zig");
const queueNext = @import("../internal/queue.zig").next;

/// Declare a borrowed mutable std.Io.Queue(T). Waiting uses run-supplied Io;
/// construction never captures Io or starts traversal. Keep the queue alive
/// until run's users have joined.
/// Empty open input waits; closed-and-drained input ends normally; cancellation
/// is an outer cursor error. Optional/error-valued items remain data.
///
/// Copies compete for the same input, never broadcast or rewind. Reference one
/// stable adapter by pointer for run-owned sharing. No new queue storage is
/// allocated here; the standard queue retains its borrowed fixed-capacity buffer.
pub fn readFrom(source: anytype) Queue(@TypeOf(source)) {
    return .{ .queue = source };
}

fn Queue(comptime Pointer: type) type {
    const T = QueueItem(Pointer);
    return struct {
        pub const graph_tag = sequences.GraphTag;
        pub const sequence_tag = sequences.SequenceTag;
        pub const node_kind = .queue;
        pub const Item = T;
        pub const Requirements: [0]type = .{};
        queue: Pointer,
    };
}

// Bind the bootstrap Io only during run preparation.
pub fn bind(source: anytype, io: std.Io) sequences.PullView(QueueCursor(@TypeOf(source).Item)) {
    return .{ .input = .{ .io = io, .queue = source.queue } };
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
