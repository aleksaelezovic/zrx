# Performance investigation

[Documentation index](README.md) · [Validation scope](validation.md)

Measure required semantics, not declarative notation. Exclusive synchronous
regions use typed direct calls; merely naming an exclusive stage must not add a
queue or worker. Producers, actual sharing, state and retention have runtime
obligations. Removing those obligations would change semantics, not provide a
free optimization.

## Opt-in tools

Exactly Zig 0.17.0, native-host LLVM ReleaseFast:

```sh
zig build benchmark -Dbench-items=4096 -Dbench-capacity=16 \
  -Dbench-warmups=2 -Dbench-trials=7
zig build benchmark-costs -Dbench-items=4096 -Dbench-capacity=16 \
  -Dbench-warmups=2 -Dbench-trials=7
zig build benchmark-spans -Dbench-items=4096 -Dbench-capacity=16 \
  -Dbench-warmups=2 -Dbench-trials=7
zig build benchmark-phases -Dbench-items=4096 -Dbench-capacity=16 \
  -Dbench-warmups=2 -Dbench-trials=7
```

The [workload](../benchmarks/graphs.zig) compares direct Zig and the current public
pipeline over linear and shared-fan-out graphs. Producer calls, produced items,
shared-transform evaluations, sink counts and ordered hashes are checked against
the direct oracle. Empty/short inputs are checked outside elapsed measurement.
The direct loop does not reproduce graph cancellation/scheduling/backpressure;
elapsed differences are not a declarative-notation overhead proof.

- `benchmark`: uninstrumented complete invocation elapsed time; alternates
  direct/pipeline trial order. Compilation, report printing and oracle calculation
  are excluded from that interval.
- `benchmark-costs`: [thread-safe run-allocator accounting](../benchmarks/tracking_allocator.zig),
  including requested/live/peak bytes, failures, resize/remap and frees. Backend
  allocations, stacks, RSS, allocator slabs and occupied payload are excluded.
- `benchmark-spans`: first/last [callback checkpoints](../benchmarks/callback_spans.zig).
  These instrumented spans are not precise executor phases or headline timings.
- `benchmark-phases`: [private coordinator checkpoints](../benchmarks/executor_phases.zig),
  separating preparation, acquisition/initialization, active execution and return
  cleanup. Active includes useful work, startup, waits and scheduling—not CPU time.

Capacity, warmups and trials must be positive; item count may be zero. Driver
reports include compiler/backend/optimization/target/CPU, workload, capacities,
allocator and Io configuration. No default timing thresholds or permanent
per-item tracing hooks are introduced.

## Next experiment

Capture a fresh revision plus local diff, OS/load/power conditions and raw results.
Old executor baselines and implementation-comparison records were removed with
that implementation; no previous speedup claim is carried forward.

1. Sweep C=1/16/256 at fixed N=4096, two warmups and seven trials, three processes
   per capacity. Do not run builds/tests alongside collection. Keep all outliers.
2. Report elapsed and allocator results separately. Do not infer queue occupancy
   from requested bytes or a bottleneck from elapsed phase proportions.
3. Profile active CPU and blocking costs before choosing one mechanism to change.
   Instrumentation is a separate pass, not a before/after timing comparison.
4. State the affected shapes and semantic tradeoffs, then preserve current
   lifecycle/fault tests and cross coverage. Stop for review after each experiment.

No optimization or new worker/boundary primitive is authorized by this roadmap.
