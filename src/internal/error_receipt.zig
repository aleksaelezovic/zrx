//! One outstanding error-lane admission per router. Queue admission is not
//! handling: acknowledge at a callback or terminal acceptance, not on enqueue.
const std = @import("std");
pub const FailureTag = opaque {};

pub fn isFailure(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "failure_record") and T.failure_record == FailureTag;
}

pub const Receipt = struct {
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    ready: std.Io.Event = .unset,
    generation: usize = 0,
    decision: enum { pending, accepted, retired } = .pending,

    pub fn begin(self: *@This()) Token {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.generation += 1;
        self.decision = .pending;
        self.ready.reset();
        return .{ .receipt = self, .generation = self.generation };
    }
    /// Seal an unaccepted delivery before waking its waiter. A late callback
    /// must not turn an already-retired error into a handled one.
    pub fn retire(self: *@This()) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.decision == .pending) self.decision = .retired;
        self.ready.set(self.io);
    }
    pub fn wait(self: *@This()) std.Io.Cancelable!bool {
        try self.ready.wait(self.io);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.decision == .accepted;
    }
};
pub const Token = struct {
    receipt: *Receipt,
    generation: usize,
    pub fn acknowledge(self: @This()) void {
        const receipt = self.receipt;
        receipt.mutex.lockUncancelable(receipt.io);
        defer receipt.mutex.unlock(receipt.io);
        if (receipt.generation == self.generation and receipt.decision == .pending) {
            receipt.decision = .accepted;
            receipt.ready.set(receipt.io);
        }
    }
};

/// Remove the internal delivery receipt before invoking user code or retaining
/// terminal data. Payload err remains an ordinary value with no lease.
pub fn accept(value: anytype) @TypeOf(value) {
    const T = @TypeOf(value);
    if (comptime isFailure(T)) {
        var result = value;
        if (result._receipt) |token| token.acknowledge();
        result._receipt = null;
        return result;
    }
    return value;
}
