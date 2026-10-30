# Signal coherence and lifecycle

[Documentation index](README.md) · [Execution and ownership](execution.md)

The [tested example](../examples/signals.zig) observes temperatures **20, 23, 18**
and derived comfort **comfortable, warm, cool**: `zig build example-signals`.
Construction/typing contracts live beside [`hold`](../src/ops/hold.zig),
signal [`map`](../src/ops/map.zig), [`values`](../src/ops/values.zig), and
[`withLatestFrom`](../src/ops/withLatestFrom.zig). Signal declaration/borrowing
rules live in [`data/signals.zig`](../src/data/signals.zig).

## One root family, one coherent commit

Only reachable dependencies are prepared. Stable references share a
cache/derivation; unused state runs no transforms and retains no input.
Run prepares resources and gated workers, evaluates pure initial maps, then
initializes all selected caches/stages initial snapshots before activation.

Each root processes replacements serially:

1. Compute selected single-parent derived candidates in dependency order,
   outside the cache lock.
2. Commit root and derived caches together under a short per-family
   `std.Io.Mutex`, using supplied Io for contended waits/wakes.
3. Unlock, then publish snapshots in source order.
4. Finish lossless publication before processing the next replacement.

A sample during derivation sees old committed state; afterward it sees fully
committed new state. No user callback or queue wait holds the commit lock.
A shared derived node evaluates once per turn, including initial state.
Grouped/separate maps preserve value/error semantics; purity is a caller
contract, not something comptime can prove.

This is not a transaction across independent roots, effects, or I/O. Chained
samples are separate reads. Large states, many caches, or concurrent samplers
can make the critical section costly despite the standard mutex's uncontended
atomic fast path; no unmeasured bottleneck/performance claim is made.

## Observation is not sampling

`values` publishes initial state and every committed replacement, including equal
root/derived results. Its capacity-one shared publication buffer backpressures
slow readers. A slot is released after every reader has read it, not after every
callback finishes. Other queues and in-flight work have separate costs.

Commit precedes notification: a sampler may see new state before a slow observer
renders it. `Emitter.push` confirms input admission, not commit. Separate update
and event sources have no causal/wall-clock ordering guarantee; use an explicit
application protocol when a request must see a particular update.

`withLatestFrom` emits ordinary `.{ event, snapshot }` pairs without flattening
tuple-valued elements. Updates alone emit no pair and sampling consumes no state.
An active sampling dependency consumes updates even while requests are idle;
without observers it retains current/candidate state, not history.
Collection/batching over `values` counts the initial snapshot.

## Completion and supervision

| Situation | Result |
|---|---|
| Update input ends normally | Final cache remains sampleable; observations drain/close |
| Event input ends | Its sampling flow finishes without waiting for more updates |
| Update source fails | Fail the run, including idle samplers without observers |
| Optional/error-valued state | Preserve it as data, under both pipe executors |
| All selected terminals finish | End the run and stop remaining updater dependencies |
| Parent cancellation/effect failure | Cancel/join work; no rollback of committed state/effects |
| Another run | Fresh declared initial caches/input execution, not external-state rewind |

Dependencies are supervised for the **whole run**, not retired independently per
branch. Final caches survive until run cleanup, not afterward. Completion and
dependency failure use a synchronized first-result boundary: a failure observed
first fails execution; shutdown cancellation cannot overturn chosen success.
Pending notifications/partial collection/batches can be discarded on failure.
Already-running effects are not atomically revoked, and no last-success fallback
after a source error is implied.

## Shallow state, explicit limits

Snapshots copy T, not pointers to live cache slots. Referents must remain valid
for **older** queued, batched, or collected snapshots too; replacing state neither
deep-copies nor destroys pointees. Scalar/value assignment into capability-owned
fields can retain a value, whereas borrowed collection/batch backing slices must
be copied before callbacks return. Neither deep-copies referents inside T.

Use `map` for whole current state and `each` on `values` for stream elements.
Array/slice state stays one value; filter update inputs before `hold` to reject
replacements while preserving its initial value. Effects belong in explicit
terminals, not derived callbacks.

There are no live setters/getters, feedback safety, multi-parent computed values,
global transactions, equality/coalescing controls, reactive reducers/scan, replay,
or durable effects. Updaters and all stream/sampling work join before cache
storage is freed; non-cooperative code cannot be forcibly interrupted.
