# Checkout retries: a small proposal

**Design approved; not implemented.** Target: Zig 0.17.0.
Agreed direction: named effects, a composable retrying flow using `run`'s Io,
and final failures as error-valued items. Idempotency and persistence remain
application responsibilities. No `idempotent` wrapper, store interface, or
journal implementation is proposed. Retry policy accepts fixed options or a
typed decision function returning an explicit tagged union for readability;
there is no separate `retry_if` option.

## `retryPipe`: ordinary composition, repeated safely

Keep the declaration input and flat operator tuple style of
[`pipe`](../../src/compose.zig). Each attempt stops at the first operation error
and skips later stages in that attempt. This is a cold declaration executed
only inside `run(bindings, flows)`, not a second eager executor.

Approved API shape, **illustrative and not yet implemented or executable**:

```zig
const map = zrx.map;
const retryPipe = zrx.retryPipe; // not implemented yet
const RetryDecision = zrx.RetryDecision; // not implemented yet

const shipments = retryPipe(&requests, .{
    map(pay),
    map(createOrder),
    map(ship),
}, retryCheckout);
// pipe(&shipments, .{forEach(showOutcome)}) is selected by run.
// showOutcome receives CheckoutError!Shipment, including final failures.

fn retryCheckout(err: CheckoutError, retry_count: usize) RetryDecision {
    if (retry_count >= 4) return .stop; // at most 4 retries, 5 total attempts
    return switch (err) {
        error.ServiceUnavailable => .{ .retry_after_ms = 1000 },
        else => .stop,
    };
}
```

`pay`, `createOrder`, and `ship` are ordinary typed callbacks. Leading service
parameters follow the current injection rule; ordinary input comes last.
Users make these effects safe to retry
using their own service contracts, keys, persistence, or other domain mechanisms.

### Two forms, one policy rule

```zig
const RetryDecision = union(enum) {
    stop,
    retry_after_ms: u64,
};
```

- **Fixed:** `.{ .max_attempts = 5, .delay_ms = 1000 }` retries operation errors
  at a constant delay, up to the limit. `max_attempts` includes the initial call;
  `null` means no fixed limit, and zero is invalid.
- **Function:** a comptime-known, explicitly typed
  `fn (OperationError, usize) RetryDecision` decides after each failed attempt.
  `retry_count` counts retries already performed: it is **0 on the first failure**.
  Return `.stop` or `.{ .retry_after_ms = delay }`; zero delay retries immediately.
  The function owns both classification and retry limits.

Normalize fixed options to the same `RetryDecision` internally. No
separate error predicate or hidden cap applies to the function form. Use that
form for permanent errors, unsafe unknown outcomes, or error-dependent delays.

- Retry starts from the **original input**, not the failed stage. Input and
  operator copies are shallow; borrowed mutable state is not reset.
- A stop decision or exhausted fixed limit emits the last operation error as
  `E!T` data to the surrounding pipe. Counts reset per item and are not persisted.
- Wait cooperatively through run-supplied `std.Io`. Source/acquisition failures
  and cancellation still fail/cancel `run`; cancellation is never retried.
  Check cancellation even for zero-delay retries; do not pass it to the policy.
- Follow normal callback coercions and rejection of empty/nested tuples. Retry does
  not restart the source, unrelated flows, or a later consumer. Initially process
  one item at a time; indefinite retries backpressure following items.

Declaring this flow allocates/starts nothing. Retry waits use run-supplied Io and
finish/join before managed services release. A retry boundary does not imply an
extra worker/queue. Application capabilities remain borrowed. No removed eager
executor or `With` variant is restored.

The final operation error is an explicit exception to ordinary stream callback
failure: the retry boundary captures it as item data; source failures and errors
outside that boundary retain normal run failure behavior.

## Retry is not durability

A shipping failure re-executes payment and order stages. `retryPipe` does not
cache results, remember a completed stage, persist attempt counts, or resume
after process death. No rollback, duplicate suppression, or exactly-once effects
are promised. Retry safety is an application contract, not proven by comptime.

**Critical window:** payment succeeds, then the process dies before saving its
receipt. A local “done” flag cannot solve this. Recover through destination
idempotency/lookup or stop; never blindly charge again.

Persistent workflows, atomic local commits, destination idempotency, and outbox
protocols remain separate future work. Flushing output is not fsync.

## Narrow milestone and checks

The approved implementation direction is run-backed `retryPipe` and a finite
checkout example with controlled service fixtures. Demonstrate an application's
retry-safe effects without prescribing a storage abstraction. No dependencies or
shared-runtime edits are authorized by this documentation task.

Before implementation, reconcile the inner composition with typed region
lowering: specify which cardinality-changing/stateful/terminal operators can
belong inside a per-item attempt. Do not silently reinterpret such operators as
singleton pipelines. This integration preserves the approved retry rules; it
does not settle that newly exposed boundary by inventing another execution model.

| Test | Expected evidence |
|---|---|
| Shipping transiently fails | Whole attempt repeats; fixture verifies application-owned duplicate safety |
| Permanent error / finite attempt limit | Immediate stop / exact limit; final error emitted as data |
| Function policy count and delays | First count 0; exact retry delays; `.stop` ends attempts; zero delay retries immediately |
| Equivalent fixed/function policies | Same attempts, delays, and final result |
| Cancellation during delay | Stop without another attempt |
| Downstream handles final error | Error remains data; subsequent items can still be processed |
| Source failure / unrelated flow failure | Normal run failure/cancellation, no source-wide replay |
| Invalid tuple / zero attempts | Reject invalid configuration before activation |

[Current execution](../execution.md) and [signal state](../state.md) remain
nonpersistent. Illustrative code is not compilation-tested.

**Next step:** review the inner-operation boundary against the declaration-only
runtime, then implement a finite checkout increment. Idempotency APIs remain
deferred. The source track was documentation-only; archiving it does not mean
`retryPipe` is implemented.
