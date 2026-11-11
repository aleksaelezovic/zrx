# zrx guide

- [Handlers and dependencies](#handlers-and-dependencies)
- [Pipes](#pipes)
- [Programs and systems](#programs-and-systems)
- [Sources](#sources)
- [Operators](#operators)
- [Handler combinators](#handler-combinators)
- [Errors](#errors)
- [Stopping early](#stopping-early)
- [Concurrency and backpressure](#concurrency-and-backpressure)
- [Input and output](#input-and-output)
- [Lifetimes](#lifetimes)
- [Writing your own](#writing-your-own)
- [How zero overhead is checked](#how-zero-overhead-is-checked)
- [Not here yet](#not-here-yet)

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

- the tuple passed to `run`: `app.run(.{ io, Scale{ .by = 2 } })`;
- operators earlier in the pipe: `provide(value)` and `resource(acquire, release)`.

Rules:

- The key is the type. Two values of the same type cannot both be passed to
  `run`; wrap one in a struct to name its role (`const Audit = struct { log: *Log };`).
- A dependency is copied into each handler that asks for it when the program
  starts. Share mutable state through a pointer type (`*Counter`).
- `std.Io` and `std.mem.Allocator` are ordinary dependencies. Operators that
  need `std.Io` (`queue`, `stdout`, ...) say so at compile time if it is missing.
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
    print(Stdout, "{d}\n"),
});
```

Nesting changes nothing: `pipe(.{ a, pipe(.{ b, c }), d })` is exactly
`pipe(.{ a, b, c, d })`, including for `provide`, whose value reaches everything
after it.

A pipe that ends with a terminal operator (`subscribe`, `drain`, `print`,
`branch`, a `route` whose cases all terminate) is *terminated*; nothing may
follow it.

## Programs and systems

```zig
const app = program(source, terminated_pipe);
try app.run(.{ io, logger });
```

`program` only describes. `run` checks the whole pipeline against the
dependencies it is given, then runs the source to completion. A program can be
run again; every run starts from fresh state.

```zig
try system(.{ ingest, report }).run(.{ io, &mailbox });
```

`system` runs its programs together with the same dependencies and returns when
all have finished. The first failure cancels the others and is returned. A
system is itself runnable, so systems nest.

Programs are started with `Io.concurrent`, each on a task of its own, so the
system stays free to notice a failure and cancel the rest. An `Io` that cannot
run anything concurrently runs them one after another instead, and does not
start one after an earlier one has failed. An `Io` that runs out of
concurrency part-way fails the system with `error.ConcurrencyUnavailable`
rather than run a program where it could block the others.

## Sources

| Source | Items |
|---|---|
| `fromSlice(items)` | Each element of a slice or array pointer. |
| `fromValue(value)` | One item. |
| `range(T, first, end)` | Integers in `[first, end)`. |
| `fromIterator(&iterator)` | `iterator.next()` until null; `next` may return `?T` or `E!?T`. |
| `fromProducer(T, producer)` | Whatever `producer(deps..., out)` pushes with `out.push(item)`. |
| `merge(.{ a, b })` | The items of several sources as they arrive; needs `std.Io` at `run`. Once the pipe is done, sources still waiting are cancelled. A push that fails ends the merge with that error at once, whatever its source goes on to do or return. Sources are started like the programs of a `system`. |
| `lines(Role)`, `stdinLines(n)`, `fileLines(path, n)` | Text lines; see [Input and output](#input-and-output). |

A producer stops when a push answers `.done`:

```zig
fn ticks(clock: Clock, out: anytype) !void {
    while (try out.push(clock.now()) == .more) {}
}
```

## Operators

Per item:

| Operator | Handler | Effect |
|---|---|---|
| `map(f)` | `fn (deps..., T) U` | Replaces each item. |
| `filter(p)` | `fn (deps..., T) bool` | Keeps items for which `p` is true. |
| `tap(f)` | `fn (deps..., T) void` | Runs `f`, passes the item on. |
| `scan(seed, f)` | `fn (deps..., A, T) A` | Emits the running state after every item. |
| `fold(seed, f)` | `fn (deps..., A, T) A` | Emits the final state once, at the end. |
| `take(n)` | | First `n` items, then stops the source. |
| `skip(n)` | | Drops the first `n` items. |
| `takeWhile(p)` | `fn (deps..., T) bool` | Items until `p` is first false, then stops the source. |
| `flatten()` | | Each element of array or slice items. |
| `batch(n)` | | Slices of `n` items (the last may be shorter), valid during the push. |
| `recover(h)` | `fn (deps..., E, T) void` | Handles errors of the operators after it. |

Dependencies:

| Operator | Effect |
|---|---|
| `provide(value)` | Adds `value`, keyed by its type, for everything after it. Shadows an earlier value of that type. |
| `resource(acquire, release)` | `acquire(deps...)` once at start, result provided downstream; `release(deps..., value)` once at the end, success or not. `release` may be `null`. |

Flow:

| Operator | Effect |
|---|---|
| `queue(n)` | Bounded buffer of `n` items between two tasks. Needs `std.Io`. |
| `branch(.{ pipe, pipe })` | Terminal. Every item goes to every sub-pipe. |
| `route(.{ when(p, pipe), otherwise(pipe) })` | Each item goes to the first case that takes it. |

Terminal:

| Operator | Effect |
|---|---|
| `subscribe(f)` | Runs `f(deps..., item)` for every item. |
| `drain()` | Discards every item. |
| `print(Role, "fmt")` | Formats every item to a writer. |

Every handler may also return an error union of the type shown.

### route

Either every case terminates, and so does the route, or every case emits the
same item type and the pipe continues after the route:

```zig
route(.{
    when(isRefund, pipe(.{map(negated)})),
    when(isLarge, pipe(.{map(withFee)})),
    otherwise(pipe(.{map(field(.cents))})),
}),
fold(0, add),
```

An item no case takes is dropped. Each case is a pipe with its own state and
its own `provide` scope.

## Handler combinators

Small handlers so that domain code does not have to restate them. They are
usable wherever a handler is, and forward the dependencies of the handlers
they are built from.

| Combinator | Meaning |
|---|---|
| `not(p)`, `all(.{ p, q })`, `any(.{ p, q })` | Predicate logic; `all` and `any` stop at the first decisive predicate. |
| `compose(.{ f, g })` | `g(f(item))`, left to right. |
| `orElse(f, fallback)` | `f(item)`, or `fallback(deps..., err, item)` when `f` fails. |
| `field(.name)` | The field `name` of a struct item. |
| `constant(value)` | `value`, whatever the item. |
| `eq(v)`, `ne(v)`, `lt(v)`, `le(v)`, `gt(v)`, `ge(v)` | Comparison with a comptime value. |

```zig
const isHot = compose(.{ field(.celsius), gt(80) });
const wanted = all(.{ isHot, not(isMuted) });
```

## Errors

A handler that returns an error fails the run: the error comes out of `run`,
after every resource has been released. `run`'s error set is inferred from your
handlers and the operators you used; it is never `anyerror`, and a program
whose handlers cannot fail has an empty one.

There are two ways to handle an error instead. To keep the item as a value of
your choosing, wrap the handler: `map(orElse(parse, rejected))` calls
`rejected(deps..., err, item)` when `parse` fails and passes its result on.

To drop the item, put `recover(handler)` before the operators that may
fail. When one of them fails for an item, the handler receives the error and
the item as it was at the `recover`. Returning normally skips the item;
returning an error fails the run.

```zig
fn reject(log: Log, err: ParseError, line: []const u8) void { ... }

pipe(.{
    recover(reject),
    map(parse),
    map(validate),
    subscribe(save),
})
```

- The handler's error parameter selects what it handles: an error set handles
  its members and lets everything else through; `anyerror` handles everything.
- `error.Canceled` is never given to a handler.
- A `recover` guards what comes *after* it, up to the next `queue`. Errors on
  the far side of a queue happen in another task and fail the run.
- It guards every item that passes through it, including the ones an earlier
  operator emits when the stream ends: a `fold` result, or the last, partial
  `batch`, is handled like any other item. Put `recover` before the `fold` if
  its result should not be guarded.
- A later stage's own end-of-stream work, such as flushing a writer, is not an
  item and fails the run.
- Nothing is rolled back: stages between the `recover` and the failure keep
  whatever state the item already gave them.

## Stopping early

A push returns `Flow`: `.more`, or `.done` when nothing downstream wants
another item. `take` and `takeWhile` answer `.done`; sources stop when they see
it; `branch` and `route` answer `.done` once every sub-pipe has. The stream then
finishes normally: `fold` emits, writers flush.

## Concurrency and backpressure

Without `queue`, a program is one loop on the caller's task. `queue(n)` is the
only task boundary: the stages before it push into a buffer of `n` items and
wait while it is full; a second task feeds the stages after it. That waiting is
the backpressure: a slow consumer slows the source instead of dropping items or
growing memory.

A program with a queue is a small group of supervised tasks: one per queue,
and one for the source and the stages before the first queue. The run returns
when all of them are done, and the first failure ends it:

- **A failure behind a queue is the result of the run.** It cancels the
  source at once, even one that is waiting for its next item and not pushing,
  and whatever the interrupted source then returns is ignored. If the source
  had already ended, it cancels the end of the stream instead: a wait for
  another queue to drain, or a final value's handler that is blocked.
- **Nothing finishes normally after a failure.** Once a worker has failed, no
  further stage emits its final value or flushes.
- **A pipe that is done stops its source** the same way (`take` after a
  `queue`). Inside `branch` and `route` that means every sub-pipe: one being
  done says nothing about its siblings, so the source is stopped when the
  last one is.
- **Every task is cancelled and joined before any resource is released**, so
  a handler never runs against a released resource.
- **Cancellation is cooperative**: it takes effect where a task calls into
  `std.Io`. A source or handler that computes without ever doing so cannot be
  interrupted.

`std.Io` is needed where a queue is, not at `run`: `provide(io)` before the
queue is enough.

With a queue, your handlers do not run on the task that called `run`: the
source and the stages before the first queue run on one task, each queue's
far side on another, and the end of the stream on a third. The caller only
waits, so that it can always cancel.

`branch` itself is a plain loop over its sub-pipes. A sub-pipe becomes
concurrent by starting with a queue:

```zig
branch(.{
    pipe(.{
        queue(64),
        map(slowWrite),
        drain(),
    }),
    pipe(.{
        queue(64),
        batch(10),
        subscribe(report),
    }),
})
```

- Each side of a queue runs on one task, so the stages of one side never run
  concurrently with each other. Handlers on *different* sides do; a dependency
  shared across a queue or between programs of a system must be safe for that.
- Items cross a queue by value. A slice item must stay valid until consumed;
  slices from `batch` and `lines` are not, so copy before queueing them.
- When the stream ends, the queue drains before anything after it finishes.
  When the far side fails or is done, the near side stops.
- A `route` case that rejoins the pipe cannot contain a queue (the pipe after
  the route would be pushed to from two tasks); put the queue after the route.

## Input and output

Readers and writers are dependencies. A *role* is the type one is keyed by:
`*std.Io.Writer` itself, or a struct with a single `writer: *std.Io.Writer`
field when a program has several (`reader: *std.Io.Reader` for input).

| | |
|---|---|
| `print(Role, "fmt")` | Terminal. Formats every item; a tuple item supplies several arguments. |
| `stdout(n)`, `stderr(n)` | Provide `zrx.Stdout` / `zrx.Stderr`, buffered by `n` bytes. |
| `createFile(Role, path, n, .{})` | Creates the file and provides a writer to it as `Role`; `.{ .exclusive = true }` refuses to replace an existing one. |
| `lines(Role)` | Source: lines of the reader keyed by `Role`. |
| `stdinLines(n)`, `fileLines(path, n)` | Sources: lines of standard input or a file; a line is at most `n` bytes, not counting its newline. |

Whoever owns a writer flushes it. The operators above flush the writers they
create when the stream ends (a failed flush fails the run) and once more, best
effort, at teardown. A writer you pass to `run` is yours to flush.

A line is valid until the next one is read.

## Lifetimes

A run goes through these steps:

1. every stage is initialized, in order (`resource` acquires here);
2. tasks are started (`queue`);
3. the source pushes items;
4. on a normal end, stages finish in order (`fold` and `batch` emit, queues
   drain), then owned writers flush, last stage first;
5. always: every task still running is cancelled and joined;
6. always: stages are torn down in reverse order (`resource` releases, files close).

A failure at any step skips to 5. No task is running by the time anything is
released, and a resource is released after everything downstream of it, so a
handler never sees a released value.

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

A stage may also declare `start`, `finish`, `flush`, `stop`, `deinit` and,
with `Provides`, `provide`. A stage that runs a task of its own takes part in
the run's supervision (`zrx.operator.Supervision`): it reports when its worker
fails and returns that error from `failure(self, down) !void`, so the errors a
run can end with are known to the compiler; [`src/pipe.zig`](../src/pipe.zig) states the contract and
[`src/ops`](../src/ops) has an example of each. To call a handler with
injection, use `zrx.di.Bound(name, handler, Env, &.{In})`.

**A source** declares `zrx_source`, `Item`, and
`run(self, env, down) !void`, which pushes until it has no more or a push
answers `.done`. See [`src/sources.zig`](../src/sources.zig).

**A composite handler** is a struct type with `zrx_handler`,
`requires(arity) []const type` and `call(env, args)`. See
[`src/handlers.zig`](../src/handlers.zig).

## How zero overhead is checked

[`tests/zero_overhead/cases.zig`](../tests/zero_overhead/cases.zig) writes each
case twice: as a zrx program and as a hand-written loop. `zig build
zero-overhead` compiles the file once per variant, in ReleaseFast for
`aarch64-linux` and `x86_64-linux`, and
[`tools/same_code.zig`](../tools/same_code.zig) compares the optimized LLVM IR
of every exported function:

- `same_*` functions must be the same multiset of instructions once value and
  block names are erased (the order of a phi's inputs and which way round a
  comparison is written are also ignored);
- `lean_*` functions may differ in loop shape, but the zrx variant must contain
  no calls, no stack slots, no more loads or stores than the hand-written one,
  and at most a quarter more instructions;
- a function that exists in only one variant fails, which is how a stage that
  was not inlined shows up.

[`behavior.zig`](../tests/zero_overhead/behavior.zig) runs both variants of each
case and requires equal results. The targets are fixed so the outcome does not
depend on the machine running the build.

Every synchronous operator has a fixture. Twelve are `same`; `take`, `batch`
and the handler combinators are `lean`, each with the reason next to it.

What this does and does not show: pipelines of the operators covered there
compile to the code of the loop. It is evidence for those shapes with this
compiler, not a proof for every pipeline. `queue` is deliberately outside it.

Two things make it work, and are worth knowing when writing an operator:

- Each stage of a program is its own local variable, so the optimizer keeps
  each in registers independently. Stages inside a `branch` or `route`
  sub-pipe are stored together with it.
- A stage that indexes into an array it owns stays in memory as a whole. Keep
  such a buffer in a stage of its own, away from counters and accumulators:
  `batch` is a counter stage followed by a buffer stage for this reason.

## Not here yet

Present in the previous implementation and not ported: HTTP serving, signals
(`hold`, `withLatestFrom`), `retryPipe`, `takeLast`, `maxItems`, and two of
the three standalone example applications. The
[record processor](../examples/apps/record-processor/README.md) is ported, and
its README lists what the port needed that the library does not have yet.
