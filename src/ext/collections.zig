//! Operators that keep items, each in room that is written where it is.
//!
//!     const busiest = pipe(.{
//!         foldBy(64, field(.service), @as(u64, 0), count),
//!         top(3, descending(field(.item))),
//!         forEach(report),
//!     });
//!     program(source, busiest).run(.{ rescue(fatal) });
//!
//! Written against the operator and handler contracts alone; the core knows
//! nothing of it. None of these is a task boundary, and none uses an
//! allocator: every count is known at compile time and the room is part of
//! a stage, as the buffer of a `queue(n)` or a `Batch(T, n)` is. An item
//! that does not fit fails with an error that has a name, `TooManyItems` or
//! `TooManyKeys`, where it is pushed, so an error path before the operator
//! can take it.
const std = @import("std");
const di = @import("../di.zig");
const core = @import("../pipe.zig");
const transform = @import("../ops/transform.zig");
const Tagged = @import("../sources.zig").Tagged;
const Flow = core.Flow;
const lift = core.lift;

/// Requires room for at least one. `usage` is the operator as one writes it.
fn expectRoom(comptime who: []const u8, comptime of: []const u8, comptime usage: []const u8, comptime count: usize) void {
    if (count == 0) @compileError(who ++ ": has room for 0 " ++ of ++ "; write a count of at least 1, as in `" ++ usage ++ "`");
}

/// What `Room` hands on: the item, and where the operator keeps things.
fn Given(comptime In: type, comptime Held: type) type {
    return struct { item: In, room: *Held };
}

fn ItemOf(comptime Got: type) type {
    return @FieldType(Got, "item");
}

fn HeldOf(comptime Got: type) type {
    return @typeInfo(@FieldType(Got, "room")).pointer.child;
}

/// The first of the two stages every operator here is made of: room for a
/// `Held(Env, In)` and nothing else. It hands each item on with a pointer
/// to that room, and the stage after it does the work through the pointer.
/// Two stages, for the reason `batch` has two: a stage with an array that
/// is indexed is kept in memory as a whole, counters and all, so the
/// arrays are alone in this one and the counters are in the next, where
/// the optimizer keeps them in registers.
fn Room(comptime who: []const u8, comptime Held: fn (comptime type, comptime type) type) type {
    return struct {
        const Op = @This();
        pub const zrx_operator = {};
        pub const name = who;

        pub fn Out(comptime Env: type, comptime In: type) type {
            return Given(In, Held(Env, In));
        }

        pub fn Stage(comptime Env: type, comptime In: type) type {
            const Holds = Held(Env, In);
            return struct {
                held: Holds,

                /// Written where it stands, and only what has to be: a
                /// table marks its places empty, and nothing else is read
                /// before it is written.
                pub fn init(self: *@This(), _: *const Op, _: Env) void {
                    if (@typeInfo(Holds) == .@"struct" and @hasDecl(Holds, "clear")) self.held.clear();
                }

                pub fn push(self: *@This(), item: In, down: anytype) !Flow {
                    return down.push(.{ .item = item, .room = &self.held });
                }
            };
        }
    };
}

/// Room for `count` items.
fn Items(comptime count: usize) fn (comptime type, comptime type) type {
    return struct {
        fn Held(comptime _: type, comptime In: type) type {
            return [count]In;
        }
    }.Held;
}

// ---------------------------------------------------------------------------
// keys
// ---------------------------------------------------------------------------

/// The item itself, as a handler: the key of an item that is its own key.
/// `distinct(64, itself)`, `sorted(64, ascending(itself))`.
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

/// Whether there is a pointer anywhere in a `T`: such a value borrows, and
/// what it points at may be gone when the next item comes.
fn holdsPointer(comptime T: type) bool {
    @setEvalBranchQuota(di.quota);
    return switch (@typeInfo(T)) {
        .pointer => true,
        .optional => |optional| holdsPointer(optional.child),
        .array => |array| holdsPointer(array.child),
        .vector => |vector| holdsPointer(vector.child),
        .error_union => |fallible| holdsPointer(fallible.payload),
        .@"struct" => |fields| for (fields.field_types) |Field| {
            if (holdsPointer(Field)) break true;
        } else false,
        .@"union" => |fields| for (fields.field_types) |Field| {
            if (holdsPointer(Field)) break true;
        } else false,
        else => false,
    };
}

/// Whether two values of `T` are the same key exactly when all of their
/// parts are equal: nothing in it is equal to itself only sometimes, as a
/// float is.
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

/// How the keys a handler returns as `Returned` are told apart. Read in one
/// place by every operator that takes a key. A key is kept after its item
/// is gone and nothing is copied for it, so it is a value.
fn Keys(comptime who: []const u8, comptime Returned: type) type {
    const K = di.Payload(Returned);
    if (holdsPointer(K)) @compileError(
        who ++ ": a key of type `" ++ @typeName(K) ++ "` points at memory that may be gone when the next item comes, and a key is kept; " ++
            "return a value that holds what it needs, for text a `Line`: `Line(64).from(text)`",
    );
    const by_text = holdsText(K);
    if (!by_text and !keptWhole(K)) @compileError(
        who ++ ": a key of type `" ++ @typeName(K) ++ "` cannot be kept and told from another; a key is an integer, an enum, a `bool`, " ++
            "a struct, array or optional of those, or a value that reads its text with `text()`, such as a `Line`",
    );
    return struct {
        const Key = K;
        const Whole = std.array_hash_map.AutoContext(K);

        fn hash(key: K) u32 {
            return if (by_text) std.array_hash_map.hashString(key.text()) else Whole.hash(.{}, key);
        }

        fn same(a: K, b: K) bool {
            return if (by_text) std.mem.eql(u8, a.text(), b.text()) else Whole.eql(.{}, a, b, 0);
        }
    };
}

/// Room for `room` keys, kept in the order they were first seen and found
/// again by their hash. `std`'s hash maps take their room from an allocator
/// and say nowhere how many bytes a capacity comes to, so this is a table
/// of this extension's own: the hash and the comparison are `std`'s, the
/// places and the walk over them are written here. A place holds zero, or
/// one more than the index of its key. There are at least twice as many
/// places as keys, so a walk always ends at an empty one. How many keys it
/// holds is not in the table: whoever keeps a key says which one it is.
/// `usage` is the operator as one writes it, for the error.
fn Table(comptime who: []const u8, comptime usage: []const u8, comptime Kept: type, comptime room: usize) type {
    const K = Kept.Key;
    // Twice the room is a power of two that a `usize` counts up to this.
    const places = if (room <= std.math.maxInt(usize) / 4 + 1) std.math.ceilPowerOfTwoAssert(usize, room * 2) else @compileError(std.fmt.comptimePrint(
        "{s}: room for {d} keys does not fit in memory: its table has at least twice as many places, more than a `usize` counts; " ++
            "write a count the stack has room for, as in `{s}`",
        .{ who, room, usage },
    ));
    const Number = if (room < 1 << 8) u8 else if (room < 1 << 16) u16 else if (room < 1 << 32) u32 else usize;
    return struct {
        keys: [room]K,
        places: [places]Number,

        /// Where a key is, or where it would go: `index` is null for a
        /// key that is not kept, and `place` is then the empty place.
        const Found = struct { place: usize, index: ?usize };

        pub fn clear(table: *@This()) void {
            @memset(&table.places, 0);
        }

        fn find(table: *const @This(), key: K) Found {
            var place: usize = Kept.hash(key) & (places - 1);
            while (true) : (place = (place + 1) & (places - 1)) {
                const number = table.places[place];
                if (number == 0) return .{ .place = place, .index = null };
                if (Kept.same(table.keys[number - 1], key)) return .{ .place = place, .index = number - 1 };
            }
        }

        /// Keeps a key that `find` did not find, as the key at `index`:
        /// that many are kept, and there is room for one more.
        fn keep(table: *@This(), found: Found, index: usize, key: K) void {
            table.keys[index] = key;
            table.places[found.place] = @intCast(index + 1);
        }
    };
}

// ---------------------------------------------------------------------------
// distinct
// ---------------------------------------------------------------------------

/// Passes an item the first time its key is seen and drops it every time
/// after: `distinct(1024, itself)`, `distinct(1024, field(.id))`.
/// `key(deps..., item)` returns the key.
///
/// Holds room for `room` keys. The item that brings one key more fails with
/// `error.TooManyKeys`, and so does every later item with a key not seen:
/// those already seen are dropped as before. A key counts as seen whatever
/// became of its item further down.
pub fn distinct(comptime room: usize, comptime key: anytype) core.Spliced("distinct", @Tuple(&.{ Room("distinct", Seen(room, key)), Distinct(room, key) })) {
    expectRoom("distinct", "keys", "distinct(1024, key)", room);
    return .{ .ops = .{ .{}, .{} } };
}

fn Seen(comptime room: usize, comptime key: anytype) fn (comptime type, comptime type) type {
    return struct {
        fn Held(comptime Env: type, comptime In: type) type {
            return Table("distinct", "distinct(1024, key)", Keys("distinct", di.Bound("distinct", key, Env, &.{In}).Return), room);
        }
    }.Held;
}

fn Distinct(comptime room: usize, comptime key: anytype) type {
    return struct {
        const Op = @This();
        pub const zrx_operator = {};
        pub const name = "distinct";

        pub fn Out(comptime _: type, comptime Got: type) type {
            return ItemOf(Got);
        }

        pub fn Stage(comptime Env: type, comptime Got: type) type {
            const Call = di.Bound(name, key, Env, &.{ItemOf(Got)});
            return struct {
                call: Call,
                len: usize,

                pub fn init(self: *@This(), _: *const Op, env: Env) void {
                    self.* = .{ .call = .init(env), .len = 0 };
                }

                pub fn push(self: *@This(), given: Got, down: anytype) !Flow {
                    const of = try lift(self.call.call(.{given.item}));
                    const found = given.room.find(of);
                    if (found.index != null) return .more;
                    const index = self.len;
                    if (index == room) return error.TooManyKeys;
                    given.room.keep(found, index, of);
                    self.len = index + 1;
                    return down.push(given.item);
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
/// Holds room for `room` keys and their states. An item with one key more
/// fails with `error.TooManyKeys` and its reducer is not asked. An item
/// whose reducer fails leaves no trace: its key keeps the state it had,
/// and a key that had none takes no room.
pub fn foldBy(
    comptime room: usize,
    comptime key: anytype,
    seed: anytype,
    comptime reducer: anytype,
) core.Spliced("foldBy", @Tuple(&.{ Room("foldBy", Folded(room, key, State(reducer, @TypeOf(seed)))), FoldBy(room, key, State(reducer, @TypeOf(seed)), reducer) })) {
    expectRoom("foldBy", "keys", "foldBy(1024, key, seed, reducer)", room);
    return .{ .ops = .{ .{}, .{ .seed = seed } } };
}

/// The state type: the reducer's declared state parameter, else the seed's
/// type, as for `fold`.
fn State(comptime reducer: anytype, comptime Seed: type) type {
    if (!di.isHandler(reducer)) @compileError("foldBy: expected a reducer `fn (deps..., state, item) state`, got `" ++ @typeName(@TypeOf(reducer)) ++ "`");
    return di.Param("foldBy", reducer, 2, 0) orelse Seed;
}

/// The keys of `foldBy` and a state for each.
fn Folded(comptime room: usize, comptime key: anytype, comptime A: type) fn (comptime type, comptime type) type {
    return struct {
        fn Held(comptime Env: type, comptime In: type) type {
            const Kept = Keys("foldBy", di.Bound("foldBy", key, Env, &.{In}).Return);
            return struct {
                keys: Table("foldBy", "foldBy(1024, key, seed, reducer)", Kept, room),
                states: [room]A,

                const Key = Kept.Key;

                pub fn clear(held: *@This()) void {
                    held.keys.clear();
                }
            };
        }
    }.Held;
}

fn FoldBy(comptime room: usize, comptime key: anytype, comptime A: type, comptime reducer: anytype) type {
    return struct {
        seed: A,

        const Op = @This();
        pub const zrx_operator = {};
        pub const name = "foldBy";

        pub fn Out(comptime Env: type, comptime Got: type) type {
            transform.expectReturn(name, "reducer", di.Bound(name, reducer, Env, &.{ A, ItemOf(Got) }).Return, A);
            return Tagged(HeldOf(Got).Key, A);
        }

        pub fn Stage(comptime Env: type, comptime Got: type) type {
            const In = ItemOf(Got);
            const KeyOf = di.Bound(name, key, Env, &.{In});
            const Reduce = di.Bound(name, reducer, Env, &.{ A, In });
            return struct {
                key: KeyOf,
                reduce: Reduce,
                seed: A,
                len: usize,
                /// Where the keys and states are, for the end of the
                /// stream: told with every item, and not looked at while
                /// no key is kept.
                room: *HeldOf(Got),

                pub fn init(self: *@This(), op: *const Op, env: Env) void {
                    self.* = .{ .key = .init(env), .reduce = .init(env), .seed = op.seed, .len = 0, .room = undefined };
                }

                /// The reducer is asked before anything is written: an item
                /// it rejects leaves the table exactly as it was.
                pub fn push(self: *@This(), given: Got, _: anytype) !Flow {
                    const of = try lift(self.key.call(.{given.item}));
                    const found = given.room.keys.find(of);
                    if (found.index) |index| {
                        given.room.states[index] = try lift(self.reduce.call(.{ given.room.states[index], given.item }));
                        return .more;
                    }
                    const index = self.len;
                    if (index == room) return error.TooManyKeys;
                    const first = try lift(self.reduce.call(.{ self.seed, given.item }));
                    given.room.keys.keep(found, index, of);
                    given.room.states[index] = first;
                    self.len = index + 1;
                    self.room = given.room;
                    return .more;
                }

                pub fn finish(self: *@This(), down: anytype) !void {
                    for (0..self.len) |index| {
                        if (try down.push(.{ .source = self.room.keys.keys[index], .item = self.room.states[index] }) == .done) return;
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
/// Text is ordered byte by byte, an enum by the values of its tags. A float
/// that is not a number comes after every number.
pub fn ascending(comptime key: anytype) type {
    return Ordered("ascending", key, false);
}

/// An order by a key, largest first. A float that is not a number comes
/// after every number here too: it is last in both orders, not largest.
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
            return keyBefore(reversed, a, b);
        }

        fn expectTwo(comptime arity: usize) void {
            if (arity != 2) @compileError(std.fmt.comptimePrint(
                "{s}: says which of two items comes first, but receives {d} values here; use it where an order is taken, as in `sorted(n, {s}(key))`",
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

/// Whether the key `a` comes before the key `b`: the one place that
/// compares two keys, for both orders. It has to be an order that `sorted`
/// and `top` can both follow: when neither of two keys comes before the
/// other, they stand at the same place towards every third. `<` alone is
/// not that for floats, where a NaN is neither smaller nor larger than
/// anything. So a NaN comes after every number, whichever way the order
/// goes, and no NaN before another.
fn keyBefore(comptime reversed: bool, a: anytype, b: @TypeOf(a)) bool {
    const K = @TypeOf(a);
    if (@typeInfo(K) == .float) {
        if (std.math.isNan(a)) return false;
        if (std.math.isNan(b)) return true;
    }
    const low, const high = if (reversed) .{ b, a } else .{ a, b };
    if (comptime isText(K)) return std.mem.lessThan(u8, low, high);
    if (comptime holdsText(K)) return std.mem.lessThan(u8, low.text(), high.text());
    return if (@typeInfo(K) == .@"enum") @backingInt(low) < @backingInt(high) else low < high;
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
/// `sorted(1024, ascending(field(.cents)))`, or a function of your own.
/// Items of which neither comes before the other keep the order they
/// arrived in.
///
/// Holds room for `room` items. The item after that fails with
/// `error.TooManyItems`, and so does every later one; the items that were
/// kept are still pushed in order at the end.
pub fn sorted(comptime room: usize, comptime before: anytype) core.Spliced("sorted", @Tuple(&.{ Room("sorted", Items(room)), Sorted(room, before) })) {
    expectRoom("sorted", "items", "sorted(1024, order)", room);
    return .{ .ops = .{ .{}, .{} } };
}

fn Sorted(comptime room: usize, comptime before: anytype) type {
    return struct {
        const Op = @This();
        pub const zrx_operator = {};
        pub const name = "sorted";

        pub fn Out(comptime Env: type, comptime Got: type) type {
            const In = ItemOf(Got);
            expectOrder(name, "sorted(n, ascending(key))", di.Bound(name, before, Env, &.{ In, In }).Return);
            return In;
        }

        pub fn Stage(comptime Env: type, comptime Got: type) type {
            const In = ItemOf(Got);
            const Call = di.Bound(name, before, Env, &.{ In, In });
            return struct {
                call: Call,
                len: usize,
                /// Where the items are, for the end of the stream: told
                /// with every item, and not looked at while none is kept.
                room: *[room]In,

                pub fn init(self: *@This(), _: *const Op, env: Env) void {
                    self.* = .{ .call = .init(env), .len = 0, .room = undefined };
                }

                pub fn push(self: *@This(), given: Got, _: anytype) !Flow {
                    const index = self.len;
                    if (index == room) return error.TooManyItems;
                    given.room[index] = given.item;
                    self.len = index + 1;
                    self.room = given.room;
                    return .more;
                }

                pub fn finish(self: *@This(), down: anytype) !void {
                    const kept = self.room[0..self.len];
                    std.mem.sort(In, kept, self.call, comesBefore);
                    for (kept) |item| {
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
/// largest, largest first. It emits what `sorted(n, before)` followed by
/// `take(count)` emits, and needs room for `count` items where that needs
/// room for all.
///
/// Holds room for `count` items and an arrival number with each. It is
/// never full: an item that comes before the last one kept takes its place.
/// When the arrival numbers have run out, the kept items are numbered again.
pub fn top(comptime count: usize, comptime before: anytype) core.Spliced("top", @Tuple(&.{ Room("top", Arrived(count)), Top(count, before) })) {
    expectRoom("top", "items", "top(3, order)", count);
    return .{ .ops = .{ .{}, .{} } };
}

/// An item and when it came: of two that the order does not tell apart,
/// the earlier comes first, as in `sorted`.
fn Arrival(comptime In: type, comptime count: usize) type {
    return struct { item: In, at: Counter(count) };
}

/// The arrival numbers of `top(count, ...)`. They count to at least 256
/// times `count`, and when they have run out the kept entries are numbered
/// again from 0 (`renumber`): once in at least 255 times `count` items.
/// Only the order of two numbers is read, never how far apart they are.
fn Counter(comptime count: usize) type {
    return if (count < 1 << 8) u16 else if (count < 1 << 24) u32 else u64;
}

/// Room for `count` items, each with when it came.
fn Arrived(comptime count: usize) fn (comptime type, comptime type) type {
    return struct {
        fn Held(comptime _: type, comptime In: type) type {
            return [count]Arrival(In, count);
        }
    }.Held;
}

fn Top(comptime count: usize, comptime before: anytype) type {
    return struct {
        const Op = @This();
        pub const zrx_operator = {};
        pub const name = "top";

        pub fn Out(comptime Env: type, comptime Got: type) type {
            const In = ItemOf(Got);
            expectOrder(name, "top(n, ascending(key))", di.Bound(name, before, Env, &.{ In, In }).Return);
            return In;
        }

        pub fn Stage(comptime Env: type, comptime Got: type) type {
            const In = ItemOf(Got);
            const Call = di.Bound(name, before, Env, &.{ In, In });
            const Entry = Arrival(In, count);
            const Number = Counter(count);
            return struct {
                call: Call,
                len: usize,
                arrived: Number,
                /// Where the entries are, for the end of the stream: told
                /// with every item, and not looked at while none is kept.
                room: *[count]Entry,

                /// `std`'s heap over the entries, the last of them in the
                /// order at the root. Its `push` takes an allocator for
                /// when it has to grow; here it never has to, and is given
                /// the one that always fails.
                const Heap = std.PriorityQueue(Entry, Call, lastFirst);

                fn comesBefore(call: Call, a: Entry, b: Entry) bool {
                    if (call.call(.{ a.item, b.item })) return true;
                    if (call.call(.{ b.item, a.item })) return false;
                    return a.at < b.at;
                }

                fn lastFirst(call: Call, a: Entry, b: Entry) std.math.Order {
                    return if (comesBefore(call, b, a)) .lt else .gt;
                }

                pub fn init(self: *@This(), _: *const Op, env: Env) void {
                    self.* = .{ .call = .init(env), .len = 0, .arrived = 0, .room = undefined };
                }

                pub fn push(self: *@This(), given: Got, _: anytype) !Flow {
                    const held = self.len;
                    self.room = given.room;
                    if (self.arrived == std.math.maxInt(Number)) self.arrived = renumber(given.room[0..held], self.call);
                    const at = self.arrived;
                    self.arrived = at + 1;
                    var heap: Heap = .{ .items = given.room[0..held], .cap = count, .context = self.call };
                    if (held == count) {
                        // Later than all that are kept: it takes the place of
                        // the last of them only if it comes before that one.
                        if (!self.call.call(.{ given.item, given.room[0].item })) return .more;
                        _ = heap.pop();
                    } else {
                        self.len = held + 1;
                    }
                    heap.push(.failing, .{ .item = given.item, .at = at }) catch unreachable;
                    return .more;
                }

                pub fn finish(self: *@This(), down: anytype) !void {
                    const kept = self.room[0..self.len];
                    inOrder(kept, self.call);
                    for (kept) |entry| {
                        if (try down.push(entry.item) == .done) return;
                    }
                }

                /// Takes the last of the order off the heap again and again,
                /// each into the place the heap gave up for it: that leaves
                /// the entries in order.
                fn inOrder(kept: []Entry, call: Call) void {
                    var heap: Heap = .{ .items = kept, .cap = count, .context = call };
                    while (heap.pop()) |entry| kept[heap.items.len] = entry;
                }

                /// Numbers the kept entries again from 0, once the numbers
                /// have run out, and returns the next number. A number is
                /// read only for two entries that tie, and two that tie are
                /// next to each other in the order, the earlier first: so
                /// the entries are put in order and numbered along it. In
                /// the opposite order they are a heap again, the last at
                /// the root, as each comes after those below it.
                fn renumber(kept: []Entry, call: Call) Number {
                    inOrder(kept, call);
                    for (kept, 0..) |*entry, at| entry.at = @intCast(at);
                    std.mem.reverse(Entry, kept);
                    return @intCast(kept.len);
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
/// Holds room for `count` items. It is never full: an item takes the place
/// of the oldest one kept.
pub fn takeLast(comptime count: usize) core.Spliced("takeLast", @Tuple(&.{ Room("takeLast", Items(count)), TakeLast(count) })) {
    expectRoom("takeLast", "items", "takeLast(3)", count);
    return .{ .ops = .{ .{}, .{} } };
}

fn TakeLast(comptime count: usize) type {
    return struct {
        const Op = @This();
        pub const zrx_operator = {};
        pub const name = "takeLast";

        pub fn Out(comptime _: type, comptime Got: type) type {
            return ItemOf(Got);
        }

        pub fn Stage(comptime Env: type, comptime Got: type) type {
            return struct {
                /// Where the next item goes: the place of the oldest, once
                /// all places are taken.
                next: usize,
                len: usize,
                /// Where the items are, for the end of the stream: told
                /// with every item, and not looked at while none is kept.
                room: *[count]ItemOf(Got),

                pub fn init(self: *@This(), _: *const Op, _: Env) void {
                    self.* = .{ .next = 0, .len = 0, .room = undefined };
                }

                pub fn push(self: *@This(), given: Got, _: anytype) !Flow {
                    const index = self.next;
                    given.room[index] = given.item;
                    self.next = if (index + 1 == count) 0 else index + 1;
                    if (self.len != count) self.len += 1;
                    self.room = given.room;
                    return .more;
                }

                pub fn finish(self: *@This(), down: anytype) !void {
                    var index = if (self.len == count) self.next else 0;
                    for (0..self.len) |_| {
                        if (try down.push(self.room[index]) == .done) return;
                        index = if (index + 1 == count) 0 else index + 1;
                    }
                }
            };
        }
    };
}
