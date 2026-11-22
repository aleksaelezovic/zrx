# Spec: math

Status: implemented as `zrx.ext.math` (`src/ext/math.zig`). The one change
it needed in the core, how a seed without a type gets one, is described
under [The seed](#the-seed) and is a proposal until the owner has decided
on its shape.

This file is the design record of the extension: why it is the way it is,
what was rejected and what was measured. The [guide](guide.md#math) says
what it does, and every behavior named there is pinned in `tests/math.zig`.
`AGENTS.md` keeps the short rules to know before editing it and points here
for the reasons.

## What it is

Handlers only, a layer over `std.math`, written against the handler
contract. It imports nothing of zrx. There are two families and one
accumulator:

- a *transform* changes one item and has an operand known at compile time,
  as `gt(80)` has one: `map(mul(2))`;
- a *reducer* takes a state and an item and returns the state: `sum`,
  `product`, `min`, `max`, `count`;
- `Stats(T)` is a state with a reducer of its own, like the guide's
  `Window`.

**There is no operator.** One reducer serves three places: `fold(0, sum)`
is the total, `scan(0, sum)` the running total, `map(reduce(0, sum))` the
total of each batch. A `sum()` operator would be a second spelling of the
first and none of the other two.

Items are integers or floats. Vectors are not taken. A number inside a
struct is taken out first, with `compose(.{ field(.cents), div(100) })`:
the compile error says so.

## Transforms

**The plain forms are the plain operators.** `add(1)` is `item + 1`, and an
overflow is what it is for `+`. That is what makes their fixtures `same`:
the loop by hand has the same operator.

**`div` rounds toward zero, `mod` is `@mod`.** Zig refuses `/` and `%` for
signed operands that are not known at compile time, so one has to be
chosen. `div` is `@divTrunc`, which is `/` wherever Zig takes `/`, and it
is `/` itself for floats, where `@divTrunc` would round the quotient. `mod`
is `@mod`, as its name says in Zig, and follows `std.math.mod` in refusing
a divisor that is not positive. For a negative item the two are therefore
not a pair: `-7` gives `-3` and `1`. The alternative was the pair of
`@divFloor` and `@mod`, for which `item == div * n + mod` holds. It was not
taken because a `div` that differs from `/` for the items where both exist
is the larger surprise. The guide states the consequence.

**`pow` takes a whole exponent that is not negative** and multiplies by
squaring, unrolled at compile time: `pow(3)` is the two multiplications one
writes by hand. It squares only as far as the exponent needs, so no product
on the way is larger than the result, and the checked form fails exactly
where the result does not fit. `std.math.pow` was not used: for integers it
is `powi(...) catch unreachable`, a loop with its own special cases, and
for floats a general power that is not `x * x`. A root or a fractional
power is a handler of the user's own over `std.math.pow`.

**`abs` is `@abs`**, so of a signed integer it returns the unsigned integer
of its size. The alternative, keeping the type, overflows for the smallest
value and would have needed a checked form; this one cannot fail.

**An operand is a value of the items' type.** Nothing is converted:
`add(-1)` for unsigned items and `add(1.5)` for integers are compile
errors where the items are known. An operand may carry a type, and a float
that is a whole number is taken for integers, since Zig takes both. What
can be seen where the operand is written is refused there: `div(0)`,
`mod(0)`, a `clamp` whose bounds are the wrong way round.

`clamp` hands `std.math.clamp` a bound written without a type as it was
written. Given as a `u32`, `@min` did not narrow its result as it does for
a literal, and the pipeline came out one instruction shorter than the
loop: better, and not the same.

## Reducers

`sum` and `product` return `state + item` and `state * item` in the type
of the state. `min` and `max` widen the item to the state before they
compare: the builtins answer in the narrowest type that holds the result.
`count` adds 1 and looks at no item.

A state has to hold every item (`holds`): the same signedness and at least
as many bits, a signed state one bit wider than an unsigned item, a float
at least as wide. An integer is not turned into a float. That is a compile
error which says to give a wider seed or to convert the items.

## The seed

This is the one change to the core in this extension, in its own commit.

**The problem.** `fold(0, f)` worked only when `f` was a function that
declared the type of its state. For a composite reducer, or an `anytype`
state, the state took the type of the seed, `comptime_int`, and the program
failed with Zig's "unable to resolve comptime value" at the call of
`program`.

**The rule, which is decided.** A seed that has a type is the state:
`fold(@as(u64, 0), sum)` is how a wider accumulator is chosen, and nothing
overrules it. A `comptime_int` or `comptime_float` seed is inferred.

**The shape, which is proposed.** A composite reducer may declare

    pub fn State(comptime Item: type) type

what it accumulates items of type `Item` in. `scan`, `fold` and `reduce`
ask for it only when the seed has no type. `sum` answers the item's type,
`count` answers `usize`. `State` and `Inferred` in `src/ops/transform.zig`
are the one place that reads a seed, for all three; `src/di.zig` is
unchanged. The order is: the parameter a reducer function declares, else
the type of the seed, else `State(Item)`, else a compile error that says to
write `@as(T, seed)`. A seed that is no value of the declared type (`-1`
for `u32` items) is a compile error too. That is asked of the seed as the
state it becomes, as it is of an [operand](#transforms) and for the same
reason: the first version took any number for a float state, and
`fold(1e300, sum)` over `f32` items began at infinity. An integer has to be
held exactly, and a float may not round to 0 or to infinity.

A seed without a type cannot be a field of the operator: there is no
runtime type to store it in until the items are known, and a
`comptime_int` field would make the whole program a compile-time value. It
is kept in the type of the operator (`Untyped`), told by a private `Mark`
and not by a name.

A handler that is no reducer is asked for its dependencies before the seed
is looked at. Without that, `fold(0, add(1))` was told to write
`@as(T, seed)`, which sends its author the wrong way; now `add` says that
it changes one item and names the reducers.

**What was weighed and not built.**

- *The item's type, with no declaration.* Wrong for `count`: the items may
  be lines, and the state is a number.
- *`State(Seed, Item)`*, which would let a reducer see the seed's type. It
  would make `fold(null, min)` possible, as an optional state. Not built:
  it widens "a seed without a type" beyond numbers, and
  `fold(@as(?u32, null), min)` already says it. It returns by decision.
- *A reducer that brings its own seed*, as in `fold(sum)`. A second form
  of `fold`, and wrong for `min` and `max`, which have no seed that is
  right for every stream.
- *Leaving the core alone*, with `fold(@as(u32, 0), sum)` everywhere. It
  works today, and is what a typed seed still means. It was the owner's
  decision that the common case should not need it.

## `min` and `max` of nothing

**The seed takes part like an item, and it is what a stream without items
comes to.** There is no other rule, and it is the rule of `fold`. For
`min` and `max` it decides the answer, so the guide spells it out:
`fold(0, max)` is right for items that are not negative,
`fold(std.math.maxInt(u32), min)` uses the value that changes no minimum,
and `fold(0, min)` is always 0.

That last one is a trap, and it is not a compile error: `State(Item)` does
not see the seed. `State(Seed, Item)` above could not catch it either,
since it sees a type and not a value.

For "nothing yet" the state is an optional: with `fold(@as(?u32, null),
min)` a stream without items comes to null. That optional is a value, as
`AGENTS.md` requires of an optional outside a predicate: the reducer drops
nothing and skips nothing, `scan` emits every state, and what comes after
decides what null means. Only `min` and `max` take an optional state; for
`sum` it is a compile error, since a sum of nothing has a value.

## Plain and checked

`checked` holds the forms that can overflow: `add`, `sub`, `mul`, `pow`,
`neg`, `sum`, `product`. They go through `std.math.add`, `sub`, `mul` and
`negate` and return `error{Overflow}!T`, so `orElse`, `attempt` and
`recover` take the failure as any item's. Their items are integers; for a
float the compile error says to write the plain form.

**`checked` holds only what can fail, and fails with nothing but
`error.Overflow`.** The brief named `error.DivisionByZero` as well. It
cannot occur: the divisor is known at compile time and `div(0)` does not
compile. An error in the set that never happens would have to be named in
every `recover` and every rescue that switches over what is left. So:

- no `checked.div`: the one division that overflows is the smallest value
  of a signed type by -1, and that is `checked.neg`;
- no `checked.mod`: with a divisor greater than 0 it cannot fail;
- no `checked.abs`, `clamp`, `min`, `max`, `count`: they cannot fail.

`tests/math.zig` asks a run of every checked form what is left for it to
fail with, and the answer is `Overflow` alone.

## `Stats`

`Stats(T)` has the fields `count`, `min`, `max` and `mean`, and
`Stats(T).add` as its reducer: `fold(Stats(f64){}, Stats(f64).add)`.

`mean` is a field and not a method so that a `Stats` can go on down the
pipe as it is, into `json.encode` or a `print`. It is the running mean,
`mean + (item - mean) / count`: a division per item, and no sum that a
long stream of integers would overflow. It is a float of the items' type,
and an `f64` for integers.

Before the first item `count` is 0, `mean` is 0, and `min` and `max` are
the values every item replaces: the largest and the smallest value of `T`,
infinity for a float. The alternative was optional fields. It was not
taken: `count` already says whether there was an item, and the identities
are what the loop by hand starts from, which keeps the fixture `same`.

## Measurements

`zig build zero-overhead`, for `aarch64-linux` and `x86_64-linux`:

| Fixture | Holds |
|---|---|
| `same_math_transforms` | `clamp`, `mod`, `add`, `pow`, `mul`, `sub`, `div` on a `u32`, and `sum` into a `u64` |
| `same_math_signed` | `div`, `mod`, `neg`, `sub` on an `i32` |
| `same_math_floats` | `neg`, `sub`, `div`, `pow`, `abs`, `clamp` on an `f64` |
| `same_math_reducers` | the five reducers, each ending a `fold` |
| `same_math_places` | `max` in `reduce`, `sum` in `scan` and in `fold` |
| `same_math_checked` | `checked.mul`, `add`, `pow` and `sum` |
| `same_math_stats` | `Stats(u32)` as the state of a `fold` |
| `lean_math_abs` | `abs` on an `i32` |

`lean_math_abs` has the same instructions on both sides. The handler was a
function of its own before it was inlined, and the optimizer wrote the
range of what it returns on the call of `llvm.abs`; the loop has the call
without the note, and `tools/same_code.zig` compares the text.

Not in a fixture: `checked.sub`, `checked.neg`, `checked.product`, and
`mod` of a float (a call into the runtime on both sides). They are the
same mechanism as what is there and are covered by `tests/math.zig`.

What the fixtures had to be arranged around, none of it a cost of the
extension:

- **A fixture that names a new error has to stand before the first one
  that names an error.** `same_math_checked` brings `error.Overflow` into
  `cases.zig`. The integer behind an error is given out as the compiler
  comes to the name, and it comes to the exported functions at the end of
  the file first. Appended at the end, the fixture took the number of
  `TooSmall`, and `same_require`, `same_rescue` and `same_recover_fail`
  failed with `icmp uge` on one side and `icmp ult` on the other. A probe
  with `@intFromError` confirmed the numbers. It stands before `recover`.
- **A range written into an instruction.** Given the result of earlier
  arithmetic, an intrinsic (`@min`, `@max`, `@abs`) or a `zext` into an
  overflow check carried a `range(...)` that differed between the
  variants. The fixtures give such an operation the item as it comes.
- **Neighbours the optimizer folds.** `-(x / 3)` and `(x + 7) - 8` with
  overflow checks were merged in one variant and not in the other, a
  difference of one instruction, once in favor of the pipeline. Such pairs
  are not next to each other in a fixture.

## Not there

Back only by decision:

- forms that wrap or saturate (`+%`, `+|`);
- a power that is not a whole number, and roots;
- conversion between integers and floats, such as a `Stats(f64)` over
  integer items without a `map` before it;
- vectors as items;
- `fold(null, min)`, see [The seed](#the-seed);
- a compile error for `fold(0, min)`.
