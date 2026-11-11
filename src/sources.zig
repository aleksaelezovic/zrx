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
const Io = std.Io;
const di = @import("di.zig");
const core = @import("pipe.zig");
const program = @import("program.zig");
const tasks = @import("tasks.zig");
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

/// The items of several sources, interleaved as they arrive; each source keeps
/// its own order. Sources run together (see `tasks.all`) and take turns
/// pushing, so the pipe still sees one item at a time. Needs `std.Io`.
pub fn merge(sources: anytype) Merge(Sources(@TypeOf(sources))) {
    var out: Sources(@TypeOf(sources)) = undefined;
    inline for (0..sources.len) |i| out[i] = sources[i];
    return .{ .sources = out };
}

fn Sources(comptime Given: type) type {
    @setEvalBranchQuota(di.quota);
    if (!di.isTuple(Given)) @compileError("merge: expected a tuple of sources `.{ a, b }`, got `" ++ @typeName(Given) ++ "`");
    const list = di.types(Given);
    if (list.len == 0) @compileError("merge: needs at least one source");
    for (list, 0..) |S, i| {
        if (!program.isSource(S)) @compileError(std.fmt.comptimePrint("merge: element {d} is not a source (got `{s}`)", .{ i, @typeName(S) }));
        if (S.Item != list[0].Item) @compileError(std.fmt.comptimePrint(
            "merge: every source must emit the same item type; source 0 emits `{s}` but source {d} emits `{s}`",
            .{ @typeName(list[0].Item), i, @typeName(S.Item) },
        ));
    }
    return @Tuple(list);
}

fn Merge(comptime Ss: type) type {
    const members = di.types(Ss);
    return struct {
        sources: Ss,

        pub const zrx_source = {};
        pub const Item = members[0].Item;

        pub fn run(self: *const @This(), env: anytype, down: anytype) !void {
            const Env = @TypeOf(env);
            if (members.len == 1) return self.sources[0].run(env, down);
            if (comptime !di.has(Env, Io)) @compileError("merge: needs `std.Io` to run sources together; pass `io` to `run(.{ io, ... })`");
            const io = di.get(env, Io);

            var turn: Turn = .{ .mutex = .init, .stopped = .init(false) };
            const Gate = Serialized(Item, @TypeOf(down));
            const gate: Gate = .{ .io = io, .turn = &turn, .down = down };

            const list = comptime blk: {
                var types: [members.len]type = undefined;
                for (members, 0..) |S, i| types[i] = Feed(S, Env, Gate);
                break :blk types;
            };
            var group: @Tuple(&list) = undefined;
            inline for (0..members.len) |i| group[i] = .{ .source = &self.sources[i], .env = env, .gate = gate };
            // Once the pipe wants no more, a source still waiting for its own
            // next item is cancelled rather than waited for.
            return tasks.all(io, group, &turn.stopped);
        }
    };
}

const Turn = struct {
    mutex: Io.Mutex,
    /// Set once the pipe wants no more or a push failed; every source then stops.
    stopped: std.atomic.Value(bool),
};

fn Serialized(comptime T: type, comptime Down: type) type {
    return struct {
        io: Io,
        turn: *Turn,
        down: Down,

        pub fn push(gate: @This(), item: T) !Flow {
            try gate.turn.mutex.lock(gate.io);
            defer gate.turn.mutex.unlock(gate.io);
            if (gate.turn.stopped.load(.acquire)) return .done;
            errdefer gate.turn.stopped.store(true, .release);
            const flow = try gate.down.push(item);
            if (flow == .done) gate.turn.stopped.store(true, .release);
            return flow;
        }
    };
}

fn Feed(comptime S: type, comptime Env: type, comptime Gate: type) type {
    return struct {
        source: *const S,
        env: Env,
        gate: Gate,

        pub fn run(self: @This()) !void {
            return self.source.run(self.env, self.gate);
        }
    };
}
