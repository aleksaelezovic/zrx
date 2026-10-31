# Run allocator costs and callback activity checkpoints

Status: opt-in instrumented baseline, not a runtime optimization. Production APIs,
runtime behavior, and existing codegen comparisons are unchanged by this pass.
Read with the [original timing record](elapsed.md).

## Reproduce

Exactly Zig **0.17.0**, native-host LLVM ReleaseFast for both executable and
imported library:

```sh
zig build measurement-test
zig build benchmark-costs 2> allocations.csv
zig build benchmark-spans 2> activity.csv
# Same shared workload options as the uninstrumented benchmark:
zig build benchmark-costs -Dbench-items=4096 -Dbench-capacity=1 \
  -Dbench-warmups=2 -Dbench-trials=7
```

`benchmark` remains the uninstrumented elapsed-time comparison. `benchmark-costs`
reports allocator metrics without elapsed time; `benchmark-spans` separately
reports instrumented callback checkpoints without an allocator wrapper. No
measurement command runs in default tests or has a timing threshold.

Reports use stderr. Lines beginning with `#` are metadata, followed by CSV. Only
accept exit status zero; all passes verify activation, production, shared-map
evaluation, item counts and ordered sink hashes against the same direct oracle.
`graph` means the archived materialized frontend; `current` means public zrx.

## Allocator accounting

The [wrapper](../../benchmarks/tracking_allocator.zig) counts raw allocator
operations at **the allocator supplied to run**, not the whole process:

- Alloc requests/successes and requested bytes, including failed requests.
- Successful fresh bytes and positive resize/remap growth bytes separately.
- Resize/remap attempts/successes, frees, and released bytes (free plus shrink).
- Current/peak live requested bytes and logical allocation counts.

Moving remap remains one logical allocation. Its peak only sees the abstract
allocator boundary, not simultaneous old/new backing storage inside the allocator.
All backing calls and statistics share an uncancelable mutex. This also protects
a non-thread-safe backing allocator; no bookkeeping allocation/printing occurs
inside callbacks. Overflow/underflow is an explicit failure. Reset requires
quiescence and rejects outstanding allocations; snapshots are synchronized.

The Io backend/driver use the unwrapped `smp_allocator`, so the wrapper cannot
recurse through its mutex backend. Exclusions include backend task frames/thread
stacks, driver state, typed stack frames, allocator metadata/slabs/caches, RSS,
payload referents and occupied queue slots. **Peak live requested bytes is not
peak retained payload or total memory.**

Every sample must end with zero live bytes/allocations, successful allocations
equal frees, and fresh plus growth bytes equal released bytes.

### Measured allocation results

Host: Apple M1 Pro, 10 cores, 16 GiB, macOS 27.0.1/26A434; Zig 0.17.0,
`stage2_llvm`, ReleaseFast (`fast`), native ARM64 / CPU `apple_a14`.
Io: `std.Io.Threaded`, async disabled, concurrent unlimited. Backing allocator:
`std.heap.smp_allocator`. Same deterministic producer/arithmetic/hash workloads
as the original benchmark; no user-managed resources or collection arrays.

Each capacity/item-count point used three processes, two unreported warmups and
seven samples per shape/variant: **756 allocation rows** over `N=0,4096`,
`C=1,16,256`. At each point all 21 samples per shape/variant had identical
accounting. The table therefore preserves all observed allocation outcomes:

| Shape / variant | Alloc successes = peak live allocations | C=1 fresh/peak bytes | C=16 fresh/peak bytes | C=256 fresh/peak bytes |
|---|---:|---:|---:|---:|
| Direct, either shape | 0 | 0 | 0 | 0 |
| Linear legacy | 33 | 2,880 | 3,480 | 13,080 |
| Linear current | 12 | 1,400 | 1,640 | 5,480 |
| Fan-out legacy | 41 | 3,504 | 4,224 | 15,744 |
| Fan-out current | 21 | 2,064 | 2,424 | 8,184 |

For every row: attempts equal successes; resize/remap attempts and growth bytes
are zero; released bytes equal fresh bytes; all final live counts/bytes are zero.
The same results held at N=0 and N=4096. A final C=16/N=4096 recheck after
simplifying the separate activity observer reproduced these allocation results.

For this host/layout/workload, the measured byte slopes are:

```text
linear legacy: 2840 + 40*C       linear current: 1384 + 16*C
fanout legacy: 3456 + 48*C       fanout current: 2040 + 24*C
```

The slopes match the separately derived reserved-payload bounds; the constants
include other run-allocator state. This does not classify every allocation or
turn requested bytes into allocator-reserved memory. The observations show fixed
per-run allocation costs rather than growth with item count at these two N
values; they do not establish a bound for arbitrary graphs.

At N=4096 each sample had activation/production/evaluation counts `1/4096/4096`,
left count/hash `2048/b9beb3e61931e56c`, and fan-out right count/hash
`4096/8458a189b5fac738` (linear `0/0`). Empty samples had one activation and
zero items/evaluations/hashes.

## Callback activity is not an exact executor phase

The [checkpoint collector](../../benchmarks/callback_spans.zig) observes:

1. First producer callback entry, relative to invocation start.
2. Producer callback exit.
3. First entry/final exit for each nonempty serial terminal sink.
4. Invocation return, after run cleanup.

The [activity driver](../../benchmarks/costs.zig) reuses the same source/math/sink
work. It adds observer references to caller-owned contexts, **not transported
Packet values**, and records only boundary callbacks. It does not lock/read the
clock for every item; two lightweight boundary tests per item remain. The trace
lock and clock still perturb execution and scheduling. Warmups use the same
instrumented callbacks as samples.

The CSV's three intervals sum to elapsed time for each sample:

- `start_to_first_source_ns`: includes declaration/setup, acquisition/activation,
  deferred worker startup and scheduling up to producer entry. Not pure setup.
- `callback_window_ns`: first source entry through the latest producer/sink exit.
  Includes computation, transport, backpressure, waiting, scheduling and gaps.
  Not CPU time, nor time spent only inside callbacks.
- `last_observed_exit_to_return_ns`: includes EOF/result observation, remaining
  completion/join work and cleanup, not necessarily only deallocation. It may
  include unobserved mapping/filter work, for example a final rejected item.

The source can return before or after the last sink. Mapping/filter callbacks
are not individually instrumented, so the latest observed exit is not a claim
that every user callback has finished. `sink_checkpoint_pairs`
counts nonempty sinks, not item invocations. Empty input has no sink markers
(`NA`), rather than fabricated zero sink timestamps.

### Instrumented checkpoint observation

Same host/configuration, N=4096/C=16, three processes, two warmups and seven
trials per graph variant: **84 samples**. There were no intentional concurrent
builds/tests during collection. Ambient load, power and thermals were uncontrolled.
All work/hash checks and per-sample interval sums passed.

Independent column medians over 21 samples, microseconds:

| Shape / variant | Start to source | Callback window | Exit to return | Elapsed |
|---|---:|---:|---:|---:|
| Linear legacy | 15.791 | 2,774.250 | 4.875 | 2,791.625 |
| Linear current | 6.000 | 1,009.792 | 2.542 | 1,022.542 |
| Fan-out legacy | 14.916 | 5,590.667 | 6.375 | 5,606.083 |
| Fan-out current | 11.959 | 2,761.084 | 5.334 | 2,776.334 |

Column medians need not sum to the elapsed median. These instrumented results
are not replacements for headline timings or proof that queue/scheduler time is
the causal bottleneck. They show that the coarse activity window, not the outer
prefix/tail, contains most observed elapsed time in these runs. Allocator counts
alone therefore do not explain end-to-end latency.

Raw `(prefix, window, tail)` nanoseconds in trial order; no samples dropped.
Their sums reconstruct all reported elapsed samples:

```text
process 1
linear graph: (15791,2465375,3334) (12083,2753875,4042) (12625,2774250,4750) (21125,2609458,4750) (22291,3427750,5334) (13709,2815000,16625) (37208,2975417,4791)
linear current: (5042,1107458,4958) (5125,806958,2000) (6000,942000,2500) (5000,1066791,3625) (5834,862875,2000) (6292,1080417,2916) (7083,1073250,5000)
fanout graph: (9166,5590667,6250) (8917,5533833,5750) (26250,5267875,6083) (13041,5021042,5375) (8833,5482667,6375) (15792,5609333,8417) (13750,5722000,8625)
fanout current: (10625,2922333,5334) (10875,1934167,3958) (12292,3007958,3875) (17000,2415625,9208) (14416,2567292,3583) (9250,2761084,6000) (17000,3024625,3167)
process 2
linear graph: (13625,3133542,5791) (10542,2896958,3958) (10708,2736917,5542) (11625,3048500,5250) (16792,3081083,9125) (9541,3163334,4416) (34791,2677125,4959)
linear current: (28084,1023250,3125) (4458,892292,2125) (13083,1002875,6584) (8167,992458,4959) (7417,967542,2208) (4625,989583,2417) (4250,1068167,2416)
fanout graph: (14125,4973542,4750) (13375,5149167,5000) (15542,4948833,5167) (18708,4599542,4458) (14375,4932667,4708) (10042,5396792,10416) (31250,5634791,6750)
fanout current: (13000,2336958,3709) (7333,1913458,3417) (6958,1984042,3917) (9375,1818125,3416) (9209,1943958,6708) (9083,2164709,7625) (16333,1912042,2625)
process 3
linear graph: (20250,2819833,4875) (32417,2526458,4542) (9000,2538833,4708) (15791,2848209,4458) (19541,2645209,16000) (16042,2748083,6167) (11959,2696333,7792)
linear current: (5167,1009792,2250) (6542,1121458,3417) (6875,878167,5500) (6958,847750,2417) (5334,1033041,2542) (4584,1061500,1625) (8584,1299291,3250)
fanout graph: (14916,6254667,8042) (30375,6569292,9875) (25250,6562541,8042) (15458,6505334,5958) (12125,5889459,21583) (22667,6441791,8209) (26167,7142917,8791)
fanout current: (13750,3746375,6834) (11959,4584458,8458) (27209,3158875,5583) (11250,3306834,7291) (17542,3718167,5666) (10125,4345042,5000) (14000,4336041,7584)
```

The uncommitted worktree is based on `39ac0c2`. Measured instrumentation-source
snapshot: `e6cd3dca1fb2073e28ea959e7c3154d03ebe15966e534fa821fc990e357c3d93`.
It uses SHA-256 of sorted relative paths `.zigversion`, `build.zig`,
`build.zig.zon`, all `benchmarks/*.zig`, and all `src/**/*.zig`, appending path,
NUL, file bytes, NUL. The allocation-only pass did not change when activity
observation was reduced from per-item to boundary-only markers.
After collection, the CSV's original `last_user_exit_to_return_ns` label was
corrected to `last_observed_exit_to_return_ns` without changing the timestamp
collection. The interval definitions and raw data above use the corrected name.

## Validation and next decision

[Instrumentation tests](../../tests/measurement.zig) cover failed/successful raw
alloc/resize/remap, growth/shrink, moved-pointer contents, equal-size resize,
forwarded alignment/return address, reset guards, concurrent allocations over a
non-thread-safe backing allocator, concurrent snapshots, actual graph cleanup,
every preparation allocation failure, and concurrent callback markers. There
are no positive duration or machine-speed assertions.

Passed with pinned Zig 0.17.0 on native macOS ARM64:

```sh
zig build measurement-test
zig build measurement-test -Doptimize=ReleaseFast
zig build test
zig build test -Doptimize=ReleaseFast
zig build check
```

The new commands also ran at N=0 and N=32, and empty activity markers were checked.
Cross compilation is not foreign execution; no race detector, RSS measurement,
occupied-payload tracking, or actual task counter was added.

Exact setup/activation/result/shutdown boundaries are not exposed by ordinary
callbacks. If finer attribution is needed, the smallest proposed extension is a
**private comptime-erased observer** at existing coordinator transitions:
prepared (buffers/readers/gated workers ready), activating (after acquisition/
initialization, before the gate), and result selected (before shutdown). Existing
outer start/return timestamps would complete that timeline. It would still measure
elapsed intervals, not pure CPU time. This needs runtime edits and is **not
implemented** here; there is no public hook or scheduler API.

Subsequent pass: [private executor phase measurements](phases.md)
implements coordinator-only checkpoints. The final checkpoint deliberately
observes the result outside worker locks, rather than timestamping worker result
selection. The data and instrumentation snapshot above remain unchanged.

The current investigation order lives in the [performance roadmap](../performance.md).
