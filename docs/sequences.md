# Values, sequences, and storage

All stages run synchronously. `pipe` passes one value between stages, including
optional values and error unions; it never implicitly unwraps them or skips stages.
For explicit error short-circuiting, see [fail-fast composition](try_pipe.md).

| Operator | Input → output |
|---|---|
| `map(transform)` / `map(.{ first, second })` | Whole value → transformed value |
| `keepIf(predicate)` | Predicate input type `T` → `?T` |
| `filter(predicate)` | Borrowed sequence → lazy view of matching elements |
| `each(transform)` / `each(.{ first, second })` | Borrowed sequence → lazy view of transformed elements |
| `collectInto(buffer)` | Sequence → `error{NoSpaceLeft}![]T` borrowing the buffer |
| `collectAlloc(allocator)` | Sequence → `error{OutOfMemory}![]T` owned by the caller |

Callbacks are comptime-known functions with one explicitly typed runtime
parameter and an explicit return type. Predicates must return `bool`. Tuple
transforms compose left to right; empty and nested tuples are rejected.
Zig's normal argument coercions apply.

`keepIf` calls its predicate once and returns the coerced input on a match, or
`null` otherwise. The next stage still receives that optional: absence is data,
not implicit control flow.

## Borrowed lazy sequences

Sources are slices, pointers to arrays, or zrx sequence views. Pass arrays by
reference (`&items` or `items[0..]`), not by value. Neither `filter` nor `each`
allocates or runs callbacks when constructing a view.

A view exposes `iterator()`, whose cursor follows Zig's conventional `next()`
interface and yields `?Item`. Each new iterator starts from the beginning;
copying a cursor copies its current position. Callbacks run during consumption,
in source order, only as needed to produce the next element. Repeated iteration
reruns callbacks and sees current source contents, not a snapshot.

These are small lazy slice adapters, not a new general iterator or byte-stream
framework. Standard readers/writers and other existing iterators should be used
or adapted when a later operator needs them; they are not sequence sources yet.

The source must outlive the view and its iterators. Do not mutate source storage
while consuming a view. Results are shallow values; pointers or slices produced
by callbacks retain their own borrowing requirements. Error unions and optional
elements are preserved as elements, not unwrapped or dropped.

## Materialization

`collectInto` borrows mutable caller-owned storage. On success it returns only
the initialized prefix; the unused suffix is unchanged. Empty output fits an
empty buffer. If capacity is insufficient it returns `error.NoSpaceLeft`:
the already-written prefix remains modified, and one additional output element
has been evaluated to detect overflow. It never silently truncates. Source and
output storage must not overlap.

`collectAlloc` uses `std.ArrayList` with the supplied `std.mem.Allocator`.
The caller must free the returned slice with the same allocator. Allocation
failure cleans up intermediate storage, but callback side effects are not rolled
back. Neither collector takes ownership of source storage or deep-copies elements.
The input view itself remains reusable after collection.

See the executable [sequence example](../examples/sequences.zig).

## Runtime capabilities and custom operators

An operator is a struct value exposing:

- `pub fn Output(comptime Input: type) type` to declare its output type.
- `pub fn apply(self: Self, value: ...) ...` to execute it.

`pipe` specializes on operator types, while instances may carry runtime state
such as an allocator, `std.Io`, a buffer, or a pointer to caller-owned state.
Instances are passed by value; borrowed fields must remain valid. `apply` must
accept `self` by value and its result must coerce to the declared output type.
Named factory functions keep these details outside the pipeline expression.

There is no implicit service context, allocation, I/O, error propagation, or
scheduling. Custom operators can use standard-library capabilities directly;
zrx does not wrap or replace `std.Io`. Observables, reducers, cancellation, and
durable/idempotent workflow policies require separate review.

## Optimization and SIMD

`each` is a lazy elementwise transformation, not an eager `forEach` effect.
Ordinary LLVM optimization may inline, fuse, or auto-vectorize its consumer
loops when the target and callback semantics permit. There is no zrx SIMD mode
and no guarantee that a particular loop vectorizes. Filtering, aliasing, and
callback side effects can constrain these optimizations.

For explicit vector math, a typed `@Vector` callback already works through
whole-value `map`; no vector-specific operator is needed. Actual instruction
selection and vector width remain target/compiler decisions.

The [codegen catalog](../tests/codegen/catalog.zig) distinguishes strict LLVM
comparisons, AArch64-only assembly comparisons for an `each` sum loop, and
behavior/cross-only cases. In the pinned compiler, `keepIf` plus optional
recovery still differs from a hand-written branch, so it is not an equality
claim. Native fixture tests also compare outputs, including short inputs,
tails, and wrapping arithmetic.
