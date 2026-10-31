# Private executor phase measurements

Status: implemented opt-in attribution, **not a transport optimization**. The
public API, graph lowering policy, task/queue topology and callback work are
unchanged. Earlier [elapsed](elapsed.md) and
[allocator/callback](resources.md) records keep their original baselines.

## What this answers

For the two bounded producer graphs, almost all observed elapsed time lies
**after activation readiness and before the coordinator observes completion**.
At N=4096/C=16 that interval was 99.54–99.92% of elapsed time across all current
samples. Acquisition and outer preparation/cleanup are not the dominant elapsed
cost in these particular runs.

This narrows the investigation to active execution, but does not distinguish
useful arithmetic from queue operations, backpressure, scheduling or waits.
It is **not proof of a specific bottleneck**, nor proof that the retained
producer/shared boundaries can disappear without changing semantics.

## Checkpoints and implementation

The private [observer contract](../../src/internal/execution/observation.zig)
has three typed checkpoints:

| Checkpoint | Direct finite path | Graph path |
|---|---|---|
| `prepared` | Terminal buffers ready, before managed acquisition | Readers/storage finalized and terminal/state workers created behind the gate, before managed/I/O acquisition |
| `activation_ready` | Managed acquisition finished, before execution | Managed/I/O acquisition, initial signal computation and cancellation check finished, before opening the gate |
| `result_observed` | Effects returned successfully or with the first error | Coordinator observed the execution outcome, before terminal-group await/cancel and teardown |

Unlike the original proposal, the final marker observes the result **on the
coordinator**, not inside a worker's result-selection mutex. This avoids adding
observer work to worker/cache locks or changing their data layout. Notification
and scheduling delay between selection and observation belongs to the active
interval. The marker is not an assertion that every execution user has joined.
The eventual return still follows the existing await/cancel/error paths.

Deferred producer/merge startup can happen after the gate. Thus `prepared` does
not mean every backend task exists, and active time includes that startup.
Preparation, acquisition or pre-gate startup failure may leave an incomplete
trace; the collector rejects it as a complete phase sample rather than inventing
timestamps. Failures/cancellation observed after the gate have the final marker.
Panic unwinding is not promised.

The [public executor implementation](../../src/run.zig) and
[graph coordinator](../../src/internal/graph_run.zig) specialize on a zero-sized
no-op observer for ordinary calls. Only the
[private benchmark facade](../../src/benchmark_api.zig) exposes observed entry
points; nothing is exported from the `zrx` package root. There is no runtime
observer registry, per-item tracing, forced inlining or new public execution API.

The [collector](../../benchmarks/executor_phases.zig) is confined to one run's
coordinator; workers never write it. It uses fixed storage and non-failing clock
reads, without allocation, printing or a trace mutex. Snapshot it only after run
returns. Relative to ordinary outer timing, it adds **three clock reads**. Clock
overhead and changed scheduling can perturb every interval.

## Reproduce and interpret

Exactly Zig **0.17.0**; native-host LLVM ReleaseFast for executable and imports:

```sh
zig build measurement-test
zig build benchmark-phases -Dbench-items=4096 -Dbench-capacity=16 \
  -Dbench-warmups=2 -Dbench-trials=7 2> phases.csv
# Repeat in three separate processes, also with -Dbench-items=0.
```

Metadata and CSV use stderr. Require exit zero. Every warmup and sample checks
the same activation, production, shared-map evaluation, sink counts and ordered
hashes as the uninstrumented benchmark's direct oracle.
The [workload implementation](../../benchmarks/graphs.zig) is shared: only its
execution entry point differs for observed calls. Ordinary `benchmark` and
`benchmark-costs` still call the ordinary public/current or archived entry point.
No allocator wrapper or callback checkpoint collector runs in this phase pass.

CSV intervals sum to elapsed time for **each** complete sample:

- `preparation_ns`: outer invocation start through `prepared`, including the
  small declaration construction, alias inspection, lowering, storage and gated
  worker setup.
- `acquisition_init_ns`: `prepared` through `activation_ready`. These workloads
  have no user-managed resources, owned I/O or signals; small/zero readings here
  do not measure the cost of a real application constructor.
- `active_ns`: `activation_ready` through `result_observed`, including gate
  opening, deferred startup, computation, transport, waiting and notification.
- `return_cleanup_ns`: result observation through outer return, including
  remaining joins, retirement, buffer/cache frees, binding cleanup and release.
  Different storage categories can be freed at different safe points; this is
  not a claim that all freeing happens after one global join.

All are elapsed intervals, not CPU time. Counts/bytes remain in the separate
allocator report; task/queue counts remain structural estimates, not new
measurements. RSS, task stacks and occupied payload storage are still unmeasured.

## Recorded native results

Apple M1 Pro, 10 cores, 16 GiB; macOS 27.0.1/26A434; Zig 0.17.0,
`stage2_llvm`, ReleaseFast (`fast`), ARM64 CPU `apple_a14`.
`std.Io.Threaded`: async disabled, concurrent unlimited; `smp_allocator`;
awake clock. N=0 and N=4096, C=16, two warmups and seven samples per shape/variant
in each of three separate processes: **168 rows**. `graph` means archived
materialized execution; `current` means the declaration-only public executor.

No intentional concurrent builds/tests during collection. Ambient load, power
and thermals were uncontrolled. No samples were discarded, including the current
fan-out outlier at 8.349 ms. All per-sample work/hash checks and interval sums
passed. Source snapshot:
`dd19697e6e89eec18df0bba0b731131dabac01ddd755106cbddde0b17d0a7538`.
Hash scope/rule: sorted relative paths `.zigversion`, `build.zig`,
`build.zig.zon`, `benchmarks/*.zig`, `src/**/*.zig`, appending path UTF-8, NUL,
file bytes, NUL into SHA-256. Worktree remains based on `39ac0c2`.

Independent medians, **microseconds**, 21 samples per row:

| N | Shape / variant | Preparation | Acquisition/init | Active | Return/cleanup | Elapsed |
|---:|---|---:|---:|---:|---:|---:|
| 0 | Linear legacy | 1.666 | 0.042 | 24.917 | 0.667 | 27.667 |
| 0 | Linear current | 1.083 | 0.042 | 10.417 | 0.250 | 11.958 |
| 0 | Fan-out legacy | 2.709 | 0.041 | 29.458 | 1.458 | 34.458 |
| 0 | Fan-out current | 2.625 | 0.042 | 19.708 | 1.000 | 23.792 |
| 4096 | Linear legacy | 2.875 | 0.041 | 3,267.917 | 1.875 | 3,271.167 |
| 4096 | Linear current | 1.541 | 0.042 | 1,080.125 | 0.583 | 1,082.333 |
| 4096 | Fan-out legacy | 3.875 | 0.042 | 5,865.583 | 3.000 | 5,875.666 |
| 4096 | Fan-out current | 3.375 | 0.042 | 2,804.125 | 1.375 | 2,808.334 |

Column medians need not sum. For current N=4096, active ranges were
903.750–1,541.958 µs linear and 1,880.917–8,342.750 µs fan-out. Do not compare
these instrumented timings with earlier separately collected medians as a
new performance improvement/regression. There was no runtime optimization here.
Empty input still starts/finishes the producer and delivery machinery; its active
time is not per-item work. Do not subtract independently scheduled empty medians
to claim exact processing costs.

### Raw intervals

`(preparation, acquisition/init, active, return/cleanup)` nanoseconds in trial
order, all samples retained. Sums reconstruct every elapsed sample:

```text
N=0
process 1
linear graph: (2333,42,31166,917) (2000,42,27750,1042) (2333,42,24458,875) (1708,42,22833,1084) (1666,0,32250,792) (5958,42,34583,2667) (2084,41,25792,1000)
linear current: (2583,84,17666,542) (1709,41,8917,208) (1417,0,8583,542) (1541,84,8791,334) (1083,42,10583,250) (917,42,19250,3000) (1542,42,10875,541)
fanout graph: (2541,0,32542,1500) (9500,0,22084,3125) (3041,42,32042,2625) (8708,42,76125,3375) (3375,41,21250,1292) (3209,41,20000,1250) (2958,42,29458,1042)
fanout current: (3250,84,18791,2000) (5291,0,18292,3042) (3667,42,26416,1834) (3958,42,27500,1125) (2625,0,14791,625) (2416,0,18625,500) (3625,0,19708,459)
process 2
linear graph: (1750,41,13209,500) (1250,42,25958,417) (959,41,22500,417) (1084,41,20709,500) (1292,83,26042,417) (1166,42,50875,667) (1708,42,33208,792)
linear current: (875,41,29917,292) (1583,42,15042,208) (1416,42,10042,166) (2625,41,10125,167) (1000,41,10792,333) (750,42,14458,167) (1084,0,8833,250)
fanout graph: (1917,42,20875,500) (4958,42,91458,2875) (3166,42,38750,2500) (3084,41,51542,3958) (2334,0,37833,3125) (3167,41,20959,1791) (2708,42,42958,3250)
fanout current: (3583,42,43916,1500) (2750,42,29250,2208) (2625,41,30125,2125) (2750,125,36584,1916) (3291,42,15583,1000) (2167,42,23708,2042) (3167,83,12583,375)
process 3
linear graph: (1625,42,13083,667) (1375,0,17125,458) (1209,41,21334,500) (1000,41,21959,500) (1333,42,30958,750) (1708,42,24917,458) (2209,0,19458,458)
linear current: (958,42,10417,416) (1000,42,5875,208) (834,41,9792,250) (750,42,8708,167) (1500,83,19459,333) (916,42,13250,458) (792,42,9291,250)
fanout graph: (1958,42,14958,500) (1958,0,31417,1083) (1708,42,21917,541) (1541,42,26167,708) (2209,41,17417,1458) (1583,0,57625,875) (2709,0,29416,625)
fanout current: (1375,42,20708,375) (1834,41,21667,250) (1500,42,17167,333) (1625,0,16583,250) (1625,42,16375,1000) (1750,0,22083,250) (1625,41,16459,291)

N=4096
process 1
linear graph: (6833,84,2450166,1584) (2875,41,2519167,1125) (1542,0,2444292,1875) (3625,42,2661625,1458) (1291,0,2500042,1750) (4375,0,2652333,1584) (1542,0,2960333,2792)
linear current: (1292,83,984000,334) (1416,42,1040792,208) (1167,0,1018958,375) (875,41,1040250,375) (1291,42,960250,375) (1250,0,992292,375) (1541,42,1085250,583)
fanout graph: (2542,42,4762625,1958) (5000,83,6011625,3333) (3792,41,5581250,3000) (3208,84,4849083,1917) (3875,42,4329042,3750) (2750,41,4954459,3833) (3166,42,5394375,2875)
fanout current: (2750,83,2098500,959) (2042,42,2804125,2125) (4916,42,1880917,750) (1708,42,2013666,1292) (3375,84,1918666,1875) (2167,83,2088167,917) (2584,83,2008000,917)
process 2
linear graph: (2625,167,3729458,1875) (3042,42,3686875,2291) (3750,0,3889750,2250) (3709,41,3662792,2292) (3583,125,3610042,2958) (3166,42,3308708,3000) (2709,41,3107375,2417)
linear current: (2458,84,1082458,583) (1417,83,1080125,708) (3458,83,1366250,917) (1791,84,1541958,1042) (2791,209,1176083,583) (1458,42,903750,208) (2333,84,1111250,541)
fanout graph: (4625,83,5550542,2875) (6500,83,5865583,3500) (4042,42,6003583,4167) (4000,0,6006458,2792) (3042,42,6138166,2625) (3417,83,5622542,3000) (3000,42,5940292,2750)
fanout current: (4750,167,3648583,1625) (2875,42,3474666,1375) (4833,42,3794250,1833) (2875,83,3658917,1375) (4667,83,3474125,1625) (2167,42,1886250,1166) (3542,0,3870125,1250)
process 3
linear graph: (3417,41,3494250,1959) (1875,41,3583917,1375) (1459,41,3267917,1750) (2208,42,3132417,2375) (1666,0,3335959,1708) (3042,42,3161916,1667) (2875,84,3449875,2125)
linear current: (3125,125,1105333,709) (1333,83,992542,792) (2750,42,1010875,291) (1542,42,1103416,667) (1833,83,1056084,208) (958,42,1177667,625) (2208,0,1202792,750)
fanout graph: (4333,0,5934917,3000) (4625,0,6213500,2583) (5750,0,6330416,3834) (3708,42,6235958,2750) (4667,42,5945583,3333) (4708,83,5641834,3208) (3833,42,5757542,2666)
fanout current: (4500,83,8342750,1750) (9291,42,2319375,1292) (5833,42,3719000,1250) (2833,42,2777666,2084) (4083,84,3570208,1542) (2375,41,3129000,1667) (5042,42,2790000,2083)
```

## Erasure and correctness evidence

The [native inspection fixture](../../tests/phase_erasure.zig) exports ordinary
and explicitly empty-observed finite and producer calls, using runtime input.
With pinned LLVM ReleaseFast:

```sh
zig build-obj -fllvm -O ReleaseFast --dep api \
  -Mroot=tests/phase_erasure.zig -O ReleaseFast \
  -Mapi=src/benchmark_api.zig -femit-llvm-ir=/PATH/phase_erasure.ll \
  -fno-emit-bin
```

On this native target, `finite_default` and `finite_empty` alias the same
implementation; likewise `graph_default` and `graph_empty`. There are no observer
symbol references in the emitted IR. This is scoped erasure evidence, not a claim
of equality to imperative graph code, a comparison with a pre-instrumentation
binary, or a new rule in the shared codegen catalog. No existing comparator or
normalization was modified.

[Eight new instrumentation tests](../../tests/phase_observation.zig) cover
incomplete/duplicate/reversed traces, both workload shapes with empty/odd/even
inputs, finite and graph acquisition/effect errors, producer join before service
release on callback failure, external cancellation, all preparation allocation
failures, cold versus post-activation worker-start failure, and native fixture
execution. No test asserts a positive duration or performance threshold.

Passed on Zig 0.17.0, native macOS ARM64:

```sh
zig fmt --check build.zig build.zig.zon src tests examples benchmarks
zig build measurement-test
zig build measurement-test -Doptimize=ReleaseFast
zig build test
zig build test -Doptimize=ReleaseFast
zig build check
```

All four benchmark commands also smoke-ran at N=32; phase reporting ran at N=0
and N=1. Smoke timings collected alongside validation builds were not used for
the results above. The six-target catalog/codegen checks passed unchanged;
foreign object compilation is not foreign execution. No race detector was run.

## Next review point

The [performance roadmap](../performance.md) specifies the capacity experiment,
profiling and semantic review required before changing retained-boundary lowering.
These phase results do not justify optimizing allocator setup or changing
independent-root progress/sharing semantics to win a benchmark.
