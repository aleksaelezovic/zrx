# Terminal effects and collection

Terminal operators describe work. They do not traverse inputs, invoke effects,
or allocate at declaration time. Activate a nonempty flat tuple of terminal
flows with `run(allocator, io, flows)`.

This applies to stream declarations, borrowed slices/array pointers, lazy views,
`fromIterator` inputs, and explicit standard-queue adapters. Conventional
iterators/queues remain consuming inputs; describing a flow does not reset them.

## Terminal families

| Operator | Callback | Execution |
|---|---|---|
| `forEach(effect)` | `fn (T) void` or `E!void` | Once per received item |
| `forEachWith(capability, effect)` | `fn (C, T) void` or `E!void` | Same, with an explicit capability |
| `collectThen(effect)` | `fn ([]const T) void` or `E!void` | Once after successful input completion |
| `collectThenWith(capability, effect)` | `fn (C, []const T) void` or `E!void` | Same, with an explicit capability |
| `batchThen(size, effect)` | `fn ([]const T) void` or `E!void` | Successive full batches and a final nonempty partial batch on successful end |
| `batchThenWith(size, capability, effect)` | `fn (C, []const T) void` or `E!void` | Same, with an explicit capability |

Callbacks are comptime-known, explicitly typed functions. Generic callbacks,
caller-supplied function pointers/closures, and non-void result payloads are
rejected. Per-item callbacks use normal Zig argument coercions; collection/batch
callbacks must accept a read-only slice compatible with the actual item type.
The capability is an explicit value; its borrowed referents must outlive `run`.

The [finite-sequence example](../examples/sequences.zig) exercises collection,
`maxItems`, and copying into application-owned storage. Run `zig build example`
to execute it along with the other examples.

Illustrative fragment, with source and domain callback setup omitted:

```zig
const zrx = @import("zrx");
const pipe = zrx.pipe;
const filter = zrx.filter;
const each = zrx.each;
const maxItems = zrx.maxItems;
const collectThenWith = zrx.collectThenWith;
const run = zrx.run;

const saveFlow = pipe(&items, .{
    filter(isWanted),
    each(transform),
    maxItems(1000),
    collectThenWith(&store, saveCopy),
});
try run(allocator, io, .{saveFlow});
```

Referencing the same stable source/derived declaration shares its evaluation
within one run, including when one consumer is per-item and another collects.
See [graph identity and lifecycle](pipes.md). Callbacks on independent flows
can run concurrently; there is no tuple-order effect ordering guarantee.

For incremental count-based grouping, see [batch effects](batching.md). Unlike
whole-input collection, batching emits full groups while input is still open.
It preallocates one reusable buffer per selected flow, rejects zero size before
activation, and invokes no callback for empty input.

## Scoped collection ownership

`collectThen` accumulates shallow items using `std.ArrayList` and the allocator
supplied to `run`. Its backing storage is freed when its callback returns,
including when that callback returns an error.

- The callback may inspect the slice only during its call. Do not save the
  borrowed slice or leave tasks using it after the callback returns.
- To keep data, copy it into explicitly application-owned storage through a
  capability. Any allocation for that retained copy is application-owned.
- The collection does not deep-copy item referents or infer destructors. A
  producer publishing borrowed slices/pointers must keep their referents valid
  until all downstream use, including the eventual collection callback, ends.
- Each collecting flow has its own accumulation buffer. A callback in one flow
  can already have run before another flow fails; there is no rollback.
- `collectInto`/`collectAlloc` are no longer public pipeline operators.
  `run` does not return owned collection results requiring caller cleanup.

## Completion and failure

| Observation | `forEach` | `collectThen` |
|---|---|---|
| Item arrives | Invoke its effect | Append to the pending collection |
| Empty successful input | No effect calls | One callback with an empty slice |
| Successful end after items | Finish after the final item | One callback with the complete collection |
| Source/iterator error | Fail execution; earlier effects remain | Discard the partial collection; no collection callback |
| Allocation failure | Fail if runtime setup fails | Also fail on accumulation growth; discard partial storage |
| Cancellation observed | Stop; earlier effects remain | Discard pending storage; do not invoke the callback |
| Callback error | Fail execution without rollback | Free its storage and fail execution without rollback |

Peer failure cancels other flows; cancellation is cooperative, not an atomic
barrier against already-running callbacks. Each collection callback requires
its own successful end and a cancellation check before invocation.
Item error unions/optionals remain data, distinct from execution failures.

An open, empty input is not complete. A never-ending source never reaches a
whole-collection callback. Uncapped collection can grow until allocation fails;
channel capacity does not bound total collected memory.

## `maxItems(limit)`

This is an optional validation operator, not truncation or a queue policy:

- Forward at most `limit` output items, in order.
- Read one more item to distinguish successful end from excess input.
- If that item exists, consume but do not forward it; fail with `TooManyItems`.
- At exactly the limit, still wait for end or an excess item. Do not close a
  source just because the limit was reached.
- Zero allows an empty source and rejects the first item of a nonempty source.

Place it where the intended count belongs: after a filter to count matches,
or before it to count input events. Immediately before collection it bounds
the number of accumulated items, not arbitrary referenced payload memory.
Runtime queue capacity and upstream prefetch are separate: upstream work may
already have processed buffered items before failure is observed.

On excess input a downstream collection callback is not invoked. Downstream
per-item or full-batch effects may already have run; those effects are not undone.
An incomplete batch is discarded. Limits are per execution/cursor, not global
counters.

## `takeLast(limit)`

Retain only the final `limit` items, dropping older retained values as new ones
arrive. This is intentional suffix selection, not an error guard.

The [retention example](../examples/retention.zig) feeds 1000 numbered logs
through `takeLast(100)` into `collectThen`: `zig build example-retention`.
Its callback receives exactly logs 901–1000, in that order.

- `run` preallocates a fixed `limit`-item ring during graph preparation, before
  producers activate. Declaring this operator does not allocate or require Io.
- Consume the whole input before publishing any retained items. Only successful
  end permits publication; error/cancellation while consuming discards the ring.
- Preserve source order in the suffix. If input has fewer than `limit` items,
  forward all of them.
- Zero retains nothing but still consumes to end and observes input errors.
  An empty successful suffix gives `collectThen` one empty slice.
- A never-ending source continues consuming with bounded retention but never
  publishes a final suffix. `forEach` after `takeLast` therefore runs only after
  input completion, not live.
- Reusing a stable retained-node reference shares its output within one run.
  A later run allocates a fresh ring and re-executes input normally.
- This is a run-backed declaration even for finite inputs, not a directly
  iterable allocation-owning view.

The ring stores shallow values; overwriting an old slot does not infer cleanup
for referenced resources. Referents of retained items must remain valid through
their eventual downstream use. Ring storage is freed after owned work joins,
on success, failure, cancellation, or even failure before activation.

`collectThen` still uses its own accumulation buffer. Combining the two bounds
retained/collected item counts but does not promise one allocation, buffer
transfer, or deep payload-memory bounds. Runtime queues remain separate.

Placement expresses intent: `maxItems(1000)` before `takeLast(100)` rejects
oversized total input, while a guard after it counts only the retained suffix.
Count-based [batch terminals](batching.md) are implemented separately.
Batch-producing streams, prefix-taking, and lossy live delivery remain
outside the implemented API. In particular, suffix retention is not a live
drop-oldest delivery policy, and batch callbacks do not publish batch-valued
streams. Any future lossy delivery policy needs an explicit per-edge contract;
it must not silently discard items for sibling readers.
