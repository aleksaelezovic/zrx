# zrx

Declarative push streams for Zig with type-keyed dependency injection, compiled
down to the loop you would have written by hand.

**Experimental.** This is a ground-up rewrite; the API is small on purpose and
may still change.

```zig
const std = @import("std");
const zrx = @import("zrx");
const pipe = zrx.pipe;
const program = zrx.program;
const fromSlice = zrx.fromSlice;
const map = zrx.map;
const filter = zrx.filter;
const fold = zrx.fold;
const stdout = zrx.stdout;
const print = zrx.print;

const Scale = struct { by: u32 };

fn scale(factor: Scale, value: u32) u32 { // `factor` is injected by its type
    return value * factor.by;
}
fn isLarge(value: u32) bool {
    return value >= 6;
}
fn add(sum: u64, value: u32) u64 {
    return sum + value;
}

pub fn main(init: std.process.Init) !void {
    const values = [_]u32{ 1, 2, 3, 4 };
    const total = pipe(.{
        map(scale),
        filter(isLarge),
        fold(0, add),
        stdout(64),
        print(zrx.Stdout, "total: {d}\n"),
    });
    try program(fromSlice(&values), total).run(.{ init.io, Scale{ .by = 2 } });
}
```

## The model

| Concept | What it is |
|---|---|
| **handler** | A plain function. Its leading parameters are dependencies, found by type; its last parameter is the data. |
| **operator** | A stage built from a handler or a setting: `map(f)`, `filter(p)`, `take(3)`, `queue(16)`, `provide(db)`. |
| **pipe** | Operators composed left to right. A pipe is itself an operator, so pipes nest. |
| **program** | One source feeding one pipe that ends in a terminal operator. Nothing runs until `run(.{ deps })`. |
| **system** | Several programs run together with the same dependencies. |

There is one way to write each thing, and mistakes are compile errors that say
what to do: a missing dependency, a handler whose parameter does not match the
stream, an operator after a terminal one, a pipe that never ends.

Read the **[guide](docs/guide.md)** for every operator, the error and
concurrency model, and how to write operators of your own. The
[examples](examples) are small and each is run and checked by the build;
[examples/apps](examples/apps/README.md) holds a complete application.

## Zero overhead, checked

Everything is resolved at compile time: every stage is a local variable of
the run, dependencies are copied into the handlers that asked for them once,
and a push is a chain of direct calls the optimizer flattens. `zig build
zero-overhead` compiles each fixture in
[`tests/zero_overhead`](tests/zero_overhead/cases.zig) twice, as a pipeline and
as a hand-written loop, and compares the optimized LLVM IR function by
function. The fixtures cover every synchronous operator. Eleven of the
fourteen are the same instructions; the other three differ only in loop shape
and are required to be free of calls and extra memory traffic.

`queue` is the one operator that costs something by design: it is a real
bounded buffer between two tasks.

## Use

Requires exactly Zig **0.17.0** (see [`.zigversion`](.zigversion)).

```sh
zig build test            # suites, compile-error contracts, examples, zero-overhead
zig build check           # the above plus formatting and cross compilation
zig build example         # run the examples
zig build zero-overhead   # print the code comparison
zig build benchmark       # throughput against a hand-written loop
```

## License

[MIT](LICENSE)
