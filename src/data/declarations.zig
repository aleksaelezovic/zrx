//! Resource-free declarations. Runtime state belongs to run, not to this graph.
const std = @import("std");
const seq = @import("sequences.zig");
const kind = @import("../internal/signal_kind.zig");
const cb = @import("../internal/callbacks.zig");
const composition = @import("../internal/composition.zig");
pub const Tag = opaque {};

pub fn Child(comptime T: type) type {
    return if (@typeInfo(T) == .pointer and @typeInfo(T).pointer.size == .one) @typeInfo(T).pointer.child else T;
}

pub fn concat(comptime a: []const type, comptime b: []const type) [a.len + b.len]type {
    var result: [a.len + b.len]type = undefined;
    for (a, 0..) |T, i| result[i] = T;
    for (b, a.len..) |T, i| result[i] = T;
    return result;
}

pub fn requirements(comptime Input: type) []const type {
    const T = Child(Input);
    if (@typeInfo(T) != .@"struct") return &.{};
    if (@hasDecl(T, "Requirements")) return &T.Requirements;
    const source = if (@hasField(T, "source")) requirements(@FieldType(T, "source")) else &.{};
    const signal = if (@hasField(T, "signal")) requirements(@FieldType(T, "signal")) else &.{};
    const combined = concat(source, signal);
    if (@hasField(T, "inputs")) {
        var result: []const type = &combined;
        for (@typeInfo(@FieldType(T, "inputs")).@"struct".field_types) |I| {
            const next = concat(result, requirements(I));
            result = &next;
        }
        return result;
    }
    return &combined;
}

pub fn services(comptime functions: anytype, comptime trailing: usize, comptime index: usize) []const type {
    if (index == functions.len) return &.{};
    const next = concat(&cb.Info(functions[index], trailing).Services, services(functions, trailing, index + 1));
    return &next;
}

pub fn requireSource(comptime Input: type) void {
    if (comptime !seq.isGraph(Input) and !kind.isSignal(Input))
        @compileError("pipe: input must be a declaration; use fromSlice or fromValue");
}

/// Borrow finite storage. Never copies an array temporary or starts iteration.
pub fn fromSlice(input: anytype) Slice(@TypeOf(input)) {
    return .{ .items = input };
}

fn Slice(comptime Input: type) type {
    if (@typeInfo(Input) != .pointer or
        (@typeInfo(Input).pointer.size != .slice and
            !(@typeInfo(Input).pointer.size == .one and @typeInfo(@typeInfo(Input).pointer.child) == .array)))
        @compileError("fromSlice: expected a borrowed slice or pointer to array");
    const T = seq.Item(Input);
    return struct {
        pub const graph_tag = seq.GraphTag;
        pub const sequence_tag = seq.SequenceTag;
        pub const node_kind = .slice;
        pub const Item = T;
        pub const Requirements: [0]type = .{};
        items: []const T,
    };
}

/// A single typed value, stored shallowly in a cold declaration.
pub fn fromValue(value: anytype) Value(@TypeOf(value)) {
    return .{ .value = value };
}

fn Value(comptime T: type) type {
    if (T == comptime_int or T == comptime_float or T == void)
        @compileError("fromValue: use an explicitly typed non-void value");
    return struct {
        pub const graph_tag = seq.GraphTag;
        pub const sequence_tag = seq.SequenceTag;
        pub const node_kind = .value;
        pub const Item = T;
        pub const Requirements: [0]type = .{};
        value: T,
    };
}

pub const Operation = enum { map, filter, tap, fold };

pub fn transform(comptime operation: Operation, comptime input: anytype) Transform(operation, cb.functions(input, 1)) {
    return .{};
}

fn resultItem(comptime operation: Operation, comptime Source: type, comptime functions: anytype) type {
    var T = if (kind.isSignal(Source)) kind.Value(Source) else seq.Item(Source);
    for (functions) |function| {
        cb.validate(function, &.{T});
        const R = cb.Info(function, 1).Return;
        if (operation == .map) {
            T = if (kind.isSignal(Source)) R else composition.Payload(R);
            if (@sizeOf(T) == 0 or (!kind.isSignal(Source) and @typeInfo(T) == .error_set))
                @compileError("map: return a nonzero-sized item; use terminal effects for void");
        } else if (operation == .filter) {
            if (composition.Payload(R) != bool) @compileError("filter: predicate must return bool or E!bool");
        } else if (composition.Payload(R) != void) {
            @compileError("tap: effect must return void or E!void");
        }
    }
    return T;
}

fn Transform(comptime operation: Operation, comptime fns: anytype) type {
    return struct {
        pub fn Output(comptime Source: type) type {
            requireSource(Source);
            if (kind.isSignal(Source) and operation != .map)
                @compileError("signal: use map, or observe values before stream operators");
            const T = resultItem(operation, Source, fns);
            return struct {
                pub const graph_tag = seq.GraphTag;
                pub const sequence_tag = seq.SequenceTag;
                pub const node_kind = switch (operation) {
                    .map => .map,
                    .filter => .filter,
                    .tap => .tap,
                    .fold => .fold,
                };
                pub const Item = T;
                pub const Requirements = concat(requirements(Source), services(fns, 1, 0));
                source: Source,
                // Signal recognition remains distinct from stream recognition.
                pub const signal_tag = if (kind.isSignal(Source)) kind.Tag else void;
                pub const signal_kind = if (kind.isSignal(Source)) .mapped else {};
                pub const Value = T;
                pub const functions = fns;
            };
        }
        pub fn apply(_: @This(), source: anytype) Output(@TypeOf(source)) {
            return .{ .source = source };
        }
    };
}

pub fn borrowed(input: anytype, comptime synchronous: bool) Borrowed(@TypeOf(input), synchronous) {
    return .{ .source = input };
}
fn Borrowed(comptime Input: type, comptime synchronous: bool) type {
    return struct {
        pub const graph_tag = seq.GraphTag;
        pub const sequence_tag = seq.SequenceTag;
        pub const node_kind = if (synchronous) .iterator else .borrowed;
        pub const Item = seq.Item(Input);
        pub const Requirements: [0]type = .{};
        source: Input,
    };
}

/// Deferred eager-at-run left reduction. Reducer: (services..., A, T) A/E!A.
pub fn fold(seed: anytype, comptime reducer: anytype) Fold(Accumulator(reducer), reducer) {
    return .{ .seed = seed };
}

fn Accumulator(comptime reducer: anytype) type {
    const Meta = cb.Info(reducer, 2);
    return Meta.Params[Meta.Params.len - 2];
}

fn Fold(comptime A: type, comptime reducer: anytype) type {
    const Meta = cb.Info(reducer, 2);
    if (@typeInfo(A) == .error_union or composition.Payload(Meta.Return) != A)
        @compileError("fold: reducer must return the exact non-error accumulator type or E!A");
    return struct {
        seed: A,
        pub fn Output(comptime Source: type) type {
            requireSource(Source);
            cb.validate(reducer, &.{ A, seq.Item(Source) });
            return struct {
                pub const graph_tag = seq.GraphTag;
                pub const sequence_tag = seq.SequenceTag;
                pub const node_kind = .fold;
                pub const Item = A;
                pub const Requirements = concat(requirements(Source), &Meta.Services);
                pub const callback = reducer;
                source: Source,
                seed: A,
            };
        }
        pub fn apply(self: @This(), source: anytype) Output(@TypeOf(source)) {
            return .{ .source = source, .seed = self.seed };
        }
    };
}

/// Compile-time callback metadata remains in the producer declaration's type.
pub fn Stream(comptime T: type) type {
    if (@sizeOf(T) == 0) @compileError("Stream: zero-sized elements are not supported");
    return struct {
        pub fn fromProducer(capacity: usize, comptime producer: anytype) Producer(T, producer) {
            return .{ .capacity = capacity };
        }
    };
}

fn Producer(comptime T: type, comptime producer: anytype) type {
    const Meta = cb.Info(producer, 1);
    cb.validate(producer, &.{*@import("streams.zig").Emitter(T)});
    if (composition.Payload(Meta.Return) != void)
        @compileError("producer: callback must return void or E!void");
    return struct {
        pub const graph_tag = seq.GraphTag;
        pub const sequence_tag = seq.SequenceTag;
        pub const node_kind = .producer;
        pub const Item = T;
        pub const Requirements = Meta.Services;
        pub const callback = producer;
        capacity: usize,
    };
}
