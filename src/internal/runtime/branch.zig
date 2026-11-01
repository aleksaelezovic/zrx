const std = @import("std");
const streams = @import("streams.zig");
const outcomes = @import("../outcomes.zig");
const seq = @import("../../data/sequences.zig");
const branching = @import("../branch.zig");
const receipts = @import("../error_receipt.zig");

/// One run-owned dispatcher. Outlets are owned by ordinary run nodes, and are
/// installed before activation. No payload or producer is copied per case.
pub fn Router(comptime Item: type, comptime Cases: type) type {
    const count = @typeInfo(Cases).@"struct".field_types.len;
    const Fields = @typeInfo(Cases).@"struct".field_types;
    const terminal = branching.Terminates(Item, Cases);
    const Pending = if (terminal) Item else seq.Item(Fields[0].Pipeline);
    const Outlets = block: {
        var types: [count]type = undefined;
        for (Fields, 0..) |C, i| types[i] = ?*streams.Stream(C.Input);
        break :block @Tuple(&types);
    };
    return struct {
        const Self = @This();
        pub fn CaseItem(comptime index: usize) type {
            return Fields[index].Input;
        }
        io: std.Io,
        input: *streams.Stream(Item).Reader,
        cases: Cases,
        outlets: Outlets = empty(),
        pending: ?*streams.Stream(Pending) = null,
        active: [count]bool = @splat(false),
        waiting_case: ?usize = null,
        mutex: std.Io.Mutex = .init,
        join_mutex: std.Io.Mutex = .init,
        task: ?std.Io.Future(anyerror!void) = null,
        attempted: bool = false,
        stopped: bool = false,
        start_error: ?anyerror = null,
        done: std.Io.Event = .unset,
        failure: ?anyerror = null,
        receipt: receipts.Receipt,

        fn empty() Outlets {
            var result: Outlets = undefined;
            inline for (0..count) |i| result[i] = null;
            return result;
        }
        pub fn outlet(self: *Self, allocator: std.mem.Allocator, comptime index: usize) !streams.Stream(CaseItem(index)) {
            const Producer = struct {
                fn produce(router: *Self, _: *streams.Stream(CaseItem(index))) !void {
                    defer router.retire(index);
                    try router.start();
                    try router.done.wait(router.io);
                    if (router.failure) |err| return err;
                }
            };
            return streams.Stream(CaseItem(index)).initProducer(allocator, self.io, 1, Producer.produce, self);
        }

        pub fn pendingOutlet(self: *Self, allocator: std.mem.Allocator) !streams.Stream(Pending) {
            const Producer = struct {
                fn produce(router: *Self, _: *streams.Stream(Pending)) !void {
                    try router.start();
                    try router.done.wait(router.io);
                    if (router.failure) |err| return err;
                }
            };
            return streams.Stream(Pending).initProducer(allocator, self.io, 1, Producer.produce, self);
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
            inline for (self.outlets) |outlet_| if (outlet_) |output| output.close();
            if (self.pending) |output| output.close();
            self.done.set(self.io);
            return result;
        }

        fn route(self: *Self) !void {
            var cursor = self.input.iterator();
            while (true) {
                try self.io.checkCancel();
                const item = (try cursor.nextOutcome()) orelse return;
                var selected = false;
                inline for (Fields, 0..) |C, i| {
                    const matches = switch (item) {
                        .failure => |err| if (comptime C.is_error) outcomes.matches(C.ErrorSet, err) else false,
                        .value => |value| if (comptime C.is_error) false else C.is_default or self.cases[i].matches(value),
                    };
                    if (matches) {
                        selected = true;
                        self.mutex.lockUncancelable(self.io);
                        const active = self.active[i];
                        const token = if (comptime C.is_error) block: {
                            if (!active) break :block null;
                            self.waiting_case = i;
                            break :block @as(?receipts.Token, self.receipt.begin());
                        } else null;
                        self.mutex.unlock(self.io);
                        if (!active and item == .failure) {
                            try self.unhandled(item.failure);
                            break;
                        }
                        if (active) {
                            const value: C.Input = if (comptime C.is_error)
                                .{ .err = @errorCast(item.failure), ._receipt = token }
                            else
                                item.value;
                            self.outlets[i].?.push(value) catch |err| {
                                if (err != error.Closed) return err;
                                if (item == .failure) {
                                    try self.unhandled(item.failure);
                                    break;
                                }
                            };
                            if (comptime C.is_error) {
                                const handled = try self.receipt.wait();
                                self.mutex.lockUncancelable(self.io);
                                self.waiting_case = null;
                                self.mutex.unlock(self.io);
                                if (!handled) try self.unhandled(item.failure);
                            }
                        }
                        break;
                    }
                }
                if (!selected and item == .failure) try self.unhandled(item.failure);
            }
        }

        fn unhandled(self: *Self, err: anyerror) !void {
            if (terminal) return err;
            if (self.pending) |output| {
                output.pushOutcome(.{ .failure = err }) catch |control| {
                    if (control == error.Closed) return err;
                    return control;
                };
            } else return err;
        }

        pub fn retire(self: *Self, index: usize) void {
            self.mutex.lockUncancelable(self.io);
            self.active[index] = false;
            if (self.waiting_case == index) self.receipt.retire();
            var any = false;
            for (self.active) |active| any = any or active;
            self.mutex.unlock(self.io);
            if (!any) self.input.close();
        }

        pub fn stop(self: *Self) void {
            self.mutex.lockUncancelable(self.io);
            self.stopped = true;
            self.mutex.unlock(self.io);
            inline for (self.outlets) |outlet_| if (outlet_) |output| output.close();
            if (self.pending) |output| output.close();
            self.input.close();
            self.join_mutex.lockUncancelable(self.io);
            defer self.join_mutex.unlock(self.io);
            if (self.task) |*task| task.cancel(self.io) catch {};
        }
    };
}
