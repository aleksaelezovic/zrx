# Count-based batch effects

`batchThen(size, effect)` and `batchThenWith(size, capability, effect)` are
deferred terminals. They describe successive callback-scoped batches over any
supported input, including live streams. They allocate nothing, need no
allocator/Io, and call no effects until selected by `run`.

The [executable mock-service example](../examples/batching.zig) sends 1000
numbered log events in ten batches of 100:

```sh
zig build example-batching
```

Illustrative fragment of that example, with source/service setup omitted:

```zig
const zrx = @import("zrx");
const pipe = zrx.pipe;
const batchThenWith = zrx.batchThenWith;
const run = zrx.run;

const sendLogs = pipe(&logs, .{
    batchThenWith(100, &service, MockLogService.send),
});
try run(allocator, io, .{sendLogs});
```

## Contract

| Observation | Behavior |
|---|---|
| Full batch of `size` items | Invoke its callback before reading the next batch; no source-completion wait |
| Successful end with a nonempty partial batch | Invoke the callback once for that shorter batch |
| Empty successful input | No callback |
| Successful end exactly on a batch boundary | No additional empty callback |
| Source/iterator error or cancellation observed | Discard the pending partial batch; earlier batch effects remain |
| Callback error | Fail execution and cancel peers; do not retry or flush again |
| Selected size is zero | Return `InvalidBatchSize` before activation, including for empty inputs |
| Preparation or consumer-worker startup failure | Release prepared buffers without invoking callbacks |

Size is a runtime configuration value. Describing an unused flow, even with a
zero size, does not validate or activate it. A later run prepares fresh storage;
borrowed application state is not reset automatically.

Unary callbacks are explicitly typed `fn ([]const T) void` or `E!void`.
With callbacks take the explicit capability first: `fn (C, []const T) void` or
`E!void`. Capabilities use normal Zig coercions. Item types must be compatible
with the read-only slice parameter; transform items with `each` when needed.
Generic callbacks, caller-supplied function pointers/closures, mutable slice
parameters, and non-void effect payloads are rejected.

Each flow invokes its callbacks serially and preserves input order. Different
flows/nodes can execute concurrently, so shared mutable capabilities require
application-provided synchronization. Optional/error-union items remain data,
not implicit execution failures. Standard queue closure is normal end; a
producer returning an error, including `Closed`, is failure.

## Memory and borrowed lifetime

During graph preparation `run` preallocates one fixed `size`-item buffer per
selected batch terminal using its supplied allocator. All selected buffers and
readers are prepared before activation. Buffer-allocation failure invokes no
producer/effect callbacks. Storage does not grow or reallocate while batching.

Every callback borrows a `[]const T` over the same reusable buffer. Its contents
are valid only during that call: do not save the slice or let asynchronous work
use it after returning. Finish/join any work using it inside the callback, or
make an explicitly application-owned copy through a capability.

Items are shallow copies. Pointer/slice referents must stay valid until their
batch callback finishes; the batch buffer does not extend arbitrary referent
lifetimes, deep-copy payloads, or infer destructors. Retaining a copy of the
outer slice alone is not a deep copy of its items.

On completion, failure, or cancellation, `run` joins/cancels consumer tasks
before freeing their prepared buffers. Cold buffers are also freed if graph
preparation or consumer startup fails. A callback that never returns or
cooperates with cancellation cannot be forcibly interrupted.

## Backpressure and scope

A callback executes synchronously in its consumer flow. While it runs, that
consumer does not read the next batch. Existing upstream queues/workers can
continue only within their own bounded buffering, then backpressure applies.
There is no per-batch task spawning, lossy queue policy, timer, deadline, or
automatic retry.

A never-ending source can deliver full batches indefinitely. A partial batch
waits until more items arrive or successful end; there is no latency-based flush.
`maxItems` before batching still counts items, not batches. If it fails, an
incomplete batch is discarded rather than treated as a successful final batch.
`takeLast` before batching delays all output until its input ends normally.
When batching after merge, groups follow the merge's chosen interleaving.

This is intentionally a **terminal**, not a `batch(n)` stage that publishes
reused slices into the graph. General batch-producing streams require a separate
ownership/release contract for downstream queues and shared readers. Time-based
windows, durable/idempotent effects, and exactly-once delivery are not promised.
