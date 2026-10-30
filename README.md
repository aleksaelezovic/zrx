# zrx

A functional reactive library for Zig, with declarative pipelines and comptime-checked composition.

Write readable transformations with standalone functions rather than method
chaining. zrx aims to make intent explicit and catch invalid compositions at
compile time wherever possible.

**Status:** Experimental value pipelines, borrowed lazy sequences, conventional
input adapters, and declarative event streams. Declare stream-backed effect
pipes without allocator/Io, then activate them together with `run`. Reused pipe
references share results automatically. Declarative merge and run-owned
replacement/derived signal state are supported.

## Usage

Import `pipe` and `map` from the `zrx` module. Use `map(transform)` for a single
typed unary function or `map(.{ first, second })` for left-to-right composition.
Transformers must be comptime-known functions with one explicitly typed runtime
parameter and an explicit return type. Both forms support type transitions.
Operator and transformer tuples must be nonempty and flat; use named helper
functions to create reusable operators.

`keepIf(predicate)` keeps one value as an optional. `filter(predicate)` and
`each(transform)` create borrowed lazy sequence views. Terminal `forEach`
effects process items individually; `collectThen` effects borrow the whole
collection after successful completion. `batchThen(n, effect)` processes
successive bounded groups while input is open. All are declarations activated by
`run`, for finite inputs and streams alike. `With` variants carry explicit
capabilities. Optional `maxItems(n)` fails on excess output rather than truncating.
`takeLast(n)` intentionally retains only the final N items, publishing them after
successful completion using a run-owned ring buffer.
See [terminal effects and collection](docs/terminals.md). Views/flows themselves
do not allocate.

See the [value example](examples/pipeline.zig), [sequence example](examples/sequences.zig),
and [ownership and operator contracts](docs/sequences.md). Operators can receive
runtime capabilities directly; errors remain explicit values.
Use `tryPipe` to opt into [fail-fast composition](docs/try_pipe.md); see its
[executable example](examples/try_pipe.zig).
Use `tap(effect)` or `tapWith(capability, effect)` for [synchronous effects](docs/effects.md);
see the [effects example](examples/effects.zig).
Use `fold(initialState, reducer)` or internally fail-fast `tryFold(initialState, reducer)`
for [finite reduction](docs/reduction.md); see the [reduction example](examples/reduction.zig).

Use `Stream(T).fromProducer(capacity, producer)` to describe an event source,
or `fromProducerWith(capacity, producer, &configuration)` to borrow explicit
producer capabilities. Producers receive `*Emitter(T)` with `push(value)` and
the execution-time allocator/Io. Producer return closes output automatically.
Declarations own no live resources and need no `deinit()`.

Pipe `&stream` through `each`/`filter` to terminal per-item, collection, or batch
effects. `run(allocator, io, .{ flowA, flowB })` creates and cleans up the live
graph. Use a pointer to the same source/derived declaration to share its results.
Use `merge(.{ &first, &second })` for same-item-type fan-in, with no allocator/Io
at declaration. Convert different domain inputs explicitly with `each`.
See [stream contracts](docs/streams.md), [effect-flow lifecycle](docs/pipes.md),
the [merge contract](docs/merging.md), and the [two-flow example](examples/pipes.zig).

Use `hold(initial)` to remember replacement state and `map` to declare a derived
signal. `values(&signal)` observes snapshots; `withLatestFrom(&signal)` pairs
events with current snapshots in ordinary tuples. Both use the same `run`
boundary. See [signal contracts](docs/signals.md) and the
[signal example](examples/signals.zig).

Use `fromIterator(&iterator)` for conventional iterators and `readFrom(io, &queue)`
for standard `std.Io.Queue(T)` inputs. These borrow consuming inputs;
terminal traversal of either adapter is deferred to `run`. Pure value
composition remains ordinary function evaluation. Stream declarations cannot
be iterated directly; `collectThen` provides scoped whole-input consumption.

## Toolchain and checks

Target Zig **0.17.0**, recorded in [`.zigversion`](.zigversion).
With that compiler on your `PATH`, run:

```sh
zig version                  # must report 0.17.0
zig fmt --check build.zig build.zig.zon src tests examples
zig build test               # unit tests, compile-fail checks, and all examples
zig build example            # run all executable examples separately
zig build example-streams    # declare and execute one bounded event flow
zig build example-branching  # run independent pipelines over one bounded source
zig build example-pipes      # share one transformation between two effect flows
zig build example-retention  # retain the final 100 of 1000 logs
zig build example-merge      # combine sources into one decision/effect flow
zig build example-batching   # send 1000 logs in batches of 100
zig build example-signals    # observe replacement and derived signal values
zig build check              # formatting, native tests, cross builds, codegen
```

For focused checks, use `zig build fmt`, `zig build cross`, or `zig build codegen`.
The [target matrix](tests/codegen/catalog.zig) covers Linux x86-64/ARM64,
macOS ARM64, Windows x86-64/ARM64, and freestanding WebAssembly.
Cross checks compile value and sequence/collection fixtures, not foreign binaries
for execution. Codegen checks compare selected LLVM bodies/aliases and scoped
AArch64 loop assembly in ReleaseFast, not all operators or whole binaries.
See the catalog for exact coverage; matches are not general equivalence proofs.
Strict comparisons exercise synchronous value/slice fixtures, not `run`.
Graph execution/retention has native lifecycle tests and cross-build coverage;
those checks are not graph-performance benchmarks.

The build exports a `zrx` module for use through Zig's package manager.

## License

Licensed under the [MIT License](LICENSE).
