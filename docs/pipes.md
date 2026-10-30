# Lazy terminal effect flows

This experimental API wires readers automatically using ordinary
`pipe`, not a second observable/computed API. It supports declarative stream
sources, declarative merge nodes, borrowed conventional inputs,
`each`/`filter`/`maxItems` views, run-owned `takeLast` retention, and per-item,
whole-collection, or count-based batch terminal effects.
Run-owned [signals](signals.md) add replacement caches, pure derived state,
lossless observation streams, and event-triggered sampling.

Run the executable [two-flow example](../examples/pipes.zig):

```sh
zig build example-pipes
```

Both effects receive `2, 4, 6`; their common transformation evaluates three
times, not six. The source and derived output capacities are one.

## Declare, then activate

An illustrative fragment of the tested example, with source/domain setup omitted:

```zig
const zrx = @import("zrx");
const pipe = zrx.pipe;
const each = zrx.each;
const forEachWith = zrx.forEachWith;
const run = zrx.run;

const doubled = pipe(&numbers, .{each(double)});
const displayFlow = pipe(&doubled, .{forEachWith(screen, displayNumber)});
const auditFlow = pipe(&doubled, .{forEachWith(audit, recordNumber)});

try run(allocator, io, .{ displayFlow, auditFlow });
```

For finite inputs and streams alike, reaching a terminal effect returns a
flow description. It does not consume input or call the effect. `run` accepts a
nonempty flat tuple of these descriptions, registers all readers, then activates
the selected flows together. Allocator and Io are explicit once at this boundary;
domain services remain explicit capabilities at effects.

Only nodes reachable from the selected flows are instantiated. Unselected pipes
create no reader claim and cannot pin the source buffer. With capacity one,
selected slow effects still apply backpressure. This is bounded lossless fan-out,
not arbitrary replay or latest-value coalescing.

## Reuse has identity

Refer to a stable declared pipe by pointer (`&doubled`) to share that node.
Its description must remain valid and unmodified through `run`; capability
referents must stay alive and safe for concurrent use.
Node identity is the declaration's address and type, including
source declarations. No function/type-based deduplication occurs.

Two separate declarations with the same transforms execute independently.
Passing sources/views by value copies descriptions rather than asserting shared
identity. Declarations own no live resources; copying a source description can
instantiate another producer if the copies are selected separately.

Each active edge receives an independent reader automatically. There is no
unused original reader left retaining capacity. A common derived node evaluates
once per input item it actually processes, then distributes those results.
Callbacks on different nodes/flows can run concurrently; shared mutable
capability referents need application-provided synchronization.

## Ownership and cleanup

Execution borrows descriptions and explicit capability referents. Keep them
alive until execution finishes. Sources capture no allocator or Io: `run`
supplies both when instantiating runtime state. Positive declared-stream capacity
is required; zero returns `UnsupportedCapacity`. Conventional sources use an
internal capacity-one forwarding queue. Derived nodes inherit upstream capacity.
Merge nodes have a capacity-one output and register one reader per input edge;
see the [fan-in contract](merging.md).

`run` owns source queues/producers, reader records, derived queues/forwarders,
the consumer task group, and prepared batch buffers. On normal end or failure it:

1. Joins or cancels/joins consumer tasks.
2. Releases prepared terminal buffers.
3. Stops/joins state updaters before their publication transport.
4. Stops derived stream workers before their upstream source producers.
5. Releases automatic readers and source/derived storage, then state caches
   after all samplers have joined.

Collection backing storage is freed in its consumer task after its callback or
on failure/cancellation. [Batch buffers](batching.md) are prepared before any
producer activates and freed only after consumer tasks join, including failure
before activation.

Declarations require no `deinit()`. A later run creates fresh runtime state and
calls producers again. This is not replay, automatic retry, or reset of borrowed
application state. Concurrent executions require safe shared capabilities.

Preparation/consumer/state-worker-startup failure frees partial runtime state
without activating producers or initial state maps. Initial maps run only after
resources and gated workers are prepared. Descriptions remain usable for another execution. After activation,
failure may follow externally visible work; retrying can repeat that work.
Merge forwarding-worker startup occurs after graph activation; its own gate
prevents partial local forwarding, but other selected flows may already be active.

Each source's order is preserved, but ordering between effects is unspecified.
The first observed consumer/source error fails the execution and cancels peers;
already-consumed items or completed effects are not rolled back. Peer flows may
stop before draining their own buffered prefix. Cleanup cancellation errors do
not replace the recorded primary error.

Consumers explicitly check cancellation between items. Producers, transforms,
and effects must cooperate with cancellation when blocking or doing long work;
non-returning non-cancelable code cannot be forcibly interrupted.

## Current boundaries

- All public `forEach`/`collectThen`/`batchThen` terminals and their `With`
  variants are deferred. Pure value stages still run as ordinary function
  calls; declaring a flow does not defer arbitrary operator side effects.
- Direct iteration of stream declarations is rejected. Whole-input consumption
  uses a [scoped collection callback](terminals.md), not an owned result returned
  from `run`. The old eager public collectors have been retired.
- `takeLast` is run-backed for finite inputs too. It preallocates its retention
  ring during graph preparation and publishes only after successful input end.
  It does not turn an endless source into a finite one.
- This implementation uses a materialized owned stream per recognized derived
  view node, including linear nodes. It reuses the bounded sharing backend;
  no new scheduler is added. Fusion and resource-cost reductions are future
  work, not zero-overhead guarantees.
- Input errors/optionals remain item data. An explicit source/iterator/effect
  failure is propagated; `pipe` does not implicitly unwrap element errors.
- Payloads are shallow values. Automatic sharing does not extend arbitrary
  referent lifetimes, deep-copy resources, infer destructors, or make callbacks
  pure/thread-safe.

Writable refs, multi-parent state, dynamic graph editing, late joining, arbitrary
custom graph operators, replay, retries, persistence, and durable/exactly-once
effects are not implemented. Low-level reader clone/tee/share are internal runtime
mechanisms, not public ownership operations.
