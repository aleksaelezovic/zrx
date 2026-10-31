# Performance investigation roadmap

[Documentation index](README.md) · [Measurement records](measurements/README.md)

Status: next investigation plan, not approval for another runtime rewrite.
Integrate the declaration-only migration and sibling changes first, then capture
a fresh revision/configuration for comparisons. Stop after each experiment for
review. Do not optimize unrelated internals while gathering a baseline.

## Goal and constraints

Pay for required semantics, not declarative notation. Comptime-known callbacks,
typed dependencies and operator structure should lower to ordinary code that Zig
can inline and optimize. A named exclusive synchronous stage must not imply a
queue, worker or hot-loop dispatch.

Producer delivery, actual sharing, state, retention and independent progress have
runtime obligations; their current implementation is not necessarily minimal.
Eliminating costs by removing those obligations is an API/semantics change, not
a free optimization. No forced inlining or universal zero-cost promise.
Current execution contracts remain in [the guide](execution.md) and source.

## What the evidence establishes

| Evidence | Finding | Boundary |
|---|---|---|
| Public finite regressions and scoped LLVM inspection | Tested exclusive finite/named paths need no transport, concurrent workers or planner heap; callback calls optimize into the loop | Not all graphs, whole-binary equality or a compile-time-cost measurement |
| [Elapsed comparison](measurements/elapsed.md#post-migration-comparison) | Current linear/shared benchmarks were faster than archived materialization on one host | Whole-run comparison, not causal attribution; direct arithmetic loops lack graph scheduling/cancellation semantics |
| [Allocator pass](measurements/resources.md#measured-allocation-results) | At C=16, current linear uses 12 run-allocator allocations/1,640 peak requested bytes; fan-out uses 21/2,424, with zero outstanding after return | Backend tasks/stacks, allocator slabs, RSS and occupied payload are excluded |
| [Phase pass](measurements/phases.md#recorded-native-results) | For N=4096/C=16, 99.54–99.92% of current elapsed samples lies in the active interval | Includes useful work, deferred startup, transport, waits and scheduling; does not identify the bottleneck |
| [Observer erasure fixture](measurements/phases.md#erasure-and-correctness-evidence) | Native LLVM aliases tested empty-observer calls to ordinary calls | Scoped empty-observer evidence, not an imperative graph equality proof |

All timings are host/workload observations, not default test thresholds.
Preserve each record's source fingerprint and compiler/configuration. Do not
relabel old numbers as measurements of the integrated revision, compare
instrumented/uninstrumented medians as speedups, or subtract independently
scheduled empty-run medians to manufacture pure processing time.

## 1. Establish the integrated reference

Before optimization:

- Finish integration and rerun the [documented checks](validation.md). Preserve
  lifecycle/fault tests and strict kernel codegen comparisons.
- Record the revision plus any local diff, exactly Zig 0.17.0, LLVM ReleaseFast,
  native target/CPU, OS, allocator and Io configuration, workload, capacity,
  warmups/trials, process count and relevant machine load/power conditions.
- Smoke all four opt-in commands. Use ordinary `benchmark` for elapsed results;
  allocator, callback and coordinator passes answer different questions.
- Preserve raw successful reports and correctness fields; exclude compilation,
  report printing and oracle calculation from measured invocation time.

Deliverable: a reproducible integrated baseline, not a promise that historical
timings will repeat. No new runtime hooks are needed.

## 2. Test transport-capacity sensitivity first

Keep the existing finite deterministic producers, callback arithmetic, sink
effects and two shapes unchanged. Start at N=4096, C=1/16/256, two warmups, seven
trials, three separate processes per capacity. Rotate variants as the existing
driver does. Do not run builds/tests alongside collection.

```sh
zig build benchmark -Dbench-items=4096 -Dbench-capacity=1 \
  -Dbench-warmups=2 -Dbench-trials=7 2> elapsed-c1-p1.csv
zig build benchmark-costs -Dbench-items=4096 -Dbench-capacity=1 \
  -Dbench-warmups=2 -Dbench-trials=7 2> allocations-c1-p1.csv
```

Repeat for the other capacities/processes. Require zero exit status and all
work/hash checks; retain outliers. Report min/median/max and raw trials for both
shapes, elapsed and memory separately. Do not tune capacity only for the candidate
then compare it against an untuned reference.

If direct timings are near clock resolution or setup dominates a new workload,
add one larger fixed N, such as 65536, to **all** variants; do not silently change
the workload between implementations. Empty/short correctness cases remain.

Interpretation:

- Strong capacity sensitivity motivates investigating amortization, wakeups and
  backpressure. It does not identify which mechanism caused the effect.
- Little sensitivity motivates profiling before assuming queues are the cause.
- A throughput/latency gain that requires more memory is a tradeoff to report,
  not evidence of zero cost.

Deliverable: one small result table and a specific profiling hypothesis. Review
it before changing the transport or adding measurement machinery.

## 3. Attribute active costs without per-item tracing

Use available native CPU and blocking/scheduling profiling tools on the
unchanged reference. Keep profiling separate from ordinary elapsed samples.
Distinguish useful callbacks, queue push/read synchronization, waits/wakeups,
deferred worker startup, shared publication and cancellation polling.

CPU sampling alone misses off-CPU waiting; scheduling time alone does not explain
useful work. Record profiler limitations and instrumentation overhead. If the
available tools cannot answer the specific hypothesis, propose the smallest
private, erased counter/checkpoint and concurrency-safe test first. Do not add a
public registry, scheduler or permanent per-stage tracing system.

Deliverable: an evidence-backed hot path or remaining ambiguity. Do not infer
occupied queue storage or task counts from elapsed time or allocator totals.

## 4. Optimize one evidenced mechanism

Choose a change only after attribution. Plausible candidates—not decisions—are
redundant transport synchronization, publication/wakeup overhead, or unnecessary
state at a retained boundary. Do not prioritize once-per-run allocation metadata
solely because it is easy to count; preparation was small in the measured graphs.

Before implementing, state:

1. Which work/state can be removed and why it is redundant.
2. Which operator/shape is affected and which paths stay unchanged.
3. Whether buffer occupancy, prefetch, independent progress or resource lifetime
   changes. A real semantic tradeoff needs user review.
4. What correctness/fault evidence and fixed-configuration before/after
   measurements will accept or reject the change.

Preserve once-per-shared evaluation, per-edge order, bounded buffering,
cooperative cancellation, prefix retirement and live siblings, first-result
handling, run-scoped signals and join-before-release. Generic callbacks can block
or have effects; do not duplicate/reorder them on a purity assumption. `take`
must not gain an extra probe, reducer errors must stop before another input
probe, and cold preparation failure must remain cold.

Use typed ordinary calls and existing Zig facilities. No operator-tag
interpreter, indiscriminate `inline`, implicit worker-per-stage return, or
flattening of independent roots into one blocking loop just to beat the benchmark.

## 5. Check the hidden costs and stop

For any accepted lowering specialization, inspect the actual exported
runtime-input fixture's LLVM/assembly without weakening the existing comparator.
Track clean-build time and generated text size separately if specializing more
runtime alias alternatives; run-time improvement can increase compiler work or
code size. Do not claim those costs were measured in the current records.

Run `zig build test`, `zig build test -Doptimize=ReleaseFast` and `zig build check`,
plus the focused lifecycle/measurement suites and affected real examples.
Compare uninstrumented elapsed distributions and separate resource accounting
under the same compiler/backend/target/workload/capacity. Report any regression
or unresolved variance rather than selecting only winning samples.

Stop with the result and next review question. Broader graph shapes, other native
platforms, cold-process startup, actual occupancy/task counters, graph inspection,
explicit execution boundaries, worker primitives and formatter/linter/
canonicalization tools are separate follow-ups, not this roadmap's implementation
scope. Durability/retries/HTTP integrations must preserve their own contracts;
repeatable execution is not durable recovery or exactly-once effects.
