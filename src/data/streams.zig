const std = @import("std");
const runtime = @import("../internal/runtime/streams.zig");

/// Borrowed only for the producer call. Cannot be saved or used after return.
/// Return closes output automatically; this handle has no close/deinit methods.
/// Io/allocator are run-supplied capabilities. Join work using the emitter before
/// returning. push waits for bounded capacity and can return Closed/Canceled.
///
/// Admission does not acknowledge effects or state commits. Items are shallow:
/// referents must outlive all downstream use, including delayed collection.
/// Run does not deep-copy values or infer payload destructors.
pub fn Emitter(comptime T: type) type {
    return struct {
        io: std.Io,
        allocator: std.mem.Allocator,
        context: *anyopaque,

        pub fn push(self: *@This(), value: T) (std.Io.QueueClosedError || std.Io.Cancelable)!void {
            const output: *runtime.Stream(T) = @ptrCast(@alignCast(self.context));
            try output.push(value);
        }
    };
}
