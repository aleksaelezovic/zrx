//! Ready-made handlers and handler combinators.
//!
//! Each returns a composite handler: a type usable wherever a handler function
//! is. Composites forward the dependencies of the handlers they are built from.
const std = @import("std");
const di = @import("di.zig");
const sequence = @import("ops/transform.zig");

fn Handlers(comptime who: []const u8, comptime handlers: anytype) void {
    @setEvalBranchQuota(di.quota);
    if (!di.isTuple(@TypeOf(handlers))) @compileError(who ++ ": expected a tuple of handlers `.{ a, b }`, got `" ++ @typeName(@TypeOf(handlers)) ++ "`");
    if (handlers.len == 0) @compileError(who ++ ": needs at least one handler");
}

fn Fallible(comptime R: type) bool {
    return @typeInfo(R) == .error_union;
}

/// For a combinator that works on one item: `does` says what it does with
/// it, `usage` shows where it belongs.
fn expectOneItem(comptime who: []const u8, comptime does: []const u8, comptime usage: []const u8, comptime arity: usize) void {
    if (arity != 1) @compileError(std.fmt.comptimePrint(
        "{s}: {s} one item, but receives {d} values here; use it where a handler takes a single item, as in {s}",
        .{ who, does, arity, usage },
    ));
}

/// A predicate that is true when `predicate` is false.
pub fn not(comptime predicate: anytype) type {
    return struct {
        pub const zrx_handler = {};

        pub fn requires(comptime arity: usize) []const type {
            return di.requires("not", predicate, arity);
        }

        pub fn call(env: anytype, args: anytype) Verdict("not", .{predicate}, false, di.types(@TypeOf(args))) {
            const result = di.invoke(predicate, env, args);
            return if (comptime Fallible(@TypeOf(result))) !(try result) else !result;
        }
    };
}

/// A predicate that holds when every one of `predicates` does; stops at the
/// first that does not. It answers what its last predicate answers: when
/// that one finds a value (an optional), so does `all`, and the predicates
/// before it are what must be true first:
/// `all(.{ http.method(.GET), http.path(item) })`.
pub fn all(comptime predicates: anytype) type {
    return Junction("all", predicates, false);
}

/// A predicate that is true when at least one of `predicates` is; stops at the first true.
pub fn any(comptime predicates: anytype) type {
    return Junction("any", predicates, true);
}

fn Junction(comptime who: []const u8, comptime predicates: anytype, comptime decisive: bool) type {
    Handlers(who, predicates);
    return struct {
        pub const zrx_handler = {};

        pub fn requires(comptime arity: usize) []const type {
            var out: []const type = &.{};
            for (predicates) |predicate| out = di.merge(out, di.requires(who, predicate, arity));
            return out;
        }

        pub fn call(env: anytype, args: anytype) Verdict(who, predicates, !decisive, di.types(@TypeOf(args))) {
            const finds = comptime Finding(who, predicates, !decisive, di.types(@TypeOf(args))) != null;
            inline for (predicates, 0..) |predicate, i| {
                const result = di.invoke(predicate, env, args);
                // What the last predicate found is the answer, returned as it is.
                if (comptime finds and i + 1 == predicates.len) return result;
                const verdict = if (comptime Fallible(@TypeOf(result))) try result else result;
                if (verdict == decisive) return if (finds) null else decisive;
            }
            return !decisive;
        }
    };
}

/// What the last of `predicates` finds, where `last_may_find` (in `all`):
/// null when every predicate answers `bool`.
fn Finding(comptime who: []const u8, comptime predicates: anytype, comptime last_may_find: bool, comptime Args: []const type) ?type {
    @setEvalBranchQuota(di.quota);
    var T: ?type = null;
    for (predicates, 0..) |predicate, i| {
        const R = di.Result(who, predicate, Args);
        const found = switch (@typeInfo(di.Payload(R))) {
            .bool => continue,
            .optional => |found| found.child,
            else => @compileError(who ++ ": every predicate must return `bool` or `E!bool`, got `" ++ @typeName(R) ++ "`"),
        };
        if (!last_may_find) sequence.expectHolds(who, R, "return `bool` here; `when`, `require` and the last predicate of `all` take a value");
        if (i + 1 != predicates.len) @compileError(std.fmt.comptimePrint(
            "all: only its last predicate can find a value, but predicate {d} of {d} returns `{s}`; put the predicates that return `bool` before it",
            .{ i + 1, predicates.len, @typeName(R) },
        ));
        T = found;
    }
    return T;
}

/// `bool`, or `?T` when the last predicate of `all` finds a `T`; `E!` of
/// that when any predicate can fail.
fn Verdict(comptime who: []const u8, comptime predicates: anytype, comptime last_may_find: bool, comptime Args: []const type) type {
    @setEvalBranchQuota(di.quota);
    const Answer = if (Finding(who, predicates, last_may_find, Args)) |T| ?T else bool;
    var Set: ?type = null;
    for (predicates) |predicate| {
        const R = di.Result(who, predicate, Args);
        if (Fallible(R)) Set = (Set orelse error{}) || @typeInfo(R).error_union.error_set;
    }
    return if (Set) |E| E!Answer else Answer;
}

/// One handler made of several applied left to right: `compose(.{ f, g })`
/// is `g(f(item))`. The first failure stops the sequence.
pub fn compose(comptime handlers: anytype) type {
    Handlers("compose", handlers);
    return struct {
        pub const zrx_handler = {};

        pub fn requires(comptime arity: usize) []const type {
            var out: []const type = &.{};
            for (handlers, 0..) |handler, i| out = di.merge(out, di.requires("compose", handler, if (i == 0) arity else 1));
            return out;
        }

        pub fn call(env: anytype, args: anytype) Composed(0, di.types(@TypeOf(args))) {
            return step(0, env, args);
        }

        fn step(comptime i: usize, env: anytype, args: anytype) Composed(i, di.types(@TypeOf(args))) {
            const result = di.invoke(handlers[i], env, args);
            if (i + 1 == handlers.len) return result;
            const value = if (comptime Fallible(@TypeOf(result))) try result else result;
            return step(i + 1, env, .{value});
        }

        /// The result of applying `handlers[i..]` to `Args`.
        fn Composed(comptime i: usize, comptime Args: []const type) type {
            @setEvalBranchQuota(di.quota);
            const R = di.Result("compose", handlers[i], Args);
            if (i + 1 == handlers.len) return R;
            const Rest = Composed(i + 1, &.{di.Payload(R)});
            if (!Fallible(R)) return Rest;
            const E = @typeInfo(R).error_union.error_set;
            return if (Fallible(Rest))
                (E || @typeInfo(Rest).error_union.error_set)!@typeInfo(Rest).error_union.payload
            else
                E!Rest;
        }
    };
}

/// Whether a fallback's error parameter of type `Takes` takes every error it
/// can be handed: all of `E`, except `Canceled`, which is never handed over.
pub fn takesAll(comptime Takes: type, comptime E: type) bool {
    if (@typeInfo(Takes) != .error_set) return false;
    const takes = @typeInfo(Takes).error_set.error_names orelse return true; // anyerror
    const names = @typeInfo(E).error_set.error_names orelse return false;
    next: for (names) |name| {
        if (std.mem.eql(u8, name, "Canceled")) continue;
        for (takes) |have| if (std.mem.eql(u8, have, name)) continue :next;
        return false;
    }
    return true;
}

/// Whether `E` holds a cancellation, which is not a failure to fall back from.
pub fn canCancel(comptime E: type) bool {
    const names = @typeInfo(E).error_set.error_names orelse return true; // anyerror
    for (names) |name| if (std.mem.eql(u8, name, "Canceled")) return true;
    return false;
}

/// `handler`, with a failure turned into a value: when `handler` returns an
/// error, the result is `fallback(deps..., err, item)` instead. Where `recover`
/// skips an item that failed, this keeps it, as whatever the fallback makes.
/// Like `recover`, it never handles `error.Canceled`: that one is returned.
pub fn orElse(comptime handler: anytype, comptime fallback: anytype) type {
    return struct {
        pub const zrx_handler = {};

        pub fn requires(comptime arity: usize) []const type {
            return di.merge(di.requires("orElse", handler, arity), di.requires("orElse", fallback, arity + 1));
        }

        pub fn call(env: anytype, args: anytype) Fallen(di.types(@TypeOf(args))) {
            return di.invoke(handler, env, args) catch |err| {
                if (comptime canCancel(Failure(di.types(@TypeOf(args))))) {
                    if (@as(anyerror, err) == error.Canceled) return error.Canceled;
                }
                const Args = comptime di.types(@TypeOf(args));
                var with_error: @Tuple(WithError(Args)) = undefined;
                // A cancellation never gets here, so the error fits the
                // fallback's parameter even when that leaves `Canceled` out.
                with_error[0] = if (comptime Given(Args) == Failure(Args)) err else @errorCast(err);
                inline for (0..args.len) |i| with_error[i + 1] = args[i];
                return di.invoke(fallback, env, with_error);
            };
        }

        fn Failure(comptime Args: []const type) type {
            const R = di.Result("orElse", handler, Args);
            if (!Fallible(R)) @compileError("orElse: the handler returns `" ++ @typeName(R) ++ "`, which cannot fail; there is nothing to fall back from");
            return @typeInfo(R).error_union.error_set;
        }

        /// The type the fallback's error parameter is given: the one it
        /// declares, or the handler's whole error set when it is generic.
        fn Given(comptime Args: []const type) type {
            return di.Param("orElse", fallback, Args.len + 1, 0) orelse Failure(Args);
        }

        /// The fallback's data: the error, then the handler's own data.
        fn WithError(comptime Args: []const type) []const type {
            return &[_]type{Given(Args)} ++ Args;
        }

        /// What the fallback returns, which must be what the handler would
        /// have; plus `error.Canceled` when the handler can be cancelled.
        fn Fallen(comptime Args: []const type) type {
            @setEvalBranchQuota(di.quota);
            const Wanted = di.Payload(di.Result("orElse", handler, Args));
            if (!takesAll(Given(Args), Failure(Args))) @compileError(
                "orElse: the fallback takes `" ++ @typeName(Given(Args)) ++ "` but the handler can fail with `" ++ @typeName(Failure(Args)) ++ "`",
            );
            const F = di.Result("orElse", fallback, WithError(Args));
            if (di.Payload(F) != Wanted) @compileError(
                "orElse: the fallback must return `" ++ @typeName(Wanted) ++ "` like the handler, got `" ++ @typeName(F) ++ "`",
            );
            if (!canCancel(Failure(Args))) return F;
            const Own = if (Fallible(F)) @typeInfo(F).error_union.error_set else error{};
            return (Own || error{Canceled})!Wanted;
        }
    };
}

/// The item when `predicate` is true for it, the error `err` when it is not:
/// `map(require(isPlausible, error.InvalidReading))`. Where `filter` drops
/// such an item without a word, this fails it, for `orElse` or `recover` to
/// handle or for the run to end with. The reverse of `orElse`.
///
/// With a predicate that finds a value (an optional), the result is what it
/// found, as `predicate(item) orelse return err` is.
pub fn require(comptime predicate: anytype, comptime err: anytype) type {
    if (@typeInfo(@TypeOf(err)) != .error_set) @compileError(
        "require: the second argument must be an error such as `error.Invalid`, got `" ++ @typeName(@TypeOf(err)) ++ "`",
    );
    // Checks the predicate's shape where the combinator is written, not where it is used.
    _ = di.requires("require", predicate, 1);
    return struct {
        pub const zrx_handler = {};

        pub fn requires(comptime arity: usize) []const type {
            expectOne(arity);
            return di.requires("require", predicate, 1);
        }

        pub fn call(env: anytype, args: anytype) Required(@TypeOf(env), di.types(@TypeOf(args))) {
            const result = di.invoke(predicate, env, args);
            const holds = if (comptime Fallible(@TypeOf(result))) try result else result;
            if (comptime @typeInfo(@TypeOf(holds)) == .optional) return holds orelse return err;
            // Two returns, not one that selects: selecting between the item
            // and a constant error leaves the result in a stack slot.
            if (!holds) return err;
            return args[0];
        }

        fn expectOne(comptime arity: usize) void {
            expectOneItem("require", "checks", "map(require(predicate, error.Invalid))", arity);
        }

        /// `error{Named}!Item`, or `error{Named}!T` for a predicate that finds
        /// a `T`, with the predicate's own errors when it can fail.
        fn Required(comptime Env: type, comptime Args: []const type) type {
            @setEvalBranchQuota(di.quota);
            expectOne(Args.len);
            di.check("require", predicate, Env, Args);
            const R = di.Result("require", predicate, Args);
            const Kept = sequence.Finds("require", R) orelse Args[0];
            const Named = @TypeOf(err);
            return (if (Fallible(R)) Named || @typeInfo(R).error_union.error_set else Named)!Kept;
        }
    };
}

/// Folds the elements of an array, slice or batch item into one value:
/// `map(reduce(Window{}, Window.add))`. The result is `seed` for an empty
/// item. Where `fold` reduces a stream, this reduces one item.
pub fn reduce(comptime seed: anytype, comptime reducer: anytype) type {
    // The reducer's declared state parameter, else the seed's type, as for `fold`.
    const State = di.Param("reduce", reducer, 2, 0) orelse @TypeOf(seed);
    return struct {
        pub const zrx_handler = {};

        pub fn requires(comptime arity: usize) []const type {
            expectOne(arity);
            return di.requires("reduce", reducer, 2);
        }

        pub fn call(env: anytype, args: anytype) Reduced(@TypeOf(env), di.types(@TypeOf(args))) {
            const In = @TypeOf(args[0]);
            var state: State = seed;
            for (if (comptime sequence.isBatch(In)) args[0].slice() else args[0]) |element| {
                const next = di.invoke(reducer, env, .{ state, element });
                state = if (comptime Fallible(@TypeOf(next))) try next else next;
            }
            return state;
        }

        fn expectOne(comptime arity: usize) void {
            expectOneItem("reduce", "folds the elements of", "map(reduce(seed, f))", arity);
        }

        fn Reduced(comptime Env: type, comptime Args: []const type) type {
            @setEvalBranchQuota(di.quota);
            expectOne(Args.len);
            const Element = sequence.Element(Args[0]) orelse
                @compileError("reduce: items must be arrays, slices, or batches, got `" ++ @typeName(Args[0]) ++ "`");
            di.check("reduce", reducer, Env, &.{ State, Element });
            const R = di.Result("reduce", reducer, &.{ State, Element });
            sequence.expectReturn("reduce", "reducer", R, State);
            return if (Fallible(R)) @typeInfo(R).error_union.error_set!State else State;
        }
    };
}

/// Projects a struct item to one of its fields: `map(field(.price))`.
pub fn field(comptime name: @EnumLiteral()) type {
    return struct {
        pub const zrx_handler = {};

        pub fn requires(comptime _: usize) []const type {
            return &.{};
        }

        pub fn call(_: anytype, args: anytype) @TypeOf(@field(args[0], @tagName(name))) {
            return @field(args[0], @tagName(name));
        }
    };
}

/// Ignores the item and returns `value`.
pub fn constant(comptime value: anytype) type {
    return struct {
        pub const zrx_handler = {};

        pub fn requires(comptime _: usize) []const type {
            return &.{};
        }

        pub fn call(_: anytype, _: anytype) @TypeOf(value) {
            return value;
        }
    };
}

/// `item == value`
pub fn eq(comptime value: anytype) type {
    return Comparison(.eq, value);
}

/// `item != value`
pub fn ne(comptime value: anytype) type {
    return Comparison(.neq, value);
}

/// `item < value`
pub fn lt(comptime value: anytype) type {
    return Comparison(.lt, value);
}

/// `item <= value`
pub fn le(comptime value: anytype) type {
    return Comparison(.lte, value);
}

/// `item > value`
pub fn gt(comptime value: anytype) type {
    return Comparison(.gt, value);
}

/// `item >= value`
pub fn ge(comptime value: anytype) type {
    return Comparison(.gte, value);
}

fn Comparison(comptime op: std.math.CompareOperator, comptime value: anytype) type {
    return struct {
        pub const zrx_handler = {};

        pub fn requires(comptime _: usize) []const type {
            return &.{};
        }

        pub fn call(_: anytype, args: anytype) bool {
            const item = args[0];
            return switch (op) {
                .eq => item == value,
                .neq => item != value,
                .lt => item < value,
                .lte => item <= value,
                .gt => item > value,
                .gte => item >= value,
            };
        }
    };
}
