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

## What remains unproven

The hosted evidence is consistent with varying native CPU features, while
fixed cross targets retain their objects. But the two historical jobs did not
log resolved CPU models/features, so their CPU equality or difference cannot
be established from those logs.

The controlled probes did not reproduce misses caused solely by tool-path,
inode, timestamp or archive restoration changes. That weakens those explanations;
it does not eliminate every x86-64-specific compiler/linker or environment issue.

The next diagnostic change records `lscpu` plus Zig's actual resolved native
triple and serialized CPU selection, using
[`tests/ci_target.zig`](../../../tests/ci_target.zig). The helper runs through the
same pinned compiler, independently of the declaration library and its tests.
No CI target, CPU flags, cache namespace or size limit changes in this increment.

Compare two new hosted runs before choosing a remedy. If native CPU differences
are confirmed, consider separate cache namespaces per resolved native
configuration, preserving current CPU coverage. A fixed baseline compilation
target is a different policy decision, not a silent cache fix.

## Validation and limits

The diagnostic helper passed on native macOS ARM64 and Linux ARM64. Root
`zig build test`, `zig build test -Doptimize=ReleaseFast` and `zig build check`
passed on native macOS ARM64 with exactly Zig 0.17.0. No application source,
library runtime, test count, cross catalog or optimization policy changed.
Workflow lint, YAML/Bash syntax, local links, instruction symlinks and whitespace
checks passed; ShellCheck was unavailable.
The diagnostic workflow has not been pushed or run on GitHub yet.
