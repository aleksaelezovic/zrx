# Declarative streams

`Stream(T)` describes an event source. It does not own a live queue, allocate
storage, capture allocator/Io, start work, or require `deinit()`.
Declare source and transformation relationships, then activate selected terminal
effect flows with `run(allocator, io, flows)`.

Target: exactly Zig **0.17.0**. This API is experimental.

## Example

The complete [stream example](../examples/streams.zig) is executable:

```sh
zig build example-streams
```

Its declaration/activation fragment (domain functions and writer setup omitted):

```zig
const zrx = @import("zrx");
const Stream = zrx.Stream;
const pipe = zrx.pipe;
const each = zrx.each;
const forEachWith = zrx.forEachWith;
const run = zrx.run;

const numbers: Stream(u32) = .fromProducer(1, produceNumbers);
const displayFlow = pipe(&numbers, .{
    each(double),
    forEachWith(&display, writeNumber),
});

try run(allocator, io, .{displayFlow});
```

The producer receives `*Emitter(u32)`, not `*Stream(u32)`:

```zig
const Emitter = zrx.Emitter;

fn produceNumbers(output: *Emitter(u32)) error{ Closed, Canceled }!void {
    for ([_]u32{ 1, 2, 3 }) |value| try output.push(value);
}
```

Returning closes output automatically. The runtime drains accepted items and
then observes the producer outcome. There is no public manual `Stream.init`,
`push`, `close`, reader clone, `tee`, or `share` ownership API.

## Producer declarations

| Constructor | Callback |
|---|---|
| `Stream(T).fromProducer(capacity, producer)` | `fn (*Emitter(T)) void` or `E!void` |
| `Stream(T).fromProducerWith(capacity, producer, capability)` | `fn (C, *Emitter(T)) void` or `E!void`, where `C` is a single-item pointer |

Callbacks are comptime-known functions with explicitly typed runtime parameters
and explicit return types. Generic callbacks, caller-supplied function pointers,
closures, and non-void result payloads are rejected. Normal Zig pointer coercions
apply, including mutable-to-const capability pointers.

`fromProducerWith` borrows its capability pointer; it does not heap-copy arbitrary
runtime configuration. Put configuration in a caller-owned struct and pass its
address. The referent and any resources it references must outlive `run`.
The declaration can be built at comptime when its inputs allow it.

Capacity is a runtime configuration value. The current graph executor requires
positive capacity and returns `UnsupportedCapacity` for zero before activation.
Storage is bounded; it does not grow automatically. Zero-sized items are
rejected at comptime.

## Execution-time capabilities and ownership

The producer's borrowed `Emitter(T)` exposes:

- `push(value)`: wait for output capacity, returning `Closed` or `Canceled` when
  appropriate;
- `io`: the `std.Io` supplied to `run`, for standard blocking/cancelable APIs;
- `allocator`: the allocator supplied to `run`, for explicit producer-local work.

The emitter is valid only during that producer call. Do not save it, its
context, or copies of it for later use, and do not leave tasks using it after the
producer returns. It deliberately has no `close`/`deinit` operations. Prefer
scoped standard APIs and `defer` cleanup in the producer. Allocations the producer
makes itself are still its responsibility; `run` does not infer their ownership.

`run` owns source buffers, producer contexts/tasks, derived buffers/tasks, and
automatic readers. It cancels/joins owned work before freeing that storage,
on normal completion and on error. Source declarations and capability referents
remain caller-owned. See [effect-flow lifecycle](pipes.md#ownership-and-cleanup).

Each run instantiates fresh runtime state. Reusing a declaration in a later run
calls its producer again; this is a new execution, not historical replay.
External services and borrowed capability state are not reset or rolled back.
Concurrent runs may share those referents, so the application must synchronize
them or avoid concurrent use.

## Pipes and automatic sharing

`each`/`filter`/`maxItems` over a stream build descriptions. Per-item
`forEach`, whole-collection `collectThen`, and count-based `batchThen` (including
their `With` variants) declare terminal effect flows. Only `run` executes those
declared callbacks.
Keep `each` elementwise and `map` whole-value; `map` does not become an
implicit event transform.
For [signals](signals.md), `map` instead describes a pure transformation of the
whole current state. Convert through `values` to process snapshots as stream
items, or use `withLatestFrom` to attach current state to events.

Refer to the same source or derived declaration by pointer to share it within
one run. Each selected downstream edge gets an independent reader. Unselected
declarations allocate nothing and retain no events.

- [Branching example](../examples/branching.zig): `zig build example-branching`
- [Shared transformation and two effect flows](../examples/pipes.zig): `zig build example-pipes`
- [Merge into decisions and effects](../examples/merge.zig): `zig build example-merge`
- [Batch log effects](../examples/batching.zig): `zig build example-batching`

[`merge(inputs)`](merging.md) is the declarative fan-in counterpart: a nonempty
flat tuple of same-item-type inputs, with no allocator or Io until `run`.
Convert different domain inputs explicitly with `each`. It preserves each input
edge's order, with unspecified interleaving, and ends only after all inputs end.

A slow selected reader applies backpressure. Per-source item order is preserved;
cross-effect order is unspecified. Current execution materializes each recognized
derived node, including linear nodes; it is not a fusion/performance guarantee.

## Errors, payloads, and consumers

Error-union and optional items remain data. They do not terminate a source or
implicitly short-circuit `pipe`. A producer return error or terminal effect
error instead fails execution and cancels peer flows. Buffered peer prefixes
may be abandoned. Earlier effects and mutations are not rolled back.

Items are shallow values. A slice/pointer published into the graph must remain
valid throughout downstream use; returning from `push` does not acknowledge
that every callback has finished with its referents. Sharing does not deep-copy
payloads or infer destructors. Keep owned resources in explicit application
scopes. Producers, transforms, and effects must cooperate with cancellation.

Collection effects borrow a read-only slice after successful end; `run` frees
it when the callback returns. Source failure, cancellation, or accumulation
failure discards partial storage without invoking that callback. Use a `With`
capability to retain an explicit copy. See [terminal contracts](terminals.md).
Direct stream iteration and the former public `collectInto`/`collectAlloc`
operators are not supported.

[Batch terminals](batching.md) instead use a preallocated reusable buffer and
invoke callbacks for full groups while the source is open. A final nonempty
partial group is flushed only on successful end; no empty batch is emitted.

## Conventional input adapters

`fromIterator(&iterator)` and `readFrom(io, &std.Io.Queue(T))` remain explicit
borrowed interoperability adapters. Their terminal effects now execute through
`run`, just like finite-slice and stream terminal effects.
They use the existing fallible cursor contract: `?T`/`E!?T`, with outer errors
distinct from error-valued items. A closed-and-drained queue yields end; an
empty open queue waits. Independently described queue readers compete rather
than broadcast. Reference the same stable adapter/view by pointer for automatic
sharing within one run. Do not concurrently use unsynchronized copies of a
borrowed mutable iterator. A queue adapter's captured Io must be compatible
with the execution's Io and lifetime.

`std.Io.Queue(T)` supplies typed buffering and cancelable waiting over borrowed,
fixed-capacity storage. It does not broadcast to independent readers or grow its
buffer. zrx keeps the reader positions and bounded fan-out transport internal to
`run`; it does not replace ordinary standard-queue use.

Use standard readers/writers, clients, iterators, and synchronization APIs for
domain I/O. Feed graph output through an emitter inside a producer rather than
building a parallel I/O framework. Pure value composition and finite view
declaration remain allocation-free; all public terminal effects use `run`.
See the [composition and borrowing rules](sequences.md).

Writable refs, dynamic graph editing, replay, automatic retry, persistence, and
durable/idempotent/exactly-once execution are not implemented.
