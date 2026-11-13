# zrx

Declarative push streams for Zig with type-keyed dependency injection, compiled
down to the loop you would have written by hand.

**Experimental, and deliberately minimal.** This is the core only: one
synchronous loop, a handful of operators, nothing that owns a resource or
starts a task. More returns one piece at a time, once this has been reviewed.

```zig
const std = @import("std");
const zrx = @import("zrx");
const pipe = zrx.pipe;
const program = zrx.program;
const fromSlice = zrx.fromSlice;
const map = zrx.map;
const filter = zrx.filter;
const fold = zrx.fold;
const subscribe = zrx.subscribe;

const Scale = struct { by: u32 };
const Out = struct { writer: *std.Io.Writer };

fn scale(factor: Scale, value: u32) u32 { // `factor` is injected by its type
    return value * factor.by;
}
fn isLarge(value: u32) bool {
    return value >= 6;
}
fn add(sum: u64, value: u32) u64 {
    return sum + value;
}
fn report(out: Out, total: u64) !void {
    try out.writer.print("total: {d}\n", .{total});
}

pub fn main(init: std.process.Init) !void {
    var buffer: [64]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &buffer);

    const values = [_]u32{ 1, 2, 3, 4 };
    const total = pipe(.{
        map(scale),
        filter(isLarge),
        fold(0, add),
        subscribe(report),
    });
    try program(fromSlice(&values), total).run(.{ Scale{ .by = 2 }, Out{ .writer = &stdout.interface } });
    try stdout.interface.flush();
}
```

## The model

| Concept | What it is |
|---|---|
| **handler** | A plain function. Its leading parameters are dependencies, found by type; its last parameter is the data. |
| **operator** | A stage built from a handler or a setting: `map(f)`, `filter(p)`, `take(3)`, `provide(db)`. |
| **pipe** | Operators composed left to right. A pipe is itself an operator, so pipes nest. |
| **program** | One source feeding one pipe that ends in a terminal operator. Nothing runs until `run(.{ deps })`. |

There is one way to write each thing, and mistakes are compile errors that say
what to do: a missing dependency, a handler whose parameter does not match the
stream, an operator after a terminal one, a pipe that never ends.

The **[guide](docs/guide.md)** has every operator and how to write your own.
The two [examples](examples) are run and checked by the build.

## Zero overhead, checked

Everything is resolved at compile time: every stage is a local variable of
the run, dependencies are copied into the handlers that asked for them once,
and a push is a chain of direct calls the optimizer flattens. `zig build
zero-overhead` compiles each fixture in
[`tests/zero_overhead`](tests/zero_overhead/cases.zig) twice, as a pipeline and
as a hand-written loop, and compares the optimized LLVM IR function by
function. Every operator is in a fixture. Seven of the eight fixtures consist
of the same instructions (the same multiset, once value and block names are
erased); the eighth (`take`) differs only in loop shape and is required to be
free of calls and extra memory traffic. A separate test runs both variants of
every fixture and requires equal results.

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
