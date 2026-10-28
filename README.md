# zrx

A functional reactive library for Zig, with declarative pipelines and comptime-checked composition.

Write readable transformations with standalone functions rather than method
chaining. zrx aims to make intent explicit and catch invalid compositions at
compile time wherever possible.

**Status:** Experimental synchronous value pipelines and borrowed lazy sequences.
Observables and subscriptions are planned for later.

## Usage

Import `pipe` and `map` from the `zrx` module. Use `map(transform)` for a single
typed unary function or `map(.{ first, second })` for left-to-right composition.
Transformers must be comptime-known functions with one explicitly typed runtime
parameter and an explicit return type. Both forms support type transitions.
Operator and transformer tuples must be nonempty and flat; use named helper
functions to create reusable operators.

`keepIf(predicate)` keeps one value as an optional. `filter(predicate)` and
`each(transform)` create borrowed lazy sequence views. Materialize explicitly
with `collectInto(buffer)` or `collectAlloc(allocator)`; free allocated results
with the same allocator. Views themselves do not allocate.

See the [value example](examples/pipeline.zig), [sequence example](examples/sequences.zig),
and [ownership and operator contracts](docs/sequences.md). Operators can receive
runtime capabilities directly; errors remain explicit values.
Use `tryPipe` to opt into [fail-fast composition](docs/try_pipe.md); see its
[executable example](examples/try_pipe.zig).

## Toolchain and checks

Target Zig **0.17.0**, recorded in [`.zigversion`](.zigversion).
With that compiler on your `PATH`, run:

```sh
zig version                  # must report 0.17.0
zig fmt --check build.zig build.zig.zon src tests examples
zig build test               # unit tests, compile-fail checks, and the example
zig build example            # run the example separately
zig build check              # formatting, native tests, cross builds, codegen
```

For focused checks, use `zig build fmt`, `zig build cross`, or `zig build codegen`.
The [target matrix](tests/codegen/catalog.zig) covers Linux x86-64/ARM64,
macOS ARM64, Windows x86-64/ARM64, and freestanding WebAssembly.
Cross checks compile value and sequence/collection fixtures, not foreign binaries
for execution. Codegen checks compare selected LLVM bodies/aliases and scoped
AArch64 loop assembly in ReleaseFast, not all operators or whole binaries.
See the catalog for exact coverage; matches are not general equivalence proofs.

The build exports a `zrx` module for use through Zig's package manager.

## License

Licensed under the [MIT License](LICENSE).
