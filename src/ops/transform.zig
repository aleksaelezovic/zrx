//! Per-item operators: each one is a small state plus a `push`.
const std = @import("std");
const di = @import("../di.zig");
const core = @import("../pipe.zig");
const Flow = core.Flow;
const End = core.End;
const lift = core.lift;

/// Replaces each item with `handler(deps..., item)`. A returned error fails the run.
pub fn map(comptime handler: anytype) Map(handler) {
    return .{};
}

fn Map(comptime handler: anytype) type {
    return struct {
        const Op = @This();
        pub const zrx_operator = {};
        pub const name = "map";

        pub fn Out(comptime Env: type, comptime In: type) type {
            const T = di.Payload(di.Bound(name, handler, Env, &.{In}).Return);
            if (T == void) @compileError("map: handler returns no value; use tap(...) for an effect that keeps the item, or forEach(...) to end the pipe");
            return T;
        }

        pub fn Stage(comptime Env: type, comptime In: type) type {
            const Call = di.Bound(name, handler, Env, &.{In});
            return struct {
                call: Call,

                pub fn init(self: *@This(), _: *const Op, env: Env) void {
                    self.call = .init(env);
                }

                pub fn push(self: *@This(), item: In, down: anytype) !Flow {
                    return down.push(try lift(self.call.call(.{item})));
                }
            };
        }
    };
}

/// Keeps the items for which `predicate(deps..., item)` is true.
pub fn filter(comptime predicate: anytype) Filter(predicate) {
    return .{};
}

fn Filter(comptime predicate: anytype) type {
    return struct {
        const Op = @This();
        pub const zrx_operator = {};
        pub const name = "filter";

        pub fn Out(comptime Env: type, comptime In: type) type {
            expectHolds(name, di.Bound(name, predicate, Env, &.{In}).Return, route_instead);
            return In;
        }

        pub fn Stage(comptime Env: type, comptime In: type) type {
            const Call = di.Bound(name, predicate, Env, &.{In});
            return struct {
                call: Call,

                pub fn init(self: *@This(), _: *const Op, env: Env) void {
                    self.call = .init(env);
                }

                pub fn push(self: *@This(), item: In, down: anytype) !Flow {
                    if (!try lift(self.call.call(.{item}))) return .more;
                    return down.push(item);
                }
            };
        }
    };
}

/// Runs `handler(deps..., item)` for its effect and passes the item on unchanged.
pub fn tap(comptime handler: anytype) Tap(handler) {
    return .{};
}

fn Tap(comptime handler: anytype) type {
    return struct {
        const Op = @This();
        pub const zrx_operator = {};
        pub const name = "tap";

        pub fn Out(comptime Env: type, comptime In: type) type {
            expectReturn(name, "handler", di.Bound(name, handler, Env, &.{In}).Return, void);
            return In;
        }

        pub fn Stage(comptime Env: type, comptime In: type) type {
            const Call = di.Bound(name, handler, Env, &.{In});
            return struct {
                call: Call,

                pub fn init(self: *@This(), _: *const Op, env: Env) void {
                    self.call = .init(env);
                }

                pub fn push(self: *@This(), item: In, down: anytype) !Flow {
                    try lift(self.call.call(.{item}));
                    return down.push(item);
                }
            };
        }
    };
}

/// Running accumulation: emits `state = reducer(deps..., state, item)` after every item.
pub fn scan(seed: anytype, comptime reducer: anytype) Accumulate(.scan, Stated(reducer, @TypeOf(seed)) orelse Untyped(seed), reducer) {
    return .{ .seed = if (comptime Stated(reducer, @TypeOf(seed)) != null) seed else .{} };
}

/// Final accumulation: emits the last state once, when the stream ends
/// (the seed itself if there were no items).
pub fn fold(seed: anytype, comptime reducer: anytype) Accumulate(.fold, Stated(reducer, @TypeOf(seed)) orelse Untyped(seed), reducer) {
    return .{ .seed = if (comptime Stated(reducer, @TypeOf(seed)) != null) seed else .{} };
}

fn Stated(comptime reducer: anytype, comptime Seed: type) ?type {
    if (!di.isHandler(reducer)) @compileError("scan/fold: expected a reducer `fn (deps..., state, item) state`, got `" ++ @typeName(@TypeOf(reducer)) ++ "`");
    return State("scan/fold", reducer, Seed);
}

/// The type a reducer accumulates in, where that can be told without the
/// items: the state parameter the reducer declares, else the type of the
/// seed. A number written without a type (`0`) has none to give, so with
/// such a seed the reducer has to say: a composite one may declare
/// `State(Item) type`, what it accumulates items of type `Item` in, and
/// this is null until the items are known (`Inferred`). A seed that has a
/// type is never overruled by that declaration: `@as(u64, 0)` is how a
/// wider accumulator is chosen.
pub fn State(comptime who: []const u8, comptime reducer: anytype, comptime Seed: type) ?type {
    if (di.Param(who, reducer, 2, 0)) |Declared| return Declared;
    switch (@typeInfo(Seed)) {
        .comptime_int, .comptime_float => {},
        else => return Seed,
    }
    // A handler that is no reducer says so itself before it is asked what
    // it accumulates in: the hint below would send its user the wrong way.
    _ = di.requires(who, reducer, 2);
    if (@TypeOf(reducer) == type and @hasDecl(reducer, "State")) return null;
    @compileError(who ++ ": the seed is a `" ++ @typeName(Seed) ++ "`, a number without a type, and the reducer does not say what it accumulates in; write `@as(T, seed)`");
}

/// What `reducer` accumulates items of type `Item` in, for a `seed` that
/// `State` found no type for. The seed has to be a value of it.
pub fn Inferred(comptime who: []const u8, comptime reducer: anytype, comptime seed: anytype, comptime Item: type) type {
    const A = reducer.State(Item);
    const fits = switch (@typeInfo(A)) {
        .float => true,
        .int => (@TypeOf(seed) == comptime_int or @trunc(seed) == seed) and seed >= std.math.minInt(A) and seed <= std.math.maxInt(A),
        else => false,
    };
    if (!fits) @compileError(std.fmt.comptimePrint(
        "{s}: the seed `{d}` is not a `{s}`, which is what the reducer accumulates `{s}` items in; give a seed of that type, or choose another with `@as(T, seed)`",
        .{ who, seed, @typeName(A), @typeName(Item) },
    ));
    return A;
}

/// A seed without a type, kept in the type of its operator: there is no
/// runtime type to store it in until the items are known. Told by a
/// declaration of a private type, not by a name: a seed of a caller's own
/// may declare anything.
fn Untyped(comptime seed: anytype) type {
    return struct {
        pub const zrx_untyped_seed: Mark = .{};
        pub const value = seed;
    };
}

const Mark = struct {};

fn Accumulate(comptime kind: enum { scan, fold }, comptime Seed: type, comptime reducer: anytype) type {
    return struct {
        seed: Seed,

        const Op = @This();
        pub const zrx_operator = {};
        pub const name = @tagName(kind);

        const untyped = @typeInfo(Seed) == .@"struct" and @hasDecl(Seed, "zrx_untyped_seed") and @TypeOf(Seed.zrx_untyped_seed) == Mark;

        /// The accumulator: the type of the seed, or for a seed without
        /// one, what the reducer says it accumulates the items in.
        fn A(comptime In: type) type {
            return if (untyped) Inferred(name, reducer, Seed.value, In) else Seed;
        }

        pub fn Out(comptime Env: type, comptime In: type) type {
            expectReturn(name, "reducer", di.Bound(name, reducer, Env, &.{ A(In), In }).Return, A(In));
            return A(In);
        }

        pub fn Stage(comptime Env: type, comptime In: type) type {
            const Call = di.Bound(name, reducer, Env, &.{ A(In), In });
            return struct {
                call: Call,
                state: A(In),

                pub fn init(self: *@This(), op: *const Op, env: Env) void {
                    self.* = .{ .call = .init(env), .state = if (untyped) Seed.value else op.seed };
                }

                pub fn push(self: *@This(), item: In, down: anytype) !Flow {
                    self.state = try lift(self.call.call(.{ self.state, item }));
                    return if (kind == .scan) down.push(self.state) else .more;
                }

                pub fn finish(self: *@This(), down: anytype) !void {
                    if (kind == .fold) _ = try down.push(self.state);
                }
            };
        }
    };
}

/// Passes the first `count` items, then tells upstream to stop.
pub fn take(count: usize) Take {
    return .{ .count = count };
}

const Take = struct {
    count: usize,

    pub const zrx_operator = {};
    pub const name = "take";

    pub fn Out(comptime _: type, comptime In: type) type {
        return In;
    }

    pub fn Stage(comptime Env: type, comptime In: type) type {
        return struct {
            remaining: usize,

            pub fn init(self: *@This(), op: *const Take, _: Env) void {
                self.remaining = op.count;
            }

            pub fn push(self: *@This(), item: In, down: anytype) !Flow {
                if (self.remaining == 0) return .done;
                self.remaining -= 1;
                if (try down.push(item) == .done) return .done;
                return if (self.remaining == 0) .done else .more;
            }
        };
    }
};

/// Drops the first `count` items.
pub fn skip(count: usize) Skip {
    return .{ .count = count };
}

const Skip = struct {
    count: usize,

    pub const zrx_operator = {};
    pub const name = "skip";

    pub fn Out(comptime _: type, comptime In: type) type {
        return In;
    }

    pub fn Stage(comptime Env: type, comptime In: type) type {
        return struct {
            remaining: usize,

            pub fn init(self: *@This(), op: *const Skip, _: Env) void {
                self.remaining = op.count;
            }

            pub fn push(self: *@This(), item: In, down: anytype) !Flow {
                if (self.remaining != 0) {
                    self.remaining -= 1;
                    return .more;
                }
                return down.push(item);
            }
        };
    }
};

/// Passes items until `predicate(deps..., item)` is first false, then tells upstream to stop.
pub fn takeWhile(comptime predicate: anytype) TakeWhile(predicate) {
    return .{};
}

fn TakeWhile(comptime predicate: anytype) type {
    return struct {
        const Op = @This();
        pub const zrx_operator = {};
        pub const name = "takeWhile";

        pub fn Out(comptime Env: type, comptime In: type) type {
            expectHolds(name, di.Bound(name, predicate, Env, &.{In}).Return, route_instead);
            return In;
        }

        pub fn Stage(comptime Env: type, comptime In: type) type {
            const Call = di.Bound(name, predicate, Env, &.{In});
            return struct {
                call: Call,
                open: bool,

                pub fn init(self: *@This(), _: *const Op, env: Env) void {
                    self.* = .{ .call = .init(env), .open = true };
                }

                pub fn push(self: *@This(), item: In, down: anytype) !Flow {
                    if (!self.open) return .done;
                    if (!try lift(self.call.call(.{item}))) {
                        self.open = false;
                        return .done;
                    }
                    return down.push(item);
                }
            };
        }
    };
}

/// Emits the elements of each array, slice, or batch item, in order.
pub fn flatten() Flatten {
    return .{};
}

const Flatten = struct {
    pub const zrx_operator = {};
    pub const name = "flatten";

    pub fn Out(comptime _: type, comptime In: type) type {
        return Element(In) orelse @compileError("flatten: items must be arrays, slices, or batches, got `" ++ @typeName(In) ++ "`");
    }

    pub fn Stage(comptime _: type, comptime In: type) type {
        return struct {
            pub fn push(_: *@This(), item: In, down: anytype) !Flow {
                for (if (comptime isBatch(In)) item.slice() else item) |element| {
                    if (try down.push(element) == .done) return .done;
                }
                return .more;
            }
        };
    }
};

/// Up to `capacity` items stored inline. Only the first `len` are valid.
pub fn Batch(comptime T: type, comptime capacity: usize) type {
    return struct {
        pub const Item = T;
        pub const Capacity = capacity;

        items: [capacity]T,
        len: usize,

        pub fn slice(self: *const @This()) []const T {
            return self.items[0..self.len];
        }
    };
}

/// The element type of an array, a slice or a batch; null for anything else.
pub fn Element(comptime In: type) ?type {
    return switch (@typeInfo(In)) {
        .array => |array| array.child,
        .pointer => |pointer| switch (pointer.size) {
            .slice => pointer.child,
            .one => switch (@typeInfo(pointer.child)) {
                .array => |array| array.child,
                else => null,
            },
            else => null,
        },
        .@"struct" => if (isBatch(In)) In.Item else null,
        else => null,
    };
}

pub fn isBatch(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "Item") and @hasDecl(T, "Capacity") and
        @TypeOf(T.Item) == type and @TypeOf(T.Capacity) == usize and T == Batch(T.Item, T.Capacity);
}

/// Groups items into inline batches of `size` (the last may be shorter).
///
/// Built from two stages so that each lives in its own local: the counter
/// stays in a register, and only the buffer (which is indexed, so the
/// optimizer must keep it in memory) is in memory.
pub fn batch(comptime size: usize) core.Spliced("batch", @Tuple(&.{ BatchSlots(size), BatchBuffer(size) })) {
    if (size == 0) @compileError("batch: size must be at least 1");
    return .{ .ops = .{ BatchSlots(size){}, BatchBuffer(size){} } };
}

/// What the counter tells the buffer: store `item` at `index` (if any), then
/// deliver the first `deliver` items (if not zero).
fn BatchStep(comptime In: type) type {
    return struct { item: ?In, index: usize, deliver: usize };
}

fn BatchSlots(comptime size: usize) type {
    return struct {
        const Op = @This();
        pub const zrx_operator = {};
        pub const name = "batch";

        pub fn Out(comptime _: type, comptime In: type) type {
            return BatchStep(In);
        }

        pub fn Stage(comptime Env: type, comptime In: type) type {
            return struct {
                len: usize,

                pub fn init(self: *@This(), _: *const Op, _: Env) void {
                    self.len = 0;
                }

                pub fn push(self: *@This(), item: In, down: anytype) !Flow {
                    const index = self.len;
                    const full = index + 1 == size;
                    self.len = if (full) 0 else index + 1;
                    return down.push(.{ .item = item, .index = index, .deliver = if (full) size else 0 });
                }

                pub fn finish(self: *@This(), down: anytype) !void {
                    if (self.len == 0) return;
                    const pending = self.len;
                    self.len = 0;
                    _ = try down.push(.{ .item = null, .index = 0, .deliver = pending });
                }
            };
        }
    };
}

fn BatchBuffer(comptime size: usize) type {
    return struct {
        const Op = @This();
        pub const zrx_operator = {};
        pub const name = "batch";

        fn Item(comptime Step: type) type {
            return @typeInfo(@FieldType(Step, "item")).optional.child;
        }

        pub fn Out(comptime _: type, comptime Step: type) type {
            return Batch(Item(Step), size);
        }

        pub fn Stage(comptime _: type, comptime Step: type) type {
            return struct {
                items: [size]Item(Step) = undefined,

                pub fn push(self: *@This(), step: Step, down: anytype) !Flow {
                    if (step.item) |item| self.items[step.index] = item;
                    if (step.deliver == 0) return .more;
                    return down.push(.{ .items = self.items, .len = step.deliver });
                }
            };
        }
    };
}

/// What a predicate finds, read in one place. A predicate answers `bool`,
/// or an optional when it finds a value in the item, as the condition of an
/// `if` does: this is `T` for `?T` (or `E!?T`) and null for `bool`. Anything
/// else is not a predicate.
pub fn Finds(comptime who: []const u8, comptime R: type) ?type {
    return switch (@typeInfo(di.Payload(R))) {
        .bool => null,
        .optional => |found| found.child,
        else => @compileError(who ++ ": predicate must return `bool`, or an optional when it finds a value, got `" ++ @typeName(R) ++ "`"),
    };
}

/// Requires a predicate that answers `bool`, where there is nowhere for a
/// value to go. One that finds a value is told so, with `instead`.
pub fn expectHolds(comptime who: []const u8, comptime R: type, comptime instead: []const u8) void {
    if (@typeInfo(di.Payload(R)) == .optional) @compileError(
        who ++ ": predicate finds a value (`" ++ @typeName(R) ++ "`), which " ++ who ++ " cannot pass on; " ++ instead,
    );
    expectReturn(who, "predicate", R, bool);
}

/// What to write where an operator only keeps or drops an item.
const route_instead = "write `route(.{ when(predicate, .{ ... }) })` to go on with what it found, or return `bool`";

/// Requires `R` to be `Want` or `E!Want`.
pub fn expectReturn(comptime who: []const u8, comptime what: []const u8, comptime R: type, comptime Want: type) void {
    if (di.Payload(R) != Want) @compileError(
        who ++ ": " ++ what ++ " must return `" ++ @typeName(Want) ++ "` or `E!" ++ @typeName(Want) ++ "`, got `" ++ @typeName(R) ++ "`",
    );
}
