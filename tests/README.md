# Validation suites

All public behavior/contract suites import the one `zrx` package module:

- `world.zig` and `world_loop.zig`: typed dependencies/resources, cold execution,
  coercions, finite lowering, callback failures and reverse release.
- `service_io.zig` and `managed_reader.zig`: service-backed singleton inputs,
  managed argv/readers/writers, injected configuration and lifetime/failure rules.
- `flat_map.zig` and `byte_streams.zig`: synchronous child traversal, owned chunk
  expansion, cross-chunk framing, pending errors and source/control failures.
- `declarative_graphs.zig`: producer/shared regions, merge, signals, prefix
  retirement, allocation/startup failure, cancellation and actual file output.
- `declarative_scan.zig` and `scan_example.zig`: recurrence, injected requirements,
  snapshots, prefixes, errors-as-data, held state and the two-pipe monitor.
- `retryPipe.zig`: serial attempts, typed policy services, exact delay/count rules,
  pending outcomes, cancellation, cold validation, sharing and checkout effects.
- `errors.zig`: recover/whenError/discard, transport/sharing, error-lane acceptance
  and retirement, reporting failures, stateful boundaries and swapped example sinks.
- `operators.zig`: bounds, suffix retention, collection/batching success/failure,
  allocation cleanup, queue binding, whole-item vectors, line framing and TCP prefixes.
- `branch.zig`: persistent case substreams, DI, retirement, state, all-terminal
  composition and gated startup.
- `http.zig`: actual echo graph with finite loopback peers, body framing/limits,
  request completion, routing/drops, header lookup, bounded JSON responses,
  cancellation, deadlines and cleanup.
- `http_configuration.zig`: managed server/provider dependencies, nominal roles,
  alias rejection, reacquisition, partial allocation cleanup and real serving.
- `predicates.zig`: static all/any composition, short circuit, nested predicates,
  typed injection and fallible-filter versus pure branch/framing requirements.
- `lifecycle_hardening.zig`: runtime-selected aliases, first-result handling and
  state errors after observation retirement; reporting/peer failure and external
  cancellation join resource users before release.
- `join_retirement.zig`: two forced producer-join schedules through a test-only
  transport shim; no alternative declaration API or executor.
- `error_lifecycle.zig`: private receipt decisions, stripped terminal data, stale
  generations and forced dispatcher acceptance/retirement/cancellation schedules.
  Test-local Io observes exact waits, not elapsed timing.
- `http_completion.zig`: forced late forwarding after HTTP interruption,
  canceled publication admission and balanced cleanup of already-issued credits.
  These private schedules require no sockets, sleeps or production hooks.
- `measurement.zig` and `phase_observation.zig`: concurrency-safe allocator/
  checkpoint tools, current graph failure cleanup and phase ordering.
  `phase_erasure.zig` supplies native runtime-input inspection fixtures.

[`contracts.zig`](contracts.zig) is the expected-diagnostic catalog for
`compile_fail/`. [`targets.zig`](targets.zig) is the only cross-target/case catalog;
every `cross/` fixture instantiates the current API. Foreign compilation is not
foreign execution or imperative codegen equality.

`zig build test` runs these suites and finite example entry points.
`zig build check` additionally checks formatting and cross-object builds.
Use `declarative-test`, `lifecycle-test`, `measurement-test`, `test-branch`,
`test-errors`, `test-error-lifecycle`, `test-http-completion`, `test-retry` or `test-http` for focused loops. See
[validation](../docs/validation.md).
