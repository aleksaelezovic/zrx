# Signals: current state inside a run

Signals describe current state driven by replacement inputs. They are graph
declarations, not live refs: no allocator, Io, work, getter/setter, or `deinit`
is required at declaration time. `run` owns state, observation transport,
updater tasks, sampling, cancellation, and cleanup.

## Example

Run the complete [signal example](../examples/signals.zig):

```sh
zig build example-signals
```

The producer supplies **23 C**, then **18 C**. `hold(20)` supplies the initial
state, so observers see **20, 23, 18**. A pure map derives the comfort values
**comfortable, warm, cool**. Each flow writes to its own fixed writer, matching
the other examples without handshakes or custom service machinery.

Its declaration/activation fragment, with domain helpers omitted:

```zig
const zrx = @import("zrx");
const pipe = zrx.pipe;
const map = zrx.map;
const hold = zrx.hold;
const values = zrx.values;
const forEachWith = zrx.forEachWith;
const run = zrx.run;

const current = pipe(&readings, .{hold(20)});
const comfort = pipe(&current, .{map(classifyTemperature)});
const showTemperatures = pipe(values(&current), .{
    forEachWith(&temperatures, writeTemperature),
});
const showComfort = pipe(values(&comfort), .{
    forEachWith(&descriptions, writeComfort),
});
try run(allocator, io, .{ showTemperatures, showComfort });
```

Only `run` allocates/activates the graph. `withLatestFrom` is a separate
event-driven sampling operator; using it is not required to create or observe
signals. Its ordering/lifetime behavior is covered by native tests.

## Operators and typing

| Form | Contract |
|---|---|
| `hold(initial)` | Stream/sequence of T → signal of T; successive items replace the whole state |
| `map(f)` / `map(.{ f, g })` on a signal | Signal of T → derived signal of U, with whole-current-value transforms |
| `values(&signal)` | Stream of initial state followed by each committed replacement |
| `withLatestFrom(&signal)` | Event stream of E → stream of `@Tuple(&.{ E, T })` |

The initial value coerces to the input item type using normal Zig rules; typed
runtime values and literals such as `20`, `.cold`, or `null` are accepted where
that coercion is valid. Literal `undefined` is rejected. Initial expressions are
ordinary caller code: `hold(loadInitial())` does not defer that function call.
Signal values and map results must be nonzero-sized, matching current transport
restrictions. No public owning `Signal(T)` constructor is introduced; infer the
description type just as for derived stream pipes.

Sampling output is an ordinary pair, not a wrapper API:

```zig
const RequestReading = @Tuple(&.{ Request, i32 });
// answerRequest(input: RequestReading):
// input[0] is the request; input[1] is the temperature snapshot.
```

Tuple-valued events/state remain nested as elements; sampling does not flatten
them. Sampling does not consume state or emit anything just because state changes.

Use `map` for a signal's current value, `each` for stream items from `values`.
An array/slice signal is mapped as a whole array/slice. Existing ordinary
value/slice maps stay eager whole-value operations, and stream maps do not become
per-item operations. Direct signal `each`, `filter`, retention, and terminals
require conversion through `values`; they do not silently mutate state.
Filter update inputs before `hold` to reject replacements while keeping prior
state; its explicit initial value is unaffected by that update filter.

Derived callbacks are comptime-known, explicitly typed, pure `fn (T) U`
functions. Existing flat nonempty function-tuple rules and normal argument
coercions apply. Purity is a contract, not a proof the compiler can establish.
Effects belong in existing [terminal flows](terminals.md) with explicit capabilities.

## Initialization, sharing, and coherent derived state

Only reachable state dependencies are instantiated. Stable references share one
cache/derivation within a run; by-value descriptions are independent. Repeated
input references still share their referenced update producer with independent
delivery edges, as in the [graph identity contract](pipes.md#reuse-has-identity).
Unused state/observations allocate nothing, retain no input, and run no transforms.

Run prepares all resources and gated consumer/state workers before evaluating
initial maps. All selected caches are initialized and initial snapshots are
staged before activating producers or consumers.

Each replacement is processed serially by its root state family:

1. Compute selected single-parent derived candidates in dependency order.
2. Commit the root and all those derived caches under one short-lived lock.
3. Release the lock, then publish snapshots in source order.
4. Process the next replacement only after those lossless publications succeed.

A sample during derivation sees old committed state; afterward it sees the
fully committed new value. No user transform, effect, or queue wait holds that
commit lock. One shared derived node evaluates once per turn, including initial
state, regardless of observer count. Grouped and separate maps preserve their
value/error semantics.

The lock is a per-root-family `std.Io.Mutex`, using the supplied Io for contended
waiting/waking. The pinned standard library uses an atomic fast path when
uncontended. Large copied state, many derived caches, or many concurrent samplers
can still make this critical section expensive; no bottleneck claim is made
without a representative benchmark.

This is not a transaction across independent roots, event effects, or I/O.
Chained sampling operations are separate reads, not an atomic multi-signal
snapshot. There is no multi-parent `computed` closure or implicit getter tracking.

## Observation and demand

`values` is lossless during successful execution: initial state once, followed
by every committed replacement, **including equal values and equal derived
results**. There is no implicit equality comparator or coalescing policy.
Its output capacity is one. Slow observers backpressure publication, rather than
silently losing versions; unselected observations create no hidden reader.
The view is declarative, but its runtime transport is concrete: one shared
capacity-one publication buffer per observed signal, with an independent read
position for each consumer. A queued item is released after all those readers
have read it, not necessarily after their callbacks finish. Other graph queues,
callbacks, and an in-flight publication have separate storage/lifetimes.

Commit precedes notification delivery. A sampler may see a newly committed value
before a slow observation callback has rendered it. `Emitter.push` acknowledges
input admission, not signal commit. Separate event/update sources have no
wall-clock or causal ordering guarantee; use an explicit application protocol
when a request must see a particular update.

A selected sampling dependency actively consumes updates even while requests
are idle. With no values observer it retains current/candidate state, not history.
Existing upstream queues and downstream collectors have their own storage costs.
`collectThen` and batching over `values` count the initial snapshot as an item.

## Completion and failure

| Situation | Behavior |
|---|---|
| Updates end normally | Keep final cache readable; values streams close after pending snapshots drain |
| Request/event input ends | That sampling flow ends without waiting for further updates |
| Update input fails | Fail the run even if samplers are idle and no observer exists |
| Error-union/optional state | Preserve it as data, not termination, unwrapping, or skipped state |
| Effect fails or parent cancellation is observed | Cancel/join owned work; do not roll back committed state or earlier effects |
| All selected terminal flows finish | End the run and stop remaining state/update dependencies |
| Description used in another run | Start with its declared initial value and fresh caches/input execution |

State dependencies remain owned/supervised for the whole run, not independently
retired when one branch finishes. Early per-branch shutdown, dynamic subscribers,
and late joining are not implemented. A final cache survives until run cleanup,
not after it; borrowed conventional inputs/application state are not rewound.

Dependency failure and terminal completion use a synchronized completion boundary:
failures observed first fail execution; ordinary shutdown cancellation cannot
replace a chosen result. Pending notifications/partial collection or batch state
can be discarded on failure. Already-running callbacks are not atomically revoked.

`pipe`/`tryPipe` do not inspect error unions inside signal state. Signal maps
preserve such values even in grouped `tryPipe` maps; a callback can explicitly
recover or use a named pure fail-fast helper. Source execution errors remain a
separate boundary. There is no automatic last-success fallback after source error.

## Ownership and limits

State and snapshots copy T shallowly, not pointers to mutable internal cache
slots. Replacing a value does not infer destructors. Pointer/slice referents must
remain valid for older snapshots too, including queued, batched, or collected
snapshots. Mutable pointees do not create implicit signal updates.
Prefer scalar/value records or stable immutable storage for this initial API.
For scalar/value T, ordinary assignment into capability-owned fields retains a
copy safely. Borrowed collection/batch slices
must instead be copied into application-owned storage before their callbacks
return. Neither operation deep-copies pointer/slice referents inside T.

Run stops/joins state updaters, then stream/sampling workers, before disposing
their cache storage. Cancellation is cooperative; callbacks that never return
cannot be forcibly interrupted. Synchronous feedback that waits for this graph
to process another update can deadlock and is not automatically detected.

Writable live refs, multi-parent state joins, global transactions, equality/
coalescing controls, reducers/scan, persistence, replay, retries, and durable or
exactly-once effects remain separate work. No signal-runtime performance claim
is made by the synchronous core's codegen comparisons.
