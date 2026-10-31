//! Deferred terminal effects; leading callback parameters are injected services.
const std = @import("std");
const decl = @import("../data/declarations.zig");
const seq = @import("../data/sequences.zig");
const cb = @import("../internal/callbacks.zig");
const composition = @import("../internal/composition.zig");
const dependencies = @import("../internal/world/dependencies.zig");
pub const Mode = enum { each, collect, batch };

pub fn terminal(comptime mode: Mode, size: usize, comptime effect: anytype) Terminal(mode, effect) {
    return .{ .size = size };
}

pub fn Flow(comptime Source: type, comptime Consumer: type) type {
    decl.requireSource(Source);
    return struct {
        pub const world_flow_tag = dependencies.FlowTag;
        pub const Requirements = decl.concat(decl.requirements(Source), if (@hasDecl(Consumer, "Services")) &Consumer.Services else &.{});
        source: Source,
        consumer: Consumer,
    };
}

fn Terminal(comptime mode: Mode, comptime effect: anytype) type {
    const Meta = cb.Info(effect, 1);
    if (composition.Payload(Meta.Return) != void)
        @compileError("terminal: callback must return void or E!void");
    return struct {
        size: usize,
        pub fn Output(comptime Source: type) type {
            const T = seq.Item(Source);
            cb.validate(effect, &.{if (mode == .each) T else []const T});
            const Consumer = struct {
                pub const Services = Meta.Services;
                size: if (mode == .batch) usize else void,
                storage: if (mode == .batch) []T else void = if (mode == .batch) &.{} else {},
                pub fn prepare(self: *@This(), allocator: std.mem.Allocator) !void {
                    if (mode == .batch) {
                        if (self.size == 0) return error.InvalidBatchSize;
                        self.storage = try allocator.alloc(T, self.size);
                    }
                }
                pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
                    if (mode == .batch) allocator.free(self.storage);
                }
                pub fn consume(self: @This(), reader: anytype, env: anytype, allocator: std.mem.Allocator, io: std.Io) anyerror!void {
                    var input = reader.iterator();
                    if (mode == .each) {
                        while (try input.next()) |value| {
                            try invoke(env, value);
                        }
                    } else if (mode == .collect) {
                        var values: std.ArrayList(T) = .empty;
                        defer values.deinit(allocator);
                        while (try input.next()) |value| try values.append(allocator, value);
                        try io.checkCancel();
                        try invoke(env, @as([]const T, values.items));
                    } else {
                        var count: usize = 0;
                        while (try input.next()) |value| {
                            self.storage[count] = value;
                            count += 1;
                            if (count == self.storage.len) {
                                try io.checkCancel();
                                try invoke(env, @as([]const T, self.storage));
                                count = 0;
                            }
                        }
                        try io.checkCancel();
                        if (count != 0) try invoke(env, @as([]const T, self.storage[0..count]));
                    }
                }
                fn invoke(env: anytype, value: anytype) !void {
                    const result = cb.invoke(effect, env, .{value});
                    if (@typeInfo(@TypeOf(result)) == .error_union) try result;
                }
            };
            return Flow(Source, Consumer);
        }
        pub fn apply(self: @This(), source: anytype) Output(@TypeOf(source)) {
            return .{ .source = source, .consumer = .{ .size = if (mode == .batch) self.size else {} } };
        }
    };
}

/// Adapt the standard line terminal without adding a second I/O implementation.
pub fn external(operator: anytype) External(@TypeOf(operator)) {
    return .{ .operator = operator };
}
fn External(comptime Operator: type) type {
    return struct {
        operator: Operator,
        pub fn Output(comptime Source: type) type {
            const OldFlow = Operator.Output(Source);
            const C = @FieldType(OldFlow, "consumer");
            const Consumer = struct {
                inner: C,
                pub fn prepare(self: *@This(), allocator: std.mem.Allocator) !void {
                    try self.inner.prepare(allocator);
                }
                pub fn prepareResources(self: *@This(), scope: anytype) !void {
                    try self.inner.prepareResources(scope);
                }
                pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
                    self.inner.deinit(allocator);
                }
                pub fn consume(self: @This(), reader: anytype, _: anytype, allocator: std.mem.Allocator, io: std.Io) !void {
                    try self.inner.consume(reader, allocator, io);
                }
            };
            return Flow(Source, Consumer);
        }
        pub fn apply(self: @This(), source: anytype) Output(@TypeOf(source)) {
            return .{ .source = source, .consumer = .{ .inner = self.operator.apply(source).consumer } };
        }
    };
}
