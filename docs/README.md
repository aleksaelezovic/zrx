# zrx documentation

zrx separates ordinary value composition from run-owned event graphs. Function
contracts live beside their implementations; examples are complete, executable,
and checked by `zig build test`. This index links both instead of duplicating
their code in partial snippets.

## Guides

1. [Execution, sharing, and ownership](execution.md)
2. [Signal coherence and lifecycle](state.md)
3. [Toolchain, testing, and codegen scope](validation.md)
4. [Future terminal, TCP, and filesystem adapters](../src/io/README.md) — not implemented

## API reference

Use the `zrx` package module, whose [root](../src/root.zig) exports this API.
Source paths below are documentation/navigation, not new package imports.

| Area | Contracts |
|---|---|
| Value executors | [`pipe`](../src/pipe.zig), [`tryPipe`](../src/tryPipe.zig) |
| Whole values | [`map`](../src/ops/map.zig), [`keepIf`](../src/ops/keepIf.zig) |
| Sequence transforms | [`filter`](../src/ops/filter.zig), [`each`](../src/ops/each.zig) |
| Eager finite reduction | [`fold`](../src/ops/fold.zig), [`tryFold`](../src/ops/tryFold.zig) |
| Synchronous whole-value effects | [`tap`](../src/ops/tap.zig), [`tapWith`](../src/ops/tapWith.zig) |
| Input declarations/adapters | [`Stream` / `Emitter`](../src/data/streams.zig), [`fromIterator`](../src/data/iterators.zig), [`readFrom`](../src/io/readFrom.zig) |
| Count guard / suffix retention | [`maxItems`](../src/ops/maxItems.zig), [`takeLast`](../src/ops/takeLast.zig) |
| Fan-in | [`merge`](../src/ops/merge.zig) |
| State | [`hold`](../src/ops/hold.zig), [`values`](../src/ops/values.zig), [`withLatestFrom`](../src/ops/withLatestFrom.zig), signal [`map`](../src/ops/map.zig) |
| Per-item terminals | [`forEach`](../src/ops/forEach.zig), [`forEachWith`](../src/ops/forEachWith.zig) |
| Collection terminals | [`collectThen`](../src/ops/collectThen.zig), [`collectThenWith`](../src/ops/collectThenWith.zig) |
| Batch terminals | [`batchThen`](../src/ops/batchThen.zig), [`batchThenWith`](../src/ops/batchThenWith.zig) |
| Graph executor | [`run`](../src/run.zig) |

Callbacks are comptime-known, explicitly typed functions. Empty/nested operator
and transformer tuples are rejected; express reusable groups as named helpers.
Normal Zig coercions apply. See each declaration for its accepted inputs,
output types, ordering, and ownership.

## Executable examples

`zig build example` runs all examples, also included in `zig build test`.

| Example | What it demonstrates | Focused command |
|---|---|---|
| [Values](../examples/pipeline.zig) | Grouped whole-value transforms | `zig build example` |
| [Fail-fast flow](../examples/try_pipe.zig) | Errors as data vs stage short-circuiting | `zig build example` |
| [Sequences](../examples/sequences.zig) | Lazy selection, collection, explicit retained copies | `zig build example` |
| [Effects](../examples/effects.zig) | Standard fixed writer and explicit capabilities | `zig build example` |
| [Reduction](../examples/reduction.zig) | Seeded accumulation and per-item reducer failure | `zig build example` |
| [Streams](../examples/streams.zig) | Producer → transformation → effect | `zig build example-streams` |
| [Branching](../examples/branching.zig) | Independent flows over one bounded source | `zig build example-branching` |
| [Shared pipe](../examples/pipes.zig) | Two effects share three, not six, transform evaluations | `zig build example-pipes` |
| [Retention](../examples/retention.zig) | Final logs 901–1000 from 1000 inputs | `zig build example-retention` |
| [Merge](../examples/merge.zig) | Explicit event union, decisions, service effects | `zig build example-merge` |
| [Batching](../examples/batching.zig) | 1000 logs in ten batches of 100 | `zig build example-batching` |
| [Signals](../examples/signals.zig) | Initial/replacement temperature and derived comfort | `zig build example-signals` |

## Source layout

- `src/root.zig`: stable public exports, not implementations.
- `src/pipe.zig`, `src/tryPipe.zig`, `src/run.zig`: execution boundaries.
- `src/data/`: stream/signal declarations, borrowed sequence/cursor machinery.
- `src/ops/`: named operators; related forms share specialization rather than
  duplicating behavior.
- `src/io/`: standard I/O interoperability and the future-adapter scope note.
- `src/internal/`: shared validation, terminal consumption, and test-only helpers.
- `src/internal/runtime/`: live transport, broadcast readers, and signal
  synchronization. Everything here is private execution machinery, not an
  additional public ownership API.
