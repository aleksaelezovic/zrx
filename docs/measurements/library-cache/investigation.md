# Native cache-miss investigation

[Cache experiment and policy](README.md)

## Hosted result: transport works, native reuse does not

Both attempts of [run 41875455512](https://github.com/aleksaelezovic/zrx/actions/runs/41875455512)
used commit `1fdac484ca3daffa9f797ca388c0413f3a616401`, Zig 0.17.0 and
runner image `ubuntu-24.04`, version `20261101.360.1`. The reported native
triple was identical: `x86_64-linux.7.0...7.0-gnu.2.39`.

| Observation | Seed, attempt 1 | Restored, attempt 2 |
|---|---:|---:|
| Setup step, including tool installation | 8s | 24s |
| `check` | 3m 04s | 2m 15s |
| ReleaseFast validation | 7m 39s | 8m 25s |
| Native artifacts reused per build mode | 0/29 | 0/29 |
| Cross objects reused | 0/46 | 46/46 |
| Test execution, per build mode | 243 passed, 20 runners | 243 passed, 20 runners |
| Smoke execution, per build mode | 8 passed | 8 passed |

Step times are GitHub's whole-second timestamps, not compiler CPU attribution.
The second attempt reran only the library job; the first attempt also passed
all three standalone-app jobs.

The seed saved 1,476,137,190 bytes of cache files as a 185,621,315-byte archive.
The rerun explicitly reported restoration of that seed's key. After validation,
the directory contained 2,913,774,731 bytes, exceeded the existing 2 GiB limit
and was cleared before saving. Raising the limit alone would not explain the
native misses. Timing differences do not establish a speedup or regression.

GitHub temporarily reported the seed job as in progress even after every step,
including cleanup, had completed. Its final recorded conclusion was success;
that status delay is separate from compilation and cache transfer.

## Controlled Linux probes

These probes use the unchanged six-test `test-predicates` suite, not the entire
library. Exactly Zig 0.17.0 was downloaded from the official index and its
archive SHA-256 verified. Generated builtin files confirmed the default
`stage2_llvm` backend. Execution was native Linux ARM64 inside the existing
Ubuntu 24.04.4 container image
`mcr.microsoft.com/playwright:v1.63.0-noble`, image ID
`5536bbbd0ffc`. This is **not** GitHub's x86-64 runner environment.

The source snapshot was commit `1fdac48`. All commands used:

```sh
zig build test-predicates -Doptimize=ReleaseFast --summary all --color off
```

Global and local cache variables pointed to one shared scratch directory.
Containers had no network access; only scratch data was mounted. All cases
executed and passed six tests; no run-result cache was used.

| Controlled change | Compilation result |
|---|---|
| Initially empty cache | Miss |
| Immediate repeat | Hit |
| Copy cache back into its original path, with new file inodes | Hit |
| Relocate Zig using hard-linked tool files | Hit |
| Change only CPU selection by appending `-Dcpu=baseline` | Miss |
| Repeat that baseline CPU selection | Hit |
| Recreate checkout with fresh inodes/timestamps, same contents/path; use native CPU again | Hit |
| Copy Zig to another path with new inodes, preserving file timestamps | Hit |
| Copy Zig to another path with new inodes and fresh timestamps | Hit |
| GNU tar POSIX/PAX gzip archive/extract cache round trip at the same path | Hit |

This does not prove portability across arbitrary workspace paths. The GNU tar
probe tests file/metadata restoration, not GitHub's zstd transport, cache service
or x86-64 ELF linker.

The container's native triple was
`aarch64-linux.7.0.14...7.0.14-gnu.2.39`. Zig resolved the CPU as
`generic+aes+ccdp+ccpp+complxnum+crc+dit+dotprod+flagm+fp16fml+fptoint+fullfp16+jsconv+lse+pauth+rcpc+rcpc_immo+rdm+sb+sha2+sha3`.
The baseline probe resolved `generic` without those feature additions.
Generated `builtin.zig` files confirmed the distinct feature sets. This shows
why logging the architecture/OS/ABI triple alone is insufficient.

## Follow-up: native CPU configurations differed

The two attempts of
[diagnostic run 41929030704](https://github.com/aleksaelezovic/zrx/actions/runs/41929030704)
used commit `450adf7c906a20345fe8ffde31c1867ca03f55c6`. Both passed every
test/smoke execution in both build modes; the rerun reused 46/46 cross objects
but 0/29 native artifacts per mode.

| | Attempt 1 | Attempt 2 |
|---|---|---|
| Reported hardware | AMD EPYC 7763 | AMD EPYC 9V74 |
| Zig CPU model | `znver3` | `znver4` |
| `check` | 4m 25s | 2m 39s |
| ReleaseFast validation | 11m 16s | 9m 59s |

The full serialized CPU selections were
`znver3-mwaitx-pku+shstk-wbnoinvd` and
`znver4-avx512bf16-avx512bitalg-avx512bw-avx512cd-avx512dq-avx512f-avx512ifma-avx512vbmi-avx512vbmi2-avx512vl-avx512vnni-avx512vpopcntdq-gfni-mwaitx-pku-wbnoinvd`.
The native triples and runner image version were identical. The cache grew from
1,501,585,575 to 2,948,655,134 bytes and was cleared by the 2 GiB limit.

Those CPU differences are sufficient to invalidate native artifacts; reuse is
not expected across them. There is no demonstrated Zig or setup-action bug.
Other inputs can still affect reuse, and these observations do not quantify
every compiler/linker cost or promise the CPU fix is the only remaining issue.

## Baseline CPU experiment

The accepted next policy uses `-Dcpu=baseline` on both library CI build commands,
with a fresh `library-validation-v2-baseline` cache namespace. Binaries still
execute on the native Linux runner; only their CPU model/features are fixed.
The size limit remains 2 GiB. User/local defaults, app jobs, compiler version,
optimization modes and cross fixtures are unchanged. No validation is skipped.

Keeping native CPU selection and partitioning caches by CPU was the alternative;
baseline selection favors reproducible regular CI inputs over host-specific CPU
coverage. The first run must seed the new namespace. A later cache-restoring
run is required to establish hosted artifact reuse and any end-to-end benefit.

`lscpu` and [`tests/ci_target.zig`](../../../tests/ci_target.zig) continue to report
the actual host CPU. The latter runs independently of the library and is not
itself passed the baseline CPU option; its output must not be mistaken for the
validation binaries' CPU policy.

## Validation and limits

The diagnostic helper passed on native macOS ARM64 and Linux ARM64. Root
`zig build test`, `zig build test -Doptimize=ReleaseFast` and `zig build check`
passed on native macOS ARM64 with exactly Zig 0.17.0. No application source,
library runtime, test count, cross catalog or optimization policy changed.
Workflow lint, YAML/Bash syntax, local links, instruction symlinks and whitespace
checks passed; ShellCheck was unavailable.
The diagnostic workflow subsequently passed both hosted attempts described above.
The baseline commands, `zig build check -Dcpu=baseline --summary all` and
`zig build test -Doptimize=ReleaseFast -Dcpu=baseline --summary all`, also passed
locally with Zig 0.17.0 on macOS ARM64. Each executed 243 tests in 20 runners
and eight smoke examples; `check` included the unchanged cross catalog.
The baseline policy's hosted results remain pending; these local results are
not Linux execution or cache-reuse evidence.
