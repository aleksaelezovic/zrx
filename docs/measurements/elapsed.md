# Measurement baseline and developer tooling

Status: historical baseline plus an opt-in legacy/current comparison.
Runtime baseline: `39ac0c2998e1a65a18a8f7692909f5276e28ff64`.
The initial baseline phase made no runtime changes. Subsequent user review
authorized the breaking declarative/DI migration and synchronous-region lowering.
Implemented behavior is documented in the
[migration record](../history/execution_migration.md). Original timing observations
retain their original baseline and are not relabeled as current results.
The [performance roadmap](../performance.md) is the single current investigation
plan; superseded lowering sketches have been removed from this evidence record.

Read alongside the [execution guide](../execution.md) and
[validation/codegen scope](../validation.md). The existing
[target/case catalog](../../tests/codegen/catalog.zig) remains the single catalog
for cross builds and codegen comparisons; this benchmark does not copy or modify it.
Selected direct/grouped/separate LLVM-body equality is not graph performance
evidence, universal zero overhead, or an instruction to force inlining.

## Questions and deliberately small scope

1. What does a complete bounded linear run cost on one native host?
2. What changes when one transformed stream feeds two selected terminal flows?
3. What work and effects were actually performed in each measurement?

The executable [benchmark](../../benchmarks/graphs.zig) now compares the current
public zrx API with the archived legacy facade and a direct equivalent. It uses
only project code and the Zig standard library. It does not wait for stdin, terminals, files, or
public networks. Its only external output is the measurement report after each
sample. It runs only via `zig build benchmark`, never as a default timing test.
`zig build check` checks formatting and tests the shared workload helpers through
the instrumentation suite; it does not run the opt-in timing driver.

### Workloads

Each fresh run produces the deterministic integers `0..<N` once, with no source
array allocation. Items initially carry a `u64` and a borrowed evaluation-counter
pointer. `mix` applies wrapping multiplication/XOR and increments that counter.
The shared transformed items are plain `u64`.

```text
linear:
  producer -> each(mix) -> filter(keepEven) -> each(finish) -> left sink

fanout:
  producer -> each(mix) [one stable pointer-shared declaration]
                 |-> filter(keepEven) -> each(finish) -> left sink
                 |-> each(otherFinish) -> right sink
```

The source capacity `C` is positive; legacy materialization inherits it at each
derived node, while current lowering retains it at transport boundaries.
Default `N=4096`, `C=16`. Left receives `floor(N/2)` items; right receives
all `N` only in fan-out. Each sink updates its own count and order-sensitive
wrapping hash. There is no terminal collection or unbounded retained payload.

The direct equivalents generate the same input, call the same named callbacks,
compute the shared transform **once**, apply the same predicate/branch transforms,
and execute the same sink updates in each branch's input order. They have no
queues/tasks and execute branches serially; the graph has no cross-branch effect
ordering contract. Thus these are semantic work/effect equivalents and useful
context, **not scheduling-equivalent implementations**. Ordinary compiler
optimization of either variant is allowed, including simplifying counters in the
direct loop. No volatile operations, forced inlining, or artificial direct
queue/task overhead is added to force a particular comparison.

Producer activation, produced items, and shared-transform evaluations must be
`1`, `N`, and `N`. Results are checked against the direct oracle after every
warmup and measured sample. Additional graph/oracle fixtures cover `N=0,1,7,32`.
Counts and ordered hashes are reported, keeping effects observable. Hashes are a
compact regression check, not a collision-free trace or proof of all semantics.
Counter writes have single owners: source writes its fields, the one shared
transform writes its evaluation field, and each terminal writes its own sink.
The driver reads them only after `run` has joined its work.

## Reproduce before comparing

Use exactly Zig **0.17.0** (also enforced by the root build). The opt-in build
wiring forces **LLVM / ReleaseFast**, for the **native host target/CPU**, for both
the executable and imported library. `-Dtarget`/`-Doptimize` do not change this
benchmark; it is not a cross-run facility. The reported optimization enum spelling
in this compiler is `fast`. Existing check steps retain their existing settings.

```sh
zig version
zig env
git rev-parse HEAD
git diff --stat
zig fmt --check build.zig benchmarks
zig build benchmark 2> baseline.csv
# Explicitly equivalent default settings:
zig build benchmark -Dbench-items=4096 -Dbench-warmups=2 \
  -Dbench-trials=7 -Dbench-capacity=16 2> baseline-explicit.csv
```

Keep the raw successful report, revision plus benchmark diff, full `zig env`,
CPU model/core count, OS/version, memory, power mode, and relevant background load
with a result. Metadata lines begin with `#`; the remaining report is CSV.
Reports use stderr, including any build/error diagnostics: only accept results
from exit status zero. A cached executable still runs on every invocation.
Compilation is outside the reported timer.

The executable explicitly uses `std.Io.Threaded` with `async_limit=.nothing`,
`concurrent_limit=.unlimited`, and the thread-safe `std.heap.smp_allocator`.
One backend is initialized per process and reused, including its worker pool and
allocator caches. Correctness fixtures precede warmups, so this is **not a
cold-process/first-thread-start measurement**.

For each shape, execute two unreported warmups per variant, then seven reported
trials per variant. The initial two-variant protocol alternated direct/graph first;
the current three-variant protocol rotates direct/graph/current first. `graph`
means legacy materialization; `current` means the new public executor. Linear runs
before fan-out. Each invocation of `execute` constructs fresh declarations and
state and, for graphs, fresh run-owned resources. The `awake` monotonic clock
surrounds the complete invocation, including graph preparation, activation,
callbacks, successful completion, joining, and cleanup. It excludes backend
initialization/deinitialization, oracle calculation, verification, and printing.
It is elapsed time, including descheduling, not CPU time or per-stage latency.

Run measurements without simultaneous builds/tests or other intentional load.
Do not discard outliers without recording a reason. Report all trials and
min/median/max, not a single best run or an unqualified overhead multiplier.
Repeat in at least three separate processes before interpreting small changes.
Increase `N` if direct samples approach clock resolution; do not subtract clock
overhead or infer precision from nanosecond output units. These defaults are a
small, cheap starting point, not a statistical-confidence claim.

## Keep cost dimensions separate

| Dimension | First milestone evidence | Meaning and exclusions |
|---|---|---|
| Elapsed time | Measured per sample | Complete invocation with warm backend, as above |
| Work/effects | Measured counters and sink hashes | Per-run activation, production, transform evaluation, per-branch ordered result checks |
| Allocator calls/bytes | **Not measured** | No counting wrapper; do not infer allocations from timing or a queue estimate |
| Peak live requested allocation bytes | **Not measured** | Not the same as total allocated bytes, allocator committed/reserved memory, RSS, or payload occupancy |
| Peak retained/occupied payload | **Not measured** | Capacity bounds below describe reserved payload slots, not observed simultaneous occupancy |
| Queue/task counts | **Source-derived estimates**, below | Logical transport owners and task submissions, not measured OS threads or simultaneous live workers |

For positive `N` and normal full completion, the original legacy
[coordinator](../../src/internal/graph_run.zig) and
[transport](../../src/internal/runtime/streams.zig) imply:

| Shape | Transport owners | Producer/forwarding tasks | Terminal tasks | Reserved payload slots / bytes |
|---|---:|---:|---:|---|
| Direct, either shape | 0 | 0 | 0 | No queue storage |
| Linear | 4 | 4 | 1 | `4*C` slots; `C*(sizeof(Packet)+3*sizeof(u64))` |
| Shared fan-out | 5 | 5 | 2 | `5*C` slots; `C*(sizeof(Packet)+4*sizeof(u64))` |

“Queue” here means one positive-capacity transport owner, not every embedded
standard queue structure, reader record, condition variable, or allocation.
Fan-out readers share the transformed buffer; they do not duplicate `mix`.
On the measured 64-bit host, `sizeof(Packet)=16`, `sizeof(u64)=8`, so default
reserved payload backing is **640 bytes linear / 768 bytes fan-out**.
Those estimates exclude reader records, node/context/index storage, temporary
values held by producers/forwarders/consumers, task frames, backend thread stacks,
allocator metadata/caches, and the fixed driver/capability/sink state.
They are neither total memory estimates nor measured peaks. There are no signal
caches, retention rings, batch buffers, I/O buffers, or collection arrays here.
Re-derive these estimates if lowering changes; do not make them public contracts.

### Original allocator-pass design, now implemented

The later [resource-cost pass](resources.md) implements and tests this design,
with measured allocator results and separately labeled callback activity spans.
The historical elapsed-time samples below are unchanged.

No public counter or intrusive runtime hook is needed for an initial allocator
pass: wrap **only the allocator supplied to `run`** in benchmark-local code.
Use a separate unwrapped allocator for the Io backend/driver. Count raw alloc,
resize, remap, and free requests and successes separately; count successful fresh
allocation bytes and positive growth bytes separately from live requested bytes.
On successful resize/remap update live bytes by `new_len-old_len`; on failure
leave live bytes unchanged; on free subtract the supplied allocation length.
Track peak live requested bytes and require zero outstanding bytes after joined
run cleanup. A moving remap peak only observes the abstract allocator boundary,
not transient internal backing allocations.

All allocator callbacks and counter updates must be serialized with a suitable
uncancelable lock, including access to a non-thread-safe backing allocator.
If using `std.Io.Mutex`, its backend must not allocate through the wrapper
(avoid recursion); never print/allocate bookkeeping through the wrapper while
holding it. Reset only while all users are quiescent; synchronize snapshots. Test
concurrent allocations, failures, successful/failed growth/shrink/remap, and
complete cleanup before trusting the numbers.

Run this as a **separate instrumented pass**, not mixed into headline timings:
the lock and bookkeeping perturb scheduling and contention. Backend task-frame/
stack allocation will remain outside its scope; name that exclusion explicitly.
RSS would require a separate host-specific process measurement and still would
not identify occupied queue payload. Actual queue occupancy/task lifetimes would
need private instrumentation; stop for review before adding any such hooks.

## Initial observation, not a performance conclusion

One default invocation on Apple M1 Pro (10 cores, 16 GiB), macOS 27.0.1
(26A434), native `aarch64-macos.27.0.1...27.0.1-none`, compiler-selected CPU
`apple_a14`, Zig 0.17.0 / `stage2_llvm` / ReleaseFast:

| Shape / variant | Min ns | Median ns | Max ns |
|---|---:|---:|---:|
| Linear direct | 2,750 | 2,791 | 2,917 |
| Linear graph | 1,612,625 | 3,853,458 | 7,059,666 |
| Fan-out direct | 8,167 | 8,292 | 8,375 |
| Fan-out graph | 5,000,250 | 9,052,333 | 103,600,792 |

Raw elapsed nanoseconds, in trial-number order (no samples dropped):

```text
linear direct: 2791 2917 2750 2791 2792 2750 2792
linear graph:  2463167 1612625 1678500 7059666 4461209 4451625 3853458
fanout direct: 8334 8333 8292 8167 8375 8209 8167
fanout graph:  10420542 9052333 9410709 7564958 103600792 7588000 5000250
```

Every reported sample had producer/evaluation counts `1/4096/4096`, left count
`2048` and hash `b9beb3e61931e56c`; fan-out right count/hash were
`4096/8458a189b5fac738` (linear right `0/0`). All fixtures/warmups also passed.
No intentional concurrent build/test was running during this invocation.
Power mode, thermals, and ambient background load were not controlled; this is
one interactive host/process, not a platform comparison or stable reference
threshold. In particular the large fan-out outlier is retained, not explained
away. Timing alone cannot attribute cost to locks, scheduling, allocations, or
lowering. No allocator/occupancy/task measurements have been fabricated from it.

## Post-migration comparison

After the public API migration, three separate `zig build benchmark` processes
used the same host (Apple M1 Pro, 10 cores, 16 GiB; macOS 27.0.1/26A434), pinned
Zig 0.17.0 LLVM ReleaseFast, native `aarch64` / compiler CPU `apple_a14`, and
`N=4096`, `C=16`, two warmups and seven trials per variant. No intentional
concurrent builds/tests ran during measurement. Ambient load, power mode and
thermals were not controlled.

`graph` uses the archived declaration frontend on the current audited transport;
it is not a replay of a binary checked out at the original baseline. `current`
uses the public declarative/DI API. Both compile in the same benchmark module
through `src/benchmark_api.zig` so shared Zig files have one module owner. Direct,
legacy, and current execute the same deterministic work/sink effects; only the
graphs implement concurrent delivery/cancellation. All 126 measured sample
counter/hash fields matched the oracle, as did fixtures/warmups.

Aggregate min/median/max over 21 samples per shape/variant, **nanoseconds**:

| Shape | Variant | Min | Median | Max |
|---|---|---:|---:|---:|
| Linear | Direct | 2,625 | 2,833 | 14,709 |
| Linear | Legacy `graph` | 2,403,625 | 2,743,084 | 3,812,125 |
| Linear | `current` | 911,209 | 1,067,041 | 1,438,834 |
| Fan-out | Direct | 7,708 | 8,208 | 8,542 |
| Fan-out | Legacy `graph` | 4,601,208 | 4,959,167 | 6,593,667 |
| Fan-out | `current` | 1,734,708 | 1,869,500 | 3,899,334 |

The current medians are lower in these workloads; producer-backed execution is
still far from the serial arithmetic loops. This comparison includes dependency
planning, lowering and cancellation changes together, and does not isolate their
individual contributions. It proves neither universal zero overhead nor a stable
speedup across workloads/platforms.

Current structural estimates (not measured task counters/occupancy):

| Shape | Transport owners | Producer/forwarding + terminal tasks | Reserved payload bytes at C=16 |
|---|---:|---:|---:|
| Linear legacy | 4 | 4 + 1 | 640 |
| Linear current | 1 | 1 + 1 | 256 |
| Fan-out legacy | 5 | 5 + 2 | 768 |
| Fan-out current | 2 | 2 + 2 | 384 |

Public regressions verify progress with only two concurrent slots for a linear
producer region and four for a shared region with two terminals, including named
exclusive ancestors. These are bounded concurrency tests, not direct task counts.
Preparation registries/contexts, backend allocations/stacks and metadata remain
excluded from payload backing. No allocator-byte or peak-occupancy measurement
was added.

Raw nanoseconds in trial order; no samples dropped:

```text
process 1
linear direct: 4250 3416 3500 3417 3125 3167 3084
linear graph: 3375333 3213750 3544583 3812125 2751834 2774000 2743084
linear current: 1438834 1424625 1329375 1215833 1142833 1196000 1111125
fanout direct: 8500 8333 8333 7917 8083 8208 7708
fanout graph: 4879833 4859750 5280791 6593667 5509291 4930416 5036667
fanout current: 1734708 1772958 1784958 3899334 1838459 1879125 1923125
process 2
linear direct: 2708 2833 2834 2625 2625 2750 2750
linear graph: 2403625 2454500 2474375 2880083 2469875 2503250 2476042
linear current: 1047167 1109583 1058166 911209 1006750 1050208 917709
fanout direct: 8542 7958 8167 8125 8417 8292 8542
fanout graph: 4842667 5116417 4959167 4784041 5262417 5036459 4957042
fanout current: 1788750 1794291 1882584 1869500 2038750 2087291 1819750
process 3
linear direct: 2709 2709 2708 2959 2792 2667 14709
linear graph: 2574291 2612334 2626667 3110459 2730083 3461667 3777458
linear current: 1121708 1001875 1041500 1086250 930708 1034125 1067041
fanout direct: 8125 8334 8417 8334 8167 8166 7875
fanout graph: 4825291 4966750 4745959 4601208 4977542 5173792 4935416
fanout current: 2152417 1890375 1849291 1843834 1875167 1830709 1952292
```

Every sample had activation/production/evaluation counts `1/4096/4096`, left
count/hash `2048/b9beb3e61931e56c`, and right count/hash
`4096/8458a189b5fac738` for fan-out (`0/0` for linear).

The code was an uncommitted migration worktree based on `39ac0c2`, not a published
revision. Its source fingerprint was
`b7994d15ffad966359f711027d4050dc4e96112418692672d17c8fa1c9e813ad`:
SHA-256 of sorted relative paths for `.zigversion`, `build.zig`, `build.zig.zon`,
`benchmarks/graphs.zig`, and all `src/**/*.zig`, appending each UTF-8 path, NUL,
file bytes, NUL. This identifies the measured source snapshot independently of
the historical raw observation above.

### Validation of the original baseline

On the compiler/host above, these checks passed:

```sh
zig fmt --check build.zig build.zig.zon src tests examples benchmarks
zig build test
zig build test -Doptimize=ReleaseFast
zig build check
zig build benchmark
zig build benchmark -Dbench-items=32 -Dbench-warmups=1 -Dbench-trials=1
zig build benchmark -Dbench-items=0 -Dbench-warmups=1 -Dbench-trials=1 -Dbench-capacity=1
zig build benchmark -Dbench-items=7 -Dbench-warmups=1 -Dbench-trials=1 -Dbench-capacity=256
```

`zig build benchmark -Dbench-capacity=0` was also checked to fail with
`ExpectedPositiveOptions`, before graph execution. The initial ReleaseFast
native-test command exceeded a 120-second terminal limit; the subsequent exact
command completed successfully. Documentation-relative links, existing agent symlink
targets, and whitespace were checked. Cross/codegen checks are compilation and
scoped comparison evidence, **not foreign benchmark execution**.

## Follow-up scope

The [performance roadmap](../performance.md) defines the next investigation and
review gates. The [implementation record](../history/execution_migration.md)
describes the completed public API/lowering migration; allocator and phase
measurements are recorded separately, not inferred from these timings.

These graphs do not represent merge, signals, `take` retirement, retention,
batching, I/O, failure/cancellation, expensive callbacks, or arbitrary graph
shapes. Cold-start and steady-state throughput need separately specified
experiments. Graph inspection/tracing, broader native platform coverage,
formatter/linter/canonicalization, and broader graph optimizations remain separate
work, not follow-on implementation authorized by this measurement record.
