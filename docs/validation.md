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
  and HTTP suites, including managed byte I/O/configuration, service sources,
  synchronous declaration expansion and bounded framing.
- `lifecycle-test`: forced alias/completion schedules and producer join/retirement
  orders, plus blocked reporting/cancellation, late HTTP publication admission
  and join-before-release checks.
  The small transport shim exposes no declaration operators/executor.
- `measurement-test`: concurrent allocator accounting, failure cleanup and
  callback/coordinator checkpoint invariants, with no timing thresholds.
- `test-branch`, `test-http`: focused routing and HTTP scopes, including startup/
  allocation failure, completion credits, header/body/JSON helpers, deadlines,
  cancellation and cleanup.
- `test-http-configuration`: managed server providers, lifetime planning,
  nominal/borrowed owners, exclusive admission and partial-allocation cleanup.
- `test-predicates`: static short-circuit all/any with normal typed injection
  and pure/fallible predicate contracts.
- `test-retry`: retry policies/DI, exact waits, pending outcomes, cancellation,
  shared execution, cold validation and the executable checkout composition.
- `test-errors`: selective recovery, persistent error lanes, shared/merge/sample
  transport, retirement-before-acceptance, reporting failures, allocation cleanup,
  stateful boundaries, and the stdout/stderr program with swapped file sinks.
- `test-error-lifecycle`: private forced receipt/dispatcher schedules, including
  late acknowledgement after retirement, stale generations, unrelated lane
  retirement and cancellation while waiting for error acceptance.
- `test-http-completion`: private deterministic HTTP credit/forwarding schedules,
  including shutdown before publication and failed publication after reservation.
- `example`: finite public demos. Each also has an `example-NAME` step.
  `io-examples` and `http-example` build/install opt-in executables without
  starting live services.
- `fmt`, `cross`: focused formatting and current-API object builds.
- `check`: formatting, all native tests and cross builds.

[Standalone apps](../examples/apps/README.md) have separate project-local checks
and dependencies. They are not part of the root library build; independent CI
jobs run each app's documented build, Debug tests, ReleaseFast tests and check.

The [diagnostic catalog](../tests/contracts.zig) requires the intended error,
not merely any compilation failure. [Test suites](../tests/README.md) cover
ordinary argument coercions, tuple composition, boxed error data, pending operation
outcomes, borrowed referents, sharing, prefix retirement, retention, batching,
signal coherence, and join-before-release behavior. Tests and comptime checks do
not prove arbitrary callback purity, termination, lifetime safety or thread safety.

## Cross-target scope

One [target/fixture catalog](../tests/targets.zig) covers Linux x86-64/ARM64,
macOS ARM64, Windows x86-64/ARM64, and freestanding WebAssembly. Exported
runtime-input fixtures instantiate current declarations, resources, producers,
signals, scan, retries, recovery/error lanes, branching, bounds/retention/batching, line I/O and HTTP.
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
ReleaseFast native library tests on Linux, plus one independent job per standalone
app. A [shared setup action](../.github/actions/setup-zig/action.yml) enforces the
root compiler pin; app pins must match. Only the checkout app fetches/links SQLite.
No app dependencies are added to the library manifest or build. Local validation
does not require a CI provider or another target matrix.

[Local app command timings](measurements/app-validation/README.md) distinguish
fresh per-job caches from warm result-cache reuse. They are observations, not
thresholds or predictions for GitHub's Linux runners.

The [library ReleaseFast profile](measurements/library-releasefast/README.md)
separates artifact compilation from test execution and reproduces CI's
check-then-ReleaseFast cache ordering. Library CI records its environment and
full Zig step summaries so a long successful run has per-artifact evidence.

Library validation reuses Zig's compilation cache, but every unit-test executable
and finite example/smoke run executes on every invocation, even on a cache hit.
The build marks those run steps with `has_side_effects`; output and exit-status
assertions remain active. All expected diagnostics and cross fixtures stay in
the graph. Cache misses use the same complete commands, not a reduced fallback.
The standalone-app jobs still opt out of build caching.

See the [restored-cache experiment](measurements/library-cache/README.md) for
measured execution evidence, the cache namespace and limitations.
