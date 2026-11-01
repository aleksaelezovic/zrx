# Toolchain and validation

[Documentation index](README.md)

Use exactly Zig **0.17.0**, pinned in [`.zigversion`](../.zigversion) and enforced
by [the build](../build.zig). Every public test, example and cross fixture imports
the same [`zrx` module](../src/root.zig). There is no alternate executor or
compatibility test surface.

```sh
zig version
zig fmt --check build.zig build.zig.zon src tests examples benchmarks
zig build test
zig build test -Doptimize=ReleaseFast
zig build check
```

- `test`: current behavior, expected-diagnostic compile failures, finite example
  entry points and actual I/O graphs using temporary files/finite loopback peers.
- `declarative-test`: public dependency/resource, graph, operator, scan, branch
  and HTTP suites.
- `lifecycle-test`: forced alias/completion schedules and producer join/retirement
  orders. The small transport shim exposes no declaration operators/executor.
- `measurement-test`: concurrent allocator accounting, failure cleanup and
  callback/coordinator checkpoint invariants, with no timing thresholds.
- `test-branch`, `test-http`: focused routing and HTTP scopes, including startup/
  allocation failure, completion credits, deadlines, cancellation and cleanup.
- `test-retry`: retry policies/DI, exact waits, error-valued outcomes, cancellation,
  shared execution, cold validation and the executable checkout composition.
- `example`: finite public demos. Each also has an `example-NAME` step.
  `io-examples` and `http-example` build/install opt-in executables without
  starting live services.
- `fmt`, `cross`: focused formatting and current-API object builds.
- `check`: formatting, all native tests and cross builds.

The [diagnostic catalog](../tests/contracts.zig) requires the intended error,
not merely any compilation failure. [Test suites](../tests/README.md) cover
ordinary argument coercions, tuple composition, errors-as-data, fail-fast callback
boundaries, borrowed referents, sharing, prefix retirement, retention, batching,
signal coherence, and join-before-release behavior. Tests and comptime checks do
not prove arbitrary callback purity, termination, lifetime safety or thread safety.

## Cross-target scope

One [target/fixture catalog](../tests/targets.zig) covers Linux x86-64/ARM64,
macOS ARM64, Windows x86-64/ARM64, and freestanding WebAssembly. Exported
runtime-input fixtures instantiate current declarations, resources, producers,
signals, scan, retries, branching, bounds/retention/batching, line I/O and HTTP.
Queue prefixes and whole-item vectors are also instantiated.
OS-backed I/O fixtures are restricted to the five hosted targets.

These checks emit objects. They do **not** execute foreign targets, establish
support for every Zig target, or assert imperative/declarative body equality.
There is no automatic codegen-comparison step. The pre-declaration executor and
its comparison fixtures were deleted, not retargeted or weakened to pass.
[Native inspection fixtures](../tests/phase_erasure.zig) exercise actual current
calls but do not establish an optimizer guarantee.

Normal compiler optimization may inline/fuse/vectorize when types, aliasing and
callback semantics permit. Whole-item vector callbacks work; no specialized SIMD
mode or universal zero-overhead guarantee is implied.

[GitHub Actions](../.github/workflows/validation.yml) runs `zig build check` and
ReleaseFast native tests on Linux. Local validation does not require CI, emulators,
or another target matrix.
