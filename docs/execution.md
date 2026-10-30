# Execution, sharing, and ownership

[Documentation index](README.md) · [Signal lifecycle](state.md)

## Choose the boundary

| Work | Boundary |
|---|---|
| Whole-value transformations/effects | [`pipe`](../src/pipe.zig), ordinary evaluation |
| Eager outer-error short-circuiting | [`tryPipe`](../src/tryPipe.zig) |
| Lazy borrowed slice traversal | [`filter`](../src/ops/filter.zig)/[`each`](../src/ops/each.zig) cursors; no allocator/Io |
| Finite infallible-cursor reduction | [`fold`](../src/ops/fold.zig)/[`tryFold`](../src/ops/tryFold.zig), eager when applied |
| Stream graphs, signals, all public terminals | [`run(allocator, io, flows)`](../src/run.zig) |

`pipe` is not an implicit effect runtime. It passes errors and optionals as data.
`tryPipe` checks only eager outer error-union boundaries, not sequence elements
or deferred signal state. `tryFold` explicitly stops inside its reducer loop.
Neither value executor cleans up owned intermediates or rolls back effects;
keep ownership reachable in caller/helper `defer`/`errdefer` scopes.

Stream/terminal declarations allocate nothing, start nothing, and need no
`deinit`. Pure stages still evaluate normally: declaring a terminal does not
defer arbitrary preceding side effects. Initial expressions and capability
construction also remain ordinary caller code.

## Identity and demand

Refer to a stable source/derived declaration by pointer to share its execution
node within one run. Identity is **address and type**, not matching functions or
descriptions. By-value copies are independent and can activate separate producers.
Keep descriptions alive and unmodified through execution.

Only nodes reachable from selected terminal flows are instantiated. Each active
edge gets an independent reader; unused declarations retain no input. A common
derived node evaluates once per item it processes, then distributes results.
Repeating `&source` in a merge is two delivery edges, not two activations.
Referencing one merge shares the same chosen interleaving among its consumers.

See the [shared-pipe example](../examples/pipes.zig) and
[merge example](../examples/merge.zig). Shared mutable capabilities require
application synchronization: independent nodes/flows can run concurrently.
There is no tuple-order guarantee for independent effects.

## Buffering and progress

Declared streams require positive capacity (`UnsupportedCapacity` for zero).
Conventional sources use capacity-one forwarding; derived nodes inherit upstream
capacity. Merge has capacity-one output plus one in-flight item per input worker,
besides input buffering. Slow selected readers apply bounded lossless backpressure,
not replay, coalescing, fairness, or a lossy queue policy.

Queue bounds do **not** bound a whole-input collection. Choose:

- [`maxItems(n)`](../src/ops/maxItems.zig): reject excess at its pipeline position,
  consuming but not forwarding the first excess item. Reaching n still waits for
  end/excess; this cannot make an endless source finite.
- [`takeLast(n)`](../src/ops/takeLast.zig): preallocated n-item suffix ring,
  publishing only after successful end, including for finite inputs.
- [`batchThen`](../src/ops/batchThen.zig): fixed reusable buffer, full callbacks
  while open; flush a nonempty partial batch only on successful end.
- [`collectThen`](../src/ops/collectThen.zig): growing accumulation, one callback
  after successful end, including an empty slice for empty input.

Operator order matters: a guard before filtering counts input; afterward it
counts matches. Retention/batching after merge follows the chosen interleaving,
not separate per-input sequences. Retention and collection own separate storage;
there is no implied buffer transfer or deep payload-memory bound.

Current lowering materializes owned transport per recognized derived node,
including linear ones. It reuses standard Io/transport machinery, not a new
scheduler. Fusion/resource reductions are future work, not zero-overhead claims.

## Lifetimes and cleanup

`run` borrows declarations and application capability referents. It owns queues,
reader records, producer/forwarding/updater tasks, caches, and prepared batch
buffers. Resources/readers and gated consumer/state workers are prepared before
initial signal maps and activation. Preparation or consumer/state-worker startup
failure frees partial runtime state without producer/effect/initial-map calls.
Merge's local forwarding-worker startup occurs after graph activation; its gate
prevents partial local forwarding, but peer flows may already have worked.

On success, failure, or cancellation, consumers join before terminal buffers
are freed; updaters stop before publication transport; derived workers stop
before upstream producers. Caches survive until samplers and stream work join.
Collection buffers are freed in their consumer after the callback or on failure.
Prepared cold batch/retention storage is also freed on startup failure.

Collection/batch callbacks borrow read-only slices **only during their calls**.
Join work using them before returning, or copy into explicitly application-owned
storage through a capability. All items/snapshots are shallow. Copying slice
headers is not retaining backing storage or deep-copying referents. Storage
valid only until an iterator's next call needs a stable copy before entering
buffered execution. Overwriting/dropping an item does not infer destructors.

An emitter is valid only during its producer call. Producer-local allocations
still need explicit cleanup. `push` acknowledges admission, not callback
completion or signal commit. Use standard readers/writers/clients directly
where appropriate; see the [I/O adapter scope](../src/io/README.md).

## Completion and failures

Source/iterator/callback failures are execution errors; optional/error-valued
items remain data. Standard queue closure means end only after draining;
a producer returning `Closed` is still a failure.

The first observed failure fails the run and cancels peers. No input/tuple-index
priority is promised. Peer buffered prefixes, pending collection, partial batches,
or retained suffixes may be discarded. Earlier effects/commits remain, and
already-running callbacks cannot be atomically revoked. Cleanup cancellation
does not replace the recorded result.

Blocking/long callbacks must cooperate with cancellation. Non-returning,
non-cancelable code cannot be forcibly interrupted; synchronous feedback waiting
on the same backpressured graph can deadlock. Worker startup can fail with
`ConcurrencyUnavailable`; no inline blocking fallback is promised.

A later run creates fresh transport/caches and invokes producers again, not
replay or reset of borrowed iterators/application state. Retrying can repeat
external effects. Concurrent runs need safe shared capability referents.
Public `collectInto`/`collectAlloc` are retired; private eager collector/reader
fixtures retain low-level lifecycle coverage but are not application APIs.

Writable refs, multi-parent state, dynamic graph edits/subscriptions, late joining,
arbitrary custom graph lowering, timers/windows, batch-producing streams, lossy
policies, replay, retries, persistence, and durable/exactly-once effects remain
separate designs. A check-then-skip alone would not establish durability.
