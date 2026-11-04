//! Private HTTP delivery schedules. No sockets, sleeps, timing guesses or
//! production hooks: force shutdown while a synchronous forwarder still runs.
const std = @import("std");
const runtime = @import("runtime");
const allocator = std.testing.allocator;
const io = std.testing.io;
const Stream = runtime.Stream(u32);

fn requestState() runtime.HttpRuntime {
    return .{
        .allocator = allocator,
        .io = io,
        .config = .{ .address = .{ .ip4 = .loopback(0) } },
        .generation = 1,
        .pending = true,
        .deliveries = 1,
    };
}

test "late synchronous forwarding after HTTP interruption cannot revive retired credit" {
    const Input = struct {
        pub const sequence_tag = Stream.sequence_tag;
        pub const Item = u32;
        server: *runtime.HttpRuntime,
        pub const Iterator = struct {
            server: *runtime.HttpRuntime,
            done: bool = false,
            pub fn next(self: *@This()) ?u32 {
                if (self.done) return null;
                self.done = true;
                const owner = self.server.completionOwner();
                const held = owner.peek();
                owner.abort();
                held.release();
                // Mirrors a callback returning after shutdown retired its input.
                // This producer itself has not been canceled: checkCancel alone
                // cannot detect that its request's admission has closed.
                return 7;
            }
        };
        pub fn iterator(self: @This()) Iterator {
            return .{ .server = self.server };
        }
    };
    var server = requestState();
    var output = try runtime.share(allocator, io, 1, Input{ .server = &server });
    defer output.deinit();
    output.setCompletion(server.completionOwner());
    var cursor = output.iterator();
    try std.testing.expectError(error.Canceled, cursor.nextOutcome());
    try std.testing.expectEqual(@as(usize, 0), server.deliveries);
    try std.testing.expect(server.done.isSet());
}

test "HTTP interruption closes value and error admission before or after request retirement" {
    for ([_]bool{ true, false }) |pending| {
        for ([_]bool{ false, true }) |failure| {
            var server = requestState();
            var output = try Stream.init(allocator, io, 1);
            defer output.deinit();
            const owner = server.completionOwner();
            output.setCompletion(owner);
            const held = owner.peek();
            owner.abort();
            held.release();
            server.pending = pending;
            const result = if (failure)
                output.pushOutcome(.{ .failure = error.OperationFailed })
            else
                output.push(7);
            try std.testing.expectError(error.Canceled, result);
            try std.testing.expectEqual(@as(usize, 0), server.deliveries);
            output.close();
            var cursor = output.iterator();
            try std.testing.expect((try cursor.nextOutcome()) == null);
        }
    }
}

test "admitted HTTP values retain their credit until delivery completes" {
    var server = requestState();
    var output = try Stream.init(allocator, io, 1);
    defer output.deinit();
    const held = server.completionOwner().peek();
    output.setCompletion(server.completionOwner());
    try output.push(7);
    try std.testing.expectEqual(@as(usize, 2), server.deliveries);
    held.release();
    output.close();
    var cursor = output.iterator();
    try std.testing.expectEqual(@as(?u32, 7), try cursor.next());
    try std.testing.expectEqual(@as(usize, 1), server.deliveries);
    try std.testing.expect(!server.done.isSet());
    try std.testing.expectEqual(@as(?u32, null), try cursor.next());
    try std.testing.expectEqual(@as(usize, 0), server.deliveries);
    try std.testing.expect(server.done.isSet());
}

test "interruption rejects new HTTP credit but outstanding delivery can still finish" {
    var server = requestState();
    var output = try Stream.init(allocator, io, 1);
    defer output.deinit();
    const owner = server.completionOwner();
    output.setCompletion(owner);
    const held = owner.peek();
    try output.push(7);
    owner.abort();
    owner.abort(); // Idempotent interruption cannot consume existing credits.
    try std.testing.expectError(error.Canceled, owner.acquire());
    try std.testing.expectError(error.Canceled, output.push(8));
    try std.testing.expectEqual(@as(usize, 2), server.deliveries);
    held.release();
    output.close();
    var cursor = output.iterator();
    try std.testing.expectEqual(@as(?u32, 7), try cursor.next());
    try std.testing.expect(!server.done.isSet());
    try std.testing.expectEqual(@as(?u32, null), try cursor.next());
    try std.testing.expectEqual(@as(usize, 0), server.deliveries);
    try std.testing.expect(server.done.isSet());
}

test "HTTP interruption between credit reservation and failed publication returns the reserved credit" {
    const Context = struct {
        server: *runtime.HttpRuntime,
        output: *Stream,
        fn acquire(raw: *anyopaque) std.Io.Cancelable!runtime.HttpCompletion.Token {
            const self: *@This() = @ptrCast(@alignCast(raw));
            const token = try self.server.completionOwner().acquire();
            self.server.completionOwner().abort();
            self.output.close();
            return token;
        }
        fn peek(raw: *anyopaque) runtime.HttpCompletion.Token {
            const self: *@This() = @ptrCast(@alignCast(raw));
            return self.server.completionOwner().peek();
        }
        fn abort(raw: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.server.completionOwner().abort();
        }
    };
    var server = requestState();
    var output = try Stream.init(allocator, io, 1);
    defer output.deinit();
    var context: Context = .{ .server = &server, .output = &output };
    output.setCompletion(.{ .context = &context, .acquire_fn = Context.acquire, .peek_fn = Context.peek, .abort_fn = Context.abort });
    const held = server.completionOwner().peek();
    try std.testing.expectError(error.Closed, output.push(7));
    try std.testing.expectEqual(@as(usize, 1), server.deliveries);
    try std.testing.expect(!server.done.isSet());
    held.release();
    try std.testing.expectEqual(@as(usize, 0), server.deliveries);
    try std.testing.expect(server.done.isSet());
    var cursor = output.iterator();
    try std.testing.expect((try cursor.nextOutcome()) == null);
}
