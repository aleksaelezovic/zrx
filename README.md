# zrx

A functional reactive library for Zig: readable, standalone pipelines with
comptime-checked composition.

**Experimental:** value pipelines, lazy borrowed sequences, finite reduction,
explicit effects, declarative event streams, and replacement/derived signals.
High-level line I/O connects terminal, file, and TCP inputs to declared effects.

The build exports a `zrx` package module. Alias its functions at the top of your
file and compose them without method chaining. From the tested
[value example](examples/pipeline.zig):

```zig
const zrx = @import("zrx");
const pipe = zrx.pipe;
const map = zrx.map;

const result: u32 = pipe(3, .{
    map(.{ double, increment }),
});
```

Value operations evaluate normally; stream graphs and terminal effects are
resource-free declarations activated by `run(allocator, io, flows)`.
Errors and ownership stay explicit.

See the **[documentation index](docs/README.md)** for API contracts, lifecycle
guides, executable examples, and the source layout.

## Toolchain and checks

Target Zig **0.17.0**, recorded in [`.zigversion`](.zigversion).
With that compiler on your `PATH`, run:

```sh
zig version                  # must report 0.17.0
zig fmt --check build.zig build.zig.zon src tests examples
zig build test               # unit tests, compile-fail checks, and example coverage
zig build test -Doptimize=ReleaseFast
zig build check              # formatting, native tests, cross builds, codegen
```

See [validation scope and focused commands](docs/validation.md). Cross builds
compile objects; they do not execute foreign targets or prove performance.
Build the opt-in [terminal/file/TCP programs](src/io/README.md) with
`zig build io-examples`.

## License

Licensed under the [MIT License](LICENSE).
