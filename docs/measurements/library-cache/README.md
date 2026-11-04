# Compilation caching without cached validation results

[Validation scope](../../validation.md) · [Earlier profile](../library-releasefast/README.md)

## Decision

Reuse compiled artifacts, not successful test results. The root
[build](../../../build.zig) marks all 20 native test runners and all eight finite
example/smoke run steps with `has_side_effects = true`. The pinned Zig 0.17.0
build runner bypasses its run-result cache for these steps while allowing their
compile dependencies to remain cached. Output and exit-status checks are unchanged.

No test cases, intended diagnostics, cross fixtures or application behavior were
removed. This changes repeated local validation too: `zig build test` genuinely
runs the tests every time.

## Hosted evidence before caching

The [diagnostic CI run](https://github.com/aleksaelezovic/zrx/actions/runs/41856212011)
at `bb368614e8a23d47a5d7ffc14d5b7b150eafccc9` passed all four jobs.
The library runner reported Zig 0.17.0, target
`x86_64-linux.7.0...7.0-gnu.2.39`, two CPUs and MemTotal 8,122,984 kB.
`check` took 2m 41s and the following ReleaseFast validation took 6m 29s.

The ReleaseFast summary reported 29 native artifact compilations and 96
expected-diagnostic compilations. Its 20 test runs passed 243 tests; their
reported durations totaled 0.410s, and eight smoke runs totaled 0.017948s.
Compiler-step durations totaled approximately 482s; they overlap and are not
command wall time or CPU time. This supports compilation caching rather than
weakening execution coverage. Variation from the previous CI run is not an
optimization result.

## Local restored-cache experiment

- Base revision: `bb368614e8a23d47a5d7ffc14d5b7b150eafccc9`, plus only the
  three root build changes forcing validation runs.
- Source SHA-256:
  `d10061cf9ccd64635e99c7e889112057fb43086b4e217e066ccbf61ef4489ba7`,
  using the earlier report's sorted path/NUL/bytes/NUL recipe.
- Exactly Zig 0.17.0, default LLVM backend, native
  `aarch64-macos.27.0.1...27.0.1-none`, Apple M1 Pro, 10 logical CPUs, 16 GiB.
- Copy nonignored source to a fresh temporary project; omit generated output
  and packages. Set both `ZIG_GLOBAL_CACHE_DIR` and `ZIG_LOCAL_CACHE_DIR` to
  one initially nonexistent directory, matching the setup action's layout.
- Run `check`, then ReleaseFast tests. Preserve and copy that cache back into
  the same cache path, then repeat both commands. This models cache restoration
  at a stable workspace path, not arbitrary relocation.
- One observation per command; default parallelism, no OS cache flush and
  uncontrolled ambient load. No competing builds launched by this agent.
  Copy/restore time is excluded; network restore/upload was not measured.

All commands append `--summary all --color off`. [Raw observations](runs.csv)
record wall time, aggregate child CPU counters, exit status and the sum of
cache-file lengths, not allocated disk blocks, compressed archive size or RAM.

| Command | Cache | Wall time | Actual validation execution |
|---|---|---:|---|
| `zig build check` | Initially empty | 91.41s | 243 tests and 8 smoke runs |
| `zig build test -Doptimize=ReleaseFast` | After that check | 70.81s | 243 tests and 8 smoke runs |
| `zig build check` | Restored | 6.80s | 243 tests and 8 smoke runs |
| `zig build test -Doptimize=ReleaseFast` | Restored | 5.04s | 243 tests and 8 smoke runs |

Both restored runs reported all 29 native artifact compilations cached and
zero test/smoke run results cached. `check` passed 208/208 steps, including
the cross catalog; ReleaseFast passed 158/158. Expected-diagnostic compilation
remained in each run. The cache contained approximately 716 MB of file bytes
after the experiment. These are local observations, not hosted-CI forecasts.

## CI policy and limits

Only the library job opts into caching through the existing pinned
`mlugg/setup-zig` action. Its cache key includes job, platform/architecture and
exact compiler version; `library-validation-v1` adds an explicit policy
namespace. Source changes use Zig's normal dependency/content validation,
not a workflow condition that skips commands on a cache hit.

The upstream action restores the latest matching cache and saves a new one
per run/attempt. Its existing 2 GiB limit remains: oversized directories are
cleared before saving, yielding a cold future build rather than weaker checks.
Standalone-app caching remains disabled, and app dependencies are unaffected.
No secrets or extra generated packages are intentionally added to the cache.

The [hosted follow-up and investigation](investigation.md) found successful cache
transport and cross-object reuse, but no native executable reuse. The restored
directory exceeded the limit and was cleared. The local result above must not
be presented as a hosted caching speedup; native CPU variation remains an
unproven hypothesis. No general runtime performance improvement is claimed.

## Validation

All four profiled commands passed. Their summaries were checked for 243/243
tests, 20 actual test-run results, eight actual smoke-run results and no cached
run results. Both restored summaries showed all 29 native artifacts cached.
The CSV was checked against the original observations.

Final ordinary workspace `zig build test`, `zig build test -Doptimize=ReleaseFast`
and `zig build check` also passed with Zig 0.17.0 on the native target above.
Workflow lint used actionlint 1.7.12 without unavailable ShellCheck integration;
YAML parsing and `bash -n` covered workflow/composite run blocks. Documentation
links, instruction symlink targets and whitespace checks passed.

The standalone apps were not retested: their source, builds and job cache policy
are unchanged in this local experiment. The subsequent hosted run passed the
library and all three apps; its library-only rerun also passed.
