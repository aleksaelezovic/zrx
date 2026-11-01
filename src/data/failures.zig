/// Explicit error-as-data inside a whenError lane. No borrowed input or hidden
/// history is retained. Map this record to a report, or terminate with discard.
pub fn Failure(comptime E: type) type {
    if (@typeInfo(E) != .error_set) @compileError("Failure: expected an error set");
    return struct {
        pub const failure_record = @import("../internal/error_receipt.zig").FailureTag;
        err: E,
        // Private transport lease, stripped before callbacks and terminal storage.
        _receipt: ?@import("../internal/error_receipt.zig").Token = null,
    };
}

pub fn requireHandledBeforeDropping(comptime T: type) void {
    if (@import("../internal/error_receipt.zig").isFailure(T))
        @compileError("error lane: handle Failure records with map/effects or explicit discard before dropping items");
}
