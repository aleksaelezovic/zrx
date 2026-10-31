# Validation suites

- `world.zig`, `world_loop.zig`, and `declarative_graphs.zig` exercise the current
  public `zrx` module: typed dependencies/resources, declaration-only execution,
  synchronous regions, sharing, state, reduction, cancellation, and actual I/O.
- `declarative_scan.zig` covers the migrated recurrence, injected dependencies,
  managed lifetimes, prefix probes/retirement, snapshots and failures.
  `scan_example.zig` tests the public two-pipe monitor. Original `scan.zig`
  remains private transport/kernel regression evidence.
- `branch.zig` tests current exclusive value/terminal cases, persistent state,
  injected predicates/effects, retirement, allocation/startup failures and cancellation.
- `http.zig` runs the actual current echo graph with finite loopback peers, including
  body framing/limits, completion credits, routing/drops, cancellation and cleanup.
- `lifecycle_hardening.zig` forces runtime-selected aliases, completed-prefix/
  peer-result ordering, and state failure after observation retirement with an
  idle sampler, including managed-service release checks.
- `join_retirement.zig` uses the private runtime facade and a test-local Io shim
  to force both producer-await/last-reader-retirement join orders. It observes
  the exact result-mutex wait and preserves real backend futures/results.
- `measurement.zig` validates benchmark-local accounting and checkpoint tools,
  including concurrent calls over a non-thread-safe backing allocator and graph
  allocation-failure cleanup. It never asserts a timing threshold.
- Its `phase_observation.zig` suite checks private coordinator markers on finite
  and graph success/error/cancellation paths. `phase_erasure.zig` provides native
  runtime-input LLVM inspection fixtures; it is not a new target/equality catalog.
- `compile_fail/world_*.zig` checks current public contracts, including rejection
  of raw eager inputs and malformed dependency/resource declarations.
  `compile_fail/declarative_scan_*.zig` checks current scan typing and requirements.
- Earlier composition/graph suites are intentionally retained as kernel and
  lifecycle regressions. Build wiring gives them `src/legacy_test_api.zig` or
  `src/runtime_test_api.zig`, not the package's public root. Their local import
  alias can still be named `zrx`; it does not establish a supported old API.
- `legacy_examples/` contains archived regression programs, not current examples.
  Current programs live under `examples/`.
- `codegen/catalog.zig` is the one target/case catalog. Original strict body
  comparisons cover the internal composition kernel. Entries marked `public_api`
  instantiate the current module for cross-object coverage, not equality claims.

`zig build declarative-test` focuses on the current public API.
`zig build lifecycle-test` runs the focused public and private hardening schedules.
`zig build test` retains all suites; `zig build check` additionally checks
formatting, cross builds, and the unchanged scoped kernel comparisons.
