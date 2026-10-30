# Declarative merge

`merge(inputs)` describes concurrent fan-in. It takes only a nonempty flat tuple
of inputs: no allocator, Io, capacity argument, activation, or `deinit()`.
`run` owns the merged transport, automatic readers, forwarding tasks, and cleanup.

The [executable example](../examples/merge.zig) combines commands and readings
into one event type, then applies named decisions and explicit service effects:

```sh
zig build example-merge
```

Illustrative fragment of that example, with domain/source setup omitted:

```zig
const zrx = @import("zrx");
const pipe = zrx.pipe;
const each = zrx.each;
const merge = zrx.merge;
const forEachWith = zrx.forEachWith;
const run = zrx.run;

const events = merge(.{
    pipe(&commands, .{each(asCommandEvent)}),
    pipe(&readings, .{each(asReadingEvent)}),
});
const displayFlow = pipe(&events, .{
    each(decide),
    forEachWith(&screen, Screen.render),
});
try run(allocator, io, .{displayFlow});
```

## Inputs and identity

- Accept a nonempty flat tuple of supported sequence inputs: declared streams,
  derived pipes/merges, borrowed slices/array pointers, iterator adapters, or
  standard-queue adapters. One input is allowed; nested tuples are rejected.
- Every input must have exactly the same item type. No implicit widening,
  error-unwrapping, union inference, or source tagging occurs. Use `each` to
  convert inputs explicitly into a common type or tagged event union.
- Arrays by value remain rejected to avoid borrowing temporary copies.
- Refer to stable source/derived declarations by pointer to share their
  execution node. Merge participates in the existing [identity rules](pipes.md#reuse-has-identity).
- Each tuple entry creates an input edge with an independent automatic reader.
  Repeating `&source` therefore repeats each event in the merged output while
  executing that producer once. Inputs are not silently deduplicated.
- Referencing one merged declaration from several flows broadcasts the same
  chosen interleaving to them. By-value copies are independent descriptions.

Keep descriptions and borrowed source storage valid and unmodified through
execution. Capability referents must stay alive and safe for concurrent use.
Conventional iterator/queue state remains borrowed: independent
copies can compete for it or require synchronization. To share its consumption,
reference one stable adapter/view rather than independently copying it.

## Execution, ordering, and buffering

Declaring an unused merge creates no read claim, does no work, and cannot pin a
source buffer. During graph preparation, `run` discovers all inputs and registers
their readers before activation, including inputs shared with other graph branches.

The current merge output capacity is **one**. Downstream derived nodes inherit
that capacity. Input nodes retain their own buffering; there is no dynamic growth
or public merge buffering mode in this increment.

On first output consumption the runtime starts one independently progressing,
sequential forwarding worker per input, using `std.Io.Group`. All those workers
wait behind a gate until local worker creation succeeds. Each worker reads one
item and forwards it before reading another.

- Preserve each input edge's order.
- Cross-input interleaving is the order of successful output admission. It is
  influenced by Io scheduling/readiness, not guaranteed wall-clock arrival order,
  tuple order, timestamp order, fairness, or deterministic round-robin.
- An empty open input does not block progress on another ready input. Merge does
  not wait for matching pairs like zip.
- A full output backpressures forwarding. Besides upstream buffers and the
  output slot, each worker can hold one in-flight item.
- Forwarding/producer startup may fail with `ConcurrencyUnavailable`. Do not
  fall back to an inline blocking loop or create a zrx scheduler.

Callbacks on different input/derived nodes may execute concurrently. Shared
mutable capability referents need application-provided synchronization. There
is no overall effect order between independent terminal flows.

## Completion, errors, and cleanup

| Observation | Behavior |
|---|---|
| One input ends normally | Continue processing other inputs |
| All inputs end normally | Finish after workers join; accepted output drains |
| An item contains an error union or null | Forward it as data |
| An input read/producer fails | Record the first observed error, cancel/join remaining merge forwarders, and fail execution |
| Failures race | No tuple-index priority; cleanup cancellation must not replace a recorded primary error |
| Local forwarding-worker startup fails | Cancel/join the workers already created; they have not passed their activation gate |
| Downstream effect fails or the parent is canceled | `run` cancels/joins owned work before freeing readers and transport |

Accepted output may drain before a merge input error is observed downstream;
other selected flows can be canceled before draining their own buffered prefix.
Earlier effects are not rolled back. A producer returning `error.Closed` is a
failure; only the standard queue adapter normalizes its transport closure to end.

Source nodes can also be used by other selected flows. A local merge-startup
failure does not promise those flows have performed no work. Once execution is
active, retrying can repeat externally visible work.

`run` owns the whole discovered graph, including source producers. The merge's
local group owns only its forwarding workers; borrowed services and conventional
iterator/queue resources stay application-owned. Cancellation remains cooperative.
No callback can be forcibly interrupted if it never returns or checks cancellation.

Payloads are shallow. Slices valid only until an iterator's next call need an
explicit stable representation/copy before entering buffered execution. Merge
does not deep-copy, destroy elements, retry, deduplicate, replay history, or
establish durable/exactly-once effects.

`collectThen` after merge waits for **all** inputs to complete successfully.
`takeLast(n)` after merge retains the suffix of the chosen interleaving, not
separate per-input suffixes. Apply it before merge for per-input retention.
Count-based [batch terminals](batching.md) consume the chosen interleaving too.
Multi-parent signal joins, combine-latest, zip, batch-producing streams, dynamic input sets, and
lossy policies remain separate work.
