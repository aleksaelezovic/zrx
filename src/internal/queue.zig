const std = @import("std");

// Shared by the standard-queue adapter and private rendezvous transport.
// Use the buffer form rather than getOne's E!T: T may itself be a bare error set,
// which is valid item data but cannot be an error union's direct payload.
pub fn next(comptime T: type, io: std.Io, queue: *std.Io.Queue(T)) std.Io.Cancelable!?T {
    var value: [1]T = undefined;
    const count = queue.get(io, &value, 1) catch |err| switch (err) {
        error.Closed => return null,
        error.Canceled => return error.Canceled,
    };
    std.debug.assert(count == 1);
    return @as(?T, value[0]);
}
