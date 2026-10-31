// Private positive-capacity storage. Standard queues remain the adapter and
// zero-capacity transport; independent read positions need different retention.
const std = @import("std");
const completion = @import("completion.zig");

pub const BranchError = std.mem.Allocator.Error || std.Io.Cancelable || error{
    UnsupportedCapacity,
    ReaderClosed,
    ReaderMoved,
    Busy,
};

pub fn Buffer(comptime T: type) type {
    return struct {
        const Self = @This();
        pub const Record = struct {
            node: std.DoublyLinkedList.Node = .{},
            position: usize = 0,
            status: enum { active, closed, moved } = .active,
            pending: usize = 0,
            delivery: ?completion.Token = null,
        };

        io: std.Io,
        storage: []T,
        mutex: std.Io.Mutex = .init,
        readable: std.Io.Condition = .init,
        writable: std.Io.Condition = .init,
        readers: std.DoublyLinkedList = .{},
        original: Record = .{},
        allocated_readers: usize = 0,
        active_readers: usize = 1,
        head: usize = 0,
        len: usize = 0,
        closed: bool = false,
        producer_pending: bool = false,
        completion_owner: ?completion.Owner = null,

        // Called once after the containing state reaches its stable address.
        pub fn activate(self: *Self) void {
            self.readers.append(&self.original.node);
        }

        pub fn assertDeinit(self: *Self) void {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            std.debug.assert(self.allocated_readers == 0);
            std.debug.assert(self.original.pending == 0);
        }

        pub fn beginRead(self: *Self, reader: *Record) !void {
            try self.mutex.lock(self.io);
            defer self.mutex.unlock(self.io);
            try check(reader);
            reader.pending += 1;
        }

        pub fn endRead(self: *Self, reader: *Record) void {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            std.debug.assert(reader.pending > 0);
            reader.pending -= 1;
        }

        pub fn push(self: *Self, value: T) (std.Io.Cancelable || error{Closed})!void {
            std.debug.assert(self.storage.len > 0);
            try self.mutex.lock(self.io);
            defer self.mutex.unlock(self.io);
            while (self.len == self.storage.len and !self.closed)
                try self.writable.wait(self.io, &self.mutex);
            if (self.closed) return error.Closed;
            self.storage[self.index(self.len)] = value;
            self.len += 1;
            self.readable.broadcast(self.io);
        }

        pub fn next(self: *Self, reader: *Record) !?T {
            std.debug.assert(self.storage.len > 0);
            try self.mutex.lock(self.io);
            defer self.mutex.unlock(self.io);
            while (true) {
                try check(reader);
                if (reader.position < self.len) {
                    const value = self.storage[self.index(reader.position)];
                    if (self.completion_owner) |owner| reader.delivery = owner.peek();
                    reader.position += 1;
                    self.reclaim();
                    return @as(?T, value);
                }
                if (self.closed and !self.producer_pending) return null;
                try self.readable.wait(self.io, &self.mutex);
            }
        }

        pub fn close(self: *Self) void {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            self.closed = true;
            self.readable.broadcast(self.io);
            self.writable.broadcast(self.io);
        }

        pub fn producerPending(self: *Self, pending: bool) void {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            self.producer_pending = pending;
            if (!pending) self.readable.broadcast(self.io);
        }

        // Before joining the Future, wait cancellably for the callback to finish.
        // A reader close can interrupt this wait without canceling a sibling's producer.
        pub fn awaitProducer(self: *Self, reader: *Record) !void {
            try self.mutex.lock(self.io);
            defer self.mutex.unlock(self.io);
            while (true) {
                try check(reader);
                if (!self.producer_pending) return;
                try self.readable.wait(self.io, &self.mutex);
            }
        }

        pub fn clone(self: *Self, allocator: std.mem.Allocator, original: *Record) BranchError!*Record {
            if (self.storage.len == 0) return error.UnsupportedCapacity;
            const reader = try allocator.create(Record);
            errdefer allocator.destroy(reader);
            try self.mutex.lock(self.io);
            defer self.mutex.unlock(self.io);
            try check(original);
            if (original.pending != 0) return error.Busy;
            reader.* = .{ .position = original.position };
            self.readers.append(&reader.node);
            self.allocated_readers += 1;
            self.active_readers += 1;
            return reader;
        }

        pub fn split(self: *Self, allocator: std.mem.Allocator) BranchError!struct { left: *Record, right: *Record } {
            if (self.storage.len == 0) return error.UnsupportedCapacity;
            const left = try allocator.create(Record);
            errdefer allocator.destroy(left);
            const right = try allocator.create(Record);
            errdefer allocator.destroy(right);
            try self.mutex.lock(self.io);
            defer self.mutex.unlock(self.io);
            try check(&self.original);
            if (self.original.pending != 0) return error.Busy;
            left.* = .{ .position = self.original.position };
            right.* = .{ .position = self.original.position };
            self.original.status = .moved;
            self.readers.remove(&self.original.node);
            self.original.node = .{};
            self.readers.append(&left.node);
            self.readers.append(&right.node);
            self.allocated_readers += 2;
            self.active_readers += 1; // Replace one claim with two, not three.
            return .{ .left = left, .right = right };
        }

        // Logical detach can run while next waits; destruction requires quiescence.
        // Return true only when the last active claim was removed.
        pub fn detach(self: *Self, reader: *Record) bool {
            self.mutex.lockUncancelable(self.io);
            if (reader.status != .active) {
                self.mutex.unlock(self.io);
                return false;
            }
            const delivery = reader.delivery;
            reader.delivery = null;
            const unread = self.len - reader.position;
            const queued = if (self.completion_owner != null and unread != 0) self.completion_owner.?.peek() else null;
            if (queued != null) std.debug.assert(self.active_readers == 1);
            reader.status = .closed;
            self.readers.remove(&reader.node);
            reader.node = .{};
            self.active_readers -= 1;
            self.reclaim();
            if (self.active_readers == 0) self.closed = true;
            self.readable.broadcast(self.io);
            self.writable.broadcast(self.io);
            const last = self.active_readers == 0;
            self.mutex.unlock(self.io);
            if (delivery) |token| token.release();
            if (queued) |token| for (0..unread) |_| token.release();
            return last;
        }

        pub fn finishDelivery(self: *Self, reader: *Record) void {
            // Set once before activation. Ordinary streams have no completion
            // credits and need no additional lock on every read.
            if (self.completion_owner == null) return;
            self.mutex.lockUncancelable(self.io);
            const delivery = reader.delivery;
            reader.delivery = null;
            self.mutex.unlock(self.io);
            if (delivery) |token| token.release();
        }

        pub fn destroy(self: *Self, allocator: std.mem.Allocator, reader: *Record) void {
            self.mutex.lockUncancelable(self.io);
            std.debug.assert(reader.status == .closed);
            std.debug.assert(reader.pending == 0);
            std.debug.assert(self.allocated_readers > 0);
            self.allocated_readers -= 1;
            self.mutex.unlock(self.io);
            allocator.destroy(reader);
        }

        fn check(reader: *Record) error{ ReaderClosed, ReaderMoved }!void {
            return switch (reader.status) {
                .active => {},
                .closed => error.ReaderClosed,
                .moved => error.ReaderMoved,
            };
        }

        // Positions are offsets within the retained window, rebased on reclaim.
        // No ever-growing sequence counter or unchecked head+offset arithmetic.
        fn index(self: *Self, offset: usize) usize {
            const until_end = self.storage.len - self.head;
            return if (offset < until_end) self.head + offset else offset - until_end;
        }

        fn reclaim(self: *Self) void {
            var prefix = self.len;
            var node = self.readers.first;
            while (node) |n| : (node = n.next) {
                const reader: *Record = @alignCast(@fieldParentPtr("node", n));
                prefix = @min(prefix, reader.position);
            }
            if (prefix == 0) return;
            self.head = self.index(prefix);
            self.len -= prefix;
            node = self.readers.first;
            while (node) |n| : (node = n.next) {
                const reader: *Record = @alignCast(@fieldParentPtr("node", n));
                reader.position -= prefix;
            }
            self.writable.broadcast(self.io);
        }
    };
}
