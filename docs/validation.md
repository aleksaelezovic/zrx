# Toolchain and validation

[Documentation index](README.md)

Use exactly Zig **0.17.0**, pinned in [`.zigversion`](../.zigversion) and enforced
by [the build](../build.zig). The package exports the `zrx` module; its source
entry point remains [`src/root.zig`](../src/root.zig).

```sh
zig version
zig fmt --check build.zig build.zig.zon src tests examples
zig build test
zig build test -Doptimize=ReleaseFast
zig build check
```

- `test`: native behavior, compile-fail fixtures, codegen-parser/fixture tests,
  and every executable example. Invalid contracts must fail with their expected
  diagnostic; unrelated errors or successful compilation fail the check.
- `check`: formatting, native tests, cross builds, and scoped codegen comparisons.
- `fmt`, `cross`, `codegen`: focused build steps using the same configuration.
- `example`: all examples; the [index](README.md#executable-examples) lists
  focused commands for stream examples.

Native coverage includes ordering, coercions/type transitions, single/tuple
equivalence, errors-as-data, fail-fast boundaries, caller ownership, graph
preparation/startup failure, cancellation/join order, sharing/backpressure,
retention, batching, merge, and signal coherence/completion. Private transport/
cursor helpers preserve low-level tests without re-exposing retired public
ownership APIs. Neither tests nor comptime checks prove arbitrary callback
purity, termination, lifetime safety, or thread safety.

## Cross-target and codegen scope

The single [catalog](../tests/codegen/catalog.zig) covers Linux x86-64/ARM64,
macOS ARM64, Windows x86-64/ARM64, and freestanding WebAssembly. Exported
runtime-input fixtures actually instantiate APIs, including graph execution.
Object compilation exercises target code/object writers; it is **not foreign
runtime execution**, support for all Zig targets, or a graph benchmark.

Selected direct imperative functions are compared with grouped/separate
pipelines using pinned LLVM ReleaseFast output:

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

Ordinary optimization may inline/fuse/auto-vectorize when callback semantics,
aliasing, and targets permit. Explicit `@Vector` callbacks already work with
whole-value `map`; there is no specialized SIMD mode or guaranteed vector width.
The codegen checker depends on the pinned LLVM backend; a future backend change
requires revisiting that check, not weakening semantic tests.

[GitHub Actions](../.github/workflows/validation.yml) is a thin Linux wrapper
around `zig build check` and ReleaseFast native tests. Local validation does not
require CI, an emulator, or duplicated target matrices.
