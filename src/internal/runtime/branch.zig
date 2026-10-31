const std = @import("std");
const streams = @import("streams.zig");

/// One run-owned dispatcher. Outlets are owned by ordinary run nodes, and are
/// installed before activation. No payload or producer is copied per case.
pub fn Router(comptime Item: type, comptime Cases: type) type {
    const count = @typeInfo(Cases).@"struct".field_types.len;
    return struct {
        const Self = @This();
        io: std.Io,
        input: *streams.Stream(Item).Reader,
        cases: Cases,
        outlets: [count]?*streams.Stream(Item) = @splat(null),
        active: [count]bool = @splat(false),
        mutex: std.Io.Mutex = .init,
        join_mutex: std.Io.Mutex = .init,
        task: ?std.Io.Future(anyerror!void) = null,
        attempted: bool = false,
        stopped: bool = false,
        start_error: ?anyerror = null,
        done: std.Io.Event = .unset,
        failure: ?anyerror = null,

        pub fn outlet(self: *Self, allocator: std.mem.Allocator, comptime index: usize) !streams.Stream(Item) {
            const Producer = struct {
                fn produce(router: *Self, _: *streams.Stream(Item)) !void {
                    defer router.retire(index);
                    try router.start();
                    try router.done.wait(router.io);
                    if (router.failure) |err| return err;
                }
            };
            return streams.Stream(Item).fromProducerWith(allocator, self.io, 1, Producer.produce, self);
        }

        fn start(self: *Self) !void {
            try self.mutex.lock(self.io);
            defer self.mutex.unlock(self.io);
            if (self.start_error) |err| return err;
            if (self.stopped) return error.Canceled;
            if (self.attempted) return;
            self.attempted = true;
            self.task = self.io.concurrent(work, .{self}) catch |err| {
                self.start_error = err;
                return err;
            };
        }

        fn work(self: *Self) anyerror!void {
            const result = self.route();
            if (result) |_| {} else |err| self.failure = err;
            for (self.outlets) |outlet_| if (outlet_) |output| output.close();
            self.done.set(self.io);
            return result;
        }

        fn route(self: *Self) !void {
            var cursor = self.input.iterator();
            while (true) {
                try self.io.checkCancel();
                const value = (try cursor.next()) orelse return;
                inline for (@typeInfo(Cases).@"struct".field_types, 0..) |C, i| {
                    if (C.is_default or if (@hasDecl(C, "bound_case")) self.cases[i].matches(value) else C.condition(value)) {
                        self.mutex.lockUncancelable(self.io);
                        const active = self.active[i];
                        self.mutex.unlock(self.io);
                        if (active) self.outlets[i].?.push(value) catch |err| {
                            if (err != error.Closed) return err;
                        };
                        break;
                    }
                }
            }
        }

        pub fn retire(self: *Self, index: usize) void {
            self.mutex.lockUncancelable(self.io);
            self.active[index] = false;
            var any = false;
            for (self.active) |active| any = any or active;
            self.mutex.unlock(self.io);
            if (!any) self.input.close();
        }

        pub fn stop(self: *Self) void {
            self.mutex.lockUncancelable(self.io);
            self.stopped = true;
            self.mutex.unlock(self.io);
            for (self.outlets) |outlet_| if (outlet_) |output| output.close();
            self.input.close();
            self.join_mutex.lockUncancelable(self.io);
            defer self.join_mutex.unlock(self.io);
            if (self.task) |*task| task.cancel(self.io) catch {};
        }
    };
}
