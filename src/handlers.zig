//! Ready-made handlers and handler combinators.
//!
//! Each returns a composite handler: a type usable wherever a handler function
//! is. Composites forward the dependencies of the handlers they are built from.
const std = @import("std");
const di = @import("di.zig");

fn Handlers(comptime who: []const u8, comptime handlers: anytype) void {
    @setEvalBranchQuota(di.quota);
    if (!di.isTuple(@TypeOf(handlers))) @compileError(who ++ ": expected a tuple of handlers `.{ a, b }`, got `" ++ @typeName(@TypeOf(handlers)) ++ "`");
    if (handlers.len == 0) @compileError(who ++ ": needs at least one handler");
}

fn Fallible(comptime R: type) bool {
    return @typeInfo(R) == .error_union;
}

/// A predicate that is true when `predicate` is false.
pub fn not(comptime predicate: anytype) type {
    return struct {
        pub const zrx_handler = {};

        pub fn requires(comptime arity: usize) []const type {
            return di.requires("not", predicate, arity);
        }

        pub fn call(env: anytype, args: anytype) Verdict("not", .{predicate}, di.types(@TypeOf(args))) {
            const result = di.invoke(predicate, env, args);
            return if (comptime Fallible(@TypeOf(result))) !(try result) else !result;
        }
    };
}

/// A predicate that is true when every one of `predicates` is; stops at the first false.
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

        pub fn call(env: anytype, args: anytype) Verdict(who, predicates, di.types(@TypeOf(args))) {
            inline for (predicates) |predicate| {
                const result = di.invoke(predicate, env, args);
                const verdict = if (comptime Fallible(@TypeOf(result))) try result else result;
                if (verdict == decisive) return decisive;
            }
            return !decisive;
        }
    };
}

/// `bool`, or `E!bool` when any predicate can fail.
fn Verdict(comptime who: []const u8, comptime predicates: anytype, comptime Args: []const type) type {
    @setEvalBranchQuota(di.quota);
    var Set: ?type = null;
    for (predicates) |predicate| {
        const R = di.Result(who, predicate, Args);
        if (di.Payload(R) != bool) @compileError(who ++ ": every predicate must return `bool` or `E!bool`, got `" ++ @typeName(R) ++ "`");
        if (Fallible(R)) Set = (Set orelse error{}) || @typeInfo(R).error_union.error_set;
    }
    return if (Set) |E| E!bool else bool;
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
                var with_error: @Tuple(WithError(di.types(@TypeOf(args)))) = undefined;
                with_error[0] = err;
                inline for (0..args.len) |i| with_error[i + 1] = args[i];
                return di.invoke(fallback, env, with_error);
            };
        }

        fn Failure(comptime Args: []const type) type {
            const R = di.Result("orElse", handler, Args);
            if (!Fallible(R)) @compileError("orElse: the handler returns `" ++ @typeName(R) ++ "`, which cannot fail; there is nothing to fall back from");
            return @typeInfo(R).error_union.error_set;
        }

        /// The fallback's data: the error, then the handler's own data.
        fn WithError(comptime Args: []const type) []const type {
            return &[_]type{Failure(Args)} ++ Args;
        }

        /// Whether the handler can report a cancellation, which is not a failure to fall back from.
        fn canCancel(comptime E: type) bool {
            const names = @typeInfo(E).error_set.error_names orelse return true; // anyerror
            for (names) |name| if (std.mem.eql(u8, name, "Canceled")) return true;
            return false;
        }

        /// What the fallback returns, which must be what the handler would
        /// have; plus `error.Canceled` when the handler can be cancelled.
        fn Fallen(comptime Args: []const type) type {
            @setEvalBranchQuota(di.quota);
            const Wanted = di.Payload(di.Result("orElse", handler, Args));
            if (di.Param(fallback, Args.len + 1, 0)) |Takes| {
                if (!di.accepts(Takes, Failure(Args))) @compileError(
                    "orElse: the fallback takes `" ++ @typeName(Takes) ++ "` but the handler can fail with `" ++ @typeName(Failure(Args)) ++ "`",
                );
            }
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
