# Toolchain and validation

[Documentation index](README.md)

Use exactly Zig **0.17.0**, pinned in [`.zigversion`](../.zigversion) and enforced
by [the build](../build.zig). The package exports the `zrx` module; its source
entry point remains [`src/root.zig`](../src/root.zig).

```sh
zig version
zig fmt --check build.zig build.zig.zon src tests examples benchmarks
zig build test
zig build test -Doptimize=ReleaseFast
zig build check
```

- `test`: native behavior, compile-fail fixtures, codegen-parser/fixture tests,
  and executable example coverage. Invalid contracts must fail with their expected
  diagnostic; unrelated errors or successful compilation fail the check. I/O
  entry points compile, their actual graphs run with finite files/loopback peers,
  and the CLI executable receives scripted stdin with exact stdout/stderr checks.
  [External example tests](../tests/io_examples.zig) import the same composition
  functions used by the entry points, keeping fixtures/assertions out of examples.
- `check`: formatting, native tests, cross builds, and scoped codegen comparisons.
- `declarative-test`: current public API, service/resource contracts, direct
  regions, producer sharing, signals, merge/reduction, scan, cancellation and I/O.
- `lifecycle-test`: forced runtime alias/completion schedules and both
  producer-await/retirement join orders, using test-local Io observation.
- `measurement-test`: concurrent raw allocator accounting, fault cleanup and
  callback/coordinator checkpoint invariants, without performance thresholds.
- `benchmark-costs` / `benchmark-spans`: opt-in run-allocator and instrumented
  activity reports, kept separate from uninstrumented `benchmark` timings.
- `benchmark-phases`: opt-in private coordinator checkpoints, separating
  preparation, acquisition/initialization, active execution and return cleanup.
  [Definitions, native data and erasure evidence](measurements/phases.md)
  distinguish elapsed intervals from CPU time.
- `fmt`, `cross`, `codegen`: focused build steps using the same configuration.
- `example`: finite noninteractive demos; the [index](README.md#executable-examples)
  lists focused commands. `io-examples` builds/installs live-I/O executables
  without running them or waiting for external input.

Native coverage includes ordering, coercions/type transitions, single/tuple
equivalence, errors-as-data, fail-fast boundaries, caller ownership, graph
preparation/startup failure, cancellation/join order, sharing/backpressure,
retention, batching, merge, and signal coherence/completion. Private transport/
cursor helpers preserve low-level tests without re-exposing retired public
ownership APIs. Neither tests nor comptime checks prove arbitrary callback
purity, termination, lifetime safety, or thread safety.

Current public streaming accumulation tests cover rerun/reset, injected reducer
requirements, managed lifetimes, ordinary suffix arguments, exclusive lowering,
sharing/prefix retirement, boxed error data, held state and source failure.
The original scan fixtures remain private regression evidence for shallow
snapshots, bounded slow-reader delivery and cancellation. The migrated two-pipe
transfer monitor has external integration tests and an executable smoke run.

Line-I/O coverage includes framing across short reads, record ownership,
resource acquisition/cleanup, startup/allocation failures, write failure,
exclusive file creation, rerun, and cancellation of a blocked TCP read.

## Cross-target and codegen scope

The single [catalog](../tests/codegen/catalog.zig) covers Linux x86-64/ARM64,
macOS ARM64, Windows x86-64/ARM64, and freestanding WebAssembly. Exported
runtime-input fixtures actually instantiate APIs, including graph execution.
Scan/hold/sampling are covered as graph cross-builds, not direct-loop codegen
equality.
OS-backed line I/O is hosted-only (five targets); the catalog records that
restriction. Inline line-value composition is checked on all six targets.
Object compilation exercises target code/object writers; it is **not foreign
runtime execution**, support for all Zig targets, or a graph benchmark.

Selected direct imperative functions are compared with grouped/separate
composition-kernel fixtures using pinned LLVM ReleaseFast output:

- Resolve aliases and narrowly normalize function-scoped LLVM IR.
- Compare selected AArch64 loop assembly without erasing instructions,
  registers, operands, or order.
- Keep behavior/cross-only cases explicit, rather than weakening comparisons
  until they pass.

The infallible `each`/`fold` sum loops have scoped assembly comparisons on the
three catalog AArch64 targets. Optional recovery after `keepIf`, fallible
`tryPipe` flow, and `tryFold` are behavior/cross-only where IR differs.
Native fixture comparisons also exercise short inputs, tails, wrapping arithmetic,
and explicit vectors. Matching selected bodies is not whole-binary equality,
a universal zero-cost/inlining proof, or a signal/run performance claim.

The eager kernel used by those original fixtures is now an internal regression
facade, not an exported API. Its comparisons were not weakened or reinterpreted
as checks of the new executor. The same catalog also includes current public
declarative finite/producer fixtures; those have object-only coverage, not
body-equality claims. Current native tests and executable examples import the
actual `zrx` module; archived lifecycle fixtures use explicit private facades.

Ordinary optimization may inline/fuse/auto-vectorize when callback semantics,
aliasing, and targets permit. Explicit `@Vector` callbacks already work with
whole-value `map`; there is no specialized SIMD mode or guaranteed vector width.
The codegen checker depends on the pinned LLVM backend; a future backend change
requires revisiting that check, not weakening semantic tests.

[GitHub Actions](../.github/workflows/validation.yml) is a thin Linux wrapper
around `zig build check` and ReleaseFast native tests. Local validation does not
require CI, an emulator, or duplicated target matrices.
