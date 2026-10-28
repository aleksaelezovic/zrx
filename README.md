# zrx

A functional reactive library for Zig, with declarative pipelines and comptime-checked composition.

Write readable transformations with standalone functions rather than method
chaining. zrx aims to make intent explicit and catch invalid compositions at
compile time wherever possible.

**Status:** Experimental synchronous `pipe` and `map`. Observables and
subscriptions are planned for later.

## Usage

Import `pipe` and `map` from the `zrx` module. Use `map(transform)` for a single
typed unary function or `map(.{ first, second })` for left-to-right composition.
Transformers must be comptime-known functions with one explicitly typed runtime
parameter and an explicit return type. Both forms support type transitions.
Operator and transformer tuples must be nonempty and flat; use named helper
functions to create reusable operators.

See the [executable pipeline example](examples/pipeline.zig). Calls are synchronous,
with no allocation by zrx or implicit error handling. Transformers may allocate
or have side effects themselves.

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
Cross checks compile objects; they do not execute foreign binaries.
Codegen checks compare selected stripped LLVM function bodies/aliases in
ReleaseFast, not whole binaries or arbitrary semantic equivalence.

The build exports a `zrx` module for use through Zig's package manager.

## License

Licensed under the [MIT License](LICENSE).
