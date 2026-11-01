# zrx

A declarative functional/reactive library for Zig. Describe inputs,
transformations, decisions and terminal effects as named standalone stages;
execute them together with `run(bindings, flows)`.

**Experimental:** one declaration-only public model,
type-keyed dependency injection, managed resources, finite inputs, producer-backed
streams, streaming accumulation, replacement/derived signals, bounded line I/O
and serial HTTP servers.
Ordinary synchronous stages compose directly rather than acquiring a worker/queue
per stage.

The package module is `zrx`. Callbacks declare dependencies as typed leading
parameters; ordinary data arguments come last. Supply allocator, Io, service
values or lifecycle recipes at `run`. Only selected terminal roots execute.
Errors and ownership stay explicit; no universal zero-overhead claim is made.

Start with the tested [resource](examples/resources.zig),
[stream](examples/streams.zig), [signal](examples/signals.zig), and
[accumulation](examples/scan.zig) examples:

```sh
zig build example
```

See the **[documentation index](docs/README.md)** for contracts, lifecycle,
and the opt-in [file program](examples/io_file.zig).

## Toolchain and checks

Use exactly Zig **0.17.0**, recorded in [`.zigversion`](.zigversion).

```sh
zig version
zig fmt --check build.zig build.zig.zon src tests examples benchmarks
zig build test
zig build test -Doptimize=ReleaseFast
zig build check
```

`zig build declarative-test` focuses on the current public API. `check` includes
native tests, formatting, and catalog cross builds.
Cross compilation is not foreign execution or performance proof.

`zig build benchmark` is an opt-in direct/pipeline workload comparison with
correctness checks, never a default timing threshold. See
[measurement scope and next investigations](docs/performance.md).

## License

Licensed under the [MIT License](LICENSE).
