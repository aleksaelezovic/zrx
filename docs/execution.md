# Execution, dependencies, sharing, and ownership

[Documentation index](README.md) · [Signal lifecycle](state.md)

## One declarative execution boundary

`pipe` connects declared inputs and stages. `fromValue` stores one typed value;
`fromSlice` borrows finite storage; producers, iterators, queues and I/O describe
other inputs. Construction does not iterate, call stage callbacks, acquire
resources, or start tasks. Ordinary Zig expressions used to build configuration
still evaluate normally.

[`fromService(T)`](../src/data/declarations.zig) starts a pipe with one shallow
copy of an exact typed binding, borrowed or managed, after acquisition. It
reads afresh each run without transferring ownership or interpreting optional/
error-union bindings as control flow. Normal DI validation and sharing apply.
It lowers as a finite singleton source, not a producer/queue boundary.

[`flatMap(factory)`](../src/ops/flatMap.zig) expands each successful item into a
by-value synchronous declaration, draining it before taking another outer item.
It supports finite pull forms such as values, slices, services, iterators,
`readChunks` and `readerLines`, including their synchronous operators. The callback and child
requirements join the enclosing run's static DI plan; there is no per-item
acquisition, nested run, task or dynamic subscription. Shared declaration
references and child graph/terminal boundaries are not supported. Here "finite"
identifies the supported pull forms, not a proof that a supplied reader or
iterator will terminate. Borrowed positions are consumed, not rewound.

[`flatten()`](../src/ops/flatten.zig) expands array, slice or owned `Chunk` items
in order. The cursor retains the current array/Chunk value, so a callback may
return an array by value without lending a slice into a temporary. Slice
referents remain borrowed. `map(factory), flatten()` is the simple array/chunk
flat-map form; `flatMap` instead expands cold declarations.

[`splitBy(separator, options)`](../src/ops/splitBy.zig) frames arrays/slices/Chunks
across chunk boundaries. A delimiter value or pure typed predicate selects
elements to exclude; predicates use normal service injection. Owned bounded
frames survive later input, sharing and retention. Default policy emits empty
delimited frames and a nonempty tail only at normal end. `.empty = .skip` treats
delimiter runs as separators; `.final = .discard` drops the unfinished tail.
It is serial state inside the direct-call region, not a new task/queue. Reader
resources own bytes and buffering, independently of framing.

Only `run(bindings, flows)` executes programs. Selected roots must terminate with
effects returning `void` or `E!void`. Intermediate declarations may return items,
signals, or reduction results. Unselected descriptions stay cold.

## Typed dependency injection

Bindings form a flat heterogeneous tuple. Exact Zig service types are keys.
Supply `std.mem.Allocator` and `std.Io` directly; tuple order is immaterial.
Other entries can be borrowed values or managed recipes providing a service type.
Repeated requests share one binding. Missing keys, duplicate provided types and
reachable provider cycles fail compilation. There is no service registry or
per-item lookup.

Callback functions are comptime-known and have explicit runtime parameter and
return types. Operators determine the trailing ordinary arguments:

| Callback | Ordinary suffix | Injected prefix |
|---|---|---|
| `map`/`each`, `filter`, `tap`, `forEach` | Item | All preceding parameters |
| `flatMap` factory | Item | All preceding parameters |
| `splitBy` predicate | Chunk element | All preceding parameters |
| `collectThen`, `batchThen` | Borrowed `[]const T` | All preceding parameters |
| `fold`, `scan` | Accumulator, item | All preceding parameters |
| Producer | `*Emitter(T)` | All preceding parameters |
| Resource acquire | Configuration | All preceding parameters |
| Resource release | Provided service value | All preceding parameters |
| `reader`/`writer` configuration provider | None | All parameters |

The suffix is always data, even if a matching service type exists. A struct
parameter requests that struct as one service; it is not implicitly unpacked.
Generic callbacks, callback closures and runtime function pointers are unsupported.
Map/each, filter and tap accept a callback or a flat nonempty callback tuple
through one composition rule. Terminals and reductions take one callback.
`map` and `each` map stream items as whole values, including slice/array items.
Signal `map` instead derives the whole current state.

Two services of one implementation type use distinct nominal role wrappers.
`deriveResource` delegates one single-field role's lifecycle to its configured
recipe. It does not infer ownership or construction from a pointer type.
See the [resource example](../examples/resources.zig).

## Resource lifetime

Reachable recipe dependencies, including release-only dependencies, determine
acquisition order. A successful acquire is released once in reverse dependency
order; a failing acquire cleans up its own partial construction. Borrowed bindings
are never implicitly destroyed. Values and injected parameters are shallow copies;
address-stable mutable services should explicitly contain pointers.

For a constructor-only derived value with no independent cleanup, use
`resource(config, acquire, null)`. Its declared dependencies are still acquired
first and retained through all users. Null means no finalizer, not inferred
destruction, ownership transfer, or permission to leak acquired handles.

Finite programs prepare terminal buffers before acquisition. Graph programs
prepare readers/state/terminal buffers and gated terminal/state workers before
recipe acquisition, selected I/O acquisition, initial signal computation, and
activation. Preparation/startup failure is cold. Acquisition may create/truncate
files or establish connections; those effects are not rolled back.

On return or failure, execution users stop/join before owned resources release.
Release callbacks return `void` and must use non-failing, uncancelable cleanup.
Fallible finalizers are a separate design. No panic unwinding or rollback is
promised.

## Synchronous regions, not one worker per stage

Ordinary synchronous stages compose into typed loops. A finite, unshared program
needs no transport, concurrent worker or planner heap allocation. Merely naming
an exclusive stage by pointer does not introduce a worker/queue. The compiler can
inline ordinary calls; no forced inlining or universal zero-cost claim is made.

Before graph activation, a bounded alias scan counts actual address-and-type
references. It distinguishes shared evaluation from independent descriptions.
Exclusive map/filter/tap/fold/scan/prefix/limit chains fuse into their terminal or
shared publication region. Runtime selection happens before processing, not as
a per-stage hot-loop interpreter.

Producer-backed inputs, shared delivery, merge, retention, sampling and signal
families currently retain audited transport/lifetime machinery. Not every
retained boundary is claimed to be the final minimal lowering. Independent
graph roots run concurrently; synchronous stages within a region do not promise
independent progress or inter-stage buffering. Explicit execution-boundary
operators and worker/queue primitives are not implemented.

Pointer identity shares one source/derived evaluation per run. By-value copies
are independent descriptions. Each selected delivery edge gets a reader; a new
run creates fresh resources and calls producers again, not a replay or reset of
borrowed application state. Keep declarations and referents stable through run.

[`branch`](../src/ops/branch.zig) routes into persistent case substreams,
evaluating injected `when` predicates in order until the first match. An optional
`otherwise` must be last. All cases either produce the same item type, merged
with per-case order and unspecified interleaving, or all end with terminal
effects and the branch itself is a selected terminal. Each case owns its own
fold/scan/prefix state. Unmatched items or items for a retired case are dropped;
retiring one case does not stop its live siblings.

## Completion, bounds, and errors

- `take(n)` succeeds after at most n items, with no extra input probe. Zero reads
  none but still acquires selected resources. Prefetch can do extra upstream work.
- `maxItems(n)` consumes but does not forward the first excess item, then fails.
  Exactly n still needs end/excess observation.
- `takeLast(n)` retains a run-owned shallow ring and publishes only after normal
  end. Zero still consumes and observes source errors.
- Collection is not bounded by transport capacity. `collectThen` borrows its
  result slice only during its successful-end callback.
- `batchThen` preallocates a positive-size buffer, calls full batches serially,
  and flushes a nonempty partial batch only on success. Failure discards pending
  items, not previously completed effects.

Stream operation errors skip success stages until explicit recovery/routing;
only unhandled terminal outcomes fail run. Source optional/error-valued items
remain data; signal-map optional/error results remain state. `fold` is a
run-executed left reduction starting from a shallow seed copy and stopping on
reducer error. There is no separate eager or `try` executor. See the
[error model and stateful boundaries](errors.md).

[`retryPipe`](retries.md) explicitly captures errors from its map/tap attempt:
it retries the original item using run-supplied Io and forwards its final
success or pending operation error through the ordinary handling model.
Cancellation and source/acquisition failures remain execution control.
It adds no implicit worker, does not reset stateful stream operators and supplies
no idempotency or durability guarantee.

[`scan`](../src/ops/scan.zig) instead emits every accumulated value, without seed
or an extra final result. Its pure reducer uses the same injected prefix and
ordinary state/item suffix, but cannot return an outer error union. Each run
starts fresh; empty input emits nothing. Exclusive recurrences stay in typed
cursors; shared references publish one recurrence through the normal boundary.
Use `hold(seed)` when current progress must be sampled. Neither scan nor hold
deep-copies referents. See the [transfer monitor](../examples/scan.zig).

First observed failure cancels peers without undoing earlier effects. Successful
terminal finalization precedes edge retirement. Closed transport drains admitted
items; removing the last reader retires its exclusive upstream chain without
stopping live siblings. Signal families remain run-scoped and sampleable after
normal update end. Shutdown cancellation cannot replace a selected result.

Cancellation is cooperative. Traversal polls between input items/acquisitions;
callbacks may use cancelable Io. Non-returning/non-cancelable code can prevent
shutdown. Callbacks must join work using borrowed arguments before returning.
Allocators/capability referents used by concurrent graph work must be safe for
that use. Retrying run can repeat external effects; this is not durable recovery.

HTTP is a scoped exception to ordinary shallow-item retention: request/body/
response storage lasts only through that request's final delivery. Supported
exclusive pipelines track completion, including filtered/unanswered requests.
Unsupported fan-out/retention/stateful compositions fail before listening.
See [HTTP request scopes](http.md) rather than assuming run-scoped referent validity.
