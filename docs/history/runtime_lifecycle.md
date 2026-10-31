# Runtime lifecycle audit

Historical review snapshot: baseline `39ac0c2998e1a65a18a8f7692909f5276e28ff64`,
Zig **0.17.0**. This audits the existing implementation, not a proposal for a
public resource API, scheduler, or new reactive semantics. No concrete runtime
bug was reproduced in this increment; changes add regression coverage only.

## State transitions and invariants

The audited coordinator is now internal [`graph_run`](../../src/internal/graph_run.zig); slots are owned by
[`resources.Scope`](../../src/internal/resources.zig). Declarations remain cold:
only selected dependencies instantiate runtime state.

| Phase | Existing transition / failure behavior |
|---|---|
| Prepare | Copy flow definitions into stable runtime fields; prepare terminal buffers; resolve nodes, readers, explicit input edges, signal families/caches, and resource slots. No acquisition, producer, terminal callback, or initial signal map runs. Partial structures unwind through local `errdefer` and scope/consumer cleanup. |
| Finalize readers | Close unused default split claims before work starts, so unselected readers cannot pin capacity. Selected edges remain separate even when they reference one shared node. |
| Gated startup | Start all terminal workers, then state-family workers, waiting on one activation event. Startup failure records an error and joins started waiters without activating producers or initial maps. |
| Acquire | Acquire slots in registration order, checking cancellation before each. Mark a slot acquired only after success. A failing acquire must clean up its own partial work; earlier successful slots remain owned until teardown. File create/truncate/connect effects are not rolled back. |
| Initialize / activate | Compute initial signal candidates, commit caches, and stage initial observations before opening the gate. Initial maps run only after acquisition succeeds. A cancellation/error here still joins gated workers and releases resources. |
| Execute | Pull lazily starts each producer once. Derived forwarding and merge-local workers may start after global activation; startup failure here is not an all-graph no-effects guarantee. |
| Successful terminal finalization | Consume through successful end/cutoff, including collection callback, partial-batch callback, or line-output finish/flush. Only then close that terminal reader and report completion. |
| Failure / cancellation | A failed terminal reports its result without first retiring its reader. Select the result before run-wide shutdown; cancel/join consumers before freeing their prepared buffers. Discard pending collections/batches/suffixes as specified, without undoing earlier effects. |
| Stop / join | Stop/join state updaters first; stop/join stream nodes in reverse dependency order. All stream workers/samplers join before caches are destroyed. Edge retirement can already have stopped individual unused producer chains. |
| Release / free | After terminal workers join, free terminal buffers; after stream workers join, destroy downstream readers/transport before upstream owners, then caches/families. Release acquired resource slots in reverse registration order and destroy all slots last. Handles therefore outlive their users. |

Preparation registers downstream nodes after their upstream dependencies, so
reverse node teardown is meaningful for the supported acyclic declarations.
This is not a general cycle detector or a proof that arbitrary callback-created
feedback can make progress.

## Completion, errors, and demand

- [`Execution`](../../src/internal/graph_run.zig) serializes terminal completion and state
  failure reports. The first reported error, or completion of all terminals,
  closes result selection. Later shutdown errors cannot replace it. Tuple order
  is not failure priority; parent cancellation remains an execution error.
  A normal producer error is observed by readers after accepted items drain,
  not at the wall-clock instant the callback returns.
- [`Stream` / `Buffer`](../../src/internal/runtime/streams.zig) distinguish
  logical close, producer completion, reader detachment, and storage destruction.
  Closed queues drain accepted items; readers wait cancellably for callback
  completion before joining its Future. Producer startup is protected by
  `start_mutex`; `result_mutex` serializes reader `Future.await` with other
  reader joins and retirement `Future.cancel`. Zig Futures themselves are not
  threadsafe. Final owner destruction requires quiescent reader users.
- [`Runtime`](../../src/internal/graph_run.zig) retains explicit input-reader edges. Producer
  return retires those edges; removing the last output reader closes the owner,
  retires inputs, then stops/joins its producer. Concurrent retirement paths can
  close the same reader: [`Buffer.detach`](../../src/internal/runtime/broadcast.zig)
  is synchronized/idempotent and only the last active removal triggers unused
  handling. Reader storage stays allocated until joined teardown.
- In shared/diamond graphs, each downstream edge retires independently; a live
  sibling keeps its claim and continues to apply backpressure. Pointer identity
  shares one producer, not one delivery edge. `take` cutoff performs no extra
  input probe, but buffering/in-flight work can already have done more upstream
  work. Zero still acquires selected resources.
- [`merge`](../../src/internal/runtime/streams.zig) gates its own forwarding
  group until every forwarder starts. It waits for all normal ends or the first
  observed input error, then joins forwarding work before returning. Local
  startup failure does not activate partial local forwarding; unrelated flows
  may already have run. Repeated input references are distinct readers.
- [`Family`](../../src/internal/runtime/signals.zig) has run-wide supervision,
  not stream-edge lifetime. Ended `values` delivery ignores closed publication
  while updates/derived commits continue. Normal update end leaves the final
  cache sampleable; a state-source error reports failure even with idle event
  inputs. Family transforms/publication run outside the commit lock. Families
  are joined only by the coordinator; stream Future joins need the separate
  serialization above.

## Ownership boundary

Run owns transport, reader records, worker tasks, copied capability containers,
batch/ring/collection storage, signal caches, and acquired line-I/O slots.
[`lines.zig`](../../src/io/lines.zig) closes owned files/TCP sockets only during
slot release; process stdio handles are borrowed. Successful output includes
flush, not fsync. Failed/canceled cleanup does not flush or promise atomic output.
Endpoint/path conflict validation is textual, not alias canonicalization.

Declarations, path bytes, iterator state, capability referents, and referents
inside shallow items/snapshots remain borrowed. Collection/batch slices and
emitters are call-scoped; escaping work must join within the call or use an
explicit application-owned copy. Run neither infers element destructors nor
reclaims application resources. Callback purity, termination, referent lifetime,
and synchronization are caller obligations, not statically proven properties.
Non-cooperative code can prevent cancellation/join from finishing.

## Evidence and coverage added

Existing suites already cover the core transitions:

| Invariant / fault | Existing evidence |
|---|---|
| Partial preparation, no activation, leak-free retry | Allocation-failure sweeps in [declarations](../../tests/declarations.zig), [batching](../../tests/batching.zig), [retention](../../tests/take_last.zig), [merge](../../tests/merge.zig), [signals](../../tests/signals.zig), and [I/O](../../tests/io.zig) |
| Partial terminal/state-worker startup | Threaded concurrency-limit failures in declarations, batching, retention, signals, and I/O; initial-map/source counters stay zero |
| Partial acquisition | I/O tests: absent later input releases earlier created output; callbacks stay gated; earlier file creation remains visible |
| Source/callback failures and parent cancellation | Declaration/terminal/batch/merge suites; blocked TCP read joins before close; record writer flush-failure fixture |
| Prefix edge retirement and run-scoped signals | [take](../../tests/take.zig): exclusive chains, repeated merge edges, idle input cancellation, zero/cutoff behavior, continued state sampling and active state errors |
| First-result boundary and cache lifetime | Signals: successful event end with endless updates, idle sampler source failure, final cache sampling, parent cancellation |

New regressions in this increment:

1. [Branching](../../tests/branching.zig): eight concurrent end readers, repeated
   across 16 runs, receive the same producer error twice each; one producer
   finishes. Extends the prior sequential cached-result test to contended joins.
2. [Take](../../tests/take.zig): two prefix finalizers rendezvous before retiring
   both arms of an active shared diamond/merge; a direct source sibling drains
   all 100 items with one producer activation (16 runs, bounded completion wait).
3. [I/O](../../tests/io.zig): cancel while the second resource acquire is blocked;
   release only the first acquired slot, never acquire the third.
4. I/O: inject a terminal callback error while a sibling callback and shared
   producer are blocked. An observed owned-file close checks that both have
   exited; the returned error remains the callback error, not cleanup cancellation.

These tests add scheduling/fault evidence, not an exhaustive interleaving proof.
No runtime source, public API, build wiring, or root guidance changed.

## Validation and next review

On native macOS ARM64 with Zig **0.17.0**, passed:

```sh
zig fmt tests/branching.zig tests/take.zig tests/io.zig
zig fmt --check build.zig build.zig.zon src tests examples
zig build test
zig build test -Doptimize=ReleaseFast
zig build check
```

`check` includes the existing six-target object builds and scoped codegen
comparisons; it does not execute foreign targets. No benchmark, sanitizer/race
detector, or proof of arbitrary callbacks was performed.

Prioritized follow-ups, **not implemented or normative requirements**:

1. Review these regression scenarios and the ordering table before pulling this
   increment. No runtime rewrite or public managed-resource interface is justified
   by the findings here.
2. If stronger race evidence is needed, add deterministic Io-level join/startup
   fault hooks that force await-versus-retirement overlap and failure at each
   post-activation startup point. Repeated native scheduling is not that guarantee.
3. If guidance is expanded later, preserve the distinction between
   prepare/gated-start failure (cold graph) and post-activation producer/merge
   startup failure (peer effects possible). The existing execution guide already
   states it; no root-guidance correction is required by this audit.

## Subsequent declaration-runtime hardening

After the public API migration, the focused `zig build lifecycle-test` suite adds
deterministic evidence without production runtime behavior changes:

- [Public schedules](../../tests/lifecycle_hardening.zig): the same typed graph
  switches shared/distinct/shared identities across runs, including mutable versus
  const references. Atomic counters verify once-per-shared evaluation and separate
  distinct evaluation; managed resources remain live through both terminal effects.
- An Io group-start trampoline observes the first terminal worker's actual return,
  after result reporting and successful edge retirement. Only then does its
  producer continue to the peer's normal end or explicit error. A separate state
  case waits for observation retirement and an entered idle event source before
  returning `StateFailed`; run must fail and join event/state users before release.
- [Private join schedules](../../tests/join_retirement.zig): a test-local Io shim
  pauses the real backend await/cancel operation while observing contention on the
  exact producer-result mutex. One schedule makes await win; the other holds the
  mutex, queues the reader, and lets retirement win first. Both run for successful
  and failed producer outcomes. Exactly one backend join is allowed; the loser
  consumes the cached result.

The only source-facade addition exposes the existing private `stopProducer` helper
to these tests. No public hook, scheduler, new dependency mechanism, or runtime
implementation fix was introduced. Test observers retain the real backend userdata
and futures; observer counters are atomic, and group-context copies use the
thread-safe testing allocator. Their test-local pointers live until all users join.

These schedules strengthen the original await-versus-retirement follow-up, not
prove every interleaving. They depend deliberately on the pinned Zig 0.17.0 Io
mutex/future interface. Ten-second waits bound hangs, not performance. Faults at
every post-activation startup point, non-cooperative callbacks, race-detector
coverage, and foreign runtime execution remain outside this increment.

On native macOS ARM64 with Zig **0.17.0**, this hardening increment passed:

```sh
zig fmt --check build.zig build.zig.zon src tests examples benchmarks
zig build lifecycle-test
zig build lifecycle-test -Doptimize=ReleaseFast
zig build test
zig build test -Doptimize=ReleaseFast
zig build check
```

Documentation links/anchors, instruction symlinks, and whitespace also passed.
No benchmark timings were collected; prior measurement snapshots are unchanged.
