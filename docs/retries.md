# Retry boundaries and application-owned idempotency

[Documentation index](README.md) · [Execution and ownership](execution.md)

[`retryPipe`](../src/ops/retryPipe.zig) is a cold, serial, per-item boundary inside
the same `run(bindings, flows)` model. See the tested
[checkout program](../examples/checkout.zig):

```sh
zig build example-checkout
```

The example retries shipping twice. Payment and order are called again on every
attempt, but their application-owned keys/results reuse the earlier effects.
It prints three calls and one effect for each service. This one-checkout,
in-memory fixture is intentionally not a persistence abstraction.

## One attempt, one original item

An attempt supports a flat nonempty tuple of built-in `map`/`each` and `tap`, including
grouped callbacks. Stop at its first callback outer error and skip later callbacks
in that attempt. Retry starts from the original **shallow** input, not the failed
stage. Mutated borrowed services/referents are not reset or rolled back.
Named helpers may return these operators; arbitrary custom operator `apply`
behavior is not silently discarded by accepting a lookalike output description.

Stateful/cardinality-changing operators, branching, prefix/count guards and
terminals belong outside this boundary. They are rejected inside it, rather
than being reinterpreted as singleton pipelines. This first milestone does not
support request-scoped HTTP lanes.

The output item is `E!T`: success contains the final payload; exhaustion or a stop
decision contains the last operation error. A following typed callback can handle
that value explicitly. Failure of one item's attempts does not drop the item or
prevent later input items from being processed. Optional/error-valued inputs
remain ordinary data until an attempt callback interprets them.

## Policy and lifetime

The source API documents both policy forms:

- Fixed `RetryOptions`/literal: explicitly choose `max_attempts` (including the
  initial attempt), or `null` for unlimited. Delay defaults to zero.
- Typed function: `(services..., OperationError, usize) RetryDecision`.
  Decide `.stop` or `.retry_after_ms`. The first failure receives count zero;
  the function owns both classification and limits, with no hidden cap.

All leading dependencies use normal DI; error/count and item arguments remain
ordinary suffix data even when their types match supplied bindings. Services
acquire once per run, not per attempt, and release after users join. Stable
references share the complete retry execution/result. New runs get fresh retry
counters, not a rewind of borrowed application state.

`run`'s Io performs waits on the awake clock. Zero delay still polls cancellation.
Cancellation is neither retried, passed to the policy, nor emitted as data.
Source/acquisition/downstream failures stay outside the retry boundary and retain
normal run failure behavior. Infinite retries backpressure following items;
no extra queue/worker is implied, and non-cooperative callbacks can prevent joining.

Zero fixed attempts fails cold before acquisition/activation, including behind
a zero prefix or inside a reusable case helper. Native tests cover delay counts,
cancelable waits, managed release, sharing, no extra source probes and allocation
failure. Runtime-input fixtures instantiate both forms on all catalog targets;
cross compilation is not foreign execution or performance proof.

## Retry is not durability

There is no result cache, completed-stage checkpoint, persisted attempt count,
restart recovery, duplicate suppression, automatic rollback, or exactly-once
effect guarantee in the library. Those are application/service contracts.

The critical external-effect window remains: payment succeeds, then the process
dies before recording its receipt. A local “done” flag cannot close that window.
Use destination idempotency/lookup, a separately designed atomic protocol, or
stop for reconciliation—not blind replay of an unsafe payment. Flushing is not fsync.
