# Library ReleaseFast validation profile

[Validation scope](../../validation.md) · [Build entry point](../../../build.zig)

## Finding and limits

The local profile is dominated by **building optimized artifacts, not executing
the tests**. It does not establish the exact cause or per-artifact cost of the
9m 49s Linux CI step: that successful run did not print detailed build summaries.
No runtime optimization, cache policy, test coverage or build scheduling changed.

The [observed CI run](https://github.com/aleksaelezovic/zrx/actions/runs/41846478171)
on revision `50df5f213b0e386550bc971bd1d8a594627be962` spent 3m 59s in
`zig build check`, then 9m 49s in `zig build test -Doptimize=ReleaseFast`.
These are whole-step durations, not compiler-versus-test attribution.

## Local experiment

- Date: 2026-11-04; same revision as the CI run.
- Exactly Zig 0.17.0, default stage2_llvm ReleaseFast backend.
- Target: `aarch64-macos.27.0.1...27.0.1-none`, Apple M1 Pro,
  10 logical CPUs, 16 GiB RAM.
- Source SHA-256:
  `aa1847db38ea75d59ec8a73d00685728c783704a2320f05a087e39de4107a97a`.
  Same path/NUL/bytes/NUL recipe as the [app timing report](../app-validation/README.md).
- One observation per configuration, default build parallelism, no OS cache
  flush, and uncontrolled ambient host load. This agent launched no competing
  builds/tests during collection. No foreign execution or timing thresholds.

Copy nonignored source into a new temporary project, excluding generated output
and packages. Set `ZIG_GLOBAL_CACHE_DIR` and `ZIG_LOCAL_CACHE_DIR` to previously
nonexistent directories. Run:

```sh
zig build test -Doptimize=ReleaseFast --summary all --verbose --color off
# Repeat with the same directories for the warm observation.
```

With a second pair of empty caches, reproduce CI's ordering:

```sh
zig build check --summary all --verbose --color off
zig build test -Doptimize=ReleaseFast --summary all --verbose --color off
```

Measure subprocess wall time with `time.perf_counter`; collect child CPU counters
with `resource.getrusage(RUSAGE_CHILDREN)` and capture complete output per command.
Source-copy/setup time is excluded. The additional flags report diagnostics only;
they do not change optimization, checks or scheduling.

## Whole-command results

[Raw command observations](runs.csv) include wall time, OS-reported aggregate
child user/system CPU time and exit status. CPU counters are not per-phase
attribution and can exceed wall time because processes run concurrently.

| Observation | Wall time | Test result |
|---|---:|---|
| ReleaseFast first, empty caches | 129.17s | 243/243 passed |
| Immediate warm repeat | 4.66s | All 20 unit-test run steps cached |
| Fresh `check`, separate caches | 97.23s | 243/243 passed; catalog cross builds passed |
| ReleaseFast after that `check` | **81.40s** | **243/243 passed** |

The first invocation also compiled Zig's build configurer. Its binary timestamp
was approximately 57.35 seconds after the fresh log was created; this is a
filesystem timestamp observation, not a precise compiler-phase timer. The CI-order
experiment avoids treating this cold setup cost as CI's ReleaseFast cost.

## Compilation versus execution

[Raw unique compile/run step rows](release-after-check-steps.csv) come directly
from the ReleaseFast-after-check summary. Reused dependency references are omitted.
Native artifact names are qualified with `test/` or `exe/` to distinguish
same-named targets; these are labels, not filesystem paths.
Durations and MaxRSS retain Zig's human-readable rounding; concurrent durations
and process RSS values must not be added into a command wall time or peak RSS.

| Category | Count | Sum of reported step durations |
|---|---:|---:|
| Native artifact compilation | 29: 20 test executables, 9 library-built example executables | approximately 390s |
| Expected-diagnostic compilation | 96 | 39.00s |
| Unit-test execution | 20 executables, 243 tests | 4.75s |
| Example/smoke execution | 8 | 1.65s |

No native ReleaseFast artifact was reused from the Debug/cross `check`.
The largest native compile was HTTP (25s, reported MaxRSS 698M), followed by
errors (22s) and graphs/retry/branch (18s each). These are whole compiler-step
durations, not LLVM-pass or function attribution. Repeated code generation or
standard-library work is a hypothesis to investigate, not proven by this table.

In the warm repeat all 29 native artifacts and all 20 test runs were cached.
All 96 diagnostic compilations still ran; seven of eight executable runs were
cached. Therefore 4.66s is **not** proof of fast uncached test execution or a safe
CI-cache speedup. The uncached step table above supplies the execution evidence.

## Recommended next experiment

First obtain native Linux attribution. The pending workflow change records the
runner CPU/memory/target and adds `--summary all` to the two library commands,
without changing their checks. Its next hosted run can confirm or revise the
local compilation-dominant finding.

Then evaluate **compiled-artifact caching with every unit test and executable
smoke still executed**, rather than blindly enabling cached test results. Compare
a fresh and restored cache on the pinned compiler, preserving all 243 tests,
all 96 intended diagnostics and the cross catalog. Make cache misses fall back
to full validation. Do not infer cache safety from the warm observation alone.

Only consider test-harness consolidation or job sharding after that evidence:
they affect compilation reuse, process isolation and the critical path. No such
change, generic helper, inlining policy or production API is implemented here.

## Validation

The profiled commands passed, including all 243 tests. After the documentation
and diagnostic workflow edits, ordinary workspace `zig build test`,
`zig build test -Doptimize=ReleaseFast` and `zig build check` also passed using
Zig 0.17.0 on the native target above; these final checks used existing caches.
All 153 step rows were checked against retained output, and the source
fingerprint was unchanged.

The workflow passed actionlint 1.7.12 without ShellCheck integration (unavailable),
YAML parsing and `bash -n` for its run blocks. Local documentation links,
instruction symlink targets and whitespace checks passed. The changed workflow
has not run on GitHub yet; no exact Linux per-artifact attribution is claimed.
