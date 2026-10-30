# Values, sequences, and storage

Value operators evaluate as ordinary function calls; sequence views and terminal
effects describe deferred work. `pipe` passes one value between stages, including
optional values and error unions; it never implicitly unwraps them or skips stages.
For explicit error short-circuiting, see [fail-fast composition](try_pipe.md).
For consuming iterators and Io-backed queue inputs, see [streams](streams.md);
the borrowed slice contracts below remain repeatable and require no Io.

| Operator | Input → output |
|---|---|
| `map(transform)` / `map(.{ first, second })` | Whole value → transformed value |
| `map(transform)` on a signal | Deferred whole-current-state derivation → signal |
| `keepIf(predicate)` | Predicate input type `T` → `?T` |
| `filter(predicate)` | Borrowed sequence → lazy view of matching elements |
| `each(transform)` / `each(.{ first, second })` | Borrowed sequence → lazy view of transformed elements |
| `fold(initialState, reducer)` | Sequence → accumulated `A` |
| `tryFold(initialState, reducer)` | Sequence → `E!A`, stopping at the first reducer error |
| `maxItems(limit)` | Sequence → lazy view that fails on an excess item |
| `takeLast(limit)` | Sequence → run-backed description retaining the final suffix |
| `merge(inputs)` | Same-item-type input tuple → run-backed fan-in description |
| `forEach(effect)` / `forEachWith(capability, effect)` | Sequence → deferred per-item effect flow |
| `collectThen(effect)` / `collectThenWith(capability, effect)` | Sequence → deferred whole-collection effect flow |
| `batchThen(size, effect)` / `batchThenWith(size, capability, effect)` | Sequence → deferred count-based batch effect flow |

Transformers and predicates are comptime-known functions with one explicitly
typed runtime parameter and an explicit return type. Predicates must return
`bool`. Tuple transforms compose left to right; empty and nested tuples are rejected.
Zig's normal argument coercions apply.

`keepIf` calls its predicate once and returns the coerced input on a match, or
`null` otherwise. The next stage still receives that optional: absence is data,
not implicit control flow.

## Borrowed lazy sequences

Sources are slices, pointers to arrays, or zrx sequence views. Pass arrays by
reference (`&items` or `items[0..]`), not by value. Neither `filter` nor `each`
allocates or runs callbacks when constructing a view.

An allocation-free slice view exposes `iterator()`, whose cursor follows Zig's
conventional `next()` interface and yields `?Item`. Each new iterator starts from the beginning;
copying a cursor copies its current position. Callbacks run during consumption,
in source order, only as needed to produce the next element. Repeated iteration
reruns callbacks and sees current source contents, not a snapshot.

These are small lazy adapters, not a new byte-stream or I/O framework.
Conventional mutable iterators can be borrowed explicitly with `fromIterator`;
standard queues use `readFrom(io, &queue)`. Those inputs are consuming rather
than repeatable. All public terminal effects use `run`, regardless of input
kind. Declarative `Stream(T)` sources and `takeLast` descriptions cannot be
iterated directly; neither can a [`merge`](merging.md) declaration. Their storage
and execution belong to `run`. Prefer standard
readers/writers for ordinary byte I/O.

[Signal declarations](signals.md) are not directly iterable sequences. Use
`map` to derive their current state, `values` for a snapshot stream, and
`withLatestFrom` for event-triggered sampling. Array/slice state stays one whole
value; `each` directly on a signal is rejected.

The source must outlive the view and its iterators. Do not mutate source storage
while consuming a view. Results are shallow values; pointers or slices produced
by callbacks retain their own borrowing requirements. Error unions and optional
elements are preserved as elements, not unwrapped or dropped.

## Terminal effects and storage

`forEach` describes per-item effects; `collectThen` describes a callback over
the complete collection after successful end. Neither traverses input when
constructed. Their `With` variants carry explicit application capabilities.
`run` supplies allocator/Io and owns execution and collection backing storage.
`batchThen` processes successive bounded groups with one run-preallocated
buffer; see [batch lifetime and completion rules](batching.md).

Collection callbacks borrow `[]const T` during the callback only. Copy into
application-owned storage if retention is needed. Partial collection is discarded
on source failure, cancellation, or allocation failure; earlier effects in other
flows are not rolled back. The former public `collectInto`/`collectAlloc`
operators are retired.

Optional `maxItems(n)` rejects excess output with `TooManyItems`, rather than
truncating. Its position determines which elements are counted. It must observe
end or one additional item, so reaching the limit alone does not complete a
live input. `takeLast(n)` instead retains a final suffix in a run-owned ring and
publishes it only after successful end. See
[terminal contracts and collection ownership](terminals.md).

See the executable [sequence example](../examples/sequences.zig).

## Reduction

Use `fold(initialState, reducer)` for eager, ordered accumulation without
materialization. Use `tryFold(initialState, reducer)` for per-item fail-fast
reduction, independently of the executor. Empty input returns the seed.
These finite, infallible-cursor reductions do not activate stream graphs;
run-backed sources and fallible cursors require a separate consumption boundary.
See [reduction contracts and ownership](reduction.md) and the executable
[reduction example](../examples/reduction.zig).

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
zrx does not wrap or replace `std.Io`. Stream graph execution has an explicit
[`run` resource/cancellation boundary](pipes.md); the pure/slice core does not.
Multi-parent state, reactive reducers, and durable/idempotent workflow policies require
separate review.
The [synchronous effect operators](effects.md) use these capabilities directly.

## Optimization and SIMD

`each` is a lazy elementwise transformation, not a terminal `forEach` effect.
Ordinary LLVM optimization may inline, fuse, or auto-vectorize its consumer
loops when the target and callback semantics permit. There is no zrx SIMD mode
and no guarantee that a particular loop vectorizes. Filtering, aliasing, and
callback side effects can constrain these optimizations.

For explicit vector math, a typed `@Vector` callback already works through
whole-value `map`; no vector-specific operator is needed. Actual instruction
selection and vector width remain target/compiler decisions.

The [codegen catalog](../tests/codegen/catalog.zig) distinguishes strict LLVM
comparisons, AArch64-only assembly comparisons for `each` and `fold` sum loops,
and behavior/cross-only cases. In the pinned compiler, `keepIf` plus optional
recovery still differs from a hand-written branch, so it is not an equality
claim. Native fixture tests also compare outputs, including short inputs,
tails, and wrapping arithmetic.
