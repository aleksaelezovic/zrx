const std = @import("std");
const composition = @import("composition.zig");
const sequences = @import("sequences.zig");
const streams = @import("streams.zig");
const declarations = @import("declarations.zig");

/// Declare per-item effects. Only run traverses input and invokes callbacks.
pub fn forEach(comptime effect: anytype) Terminal(effect, false, .each) {
    return .{ .capability = {} };
}

pub fn forEachWith(capability: anytype, comptime effect: anytype) Terminal(effect, true, .each) {
    return .{ .capability = capability };
}

/// Borrow the complete collection during one callback after successful end.
/// Run frees the shallow backing storage after the callback, even on failure.
pub fn collectThen(comptime effect: anytype) Terminal(effect, false, .collection) {
    return .{ .capability = {} };
}

pub fn collectThenWith(capability: anytype, comptime effect: anytype) Terminal(effect, true, .collection) {
    return .{ .capability = capability };
}

/// Borrow successive batches during callbacks. Only successful end flushes a
/// nonempty partial batch; failure/cancellation discards pending items.
pub fn batchThen(size: usize, comptime effect: anytype) Terminal(effect, false, .batch) {
    return .{ .capability = {}, .batch_size = size };
}

pub fn batchThenWith(size: usize, capability: anytype, comptime effect: anytype) Terminal(effect, true, .batch) {
    return .{ .capability = capability, .batch_size = size };
}

fn Terminal(comptime effect: anytype, comptime with_capability: bool, comptime mode: enum { each, collection, batch }) type {
    const name = switch (mode) {
        .each => if (with_capability) "forEachWith" else "forEach",
        .collection => if (with_capability) "collectThenWith" else "collectThen",
        .batch => if (with_capability) "batchThenWith" else "batchThen",
    };
    const BatchSize = if (mode == .batch) usize else void;
    const info = composition.callbackInfo(effect, name ++ ": effect", if (with_capability) 2 else 1);
    const Capability = if (with_capability) info.param_types[0].? else void;
    const Argument = info.param_types[if (with_capability) 1 else 0].?;
    const Return = info.return_type.?;
    if (Return != void and
        (@typeInfo(Return) != .error_union or composition.Payload(Return) != void))
        @compileError(name ++ ": effect must return void or an error union with void payload");
    if (mode != .each and (@typeInfo(Argument) != .pointer or
        @typeInfo(Argument).pointer.size != .slice or !@typeInfo(Argument).pointer.attrs.@"const"))
        @compileError(name ++ ": effect must accept a read-only slice []const T");
    return struct {
        capability: Capability,
        batch_size: BatchSize = if (mode == .batch) 0 else {},

        pub fn Output(comptime Input: type) type {
            const Item = sequences.Item(Input);
            _ = @TypeOf(@as(Argument, @as(if (mode == .each) Item else []const Item, undefined)));
            const Consumer = struct {
                capability: Capability,
                batch_size: BatchSize,
                storage: if (mode == .batch) []Item else void = if (mode == .batch) &.{} else {},

                pub fn prepare(self: *@This(), allocator: std.mem.Allocator) !void {
                    if (mode == .batch) {
                        if (self.batch_size == 0) return error.InvalidBatchSize;
                        self.storage = try allocator.alloc(Item, self.batch_size);
                    }
                }

                pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
                    if (mode == .batch) allocator.free(self.storage);
                }

                pub fn consume(self: @This(), reader: *streams.Stream(Item).Reader, allocator: std.mem.Allocator, io: std.Io) anyerror!void {
                    var input = reader.iterator();
                    if (mode == .each) {
                        while (true) {
                            try io.checkCancel();
                            const value = (try input.next()) orelse return;
                            try self.invoke(value);
                        }
                    } else if (mode == .batch) {
                        var count: usize = 0;
                        while (true) {
                            try io.checkCancel();
                            const value = (try input.next()) orelse break;
                            self.storage[count] = value;
                            count += 1;
                            if (count == self.storage.len) {
                                try io.checkCancel();
                                try self.invoke(self.storage);
                                count = 0;
                            }
                        }
                        try io.checkCancel();
                        if (count != 0) try self.invoke(self.storage[0..count]);
                    } else {
                        var values: std.ArrayList(Item) = .empty;
                        defer values.deinit(allocator);
                        while (true) {
                            try io.checkCancel();
                            const value = (try input.next()) orelse break;
                            try values.append(allocator, value);
                        }
                        try io.checkCancel();
                        try self.invoke(@as([]const Item, values.items));
                    }
                }

                fn invoke(self: @This(), value: Argument) anyerror!void {
                    const result = if (with_capability) effect(self.capability, value) else effect(value);
                    if (Return != void) try result;
                }
            };
            return declarations.Flow(Input, Consumer);
        }

        pub fn apply(self: @This(), source: anytype) Output(@TypeOf(source)) {
            return .{
                .source = source,
                .consumer = .{ .capability = self.capability, .batch_size = self.batch_size },
            };
        }
    };
}
