//! Bind typed service references to graph regions before activation. The audited
//! transport runtime retains ownership of shared nodes, readers, caches and I/O.
const std = @import("std");
const decl = @import("../../data/declarations.zig");
const seq = @import("../../data/sequences.zig");
const signals = @import("../signal_kind.zig");
const cb = @import("../callbacks.zig");
const graph = @import("../graph_run.zig");
const streams = @import("../../data/streams.zig");
const transport = @import("../runtime/streams.zig");
const regions = @import("regions.zig");
const Key = struct { address: usize, type_id: usize };
const Allocation = struct { ptr: *anyopaque, free: *const fn (std.mem.Allocator, *anyopaque) void };

fn referenceCapacity(comptime T: type) usize {
    if (@typeInfo(T) == .pointer) return 1 + referenceCapacity(decl.Child(T));
    var count: usize = 0;
    if (@hasField(T, "source")) count += referenceCapacity(@FieldType(T, "source"));
    if (@hasField(T, "signal")) count += referenceCapacity(@FieldType(T, "signal"));
    if (@hasField(T, "inputs")) {
        for (@typeInfo(@FieldType(T, "inputs")).@"struct".field_types) |I| count += referenceCapacity(I);
    }
    return count;
}

fn typeId(comptime T: type) usize {
    const Identity = struct {
        const Declaration = T;
        var byte: u8 = 0;
    };
    return @intFromPtr(&Identity.byte);
}

pub fn Scope(comptime Env: type) type {
    const capacity = block: {
        var count: usize = 0;
        for (Env.RootTypes) |F| count += referenceCapacity(@FieldType(F, "source"));
        break :block count;
    };
    return struct {
        const Self = @This();
        allocator: std.mem.Allocator,
        env: *Env,
        index: std.AutoHashMapUnmanaged(Key, *anyopaque) = .{},
        counts: [capacity]struct { key: Key, count: usize } = undefined,
        counted: usize = 0,
        owned: std.ArrayList(Allocation) = .empty,
        pub fn deinit(self: *Self) void {
            for (self.owned.items) |entry| entry.free(self.allocator, entry.ptr);
            self.owned.deinit(self.allocator);
            self.index.deinit(self.allocator);
        }
        pub fn inspect(self: *Self, input: anytype) !void {
            const T = @TypeOf(input);
            if (comptime @typeInfo(T) == .pointer) {
                const key: Key = .{ .address = @intFromPtr(input), .type_id = typeId(decl.Child(T)) };
                for (self.counts[0..self.counted]) |*slot| {
                    if (std.meta.eql(slot.key, key)) {
                        slot.count += 1;
                        return;
                    }
                }
                self.counts[self.counted] = .{ .key = key, .count = 1 };
                self.counted += 1;
                return self.inspect(input.*);
            }
            if (comptime @hasField(T, "source")) try self.inspect(input.source);
            if (comptime @hasField(T, "signal")) try self.inspect(input.signal);
            if (comptime @hasField(T, "inputs")) inline for (input.inputs) |source| try self.inspect(source);
        }
        fn shared(self: *Self, input: anytype) bool {
            const key: Key = .{ .address = @intFromPtr(input), .type_id = typeId(decl.Child(@TypeOf(input))) };
            for (self.counts[0..self.counted]) |slot| if (std.meta.eql(slot.key, key)) return slot.count > 1;
            unreachable;
        }
        pub fn hasShared(self: *const Self) bool {
            for (self.counts[0..self.counted]) |slot| if (slot.count > 1) return true;
            return false;
        }
        fn reference(self: *Self, input: anytype) !Lowered(@TypeOf(input), Env) {
            const T = @typeInfo(@TypeOf(input)).pointer.child;
            const L = Lowered(T, Env);
            const key: Key = .{ .address = @intFromPtr(input), .type_id = typeId(T) };
            if (self.index.get(key)) |ptr| return @ptrCast(@alignCast(ptr));
            const ptr = try self.allocator.create(L);
            errdefer self.allocator.destroy(ptr);
            ptr.* = try self.lower(input.*);
            const Free = struct {
                fn free(allocator: std.mem.Allocator, raw: *anyopaque) void {
                    allocator.destroy(@as(*L, @ptrCast(@alignCast(raw))));
                }
            };
            // Recursive lowering may have grown both containers. Reserve only
            // after recursion; commit ownership and identity without another
            // fallible operation so failure cannot leave a freed owned entry.
            try self.index.ensureUnusedCapacity(self.allocator, 1);
            try self.owned.ensureUnusedCapacity(self.allocator, 1);
            self.owned.appendAssumeCapacity(.{ .ptr = ptr, .free = Free.free });
            self.index.putAssumeCapacity(key, ptr);
            return ptr;
        }
        pub fn lower(self: *Self, input: anytype) anyerror!Lowered(@TypeOf(input), Env) {
            const T = @TypeOf(input);
            if (comptime @typeInfo(T) == .pointer) return self.reference(input);
            if (comptime @hasDecl(T, "node_kind")) {
                if (T.node_kind == .slice) return .{ .input = input, .env = self.env };
                if (T.node_kind == .value) return .{ .input = input, .env = self.env };
                if (T.node_kind == .producer) {
                    const Forward = struct {
                        fn produce(env: *Env, emitter: *streams.Emitter(T.Item)) !void {
                            const result = cb.invoke(T.callback, env, .{emitter});
                            if (@typeInfo(@TypeOf(result)) == .error_union) try result;
                        }
                    };
                    return streams.Stream(T.Item).fromProducerWith(input.capacity, Forward.produce, self.env);
                }
                if (T.node_kind == .borrowed or T.node_kind == .iterator) return input.source;
                if (comptime signals.isSignal(T)) return .{ .source = try self.lower(input.source), .env = self.env };
                return .{ .plan = try makePlan(self, input) };
            }
            if (comptime @hasField(T, "inputs")) {
                var result: Lowered(T, Env) = undefined;
                inline for (0..input.inputs.len) |i| result.inputs[i] = try self.lower(input.inputs[i]);
                return result;
            }
            if (comptime signals.isValues(T)) return .{ .signal = try self.lower(input.signal) };
            if (comptime signals.isSample(T))
                return .{ .source = try self.lower(input.source), .signal = try self.lower(input.signal) };
            if (comptime @hasField(T, "source")) {
                var result: Lowered(T, Env) = undefined;
                result.source = try self.lower(input.source);
                if (comptime @hasField(T, "initial")) result.initial = input.initial;
                if (comptime @hasField(T, "limit")) result.limit = input.limit;
                return result;
            }
            return input;
        }
    };
}

pub fn Lowered(comptime T: type, comptime Env: type) type {
    if (@typeInfo(T) == .pointer) return *Lowered(@typeInfo(T).pointer.child, Env);
    if (@hasDecl(T, "node_kind")) {
        if (T.node_kind == .slice) return regions.View(T, Env);
        if (T.node_kind == .value) return regions.View(T, Env);
        if (T.node_kind == .producer) return streams.Stream(T.Item);
        if (T.node_kind == .borrowed or T.node_kind == .iterator) return @FieldType(T, "source");
        if (signals.isSignal(T)) return BoundSignal(T, Env);
        return BoundRegion(T, Env);
    }
    if (@hasField(T, "inputs")) {
        const Inputs = @typeInfo(@FieldType(T, "inputs")).@"struct".field_types;
        var lowered: [Inputs.len]type = undefined;
        for (Inputs, 0..) |I, i| lowered[i] = Lowered(I, Env);
        return @TypeOf(@import("../../ops/merge.zig").merge(@as(@Tuple(&lowered), undefined)));
    }
    if (signals.isValues(T)) return @TypeOf(@import("../../ops/values.zig").values(@as(Lowered(@FieldType(T, "signal"), Env), undefined)));
    if (signals.isSample(T)) {
        const operator = @import("../../ops/withLatestFrom.zig").withLatestFrom(@as(Lowered(@FieldType(T, "signal"), Env), undefined));
        return @TypeOf(operator).Output(Lowered(@FieldType(T, "source"), Env));
    }
    if (@hasField(T, "source")) {
        const S = Lowered(@FieldType(T, "source"), Env);
        if (signals.isSignal(T)) {
            const op = @import("../../ops/hold.zig").hold(@as(T.Value, undefined));
            return @TypeOf(op).Output(S);
        }
        if (T.declaration_kind == .taken) return @TypeOf(@import("../../ops/take.zig").take(0)).Output(S);
        if (T.declaration_kind == .bounded) return @TypeOf(@import("../../ops/maxItems.zig").maxItems(0)).Output(S);
        if (T.declaration_kind == .retained) return @TypeOf(@import("../../ops/takeLast.zig").takeLast(0)).Output(S);
    }
    return T;
}

fn BoundRegion(comptime T: type, comptime Env: type) type {
    return struct {
        pub const graph_tag = seq.GraphTag;
        pub const region_source = true;
        pub const sequence_tag = seq.SequenceTag;
        pub const Item = T.Item;
        plan: Plan(T, Env),
        pub fn materialize(self: *@This(), scope: anytype) !*graph.Runtime(Item) {
            return self.plan.materialize(scope);
        }
    };
}

fn Here(comptime Input: type, comptime Env: type) type {
    return struct {
        source: Lowered(regions.Base(Input), Env),
        definition: Input,
        env: *Env,
        pub fn materialize(self: *@This(), scope: anytype) !*graph.Runtime(seq.Item(Input)) {
            const T = seq.Item(Input);
            const upstream = try graph.resolve(scope, &self.source);
            const reader = try upstream.acquire(scope.allocator);
            try scope.reserve();
            const owner = try scope.allocator.create(transport.Stream(T));
            errdefer scope.allocator.destroy(owner);
            owner.* = try transport.share(scope.allocator, scope.io, upstream.capacity, regions.view(self.definition, reader, self.env));
            errdefer owner.deinit();
            return graph.Runtime(T).create(scope.allocator, owner, upstream.capacity, .{reader});
        }
    };
}
fn Plan(comptime Input: type, comptime Env: type) type {
    if (!regions.expandable(Input)) return Here(Input, Env);
    return union(enum) {
        here: Here(Input, Env),
        upstream: Plan(regions.Expanded(Input), Env),
        pub fn materialize(self: *@This(), scope: anytype) !*graph.Runtime(seq.Item(Input)) {
            return switch (self.*) {
                .here => |*value| value.materialize(scope),
                .upstream => |*value| value.materialize(scope),
            };
        }
    };
}
fn makePlan(scope: anytype, input: anytype) anyerror!Plan(@TypeOf(input), @typeInfo(@TypeOf(scope.env)).pointer.child) {
    if (comptime regions.expandable(@TypeOf(input))) {
        if (!scope.shared(regions.base(input)))
            return .{ .upstream = try makePlan(scope, regions.expand(input)) };
        return .{ .here = .{ .source = try scope.lower(regions.base(input)), .definition = input, .env = scope.env } };
    }
    return .{ .source = try scope.lower(regions.base(input)), .definition = input, .env = scope.env };
}

fn BoundSignal(comptime T: type, comptime Env: type) type {
    return struct {
        pub const signal_tag = signals.Tag;
        pub const signal_kind = .mapped;
        pub const bound_signal = true;
        pub const Value = T.Value;
        source: Lowered(@FieldType(T, "source"), Env),
        env: *Env,
        pub fn compute(raw: *anyopaque, input: signals.Value(@FieldType(T, "source"))) Value {
            return signalCompose(T.functions, @as(*Env, @ptrCast(@alignCast(raw))), input, 0);
        }
    };
}
fn signalCompose(comptime functions: anytype, env: anytype, input: anytype, comptime index: usize) @TypeOf(block: {
    const result = cb.invoke(functions[index], env, .{input});
    break :block if (index + 1 == functions.len) result else signalCompose(functions, env, result, index + 1);
}) {
    const result = cb.invoke(functions[index], env, .{input});
    return if (index + 1 == functions.len) result else signalCompose(functions, env, result, index + 1);
}

fn Root(comptime F: type, comptime Env: type) type {
    const Input = @FieldType(F, "source");
    const Base = Lowered(regions.Base(Input), Env);
    const C = @FieldType(F, "consumer");
    const Consumer = struct {
        definition: Input,
        inner: C,
        env: *Env,
        pub fn prepare(self: *@This(), allocator: std.mem.Allocator) !void {
            try self.inner.prepare(allocator);
        }
        pub fn prepareResources(self: *@This(), scope: anytype) !void {
            if (@hasDecl(C, "prepareResources")) try self.inner.prepareResources(scope);
        }
        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            self.inner.deinit(allocator);
        }
        pub fn consume(self: @This(), reader: anytype, allocator: std.mem.Allocator, io: std.Io) !void {
            try self.inner.consume(regions.view(self.definition, reader, self.env), self.env, allocator, io);
        }
    };
    return graph.Flow(Base, Consumer);
}

fn ExpandedFlow(comptime F: type) type {
    return struct {
        source: regions.Expanded(@FieldType(F, "source")),
        consumer: @FieldType(F, "consumer"),
    };
}
pub fn Flow(comptime F: type, comptime Env: type) type {
    if (!regions.expandable(@FieldType(F, "source"))) return Root(F, Env);
    return union(enum) {
        pub const flow_tag = graph.FlowTag;
        here: Root(F, Env),
        upstream: Flow(ExpandedFlow(F), Env),
        pub fn prepare(self: *@This(), scope: anytype) !void {
            switch (self.*) {
                .here => |*value| try value.prepare(scope),
                .upstream => |*value| try value.prepare(scope),
            }
        }
        pub fn execute(self: *@This(), allocator: std.mem.Allocator, io: std.Io) !void {
            switch (self.*) {
                .here => |*value| try value.execute(allocator, io),
                .upstream => |*value| try value.execute(allocator, io),
            }
        }
        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            switch (self.*) {
                .here => |*value| value.deinit(allocator),
                .upstream => |*value| value.deinit(allocator),
            }
        }
    };
}
pub fn flow(scope: anytype, definition: anytype) !Flow(@TypeOf(definition), @typeInfo(@TypeOf(scope.env)).pointer.child) {
    if (comptime regions.expandable(@FieldType(@TypeOf(definition), "source"))) {
        if (!scope.shared(regions.base(definition.source))) {
            return .{ .upstream = try flow(scope, ExpandedFlow(@TypeOf(definition)){
                .source = regions.expand(definition.source),
                .consumer = definition.consumer,
            }) };
        }
        return .{ .here = .{
            .source = try scope.lower(regions.base(definition.source)),
            .consumer = .{ .definition = definition.source, .inner = definition.consumer, .env = scope.env },
        } };
    }
    return .{
        .source = try scope.lower(regions.base(definition.source)),
        .consumer = .{ .definition = definition.source, .inner = definition.consumer, .env = scope.env },
    };
}
