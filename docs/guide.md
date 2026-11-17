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
- the tuple on `program(...).provide(.{ ... })`, available to the source and every stage.

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
`pipe(.{ a, b, c, d })`.

A pipe that ends with a terminal operator (`subscribe`, `drain`, `print`,
`branch`, a `route` whose cases all terminate) is *terminated*; nothing may
follow it.

## Programs and systems

```zig
const app = program(source, terminated_pipe);
try app.run(.{ io, logger });
```

`program` describes the work. `run` constructs fresh stage state each time
and uses the source and dependencies supplied by the caller.

```zig
const report = program(source, pipe(.{
    queue(32),
    fold(0, add),
    print(Report, "{d}\n"),
})).provide(.{
    fileWriter(Report, path, 4096, .{ .mode = .create_new }),
});

try report.run(.{io});
```

`provide` adds bindings to the program description. Each run applies them
left to right, starting with the values passed to `run`. A binding shadows
an earlier binding of the same type. The final environment is shared by the
source and all stages, including branch and route cases.

`resource(acquire, release)` is a binding that calls `acquire(deps...)` once
per run. Later bindings can use its result as a dependency. On exit, acquired
resources are released in reverse order after the program's tasks have
joined. `release(deps..., value)` uses the dependencies in scope at acquisition
and returns `void`. Use `null` for a computed binding that needs no release.

```zig
try system(.{ ingest, report }).run(.{ io, &mailbox });
```

`system` runs its programs together with the same dependencies and returns when
all have finished. The first failure cancels the others and is returned; a
program that had ended before that has released its resources. A system is itself runnable,
so systems nest. With more than one program, each runs as a task of its own,
so the `Io` must be able to run tasks concurrently; with one that cannot,
`run` returns `error.ConcurrencyUnavailable`.

## Sources

| Source | Items |
|---|---|
| `fromSlice(items)` | Each element of a slice or array pointer. |
| `fromValue(value)` | One item. |
| `range(T, first, end)` | Integers in `[first, end)`. |
| `fromIterator(&iterator)` | `iterator.next()` until null; `next` may return `?T` or `E!?T`. |
| `fromProducer(T, producer)` | Whatever `producer(deps..., out)` pushes with `out.push(item)`. |
| `merge(.{ a, b })` | The items of several sources as they arrive. With more than one, each source runs as a task (needs `std.Io` with concurrency) and they take turns pushing. Once a push is answered `.done`, the other sources are cancelled where they wait. |
| `lines(Role, n)`, `stdinLines(n)`, `fileLines(path, n)` | Text lines; see [Input and output](#input-and-output). |

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
| `flatten()` | | Each element of array, slice, or batch items. |
| `batch(n)` | | Inline `Batch(T, n)` values (the last may contain fewer items). |
| `recover(h)` | `fn (deps..., E, T) void` | Handles errors of the operators after it. |

Flow:

| Operator | Effect |
|---|---|
| `queue(n)`, `queue(&slots)` | Bounded buffer between two tasks. Pass a comptime capacity or a mutable array pointer. Needs `std.Io`. |
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

An item no case takes is dropped. Each case has its own stage state.

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
handlers and the operators you used: it is `anyerror` only if a handler's is,
and a program whose handlers cannot fail has an empty one.

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
- `error.Canceled` is never given to a handler. A write that was interrupted
  because the run is being cancelled is: `std.Io.Writer` reports it as
  `error.WriteFailed` like any failed write.
- A `recover` guards what comes *after* it, up to the next `queue`. Errors on
  the far side of a queue happen in another task and fail the run.
- A value that a stage *before* the `recover` emits at the end of the stream
  (a final `fold` value) is an item like any other. Errors of a later
  stage's own end of stream do not belong to an item and
  fail the run.
- Nothing is rolled back: stages between the `recover` and the failure keep
  whatever state the item already gave them.

## Stopping early

A push returns `Flow`: `.more`, or `.done` when nothing downstream wants
another item. `take` and `takeWhile` answer `.done`; sources stop when they see
it; `branch` and `route` answer `.done` once every sub-pipe has. The stream then
finishes normally: `fold` emits, writers flush.

`.done` is a hint that sticks: a stage that answered it keeps answering it,
and whoever is answered it stops pushing items. A value emitted at the end of
the stream (`fold`, `batch`) is still pushed and is refused by the stage that
is done; a handler between the two may run for it. (A `route` whose cases
rejoin drops such a value itself once the pipe after it is done.)

To stop a run from outside, cancel the task that called `run`. With a queue,
`run` returns `error.Canceled` under the rules in
[what a run guarantees](#what-a-run-guarantees). Without a queue or a
multi-source `merge`, cancellation is handled by the source and handlers
through their own `Io` calls. To stop
*gracefully*, end the source: when a source returns, everything it pushed is
still handled (unless a stage is done, or something fails), queues drain,
and the stream finishes and flushes as usual.

## Concurrency and backpressure

Without `queue` (and without `merge`, whose sources are tasks), a program is
one loop on the caller's task. A `queue` is the task boundary. The stages
before it push into a fixed-capacity buffer and wait while it is full. Another
task feeds the stages after it. That wait gives the pipeline backpressure.

`queue(n)` reserves the buffer on the stack of the task calling `run`.
The buffer uses `n * @sizeOf(Item)` bytes. For large queues, place a mutable
array in preallocated storage and use `queue(&slots)`.

```zig
var slots: [1024]zrx.Line(32768) = undefined;

// In the program's pipe, at the point where it carries Line(32768):
const work = pipe(.{
    queue(&slots),
    print(Report, "{f}\n"),
});
```

The array length determines capacity and its element type must match the
queue's input. Keep the array alive through `run` and give each active
queue exclusive use of its array. Sequential runs can reuse it. The worker
takes one item at a time and pushes it downstream before taking the next.
Queue storage requires no allocator dependency.

A queue splits the pipe into *segments*. The source with the stages up to the
first queue is one segment, and each queue starts the next. With a queue in
the pipe every segment runs as a task of its own, the source included, and
`run` only waits for them: no item handler runs on the task that called `run`
(a `resource` is still acquired and released there). The
`Io` must be able to run tasks concurrently (`error.ConcurrencyUnavailable`
otherwise).

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

- The stages of one side of a queue never run concurrently with each other:
  one task runs them (under a `merge`, one source at a time). Handlers on *different* sides do; a dependency
  shared across a queue or between programs of a system must be safe for that.
- Items cross a queue by value. Lines and batches store their contents inline.
  Queue storage grows with capacity times item size, including the full
  inline storage of a line or batch.
- If your source or handler emits pointers or slices, it is responsible for
  keeping their backing storage valid for as long as any stage can use it.
  This includes operators that retain items, such as `batch` and `fold`.
  zrx copies the reference and leaves cleanup to its owner, even if an
  item is dropped or a run stops early.
- Built-in queues use the program's resolved `std.Io` dependency.
- Stages before a queue may have handled more items than the stages after it
  take: the queue holds some, and the source runs ahead.
- Cancellation is cooperative: a handler or source that never calls into
  `std.Io` cannot be interrupted.
- A `route` case that rejoins the pipe cannot contain a queue (the pipe after
  the route would be pushed to from two tasks); put the queue after the route.
- When the stages after a queue are done (`take`), the segment before it
  finds out at its next push. A source that is waiting for input at that
  moment keeps waiting until its next item or its end.

### What a run guarantees

For one program with a queue in its pipe:

- **On success**, each stage's `finish` runs once. The end of the stream
  travels with the items: a segment finishes its stages and closes its
  output queue, and the next segment drains the queue and finishes.
- **On an error**, `run` returns the error. A segment may already have
  finished or may be cancelled part-way through finishing.
- **Which error**: the first failure of any segment, or `error.Canceled` if
  the task that called `run` was asked to cancel before the run had joined
  its tasks.
- **Always**, every task has returned before the program releases its resources.
- **A failure does not wait** for a source or a handler that is waiting in
  an `Io` call: it is cancelled there. Handlers may still run for a few
  items that were already in a queue.
- **A queue whose far side has ended**, for whatever reason, takes no more:
  a push into it answers `.done`.

That list is short on purpose. [The segments spec](spec-segments.md) is the
full statement, with what is *not* promised.

## Input and output

Readers and writers are dependencies. A *role* is the type one is keyed by:
`*std.Io.Writer` itself, or a struct with a single `writer: *std.Io.Writer`
field when a program has several (`reader: *std.Io.Reader` for input).

| | |
|---|---|
| `print(Role, "fmt")` | Terminal. Formats and flushes every item. A tuple supplies several format arguments. |
| `stdout(n)`, `stderr(n)` | Provide `zrx.Stdout` / `zrx.Stderr`, buffered by `n` bytes. |
| `fileWriter(Role, path, n, options)` | Binds a file writer as `Role`. The default mode is `.replace`. Use `.create_new` to require a new path. |
| `lines(Role, n)` | Source: lines of the reader keyed by `Role`. |
| `stdinLines(n)`, `fileLines(path, n)` | Sources: lines of standard input or a file; a line is at most `n` bytes, not counting its newline. |

Pass `stdout`, `stderr`, and `fileWriter` to `Program.provide`. The file
closes when the program releases its resources. `print` flushes after each
item and again at normal stream end. Handlers that write directly to a
writer control their own flushing. If multiple tasks use one writer, the
caller must serialize those writes.

Line sources emit `Line(n)`. Each value carries up to `n` bytes inline,
plus its length. Use `line.text()` to inspect the bytes while the line is
alive, or `print(Role, "{f}\n")` to write it. For `lines(Role, n)`, use a
reader buffer of at least `n + 1` bytes to fit the longest line and its
newline. On `error.StreamTooLong`, the reader stays at the start of the
rejected line. You can retry with a larger limit if the reader has room.

`batch(n)` emits `Batch(T, n)`. Use `group.slice()` while the group is alive,
or `flatten()` to emit its items. Both slice accessors borrow from the value
they are called on. Keep the whole value when storing or queueing it.

## Lifetimes

A run goes through these steps:

1. Apply bindings and acquire program resources in declaration order.
2. Construct stages and run the source. With queues, each segment runs on
   its own task.
3. On normal input end, finish each segment in stream order. Final values
   from `fold` and `batch` are pushed downstream here.
4. After the tasks have joined, release acquired resources in reverse
   order, including after a failed run or a partial acquisition.

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

            pub fn init(self: *@This(), _: *const Counted, env: Env) void {
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

A stage implements `push` and can implement `finish` for normal input end.
Use `init` for infallible in-place construction. If omitted, the stage is
constructed with `.{}`. To call a handler with injection, use
`zrx.di.Bound(name, handler, Env, &.{In})`.

An operator that hands items to a task of its own, as `queue` does, declares
a task boundary; one that holds sub-pipes, as `branch` does, passes their
tasks on. Both contracts are in [`src/pipe.zig`](../src/pipe.zig).

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

Every synchronous operator has a fixture. Twelve are `same`; `take`, `batch`
and the handler combinators are `lean`, each with the reason next to it.

What this does and does not show: pipelines of the operators covered there
compile to the code of the loop. The comparison is of instruction shape: it
cannot hide an extra call, load, store, branch or comparison, but it does not
check how the instructions are wired together, which is why the behaviour test
exists alongside it. It is evidence for those shapes with this compiler, not
a proof for every pipeline. `queue` is deliberately outside it.

Two things make it work, and are worth knowing when writing an operator:

- Each stage of a program is its own local variable, so the optimizer keeps
  each in registers independently. Stages inside a `branch` or `route`
  sub-pipe are stored together with it.
- A stage that indexes into an array it owns stays in memory as a whole. Keep
  such a buffer in a stage of its own, away from counters and accumulators:
  `batch` is a counter stage followed by a buffer stage for this reason.

## Not here yet

Stopping a source from outside, so that a signal or a timeout ends a run
gracefully, is proposed in [the segments spec](spec-segments.md) and not
built. Nor is interrupting a source that waits for input once the stages
behind a queue are done; the spec says why.

Present in the previous implementation and not ported: HTTP serving, signals
(`hold`, `withLatestFrom`), `retryPipe`, `takeLast`, `maxItems`, and two of
the three standalone example applications. The
[record processor](../examples/apps/record-processor/README.md) is ported, and
its README lists what the port needed that the library does not have yet.
