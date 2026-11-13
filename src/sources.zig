//! Sources: where a program's items come from.
//!
//! A source is a value whose type declares:
//!
//!     pub const zrx_source = {};
//!     pub const Item = T;
//!     pub fn run(self: *const Self, env: anytype, down: anytype) !void
//!
//! `run` calls `down.push(item)` for each item and returns when it has no more
//! or when a push answers `.done`.
const std = @import("std");
const di = @import("di.zig");
const core = @import("pipe.zig");
const Flow = core.Flow;
const lift = core.lift;

/// Every element of a slice or array, in order. The storage must outlive the run.
pub fn fromSlice(items: anytype) FromSlice(Element(@TypeOf(items))) {
    return .{ .items = items };
}

fn Element(comptime T: type) type {
    switch (@typeInfo(T)) {
        .pointer => |pointer| switch (pointer.size) {
            .slice => return pointer.child,
            .one => switch (@typeInfo(pointer.child)) {
                .array => |array| return array.child,
                else => {},
            },
            else => {},
        },
        else => {},
    }
    @compileError("fromSlice: expected a slice or a pointer to an array, got `" ++ @typeName(T) ++ "`");
}

fn FromSlice(comptime T: type) type {
    return struct {
        items: []const T,

        pub const zrx_source = {};
        pub const Item = T;

        pub fn run(self: *const @This(), _: anytype, down: anytype) !void {
            for (self.items) |item| {
                if (try down.push(item) == .done) return;
            }
        }
    };
}

/// A single item.
pub fn fromValue(value: anytype) FromValue(@TypeOf(value)) {
    return .{ .value = value };
}

fn FromValue(comptime T: type) type {
    return struct {
        value: T,

        pub const zrx_source = {};
        pub const Item = T;

        pub fn run(self: *const @This(), _: anytype, down: anytype) !void {
            _ = try down.push(self.value);
        }
    };
}

/// The integers from `first` up to but not including `end`.
pub fn range(comptime T: type, first: T, end: T) Range(T) {
    return .{ .first = first, .end = end };
}

fn Range(comptime T: type) type {
    if (@typeInfo(T) != .int) @compileError("range: expected an integer type, got `" ++ @typeName(T) ++ "`");
    return struct {
        first: T,
        end: T,

        pub const zrx_source = {};
        pub const Item = T;

        pub fn run(self: *const @This(), _: anytype, down: anytype) !void {
            var value = self.first;
            while (value < self.end) : (value += 1) {
                if (try down.push(value) == .done) return;
            }
        }
    };
}

/// Items pulled from `iterator.next()` until it returns null. `iterator` is a
/// pointer; `next` may return `?T` or `E!?T`.
pub fn fromIterator(iterator: anytype) FromIterator(@TypeOf(iterator)) {
    return .{ .iterator = iterator };
}

fn FromIterator(comptime Pointer: type) type {
    const Next = switch (@typeInfo(Pointer)) {
        .pointer => |pointer| if (pointer.size == .one and !pointer.attrs.@"const" and
            @typeInfo(pointer.child) == .@"struct" and @hasDecl(pointer.child, "next"))
            @typeInfo(@TypeOf(pointer.child.next)).@"fn".return_type.?
        else
            notAnIterator(Pointer),
        else => notAnIterator(Pointer),
    };
    const T = switch (@typeInfo(di.Payload(Next))) {
        .optional => |optional| optional.child,
        else => @compileError("fromIterator: `next` must return `?T` or `E!?T`, got `" ++ @typeName(Next) ++ "`"),
    };
    return struct {
        iterator: Pointer,

        pub const zrx_source = {};
        pub const Item = T;

        pub fn run(self: *const @This(), _: anytype, down: anytype) !void {
            while (try lift(self.iterator.next())) |item| {
                if (try down.push(item) == .done) return;
            }
        }
    };
}

fn notAnIterator(comptime T: type) noreturn {
    @compileError("fromIterator: expected a mutable pointer to a struct with `next`, got `" ++ @typeName(T) ++ "`");
}

/// Items of type `T` pushed by `producer(deps..., out)`. The producer calls
/// `out.push(item)`, which returns a `Flow`; it should return once a push
/// answers `.done`:
///
///     fn ticks(clock: Clock, out: anytype) !void {
///         while (try out.push(clock.now()) == .more) {}
///     }
pub fn fromProducer(comptime T: type, comptime producer: anytype) FromProducer(T, producer) {
    return .{};
}

fn FromProducer(comptime T: type, comptime producer: anytype) type {
    return struct {
        pub const zrx_source = {};
        pub const Item = T;

        pub fn run(_: *const @This(), env: anytype, down: anytype) !void {
            const Out = Emitter(T, @TypeOf(down));
            const Call = di.Bound("fromProducer", producer, @TypeOf(env), &.{Out});
            if (comptime di.Payload(Call.Return) != void) @compileError("fromProducer: producer must return `void` or `E!void`, got `" ++ @typeName(Call.Return) ++ "`");
            const call: Call = .init(env);
            try lift(call.call(.{Out{ .down = down }}));
        }
    };
}

fn Emitter(comptime T: type, comptime Down: type) type {
    return struct {
        down: Down,

        pub fn push(out: @This(), item: T) !Flow {
            return out.down.push(item);
        }
    };
}
