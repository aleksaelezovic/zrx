//! Arithmetic on the items of a pipe, on top of `std.math`.
//!
//!     map(mul(2))                    // each item, changed
//!     fold(0, sum)                   // one total, at the end
//!     scan(0, sum)                   // the running total
//!     map(reduce(0, sum))            // the total of each batch
//!     fold(Stats(f64){}, Stats(f64).add)
//!
//! Two families of handlers and one accumulator. A *transform* changes one
//! item, with an operand known at compile time as `gt(80)` has one. A
//! *reducer* takes a state and an item and returns the state: one reducer
//! serves `fold`, `scan` and `reduce`, which is why there is no operator
//! here that adds up a stream.
//!
//! The plain forms are the plain operators: `add(1)` is `item + 1`, and an
//! overflow is what it is for `+`, a bug that a safe build stops at. The
//! forms in `checked` return `error.Overflow` instead, for an error path to
//! take. Items are integers or floats.
//!
//! Nothing here is known to the core: these are composite handlers.
const std = @import("std");

// ---------------------------------------------------------------------------
// Transforms
// ---------------------------------------------------------------------------

/// `item + n`: `map(add(1))`.
pub fn add(comptime n: anytype) type {
    return Binary(.add, false, n);
}

/// `item - n`
pub fn sub(comptime n: anytype) type {
    return Binary(.sub, false, n);
}

/// `item * n`
pub fn mul(comptime n: anytype) type {
    return Binary(.mul, false, n);
}

/// The item divided by `n`. Between integers the result is rounded toward
/// zero, as `/` rounds where Zig takes it (`@divTrunc`). `div(0)` does not
/// compile.
pub fn div(comptime n: anytype) type {
    return Binary(.div, false, n);
}

/// `@mod(item, n)`: what is left of the item over a multiple of `n`, never
/// negative. `n` is greater than 0, as `std.math.mod` requires.
pub fn mod(comptime n: anytype) type {
    return Binary(.mod, false, n);
}

/// The item multiplied by itself `n` times over: `pow(2)` is `item * item`.
/// `n` is a whole number that is not negative, and `pow(0)` is 1.
pub fn pow(comptime n: anytype) type {
    return Power(false, n);
}

/// The item, or the bound it is beyond: no less than `lo`, no more than `hi`.
pub fn clamp(comptime lo: anytype, comptime hi: anytype) type {
    const who = "math.clamp";
    expectOperand(who, "lower bound", lo);
    expectOperand(who, "upper bound", hi);
    if (lo > hi) @compileError(std.fmt.comptimePrint(
        "{s}: the lower bound `{d}` is above the upper bound `{d}`; write the lower one first",
        .{ who, lo, hi },
    ));
    return struct {
        pub const zrx_handler = {};

        pub fn requires(comptime arity: usize) []const type {
            expectItem(who, "clamp(lo, hi)", arity);
            return &.{};
        }

        pub fn call(_: anytype, args: anytype) Clamped(@TypeOf(args[0])) {
            return std.math.clamp(args[0], comptime bound(@TypeOf(args[0]), lo), comptime bound(@TypeOf(args[0]), hi));
        }

        // The order of the bounds is judged as they were written: rounding
        // can make two bounds equal and cannot turn them round.
        fn Clamped(comptime T: type) type {
            expectNumber(who, T);
            _ = operand(who, "lower bound", T, lo);
            _ = operand(who, "upper bound", T, hi);
            return T;
        }
    };
}

/// A bound of `clamp` as `std.math.clamp` is to be given it: a number
/// written without a type as it was written, which is what one writes by
/// hand and what `@min` and `@max` read the range of the result from.
fn bound(comptime T: type, comptime n: anytype) if (isLiteral(T, n)) @TypeOf(n) else T {
    return if (isLiteral(T, n)) n else operand("math.clamp", "bound", T, n);
}

fn isLiteral(comptime T: type, comptime n: anytype) bool {
    return switch (@typeInfo(@TypeOf(n))) {
        .comptime_int => true,
        .comptime_float => @typeInfo(T) == .float,
        else => false,
    };
}

/// `@abs(item)`: how far the item is from zero. Of a signed integer that
/// is the unsigned integer of its size, so nothing overflows.
pub const abs = struct {
    pub const zrx_handler = {};
    const who = "math.abs";

    pub fn requires(comptime arity: usize) []const type {
        expectItem(who, "abs", arity);
        return &.{};
    }

    pub fn call(_: anytype, args: anytype) Distance(@TypeOf(args[0])) {
        return @abs(args[0]);
    }

    fn Distance(comptime T: type) type {
        expectNumber(who, T);
        return @TypeOf(@abs(@as(T, 0)));
    }
};

/// `-item`. The items are signed integers or floats.
pub const neg = Negation(false);

/// The transforms and reducers that can overflow, returning
/// `error.Overflow` where the plain form would: `map(checked.mul(1000))`,
/// `fold(0, checked.sum)`. The error is the item's, so `orElse`, `attempt`
/// and `recover` take it. Their items are integers: a float does not
/// overflow.
///
/// Nothing else is here because nothing else can fail. `div(0)` and
/// `mod(0)` do not compile, `abs` returns a type that holds every result,
/// and the one division that overflows, the smallest value of a signed
/// type by -1, is `checked.neg`.
pub const checked = struct {
    /// `std.math.add(T, item, n)`
    pub fn add(comptime n: anytype) type {
        return Binary(.add, true, n);
    }

    /// `std.math.sub(T, item, n)`
    pub fn sub(comptime n: anytype) type {
        return Binary(.sub, true, n);
    }

    /// `std.math.mul(T, item, n)`
    pub fn mul(comptime n: anytype) type {
        return Binary(.mul, true, n);
    }

    /// `pow(n)`, with each of its multiplications checked.
    pub fn pow(comptime n: anytype) type {
        return Power(true, n);
    }

    /// `std.math.negate(item)`: fails for the smallest value of its type.
    pub const neg = Negation(true);

    /// `sum`, failing where the total no longer fits its type.
    pub const sum = Reducer(.sum, true);

    /// `product`, failing where it no longer fits its type.
    pub const product = Reducer(.product, true);
};

const Operation = enum { add, sub, mul, div, mod };

fn Binary(comptime operation: Operation, comptime is_checked: bool, comptime n: anytype) type {
    const name = @tagName(operation);
    const who = (if (is_checked) "math.checked." else "math.") ++ name;
    expectOperand(who, "operand", n);
    return struct {
        pub const zrx_handler = {};

        pub fn requires(comptime arity: usize) []const type {
            expectItem(who, name ++ "(n)", arity);
            return &.{};
        }

        pub fn call(_: anytype, args: anytype) Changed(@TypeOf(args[0])) {
            const T = @TypeOf(args[0]);
            const item = args[0];
            const by = comptime judged(T);
            if (is_checked) return switch (operation) {
                .add => std.math.add(T, item, by),
                .sub => std.math.sub(T, item, by),
                .mul => std.math.mul(T, item, by),
                .div, .mod => comptime unreachable,
            };
            return switch (operation) {
                .add => item + by,
                .sub => item - by,
                .mul => item * by,
                .div => if (comptime @typeInfo(T) == .int) @divTrunc(item, by) else item / by,
                .mod => @mod(item, by),
            };
        }

        fn Changed(comptime T: type) type {
            if (is_checked) expectInteger(who, name, T) else expectNumber(who, T);
            _ = judged(T);
            return if (is_checked) error{Overflow}!T else T;
        }

        /// The operand as a `T`, and whether the operation takes it. That
        /// is asked of the `T`, since it is the `T` the items are divided
        /// by: an operand is not 0 because it was not written as 0.
        fn judged(comptime T: type) T {
            const by = operand(who, "operand", T, n);
            switch (operation) {
                .div => if (by == 0) @compileError(who ++ ": dividing by 0 never works; give an operand other than 0"),
                .mod => if (!(by > 0)) @compileError(std.fmt.comptimePrint("{s}: the operand must be greater than 0, got `{d}`", .{ who, n })),
                else => {},
            }
            return by;
        }
    };
}

fn Power(comptime is_checked: bool, comptime n: anytype) type {
    const who = if (is_checked) "math.checked.pow" else "math.pow";
    expectOperand(who, "exponent", n);
    if (n < 0 or !isWhole(n)) @compileError(std.fmt.comptimePrint(
        "{s}: the exponent must be a whole number that is not negative, got `{d}`; for a root or another power, write a handler of your own over `std.math.pow`",
        .{ who, n },
    ));
    const exponent: comptime_int = n;
    return struct {
        pub const zrx_handler = {};

        pub fn requires(comptime arity: usize) []const type {
            expectItem(who, "pow(n)", arity);
            return &.{};
        }

        /// By squaring, and only as far as the exponent needs: these are
        /// the multiplications one writes by hand, and no product on the
        /// way is larger than the result, so the checked form fails only
        /// where the result does not fit. Except in `i1`, which has no 1:
        /// the square of -1 does not fit where its cube does, so there the
        /// checked form answers by whether the exponent is odd.
        pub fn call(_: anytype, args: anytype) Raised(@TypeOf(args[0])) {
            const T = @TypeOf(args[0]);
            if (is_checked and T == i1) {
                if (exponent % 2 == 1) return args[0];
                return if (exponent != 0 and args[0] == 0) 0 else error.Overflow;
            }
            if (exponent == 0) return 1;
            comptime var left = exponent;
            comptime var begun = false;
            var square: T = args[0];
            var result: T = undefined;
            inline while (left != 0) {
                if (left & 1 == 1) {
                    result = if (!begun) square else if (is_checked) try std.math.mul(T, result, square) else result * square;
                    begun = true;
                }
                left >>= 1;
                if (left != 0) square = if (is_checked) try std.math.mul(T, square, square) else square * square;
            }
            return result;
        }

        fn Raised(comptime T: type) type {
            if (is_checked) expectInteger(who, "pow", T) else expectNumber(who, T);
            return if (is_checked) error{Overflow}!T else T;
        }
    };
}

fn Negation(comptime is_checked: bool) type {
    return struct {
        pub const zrx_handler = {};
        const who = if (is_checked) "math.checked.neg" else "math.neg";

        pub fn requires(comptime arity: usize) []const type {
            expectItem(who, "neg", arity);
            return &.{};
        }

        pub fn call(_: anytype, args: anytype) Negated(@TypeOf(args[0])) {
            return if (is_checked) std.math.negate(args[0]) else -args[0];
        }

        fn Negated(comptime T: type) type {
            if (is_checked) expectInteger(who, "neg", T) else expectNumber(who, T);
            if (@typeInfo(T) == .int and @typeInfo(T).int.signedness == .unsigned) @compileError(
                who ++ ": items are `" ++ @typeName(T) ++ "`, which has no negative values; make them signed first",
            );
            return if (is_checked) error{Overflow}!T else T;
        }
    };
}

// ---------------------------------------------------------------------------
// Reducers
// ---------------------------------------------------------------------------

/// The items added up: `fold(0, sum)` is the total of a stream,
/// `scan(0, sum)` the running total, `map(reduce(0, sum))` the total of
/// each batch. The total has the items' type; a seed with a type chooses
/// a wider one, as in `fold(@as(u64, 0), sum)`.
pub const sum = Reducer(.sum, false);

/// The items multiplied: `fold(1, product)`.
pub const product = Reducer(.product, false);

/// The smallest item, and the seed where there is none. The seed takes
/// part like an item, so it is the largest value an item can have,
/// `fold(std.math.maxInt(u32), min)`, or null in a state that is an
/// optional, `fold(@as(?u32, null), min)`, which is then what a stream
/// without items comes to.
pub const min = Reducer(.min, false);

/// The largest item, and the seed where there is none: see `min`.
/// `fold(0, max)` is right for items that are not negative.
pub const max = Reducer(.max, false);

/// How many items there were, whatever they are: `fold(0, count)`. The
/// count is a `usize` unless the seed has a type.
pub const count = Reducer(.count, false);

const Reduction = enum { sum, product, min, max, count };

fn Reducer(comptime reduction: Reduction, comptime is_checked: bool) type {
    return struct {
        pub const zrx_handler = {};
        const name = @tagName(reduction);
        const who = (if (is_checked) "math.checked." else "math.") ++ name;

        /// What a seed without a type becomes; see `fold` in the guide.
        pub fn State(comptime Item: type) type {
            if (reduction == .count) return usize;
            if (is_checked) expectInteger(who, name, Item) else expectNumber(who, Item);
            return Item;
        }

        pub fn requires(comptime arity: usize) []const type {
            if (arity != 2) @compileError(std.fmt.comptimePrint(
                "{s}: is a reducer, a handler of a state and an item, but receives {d} value(s) here; use it as fold(seed, {s}), scan(seed, {s}) or map(reduce(seed, {s}))",
                .{ who, arity, name, name, name },
            ));
            return &.{};
        }

        pub fn call(_: anytype, args: anytype) Reduced(@TypeOf(args[0]), @TypeOf(args[1])) {
            const A = @TypeOf(args[0]);
            const state = args[0];
            switch (reduction) {
                .count => return state + 1,
                .sum => return if (is_checked) std.math.add(A, state, args[1]) else state + args[1],
                .product => return if (is_checked) std.math.mul(A, state, args[1]) else state * args[1],
                .min, .max => {
                    // The builtins answer in the narrowest type that holds
                    // the result, so the item is widened to the state first.
                    const item: Held(A) = args[1];
                    const held = if (comptime A == Held(A)) state else state orelse return item;
                    return if (reduction == .min) @min(held, item) else @max(held, item);
                },
            }
        }

        /// The state without its optional: only `min` and `max` have a
        /// state that can be "nothing yet".
        fn Held(comptime A: type) type {
            return switch (@typeInfo(A)) {
                .optional => |optional| if (reduction == .min or reduction == .max) optional.child else A,
                else => A,
            };
        }

        fn Reduced(comptime A: type, comptime Item: type) type {
            if (reduction == .count) {
                if (@typeInfo(A) != .int) @compileError(
                    who ++ ": counts in an integer, but the state is a `" ++ @typeName(A) ++ "`; give a seed such as `0` or `@as(u32, 0)`",
                );
                return A;
            }
            _ = State(Item);
            if (@typeInfo(A) == .optional and Held(A) == A) @compileError(
                who ++ ": the state is an optional, `" ++ @typeName(A) ++ "`, which only min and max take: they have no value before the first item, and this has its seed",
            );
            if (!holds(Held(A), Item)) @compileError(
                who ++ ": a state of type `" ++ @typeName(A) ++ "` does not take `" ++ @typeName(Item) ++
                    "` items; give a seed whose type holds every item, as in `@as(T, seed)`, or convert the items first",
            );
            return if (is_checked) error{Overflow}!A else A;
        }
    };
}

/// Whether every value of the number type `Item` is a value of `A`.
fn holds(comptime A: type, comptime Item: type) bool {
    return switch (@typeInfo(A)) {
        .int => |a| switch (@typeInfo(Item)) {
            .int => |item| if (a.signedness == item.signedness) a.bits >= item.bits else a.signedness == .signed and a.bits > item.bits,
            else => false,
        },
        .float => |a| switch (@typeInfo(Item)) {
            .float => |item| a.bits >= item.bits,
            else => false,
        },
        else => false,
    };
}

// ---------------------------------------------------------------------------
// An accumulator
// ---------------------------------------------------------------------------

/// How many items there were, the smallest, the largest and their mean,
/// kept as the items pass: `fold(Stats(f64){}, Stats(f64).add)`, or with
/// `scan` and `reduce` like any reducer. The items are `T`s: floats, or
/// integers of at most 128 bits, the widest that becomes a float.
///
/// `mean` is a float (`f64` for integer items) and is the running mean,
/// which no number of items overflows: the mean of finite items is finite.
/// It is rounded once for each item, so it is not the sum divided by the
/// count to the last digit. Before the first item `count` is 0, `mean` is
/// 0, and `min` and `max` are the values every item replaces: the largest
/// and the smallest value of `T` (infinity for a float). Ask `count`
/// whether there was an item.
///
/// An item that is NaN is counted and makes the mean NaN from then on;
/// `min` and `max` pass over it. An infinity is the `min` or the `max` and
/// the mean, and the item after it makes the mean NaN.
pub fn Stats(comptime T: type) type {
    const float = switch (@typeInfo(T)) {
        // A wider integer has no conversion to a float at run time: LLVM
        // stops on it. And beyond 1023 bits it would be infinite.
        .int => |int| if (int.bits > 128) @compileError(
            "math.Stats: takes integers of at most 128 bits, got `" ++ @typeName(T) ++ "`; make the items narrower first",
        ) else false,
        .float => true,
        else => @compileError("math.Stats: takes the type of the items, an integer or a float, got `" ++ @typeName(T) ++ "`"),
    };
    const Mean = if (float) T else f64;
    // What the mean is calculated in: the count has to be a value of it,
    // and no `f16` is a whole number above 65504.
    const Wide = if (@typeInfo(Mean).float.bits < 64) f64 else Mean;
    // Only items of the type the mean is calculated in can be too far
    // apart for their difference: an integer of 128 bits is below 2^128,
    // and the largest `f32` far below the largest `f64`.
    const spans = Wide == T;
    return struct {
        count: usize = 0,
        min: T = if (float) std.math.inf(T) else std.math.maxInt(T),
        max: T = if (float) -std.math.inf(T) else std.math.minInt(T),
        mean: Mean = 0,

        pub fn add(stats: @This(), value: T) @This() {
            const seen = stats.count + 1;
            const of: Wide = @floatFromInt(seen);
            const item: Wide = if (float) value else @floatFromInt(value);
            const mean: Wide = stats.mean;
            // The difference of two finite values can be infinite, that of
            // their parts cannot: then each is divided before the two are
            // subtracted. Only then, since a part can round to nothing
            // where the difference does not, as half the smallest float.
            const apart = item - mean;
            const step = if (!spans or std.math.isFinite(apart)) apart / of else item / of - mean / of;
            return .{
                .count = seen,
                .min = @min(stats.min, value),
                .max = @max(stats.max, value),
                .mean = @floatCast(mean + step),
            };
        }
    };
}

// ---------------------------------------------------------------------------
// What a user wrote, checked
// ---------------------------------------------------------------------------

/// A transform is given one item.
fn expectItem(comptime who: []const u8, comptime usage: []const u8, comptime arity: usize) void {
    if (arity != 1) @compileError(std.fmt.comptimePrint(
        "{s}: changes one item, but receives {d} values here; use it where a handler takes a single item, as in map({s}). The reducers for fold, scan and reduce are sum, product, min, max and count",
        .{ who, arity, usage },
    ));
}

fn isNumber(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .int, .float => true,
        else => false,
    };
}

fn expectNumber(comptime who: []const u8, comptime T: type) void {
    if (!isNumber(T)) @compileError(
        who ++ ": items must be integers or floats, got `" ++ @typeName(T) ++ "`; take the number out of the item first, as in `compose(.{ field(.name), ... })`",
    );
}

fn expectInteger(comptime who: []const u8, comptime plain: []const u8, comptime T: type) void {
    expectNumber(who, T);
    if (@typeInfo(T) != .int) @compileError(
        who ++ ": items must be integers, got `" ++ @typeName(T) ++ "`; a float does not overflow, so write `" ++ plain ++ "`",
    );
}

/// An operand is a number known at compile time, with or without a type.
fn expectOperand(comptime who: []const u8, comptime what: []const u8, comptime n: anytype) void {
    switch (@typeInfo(@TypeOf(n))) {
        .comptime_int, .comptime_float, .int, .float => {},
        else => @compileError(who ++ ": the " ++ what ++ " must be a number, got `" ++ @typeName(@TypeOf(n)) ++ "`"),
    }
}

/// The operand `n` as the items' type `T` has it. Whatever judges an
/// operand judges what this returns and not what was written: `1e-10` is
/// not 0 where it is written, and it is 0 for `f16` items.
///
/// An operand has to be a value of the items' type. An integer type takes
/// a whole number in its range, and a float takes an integer it holds
/// exactly, which is what Zig takes for a literal. A float is rounded to a
/// float type as Zig rounds a literal, unless that makes it 0 or infinite:
/// then it is another number, and refused. So is NaN.
fn operand(comptime who: []const u8, comptime what: []const u8, comptime T: type, comptime n: anytype) T {
    const integer = switch (@typeInfo(@TypeOf(n))) {
        .comptime_int, .int => true,
        else => false,
    };
    switch (@typeInfo(T)) {
        .int => if (isWhole(n) and n >= std.math.minInt(T) and n <= std.math.maxInt(T)) {
            return if (integer) @intCast(n) else @intFromFloat(n);
        },
        .float => if (integer) {
            const nearest: T = @floatFromInt(n);
            if (std.math.isFinite(nearest) and @as(comptime_int, @intFromFloat(nearest)) == n) return nearest;
        } else {
            // Every float there is, is an `f128`.
            const written: f128 = n;
            const rounded: T = @floatCast(written);
            if (std.math.isNan(written)) @compileError(who ++ ": the " ++ what ++ " is NaN, which nothing can be calculated with");
            const became = if (std.math.isInf(rounded) and !std.math.isInf(written))
                "infinite"
            else if (rounded == 0 and written != 0)
                "0"
            else
                return rounded;
            @compileError(std.fmt.comptimePrint(
                "{s}: the {s} `{e}` is {s} as a `{s}`, which is what the items are; give one that type holds",
                .{ who, what, n, became, @typeName(T) },
            ));
        },
        else => comptime unreachable,
    }
    @compileError(std.fmt.comptimePrint(
        "{s}: the {s} `{d}` is not a `{s}`, which is what the items are",
        .{ who, what, n, @typeName(T) },
    ));
}

fn isWhole(comptime n: anytype) bool {
    return switch (@typeInfo(@TypeOf(n))) {
        .comptime_int, .int => true,
        else => @trunc(n) == n,
    };
}
