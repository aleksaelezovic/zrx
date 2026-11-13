# zrx guide

- [Handlers and dependencies](#handlers-and-dependencies)
- [Pipes](#pipes)
- [Programs](#programs)
- [Sources](#sources)
- [Operators](#operators)
- [Errors](#errors)
- [Stopping early](#stopping-early)
- [What a run does](#what-a-run-does)
- [Writing your own](#writing-your-own)
- [How zero overhead is checked](#how-zero-overhead-is-checked)
- [Not here](#not-here)

## Handlers and dependencies

A handler is a comptime-known function. The operator it is given to decides
its trailing *data* parameters (one item for `map`; state and item for `fold`).
Every parameter before those is a *dependency*, looked up by its exact type.

```zig
const Scale = struct { by: u32 };

fn scale(factor: Scale, value: u32) u32 { ... }
//       ^ dependency   ^ data
```

Dependencies come from two places:

- the tuple passed to `run`: `app.run(.{ Scale{ .by = 2 }, &log })`;
- `provide(value)` earlier in the pipe.

Rules:

- The key is the type. Two values of the same type cannot both be passed to
  `run`; wrap one in a struct to name its role (`const Audit = struct { log: *Log };`).
- A dependency is copied into each handler that asks for it when the program
  starts. Share mutable state through a pointer type (`*Counter`).
- A data parameter may be `anytype`; dependency parameters must be typed.
- A handler may return `E!T`. See [Errors](#errors).

## Pipes

`pipe(.{ a, b, c })` composes operators left to right. A pipe is a value: name
it, reuse it, put it inside another pipe.

```zig
const parse = pipe(.{
    map(trim),
    filter(isNotEmpty),
    map(toNumber),
});
const total = pipe(.{
    parse,
    fold(0, add),
    subscribe(report),
});
```

Nesting changes nothing: `pipe(.{ a, pipe(.{ b, c }), d })` is exactly
`pipe(.{ a, b, c, d })`, including for `provide`, whose value reaches everything
after it.

A pipe that ends with a terminal operator (`subscribe`, `drain`) is
*terminated*; nothing may follow it.

## Programs

`program(source, pipe)` binds one source to one terminated pipe. It is a value;
nothing happens until `run`, and every run starts from fresh state.

```zig
const app = program(fromSlice(&values), total);
try app.run(.{ Scale{ .by = 2 } });
```

A program is one loop on the task that calls `run`. It starts no task and owns
no resource: a writer, a file or an allocator is yours, passed in as a
dependency, and yours to flush or free after `run` returns.

## Sources

| | |
|---|---|
| `fromSlice(items)` | Every element of a slice or array. The storage must outlive the run. |
| `fromValue(value)` | One item. |
| `range(T, first, end)` | Integers in `[first, end)`. |
| `fromIterator(&iterator)` | `iterator.next()` until null; `next` may return `?T` or `E!?T`. |
| `fromProducer(T, producer)` | Whatever `producer(deps..., out)` pushes with `out.push(item)`. |

## Operators

| | | |
|---|---|---|
| `map(f)` | per item | Replaces each item with `f(item)`. |
| `filter(p)` | per item | Keeps the items for which `p(item)` is true. |
| `tap(f)` | per item | Calls `f(item)` and passes the item on unchanged. |
| `scan(seed, f)` | state | Emits every state `f(state, item)`. |
| `fold(seed, f)` | state | Emits the final state once, when the stream ends. |
| `take(n)` | flow | The first `n` items, then stops the source. |
| `skip(n)` | flow | Everything after the first `n` items. |
| `takeWhile(p)` | flow | Items until `p` is false, then stops the source. |
| `flatten()` | per item | The elements of each array or slice item. |
| `provide(value)` | dependencies | Makes `value` available, by its type, to everything after it. |
| `subscribe(f)` | terminal | Calls `f(item)` for each item. |
| `drain()` | terminal | Ends a pipe without doing anything. |

The seed of `scan` and `fold` takes the reducer's state type, so `fold(0, add)`
works with an `add` that returns `u64`.

## Errors

A handler that returns an error fails the run: the error comes out of `run`.
`run`'s error set is inferred from your handlers; a program whose handlers
cannot fail has an empty one. Nothing handles an error inside a pipe: handle it
in the handler, or let it fail the run.

## Stopping early

A push returns `Flow`: `.more`, or `.done` when nothing downstream wants
another item. `take` and `takeWhile` answer `.done`, and sources stop when they
see it. The stream then finishes normally: `fold` emits.

`.done` is a hint that sticks: a stage that answered it keeps answering it. A
value emitted at the end of the stream (`fold`) is still pushed and is refused
by the stage that is done.

## What a run does

1. Every stage is initialized, in order.
2. The source pushes items until it has no more or is answered `.done`.
3. On a normal end, stages finish in order (`fold` emits).

An error at any step ends the run there. There is no teardown step: no stage
owns anything.

## Writing your own

Most code needs only handlers. When you need more, the same contracts the
library uses are public.

**An operator** is a value whose type declares `zrx_operator`, a `name`,
`Out(Env, In)` and `Stage(Env, In)`. This one counts items into an injected
`*usize` and passes them on:

```zig
pub fn counted() Counted {
    return .{};
}

const Counted = struct {
    pub const zrx_operator = {};
    pub const name = "counted";

    pub fn Out(comptime Env: type, comptime In: type) type {
        if (!zrx.di.has(Env, *usize)) @compileError("counted: needs a `*usize` dependency");
        return In; // or zrx.End for a terminal operator
    }

    pub fn Stage(comptime Env: type, comptime In: type) type {
        return struct {
            count: *usize,

            pub fn init(self: *@This(), _: *const Counted, env: Env) !void {
                self.count = zrx.di.get(env, *usize);
            }

            pub fn push(self: *@This(), item: In, down: anytype) !zrx.Flow {
                self.count.* += 1;
                return down.push(item);
            }
        };
    }
};
```

A stage may also declare `finish` and, with `Provides`, `provide`;
[`src/pipe.zig`](../src/pipe.zig) states the contract. To call a handler with
injection, use `zrx.di.Bound(name, handler, Env, &.{In})`.

**A source** declares `zrx_source`, `Item`, and
`run(self, env, down) !void`, which pushes until it has no more or a push
answers `.done`. See [`src/sources.zig`](../src/sources.zig).

## How zero overhead is checked

[`tests/zero_overhead/cases.zig`](../tests/zero_overhead/cases.zig) writes each
case twice: as a zrx program and as a hand-written loop. `zig build
zero-overhead` compiles the file once per variant, in ReleaseFast for
`aarch64-linux` and `x86_64-linux`, and
[`tools/same_code.zig`](../tools/same_code.zig) compares the optimized LLVM IR
of every exported function:

- `same_*` functions must be the same multiset of instructions once value and
  block names are erased. The order of a phi's inputs is ignored, and `x > c`
  matches the identical `x >= c + 1`; a comparison does not match its negation;
- `lean_*` functions may differ in loop shape, but the zrx variant must contain
  no calls, no stack slots, no more loads or stores than the hand-written one,
  and at most a quarter more instructions;
- a function that exists in only one variant fails, which is how a stage that
  was not inlined shows up.

[`behavior.zig`](../tests/zero_overhead/behavior.zig) runs both variants of each
case and requires equal results. The targets are fixed so the outcome does not
depend on the machine running the build.

Every operator is in a fixture. Seven are `same`; `take` is `lean`, with the
reason next to it.

What this does and does not show: pipelines of the operators covered there
compile to the code of the loop. The comparison is of instruction shape: it
cannot hide an extra call, load, store, branch or comparison, but it does not
check how the instructions are wired together, which is why the behaviour test
exists alongside it. It is evidence for those shapes with this compiler, not
a proof for every pipeline.

It works because each stage of a program is its own local variable, so the
optimizer keeps each in registers independently.

## Not here

The library was cut back to this core so that it can be reviewed as a whole.
These existed before and are in the history; each returns only by an explicit
decision, one at a time:

- sub-pipes: `branch`, `route`;
- `batch`, `recover`, `resource`;
- handler combinators (`all`, `any`, `compose`, `orElse`, `field`, `eq`, ...);
- input and output: `print`, `stdout`, `stderr`, `createFile`, `lines`,
  `stdinLines`, `fileLines`;
- tasks: `queue`, `merge`, `system`;
- the record-processor example application.
