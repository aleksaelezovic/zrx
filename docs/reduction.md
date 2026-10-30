# Finite-sequence reduction

`fold(initialState, reducer)` and `tryFold(initialState, reducer)` eagerly consume
an existing borrowed slice, pointer to an array, or zrx view in source order.
They return one accumulated value without materializing the sequence.
See the executable [reduction example](../examples/reduction.zig).

These eager value operators stay separate from run-backed stream graphs.
Their source cursor must be infallible: stream declarations and fallible
iterator adapters/count guards are not accepted directly. Use a run terminal
such as `collectThen` and reduce its finite callback slice when needed.
Source-error propagation for eager reduction is a separate contract, not
silently added to the reviewed reducer error sets.

| Operator | Reducer | Stage output |
|---|---|---|
| `fold(initialState, reducer)` | `fn (A, T) A` | `A` |
| `tryFold(initialState, reducer)` | `fn (A, T) E!A` | `E!A` |

The reducer is one comptime-known function with two explicitly typed runtime
parameters and an explicit return type. Generic callbacks, function pointers,
closures, and callback tuples are unsupported. The first parameter determines
the accumulator type `A`. The initial value is coerced to `A` once when the
operator is constructed; it may be a runtime value or a literal. Source elements
coerce normally to `T`, which need not equal `A`.

The result type (success payload for `tryFold`) must **exactly** match `A`.
`A` cannot itself be an outer error union. `fold` rejects outer error-union
returns; use `tryFold` for fallible reducers. `tryFold` requires an error-union
return, including an explicit `error{}!A` if desired.

## Order and consumption

Neither operator iterates or invokes callbacks during construction. Each
application starts a fresh cursor and a shallow copy of the stored seed. The
reducer receives that state by value and returns its replacement, left to right.
There is no reassociation, parallelism, or hidden allocation.

Empty or all-filtered input returns the seed with zero reducer calls, as success
for `tryFold`. A completed traversal of `n` yielded items calls the reducer `n`
times and cursor `next()` `n + 1` times, including exhaustion.

Upstream lazy callbacks run interleaved with reduction as needed to produce
each item; filters can examine more source items than they yield. Views remain
reusable over slices: another application starts over, rereads storage, and reruns
callbacks. An infallible conventional iterator may be borrowed explicitly through
`fromIterator`; reuse then resumes its shared position rather than rewinding.
Such consuming sources must eventually end for reduction to complete. Arrays
by value, bare cursors, and arbitrary unadapted iterators are not accepted sources.
Even empty input must satisfy source and callback type contracts at comptime.

## Loop errors and pipeline errors

`tryFold` stops at the first reducer error under **both** executors. Failure on
the `k`th yielded item invokes the reducer `k` times and cursor `next()` `k`
times: no extra probe or later upstream callbacks. The error is returned, not
passed back into the reducer.

- `pipe` passes that `E!A` result to the next stage as data; an explicit recovery
  callback can continue the pipeline.
- `tryPipe` checks the returned outer error union and skips later stages on
  failure. Its error set merges the input and stage error sets normally.

`tryFold` controls iteration; `tryPipe` controls pipeline stages. Neither
executor automatically inspects error-union or optional sequence elements.
Those elements, and errors nested inside accumulator fields or optional
payloads, remain ordinary data. A `tryFold` reducer must explicitly return an
outer error to terminate consumption. See [executor boundaries](try_pipe.md#boundaries-and-grouping).

## State and ownership

Each application starts from the operator's stored seed, not its previous
result. Copying the operator copies the seed shallowly. Pointers and slices still
alias their referents: reuse does not reset externally mutated state.

Reducers may carry explicit allocator, writer, or state capabilities in their
accumulator. `foldWith` and similar `With` helpers are deferred. Use existing
`filter`/`each` before folding, `map` after it, and `tap`/`tapWith` for result
effects. There is no special reducer tuple or new context framework.

Neither operator itself allocates, clones, frees, closes, or rolls back anything.
On `tryFold` failure, earlier effects remain; the local accumulator is not
returned or deinitialized. Keep owned resources reachable from a caller/helper
cleanup scope with `defer`/`errdefer`. Reusing copied ownership handles does not
transfer ownership or deep-clone resources.

Borrowed storage and capabilities must outlive their use and any borrowed
results. Do not mutate source storage during consumption or return references
to temporary accumulator storage. Large states may have copying costs; no
copy-elision or general zero-overhead guarantee is made.

## Validation scope

Native and compile-fail tests cover types, empty input, ordering, coercions,
state reuse, error data, early stopping under both executors, and caller cleanup.
Exported runtime-input fixtures instantiate both operators across the existing
[target matrix](../tests/codegen/catalog.zig), without executing foreign binaries.
The catalog records scoped codegen comparisons separately from behavior/cross-only
coverage. The infallible sum fixture matches the direct loop's scoped assembly
on the three catalog AArch64 targets. The `tryFold` fixture differs in LLVM IR
and remains behavior/cross-only; this is not a general performance claim.
Scan, seedless reduce, and stateful reactive reduction remain future design topics.
