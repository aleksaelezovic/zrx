# zrx documentation

zrx describes programs as cold declarations. `run(bindings, flows)` injects
services, owns resource lifetimes, and executes selected terminal effects.

## Guides

- [Execution, dependencies, sharing, and ownership](execution.md)
- [Signal lifecycle](state.md)
- [Retries and application-owned idempotency](retries.md)
- [Toolchain and validation scope](validation.md)
- [Performance investigation roadmap](performance.md)
- [Operation errors and explicit handling](errors.md)
- [Bounded line I/O](../src/io/README.md)
- [HTTP request scopes and lifecycle](http.md)

## API contracts

The [`zrx` module](../src/root.zig) is the only public package surface.

| Area | Source |
|---|---|
| Declaration composition and callbacks | [`pipe`, `map`/`each`, `filter`, `tap`](../src/compose.zig) |
| Finite inputs, producers, deferred reduction | [`fromSlice`, `fromValue`, `Stream`, `fold`](../src/data/declarations.zig) |
| Borrowed consuming inputs | [`fromIterator`](../src/compose.zig), [`readFrom`](../src/io/readFrom.zig) |
| Accumulated updates | [`scan`](../src/ops/scan.zig) |
| Per-item retry boundaries | [`retryPipe`, `RetryDecision`, `RetryOptions`](../src/ops/retryPipe.zig) |
| Recovery and explicit error records | [`recover`](../src/ops/recover.zig), [`Failure`](../src/data/failures.zig) |
| Exclusive cases | [`branch`, `when`, `whenError`, `otherwise`](../src/ops/branch.zig) |
| Resource recipes and nominal roles | [`resource`, `deriveResource`](../src/internal/world/resources.zig) |
| Dependency planning | [Typed run-local service storage](../src/internal/world/dependencies.zig) |
| Execution | [`run`](../src/run.zig) |
| Terminal effects | [`forEach`, `collectThen`, `batchThen`, `discard`](../src/ops/effects.zig) |
| Prefix, limits, suffix | [`take`](../src/ops/take.zig), [`maxItems`](../src/ops/maxItems.zig), [`takeLast`](../src/ops/takeLast.zig) |
| Merge and state | [`merge`](../src/ops/merge.zig), [`hold`](../src/ops/hold.zig), [`values`](../src/ops/values.zig), [`withLatestFrom`](../src/ops/withLatestFrom.zig) |
| Owned record values and I/O | [`Line`](../src/data/lines.zig), [line sources and resource glue](../src/io/lines.zig) |
| Serial HTTP server | [Request scopes, bodies and responses](../src/io/http.zig) |

Only `run` executes declarations.
Leading callback parameters are exact-type service requests; trailing parameters
are the operator's ordinary data. Stream operation errors skip success stages
until handled; only unhandled terminal outcomes fail execution. See the
[error model](errors.md); signal map results remain current-state data.

## Executable examples

`zig build example` runs these finite, noninteractive programs. Tests compile and
smoke-check their entry points and import reusable compositions.

- [Two managed database roles](../examples/resources.zig): derived resources,
  injected allocator/Io, direct processing, reverse release.
- [Producer and synchronous region](../examples/streams.zig): injected service,
  filtering, deferred reduction, terminal effect.
- [Replacement signal](../examples/signals.zig): injected initial/derived updates.
- [Transfer monitor](../examples/scan.zig): scan updates, held progress and
  independently sampled reports, with distinct injected writer roles.
  `zig build example-scan` runs it separately.
- [Checkout retries](../examples/checkout.zig): typed policies and application-owned
  duplicate safety, without a persistence framework. `zig build example-checkout`.
- [Success/error sinks](../examples/errors.zig): persistent stdout/stderr lanes
  with ordinary map failures. `zig build example-errors`.
- [Path-owned file copy](../examples/io_file.zig): `zig build io-examples`, then
  `zig-out/bin/copy-lines INPUT OUTPUT`. Output must not exist. No live waits
  occur in default checks.
- [Terminal cases](../examples/cases.zig): `zig build example-cases`; all cases
  terminate, so the branch is itself a terminal root.
- [HTTP echo server](../examples/http_echo.zig): `zig build http-example` builds
  the opt-in executable. Default checks run finite loopback tests, not a live server.

## Standalone applications

[App project and testing conventions](../examples/apps/README.md) define the
separate `examples/apps/` area. It currently has no implemented apps. Future apps
own their dependencies and finite simulations; the library build does not build
them or resolve their app-only dependencies.
