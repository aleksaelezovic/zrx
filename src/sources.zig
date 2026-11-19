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
const completion = @import("completion.zig");
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
        pub const zrx_stop_source = std.mem.indexOfScalar(type, di.requires("fromProducer", producer, 1), completion.Stop) != null;
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
/// its own order. Sources run together, each as a task (see `tasks.Scope`),
/// and take turns pushing, so the pipe still sees one item at a time. Once a
/// push is answered `.done`, or a source fails, the others are cancelled
/// where they wait.
/// Needs `std.Io` with concurrency: `error.ConcurrencyUnavailable` otherwise.
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
        pub const zrx_stop_source = blk: {
            for (members) |S| if (completion.sourceWantsStop(S)) break :blk true;
            break :blk false;
        };
        pub const Item = members[0].Item;

        pub fn run(self: *const @This(), env: anytype, down: anytype) !void {
            const Env = @TypeOf(env);
            if (members.len == 1) return self.sources[0].run(env, down);
            if (comptime !di.has(Env, Io)) @compileError("merge: needs `std.Io` to run sources together; pass `io` to `run(.{ io, ... })`");
            const io = di.get(env, Io);

            var scope: tasks.Scope = .{};
            var turn: Turn = .{ .mutex = .init, .stopped = false, .scope = &scope };
            const Gate = Serialized(Item, @TypeOf(down));
            const gate: Gate = .{ .io = io, .turn = &turn, .down = down };

            const list = comptime blk: {
                var types: [members.len]type = undefined;
                for (members, 0..) |S, i| types[i] = Feed(S, Env, Gate);
                break :blk types;
            };
            var group: @Tuple(&list) = undefined;
            inline for (0..members.len) |i| group[i] = .{ .source = &self.sources[i], .env = env, .gate = gate };
            return scope.run(io, group);
        }
    };
}

/// An item and where it came from. `mergeTagged` emits it when given an enum
/// (`source` is the tag of the source); `each` emits it for what its sub-pipe
/// emits (`source` is the item the sub-pipe ran for).
pub fn Tagged(comptime Tag: type, comptime T: type) type {
    return struct { source: Tag, item: T };
}

/// `merge`, with every item marked by the source it came from. `sources`
/// names one source for each tag of `T`:
///
///     mergeTagged(Side, .{ .left = a, .right = b })
///
/// With an enum, every source emits the same item type and the merged source
/// emits `Tagged(T, Item)`. With a tagged union, each source feeds the
/// variant of its name, so the sources may emit different types, and the
/// merged source emits `T`. An item is then as large as the largest variant.
pub fn mergeTagged(comptime T: type, sources: anytype) Merge(Marked(T, @TypeOf(sources))) {
    var out: Marked(T, @TypeOf(sources)) = undefined;
    inline for (comptime tagNames(T), 0..) |tag, i| out[i] = .{ .source = @field(sources, tag) };
    return .{ .sources = out };
}

fn tagNames(comptime T: type) []const [:0]const u8 {
    const names = switch (@typeInfo(T)) {
        .@"enum" => |info| info.field_names,
        .@"union" => |info| if (info.tag_type != null) info.field_names else notTags(T),
        else => notTags(T),
    };
    if (names.len == 0) @compileError("mergeTagged: `" ++ @typeName(T) ++ "` has no tags, so there is nothing to merge");
    return names;
}

fn notTags(comptime T: type) noreturn {
    @compileError("mergeTagged: expected an enum or a tagged union to mark the items with, got `" ++ @typeName(T) ++ "`");
}

/// The sources of a `mergeTagged`, in the order of `T`'s tags, each marking what it emits.
fn Marked(comptime T: type, comptime Given: type) type {
    @setEvalBranchQuota(di.quota);
    const tags = tagNames(T);
    if (@typeInfo(Given) != .@"struct" or di.isTuple(Given)) @compileError(
        "mergeTagged: expected one source for each tag, named `.{ ." ++ tags[0] ++ " = source, ... }`, got `" ++ @typeName(Given) ++ "`",
    );
    for (@typeInfo(Given).@"struct".field_names) |name| if (!@hasField(T, name)) @compileError(
        "mergeTagged: `." ++ name ++ "` is not a tag of `" ++ @typeName(T) ++ "`",
    );
    var list: [tags.len]type = undefined;
    for (tags, 0..) |tag, i| {
        if (!@hasField(Given, tag)) @compileError(
            "mergeTagged: `" ++ @typeName(T) ++ "." ++ tag ++ "` has no source; add `." ++ tag ++ " = ...`",
        );
        const S = @FieldType(Given, tag);
        if (!program.isSource(S)) @compileError("mergeTagged: `." ++ tag ++ "` is not a source (got `" ++ @typeName(S) ++ "`)");
        list[i] = Mark(T, tag, S);
    }
    const First = @FieldType(Given, tags[0]).Item;
    switch (@typeInfo(T)) {
        .@"enum" => for (tags[1..]) |tag| if (@FieldType(Given, tag).Item != First) @compileError(
            "mergeTagged: with an enum every source must emit the same item type; `." ++ tags[0] ++ "` emits `" ++ @typeName(First) ++
                "` but `." ++ tag ++ "` emits `" ++ @typeName(@FieldType(Given, tag).Item) ++ "`. Pass a tagged union to merge different types",
        ),
        else => {
            var same = true;
            for (tags) |tag| {
                const Emits = @FieldType(Given, tag).Item;
                if (Emits != @FieldType(T, tag)) @compileError(
                    "mergeTagged: `." ++ tag ++ "` emits `" ++ @typeName(Emits) ++ "` but `" ++ @typeName(T) ++ "." ++ tag ++
                        "` holds `" ++ @typeName(@FieldType(T, tag)) ++ "`",
                );
                same = same and Emits == First;
            }
            if (same) @compileError(
                "mergeTagged: every variant of `" ++ @typeName(T) ++ "` holds `" ++ @typeName(First) ++
                    "`; pass an enum instead and receive `Tagged(Enum, " ++ @typeName(First) ++ ")`",
            );
        },
    }
    return @Tuple(&list);
}

/// The source `S`, with each of its items marked as coming from `tag` of `T`.
fn Mark(comptime T: type, comptime tag: [:0]const u8, comptime S: type) type {
    const by_enum = @typeInfo(T) == .@"enum";
    const Out = if (by_enum) Tagged(T, S.Item) else T;
    return struct {
        source: S,

        pub const zrx_source = {};
        pub const zrx_stop_source = completion.sourceWantsStop(S);
        pub const Item = Out;

        pub fn run(self: *const @This(), env: anytype, down: anytype) !void {
            return self.source.run(env, Marking(@TypeOf(down)){ .down = down });
        }

        fn Marking(comptime Down: type) type {
            return struct {
                down: Down,

                pub fn push(marking: @This(), item: S.Item) !Flow {
                    return marking.down.push(if (by_enum) Out{ .source = @field(T, tag), .item = item } else @unionInit(T, tag, item));
                }
            };
        }
    };
}

const Turn = struct {
    mutex: Io.Mutex,
    /// Set once the pipe wants no more or a push failed; every source then stops.
    stopped: bool,
    /// The sources' scope, which is told when the pipe wants no more: a
    /// source that is not pushing would never find out here.
    scope: *tasks.Scope,
};

fn Serialized(comptime T: type, comptime Down: type) type {
    return struct {
        io: Io,
        turn: *Turn,
        down: Down,

        pub fn push(gate: @This(), item: T) !Flow {
            try gate.turn.mutex.lock(gate.io);
            defer gate.turn.mutex.unlock(gate.io);
            if (gate.turn.stopped) return .done;
            errdefer gate.turn.stopped = true;
            if (try gate.down.push(item) == .done) {
                gate.turn.stopped = true;
                gate.turn.scope.done(gate.io);
                return .done;
            }
            return .more;
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
