//! Forced private schedules. Event/mutex addresses are inspected only by this
//! test-local Io shim; production execution has no scheduling hook.
const std = @import("std");
const runtime = @import("runtime");
const allocator = std.testing.allocator;
const io = std.testing.io;
const Failure = runtime.Failure(error{Bad});

test "retirement seals a receipt before late callback acceptance" {
    var receipt: runtime.ErrorReceipt = .{ .io = io };
    const token = receipt.begin();
    receipt.retire();
    token.acknowledge();
    try std.testing.expect(!try receipt.wait());
}

test "accepted receipts stay handled across retirement and repeated acceptance" {
    var receipt: runtime.ErrorReceipt = .{ .io = io };
    const token = receipt.begin();
    const report: Failure = .{ .err = error.Bad, ._receipt = token };
    const accepted = runtime.acceptFailure(report);
    try std.testing.expectEqual(error.Bad, accepted.err);
    try std.testing.expect(accepted._receipt == null);
    receipt.retire();
    _ = runtime.acceptFailure(report);
    _ = runtime.acceptFailure(accepted);
    try std.testing.expect(try receipt.wait());
}

test "stale copies cannot acknowledge another error generation" {
    var receipt: runtime.ErrorReceipt = .{ .io = io };
    const old = receipt.begin();
    old.acknowledge();
    try std.testing.expect(try receipt.wait());
    const current = receipt.begin();
    old.acknowledge();
    try std.testing.expect(!receipt.ready.isSet());
    current.acknowledge();
    try std.testing.expect(try receipt.wait());
}

test "accepted record copies contain no receipt in retained storage" {
    var receipt: runtime.ErrorReceipt = .{ .io = io };
    const report: Failure = .{ .err = error.Bad, ._receipt = receipt.begin() };
    var stored: std.ArrayList(Failure) = .empty;
    defer stored.deinit(allocator);
    try stored.append(allocator, runtime.acceptFailure(report));
    try std.testing.expect(stored.items[0]._receipt == null);
    try std.testing.expect(try receipt.wait());
}

const ErrorCase = struct {
    pub const Input = Failure;
    pub const Pipeline = @import("runtime").Stream(u32);
    pub const is_error = true;
    pub const is_default = false;
    pub const ErrorSet = error{Bad};
};
const SuccessCase = struct {
    pub const Input = u32;
    pub const Pipeline = @import("runtime").Stream(u32);
    pub const is_error = false;
    pub const is_default = true;
    pub fn matches(_: @This(), _: u32) bool {
        return true;
    }
};
const Cases = @Tuple(&.{ ErrorCase, SuccessCase });
const Router = runtime.ErrorRouter(u32, Cases);
const Stream = runtime.Stream(u32);

const WaitProbe = struct {
    word: *const u32,
    blocked: std.Io.Event = .unset,
};
const Hooks = struct {
    // Preserve the real backend userdata. The sequential fixture owns this
    // pointer until router and outlet producers have all stopped/joined.
    var current: *WaitProbe = undefined;
    fn wait(userdata: ?*anyopaque, word: *const u32, expected: u32, timeout: std.Io.Timeout) std.Io.Cancelable!void {
        if (word == current.word) current.blocked.set(io);
        return io.vtable.futexWait(userdata, word, expected, timeout);
    }
};
fn wait(event: *std.Io.Event) !void {
    try event.waitTimeout(io, .{ .duration = .{ .raw = .fromSeconds(10), .clock = .awake } });
}

const Schedule = enum { retire_first, accept_first, unrelated_retirement, cancel };
fn routerSchedule(schedule: Schedule) !void {
    var table = io.vtable.*;
    table.futexWait = Hooks.wait;
    const observed: std.Io = .{ .userdata = io.userdata, .vtable = &table };
    var input = try Stream.init(allocator, observed, 2);
    defer input.deinit();
    try input.pushOutcome(.{ .failure = error.Bad });
    input.close();
    var input_edges = try runtime.tee(&input);
    defer input_edges.deinit();
    input_edges.right.close();
    var router: Router = .{
        .io = observed,
        .input = &input_edges.left,
        .cases = .{ .{}, .{} },
        .receipt = .{ .io = observed },
    };
    var probe: WaitProbe = .{ .word = @ptrCast(&router.receipt.ready) };
    Hooks.current = &probe;
    var errors = try router.outlet(allocator, 0);
    defer errors.deinit();
    var error_edges = try runtime.tee(&errors);
    defer error_edges.deinit();
    error_edges.right.close();
    var pending = try router.pendingOutlet(allocator);
    defer pending.deinit();
    var pending_edges = try runtime.tee(&pending);
    defer pending_edges.deinit();
    pending_edges.right.close();
    router.outlets[0] = &errors;
    router.pending = &pending;
    router.active = .{ true, true };
    // Stop/join every user before destroying any router-owned referent, including
    // on assertion/timeout failure. A fake success lane has no published items.
    defer {
        router.stop();
        runtime.stopProducer(&errors);
        runtime.stopProducer(&pending);
    }
    var error_cursor = error_edges.left.iterator();
    const queued = (try error_cursor.next()).?;
    try wait(&probe.blocked); // The router is waiting for this exact receipt.
    try std.testing.expect(!router.receipt.ready.isSet());
    try std.testing.expect(queued._receipt != null);
    switch (schedule) {
        .retire_first => {
            router.retire(0);
            // Force even a late/in-flight callback to attempt acceptance before
            // selecting the original error from the pending outlet.
            _ = runtime.acceptFailure(queued);
        },
        .accept_first => {
            _ = runtime.acceptFailure(queued);
            router.retire(0);
        },
        .unrelated_retirement => {
            router.retire(1);
            try std.testing.expect(!router.receipt.ready.isSet());
            _ = runtime.acceptFailure(queued);
        },
        .cancel => router.stop(),
    }
    var pending_cursor = pending_edges.left.iterator();
    if (schedule == .cancel) {
        try std.testing.expectEqual(error.Canceled, router.failure.?);
        // Stop closed this cold outlet without starting its producer. Cancellation
        // is the dispatcher's outer result, never a pending outcome item.
        try std.testing.expect((try pending_cursor.nextOutcome()) == null);
    } else if (schedule == .retire_first) {
        const item = try pending_cursor.nextOutcome();
        try std.testing.expect(item != null);
        try std.testing.expect(item.? == .failure);
        try std.testing.expectEqual(error.Bad, item.?.failure);
        try std.testing.expectEqual(@as(?u32, null), try pending_cursor.next());
    } else {
        try std.testing.expectEqual(@as(?u32, null), try pending_cursor.next());
    }
}

test "queued error retirement preserves the original error despite late acceptance" {
    try routerSchedule(.retire_first);
}
test "callback acceptance wins before lane retirement" {
    try routerSchedule(.accept_first);
}
test "retiring another lane cannot wake the outstanding error receipt" {
    try routerSchedule(.unrelated_retirement);
}
test "canceling a dispatcher blocked on error acceptance stays control flow" {
    try routerSchedule(.cancel);
}
