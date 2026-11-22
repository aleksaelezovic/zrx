//! Operators that keep items in a `std` container, and so need memory.
//!
//!     const busiest = pipe(.{
//!         foldBy(field(.service), @as(u64, 0), count),
//!         top(3, descending(field(.item))),
//!         forEach(report),
//!     });
//!     program(source, busiest).run(.{ gpa, collections.memory(), rescue(fatal) });
//!
//! Written against the operator, handler and resource contracts alone; the
//! core knows nothing of it. None of these is a task boundary.
//!
//! A stage has no hook that runs when a run fails, so a stage cannot own
//! what must be given back then. The memory is a binding instead:
//! `memory()` holds a `std.heap.ArenaAllocator` for the run and provides
//! it as `Memory`, which the operators ask for. Whatever they still hold
//! goes back to the allocator when the run is over, however it ended.
const std = @import("std");
const Allocator = std.mem.Allocator;
const di = @import("../di.zig");
const core = @import("../pipe.zig");
const transform = @import("../ops/transform.zig");
const Tagged = @import("../sources.zig").Tagged;
const Flow = core.Flow;
const lift = core.lift;

// ---------------------------------------------------------------------------
// memory
// ---------------------------------------------------------------------------

/// Where the operators here keep their containers: an arena that lives as
/// long as the run. Bind `memory()` to have one made from the run's
/// `std.mem.Allocator`, or pass one of your own: `Memory{ .arena = &arena }`.
///
/// It is an arena, with what that means: a container that grew leaves its
/// smaller self behind, and everything goes back to the allocator at once,
/// when the arena is freed. `sorted`, `top` and `takeLast` hold one buffer
/// and give it back at the end of their stream, which the arena can use
/// again where nothing was taken from it since; the maps of `distinct` and
/// `foldBy` stay until the arena is freed.
pub const Memory = struct {
    arena: *std.heap.ArenaAllocator,

    fn allocator(held: Memory) Allocator {
        return held.arena.allocator();
    }
};

/// A binding that provides `Memory` for the run: an arena over the
/// `std.mem.Allocator` among the bindings, freed when the run is over,
/// whether it ended or failed.
pub fn memory() Arena {
    return .{};
}

const Arena = struct {
    pub const zrx_resource = {};
    pub const Provides = Memory;
    pub const needs: []const type = &.{Allocator};

    pub fn bind(_: Arena, env: anytype, rest: anytype) !void {
        // Written in place: `.init(...)` left a copy of the arena on the
        // stack that the optimizer did not take out.
        var arena: std.heap.ArenaAllocator = .{ .child_allocator = di.get(env, Allocator), .state = .init };
        defer arena.deinit();
        return rest.call(Memory{ .arena = &arena });
    }
};

fn expectMemory(comptime who: []const u8, comptime keeps: []const u8, comptime Env: type) void {
    if (!di.has(Env, Memory)) @compileError(
        who ++ ": needs `collections.Memory` to keep " ++ keeps ++ " in; bind it with `collections.memory()` and pass an allocator: `run(.{ gpa, collections.memory() })`",
    );
}

// ---------------------------------------------------------------------------
// keys
// ---------------------------------------------------------------------------

/// The item itself, as a handler: the key of an item that is its own key.
/// `distinct(itself)`, `sorted(ascending(itself))`.
pub const itself = struct {
    pub const zrx_handler = {};

    pub fn requires(comptime _: usize) []const type {
        return &.{};
    }

    pub fn call(_: anytype, args: anytype) @TypeOf(args[0]) {
        return args[0];
    }
};

/// A `[]const u8`, or a pointer to an array of bytes.
fn isText(comptime T: type) bool {
    const info = switch (@typeInfo(T)) {
        .pointer => |pointer| pointer,
        else => return false,
    };
    return switch (info.size) {
        .slice => info.child == u8,
        .one => switch (@typeInfo(info.child)) {
            .array => |array| array.child == u8,
            else => false,
        },
        else => false,
    };
}

/// Whether a `T` holds a text of its own and reads it with `text()`, as a
/// `Line` does. Told by name: it is what a caller's own type may declare.
fn holdsText(comptime T: type) bool {
    if (@typeInfo(T) != .@"struct" or !@hasDecl(T, "text")) return false;
    const reads = switch (@typeInfo(@TypeOf(T.text))) {
        .@"fn" => |reads| reads,
        else => return false,
    };
    return reads.param_types.len == 1 and reads.param_types[0] == *const T and reads.return_type == []const u8;
}

/// Whether two values of `T` are the same key exactly when all of their
/// parts are equal: nothing in it points elsewhere, and nothing in it is
/// equal to itself only sometimes, as a float is.
fn keptWhole(comptime T: type) bool {
    @setEvalBranchQuota(di.quota);
    return switch (@typeInfo(T)) {
        .bool, .int, .@"enum" => true,
        .optional => |optional| keptWhole(optional.child),
        .array => |array| keptWhole(array.child),
        .@"struct" => |fields| for (fields.field_types) |Field| {
            if (!keptWhole(Field)) break false;
        } else true,
        else => false,
    };
}

/// How the keys a handler returns as `Returned` are kept and told apart.
/// Read in one place by every operator that takes a key.
fn Keys(comptime who: []const u8, comptime Returned: type) type {
    const K = di.Payload(Returned);
    const kind: enum { whole, bytes, text } = if (isText(K)) .bytes else if (holdsText(K)) .text else if (keptWhole(K)) .whole else @compileError(
        who ++ ": a key of type `" ++ @typeName(K) ++ "` cannot be kept and told from another; a key is an integer, an enum, a `bool`, " ++
            "a struct, array or optional of those, or text: a `[]const u8`, or a value that reads its text with `text()`, such as a `Line`",
    );
    return struct {
        /// The key as it is kept, and as `foldBy` hands it on.
        const Key = if (kind == .bytes) []const u8 else K;
        /// A `[]const u8` may point into something that is gone after the
        /// push, so the first of each is copied into the arena.
        const copied = kind == .bytes;

        /// Keys in the order they were first seen, each with a `V`.
        fn Map(comptime V: type) type {
            return switch (kind) {
                .whole => std.array_hash_map.Auto(K, V),
                .bytes => std.array_hash_map.String(V),
                .text => std.array_hash_map.Custom(K, V, struct {
                    pub fn hash(_: @This(), key: K) u32 {
                        return std.array_hash_map.hashString(key.text());
                    }
                    pub fn eql(_: @This(), a: K, b: K, _: usize) bool {
                        return std.mem.eql(u8, a.text(), b.text());
                    }
                }, true),
            };
        }
    };
}

// ---------------------------------------------------------------------------
// distinct
// ---------------------------------------------------------------------------

/// Passes an item the first time its key is seen and drops it every time
/// after: `distinct(itself)`, `distinct(field(.id))`. `key(deps..., item)`
/// returns the key.
///
/// Holds every key it has seen, until the run is over. A key counts as
/// seen whatever became of its item further down.
pub fn distinct(comptime key: anytype) Distinct(key) {
    return .{};
}

fn Distinct(comptime key: anytype) type {
    return struct {
        const Op = @This();
        pub const zrx_operator = {};
        pub const name = "distinct";

        pub fn Out(comptime Env: type, comptime In: type) type {
            expectMemory(name, "the keys it has seen", Env);
            _ = Keys(name, di.Bound(name, key, Env, &.{In}).Return);
            return In;
        }

        pub fn Stage(comptime Env: type, comptime In: type) type {
            const Call = di.Bound(name, key, Env, &.{In});
            const Kept = Keys(name, Call.Return);
            return struct {
                call: Call,
                memory: Memory,
                seen: Kept.Map(void),

                pub fn init(self: *@This(), _: *const Op, env: Env) void {
                    self.* = .{ .call = .init(env), .memory = di.get(env, Memory), .seen = .empty };
                }

                pub fn push(self: *@This(), item: In, down: anytype) !Flow {
                    const gpa = self.memory.allocator();
                    const found = try self.seen.getOrPut(gpa, try lift(self.call.call(.{item})));
                    if (found.found_existing) return .more;
                    if (Kept.copied) found.key_ptr.* = gpa.dupe(u8, found.key_ptr.*) catch |err| {
                        _ = self.seen.pop();
                        return err;
                    };
                    return down.push(item);
                }
            };
        }
    };
}

// ---------------------------------------------------------------------------
// foldBy
// ---------------------------------------------------------------------------

/// `fold`, once for every key: each item is folded into the state of its
/// key, `state = reducer(deps..., state, item)`, starting from `seed`. When
/// the stream ends, every key goes on with its state as a
/// `Tagged(Key, State)`, `.source` the key and `.item` the state, in the
/// order the keys were first seen.
///
/// Holds one key and one state for every key, until the run is over.
/// An item whose reducer fails leaves no trace: its key keeps the state it
/// had, and a key that had none is forgotten.
pub fn foldBy(comptime key: anytype, seed: anytype, comptime reducer: anytype) FoldBy(key, State(reducer, @TypeOf(seed)), reducer) {
    return .{ .seed = seed };
}

/// The state type: the reducer's declared state parameter, else the seed's
/// type, as for `fold`.
fn State(comptime reducer: anytype, comptime Seed: type) type {
    if (!di.isHandler(reducer)) @compileError("foldBy: expected a reducer `fn (deps..., state, item) state`, got `" ++ @typeName(@TypeOf(reducer)) ++ "`");
    return di.Param("foldBy", reducer, 2, 0) orelse Seed;
}

fn FoldBy(comptime key: anytype, comptime A: type, comptime reducer: anytype) type {
    return struct {
        seed: A,

        const Op = @This();
        pub const zrx_operator = {};
        pub const name = "foldBy";

        pub fn Out(comptime Env: type, comptime In: type) type {
            expectMemory(name, "a state for every key", Env);
            const Kept = Keys(name, di.Bound(name, key, Env, &.{In}).Return);
            transform.expectReturn(name, "reducer", di.Bound(name, reducer, Env, &.{ A, In }).Return, A);
            return Tagged(Kept.Key, A);
        }

        pub fn Stage(comptime Env: type, comptime In: type) type {
            const KeyOf = di.Bound(name, key, Env, &.{In});
            const Reduce = di.Bound(name, reducer, Env, &.{ A, In });
            const Kept = Keys(name, KeyOf.Return);
            const fallible = @typeInfo(Reduce.Return) == .error_union;
            return struct {
                key: KeyOf,
                reduce: Reduce,
                memory: Memory,
                seed: A,
                states: Kept.Map(A),

                pub fn init(self: *@This(), op: *const Op, env: Env) void {
                    self.* = .{ .key = .init(env), .reduce = .init(env), .memory = di.get(env, Memory), .seed = op.seed, .states = .empty };
                }

                pub fn push(self: *@This(), item: In, _: anytype) !Flow {
                    const gpa = self.memory.allocator();
                    const found = try self.states.getOrPut(gpa, try lift(self.key.call(.{item})));
                    if (!found.found_existing) {
                        if (Kept.copied) found.key_ptr.* = gpa.dupe(u8, found.key_ptr.*) catch |err| {
                            _ = self.states.pop();
                            return err;
                        };
                        found.value_ptr.* = self.seed;
                    }
                    if (fallible) {
                        found.value_ptr.* = self.reduce.call(.{ found.value_ptr.*, item }) catch |err| {
                            if (!found.found_existing) _ = self.states.pop();
                            return err;
                        };
                    } else {
                        found.value_ptr.* = self.reduce.call(.{ found.value_ptr.*, item });
                    }
                    return .more;
                }

                pub fn finish(self: *@This(), down: anytype) !void {
                    for (self.states.keys(), self.states.values()) |of, state| {
                        if (try down.push(.{ .source = of, .item = state }) == .done) return;
                    }
                }
            };
        }
    };
}

// ---------------------------------------------------------------------------
// orders
// ---------------------------------------------------------------------------

/// An order by a key, smallest first: of two items, the one whose
/// `key(deps..., item)` is smaller comes first. For `sorted` and `top`.
/// Text is ordered byte by byte, an enum by the values of its tags.
pub fn ascending(comptime key: anytype) type {
    return Ordered("ascending", key, false);
}

/// An order by a key, largest first.
pub fn descending(comptime key: anytype) type {
    return Ordered("descending", key, true);
}

fn Ordered(comptime who: []const u8, comptime key: anytype, comptime reversed: bool) type {
    // Checks the key's shape where the order is written, not where it is used.
    _ = di.requires(who, key, 1);
    return struct {
        pub const zrx_handler = {};

        pub fn requires(comptime arity: usize) []const type {
            expectTwo(arity);
            return di.requires(who, key, 1);
        }

        pub fn call(env: anytype, args: anytype) Answer(di.types(@TypeOf(args))) {
            const first = di.invoke(key, env, .{args[0]});
            const second = di.invoke(key, env, .{args[1]});
            const fallible = comptime @typeInfo(@TypeOf(first)) == .error_union;
            const a = if (fallible) try first else first;
            const b = if (fallible) try second else second;
            return if (reversed) smaller(b, a) else smaller(a, b);
        }

        fn expectTwo(comptime arity: usize) void {
            if (arity != 2) @compileError(std.fmt.comptimePrint(
                "{s}: says which of two items comes first, but receives {d} values here; use it where an order is taken, as in `sorted({s}(key))`",
                .{ who, arity, who },
            ));
        }

        fn Answer(comptime Args: []const type) type {
            @setEvalBranchQuota(di.quota);
            expectTwo(Args.len);
            const R = di.Result(who, key, &.{Args[0]});
            const K = di.Payload(R);
            const ordered = isText(K) or holdsText(K) or switch (@typeInfo(K)) {
                .int, .float, .@"enum" => true,
                else => false,
            };
            if (!ordered) @compileError(
                who ++ ": a key of type `" ++ @typeName(K) ++ "` has no order here; a key is an integer, a float, an enum, or text: a `[]const u8`, " ++
                    "or a value that reads its text with `text()`. For anything else write the order yourself: `fn (a: Item, b: Item) bool`, true when `a` comes first",
            );
            return if (@typeInfo(R) == .error_union) @typeInfo(R).error_union.error_set!bool else bool;
        }
    };
}

fn smaller(a: anytype, b: @TypeOf(a)) bool {
    const K = @TypeOf(a);
    if (comptime isText(K)) return std.mem.lessThan(u8, a, b);
    if (comptime holdsText(K)) return std.mem.lessThan(u8, a.text(), b.text());
    return if (@typeInfo(K) == .@"enum") @backingInt(a) < @backingInt(b) else a < b;
}

/// Requires an order: a handler of two items that answers `bool` and cannot
/// fail. `usage` is the operator as one writes it with a key.
fn expectOrder(comptime who: []const u8, comptime usage: []const u8, comptime R: type) void {
    if (di.Payload(R) != bool) @compileError(
        who ++ ": the order must return `bool`, true when its first item comes before its second, got `" ++ @typeName(R) ++
            "`; to order by a key, write `" ++ usage ++ "` or `descending(key)`",
    );
    if (@typeInfo(R) == .error_union) @compileError(
        who ++ ": the order can fail (`" ++ @typeName(R) ++ "`), but it is asked while items are put in order, where a failure has nowhere to go; " ++
            "do what can fail in a `map` before " ++ who,
    );
}

// ---------------------------------------------------------------------------
// sorted
// ---------------------------------------------------------------------------

/// Keeps every item and, when the stream ends, pushes them in order.
/// `before(deps..., a, b)` says whether `a` comes before `b`:
/// `sorted(ascending(field(.cents)))`, or a function of your own. Items
/// of which neither comes before the other keep the order they arrived in.
///
/// Holds the whole stream until its end.
pub fn sorted(comptime before: anytype) Sorted(before) {
    return .{};
}

fn Sorted(comptime before: anytype) type {
    return struct {
        const Op = @This();
        pub const zrx_operator = {};
        pub const name = "sorted";

        pub fn Out(comptime Env: type, comptime In: type) type {
            expectMemory(name, "the items", Env);
            expectOrder(name, "sorted(ascending(key))", di.Bound(name, before, Env, &.{ In, In }).Return);
            return In;
        }

        pub fn Stage(comptime Env: type, comptime In: type) type {
            const Call = di.Bound(name, before, Env, &.{ In, In });
            return struct {
                call: Call,
                memory: Memory,
                items: std.ArrayList(In),

                pub fn init(self: *@This(), _: *const Op, env: Env) void {
                    self.* = .{ .call = .init(env), .memory = di.get(env, Memory), .items = .empty };
                }

                pub fn push(self: *@This(), item: In, _: anytype) !Flow {
                    try self.items.append(self.memory.allocator(), item);
                    return .more;
                }

                pub fn finish(self: *@This(), down: anytype) !void {
                    defer self.items.clearAndFree(self.memory.allocator());
                    std.mem.sort(In, self.items.items, self.call, comesBefore);
                    for (self.items.items) |item| {
                        if (try down.push(item) == .done) return;
                    }
                }

                fn comesBefore(call: Call, a: In, b: In) bool {
                    return call.call(.{ a, b });
                }
            };
        }
    };
}

// ---------------------------------------------------------------------------
// top
// ---------------------------------------------------------------------------

/// The first `count` items of the order `before`, pushed in that order when
/// the stream ends: `top(3, descending(field(.cents)))` is the three
/// largest, largest first. It emits what `sorted(before)` followed by
/// `take(count)` emits, and keeps `count` items where that keeps all.
///
/// Holds `count` items, and an arrival number with each, from the first
/// item until the end of the stream.
pub fn top(count: usize, comptime before: anytype) Top(before) {
    return .{ .count = count };
}

fn Top(comptime before: anytype) type {
    return struct {
        count: usize,

        const Op = @This();
        pub const zrx_operator = {};
        pub const name = "top";

        pub fn Out(comptime Env: type, comptime In: type) type {
            expectMemory(name, "the items", Env);
            expectOrder(name, "top(n, ascending(key))", di.Bound(name, before, Env, &.{ In, In }).Return);
            return In;
        }

        pub fn Stage(comptime Env: type, comptime In: type) type {
            const Call = di.Bound(name, before, Env, &.{ In, In });
            return struct {
                memory: Memory,
                limit: usize,
                arrived: usize,
                /// The kept items, the last of them in the order at the root.
                kept: Heap,

                /// An item and when it came: of two that the order does not
                /// tell apart, the earlier comes first, as in `sorted`.
                const Entry = struct { item: In, at: usize };
                const Heap = std.PriorityQueue(Entry, Call, lastFirst);

                fn comesBefore(call: Call, a: Entry, b: Entry) bool {
                    if (call.call(.{ a.item, b.item })) return true;
                    if (call.call(.{ b.item, a.item })) return false;
                    return a.at < b.at;
                }

                fn lastFirst(call: Call, a: Entry, b: Entry) std.math.Order {
                    return if (comesBefore(call, b, a)) .lt else .gt;
                }

                pub fn init(self: *@This(), op: *const Op, env: Env) void {
                    self.* = .{ .memory = di.get(env, Memory), .limit = op.count, .arrived = 0, .kept = .initContext(.init(env)) };
                }

                pub fn push(self: *@This(), item: In, _: anytype) !Flow {
                    if (self.limit == 0) return .done;
                    const gpa = self.memory.allocator();
                    const entry: Entry = .{ .item = item, .at = self.arrived };
                    self.arrived += 1;
                    if (self.kept.count() == self.limit) {
                        // Later than all that are kept: it takes the place of
                        // the last of them only if it comes before that one.
                        if (!self.kept.context.call(.{ item, self.kept.items[0].item })) return .more;
                        _ = self.kept.pop();
                    } else {
                        try self.kept.ensureTotalCapacityPrecise(gpa, self.limit);
                    }
                    try self.kept.push(gpa, entry);
                    return .more;
                }

                pub fn finish(self: *@This(), down: anytype) !void {
                    defer self.kept.clearAndFree(self.memory.allocator());
                    std.mem.sort(Entry, self.kept.items, self.kept.context, comesBefore);
                    for (self.kept.items) |entry| {
                        if (try down.push(entry.item) == .done) return;
                    }
                }
            };
        }
    };
}

// ---------------------------------------------------------------------------
// takeLast
// ---------------------------------------------------------------------------

/// The last `count` items, pushed in the order they came when the stream
/// ends. Where `take` stops the source, this has to see all of it.
///
/// Holds `count` items, from the first item until the end of the stream.
pub fn takeLast(count: usize) TakeLast {
    return .{ .count = count };
}

const TakeLast = struct {
    count: usize,

    pub const zrx_operator = {};
    pub const name = "takeLast";

    pub fn Out(comptime Env: type, comptime In: type) type {
        expectMemory(name, "the items", Env);
        return In;
    }

    pub fn Stage(comptime Env: type, comptime In: type) type {
        return struct {
            memory: Memory,
            limit: usize,
            last: std.Deque(In),

            pub fn init(self: *@This(), op: *const TakeLast, env: Env) void {
                self.* = .{ .memory = di.get(env, Memory), .limit = op.count, .last = .empty };
            }

            pub fn push(self: *@This(), item: In, _: anytype) !Flow {
                if (self.limit == 0) return .done;
                if (self.last.len == self.limit) {
                    _ = self.last.popFront();
                } else {
                    try self.last.ensureTotalCapacityPrecise(self.memory.allocator(), self.limit);
                }
                self.last.pushBackAssumeCapacity(item);
                return .more;
            }

            pub fn finish(self: *@This(), down: anytype) !void {
                defer self.last.deinit(self.memory.allocator());
                var items = self.last.iterator();
                while (items.next()) |item| {
                    if (try down.push(item) == .done) return;
                }
            }
        };
    }
};
