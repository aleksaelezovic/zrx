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
- [HTTP](#http)
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

Dependencies come from the *bindings* a program is run with:
`app.run(.{ io, Scale{ .by = 2 } })`. A program can be given some of them in
advance with `provide`; see [Programs and systems](#programs-and-systems).
The source and every stage see the same ones.

Rules:

- The key is the type, and a type has one provider. Two values of the same
  type cannot both be passed to `run`; wrap one in a struct to name its role
  (`const Audit = struct { log: *Log };`).
- The order bindings are written in does not matter.
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

Where a pipe is expected, pass an inline operator tuple or a constructed
`pipe(...)` value. This applies to `program`, each child of `branch`, and the
sub-pipes of `when`, `otherwise`, `concurrent`, `each` and `attempt`. Both
forms construct the same pipe;
`pipe(...)` is useful for named, reusable compositions. Bare operators are
rejected; wrap even a single operator in `.{ ... }`.

```zig
const app = program(source, .{
    parse,
    forEach(save),
});
```

A pipe that ends with a terminal operator (`forEach`, `drain`, `print`,
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
const report = program(source, .{
    queue(32),
    fold(0, add),
    print(Report, "{d}\n"),
}).provide(.{
    fileWriter(Report, path, 4096, .{ .mode = .create_new }),
});

try report.run(.{io});
```

`provide` gives a program *defaults*: bindings that `run` uses unless it is
given one that provides the same type. It is not a second kind of
dependency: `p.provide(a).run(b)` runs with everything in `b` and with the
bindings of `a` whose type `b` does not provide. Among the defaults, and among what `run` is
given, a type has one provider; a second one is a compile error. The
resulting environment is shared by the source and all stages, including
branch and route cases.

A binding is a value, which provides its own type, or a *resource*.
`resource(acquire, release)` calls `acquire(deps...)` once per run and
provides what it returns. `release(deps..., value)` returns `void`. Use
`null` for a computed binding that needs no release. `stdout`, `stderr` and
`fileWriter` are resources that need `std.Io`.

Bindings may be written in any order, in `provide` or in `run`:

```zig
const app = program(source, work).provide(.{
    resource(openSession, closeSession), // needs a Connection
    resource(connect, disconnect), // needs a Config
});
try app.run(.{ io, config });
```

What every resource provides and needs is known at compile time, and that
decides the order. A run starts with the values, then acquires a resource
once everything it needs is there. Of the resources that are ready, it takes
the one written first; defaults count as written before what `run` is
given. A resource that needs a type nothing provides, and resources that
need each other, are compile errors. Acquired resources are released in the
reverse order, after the program's tasks have joined.

A default that `run` replaces is not acquired. A test can run the `report`
program above with `Report{ .writer = &writer }` in the tuple, and no file
is created.

```zig
try system(.{ ingest, report }).run(.{ io, &mailbox });
```

`system` runs its programs together with the same bindings and returns when
all have finished. What it is given replaces a default of the same type in
each program, and a resource among it is acquired once, around all of them. The first failure cancels the others and is returned; a
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
| `mergeTagged(T, .{ .a = x, .b = y })` | `merge`, with every item marked by the source it came from; see [below](#knowing-where-an-item-came-from). |
| `lines(Role, n)`, `stdinLines(n)`, `fileLines(path, n)` | Text lines; see [Input and output](#input-and-output). |
| `fileBytes(path, n)` | The bytes of a file, at most `n` at a time; see [Input and output](#input-and-output). |

A producer stops when a push answers `.done`:

```zig
fn ticks(clock: Clock, out: anytype) !void {
    while (try out.push(clock.now()) == .more) {}
}
```

### Knowing where an item came from

`merge` forgets which source an item came from. `mergeTagged` keeps it: name
one source for each tag of an enum, and every item arrives as
`Tagged(Enum, Item)`, a struct with the fields `source` and `item`.

```zig
const Side = enum { left, right };

fn parse(line: zrx.Tagged(Side, Line)) !Event { ... }

const logs = mergeTagged(Side, .{
    .left = fileLines(left_path, max_line),
    .right = fileLines(right_path, max_line),
});
```

To merge sources of *different* item types, pass a tagged union instead. Each
source feeds the variant of its name, and the items are the union itself:

```zig
const Input = union(enum) { tick: Tick, line: Line };

const input = mergeTagged(Input, .{
    .tick = fromProducer(Tick, ticks),
    .line = stdinLines(max_line),
});
```

A union item is as large as its largest variant, which is what a `queue`
after it stores per slot. With an enum every source must emit the same type;
a union whose variants all hold the same type is rejected in favor of the
enum. Everything else is `merge`: the sources run as tasks and take turns.

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
| `concurrent(n, sub)` | Shares items among `n` worker-local copies of a synchronous pipe, with serialized unordered output. Accepts an operator tuple or `pipe(...)`; needs `std.Io`. |
| `batchWithin(n, duration)` | Emits `Batch(T, n)` when full or after the first item's maximum age. Needs `std.Io`. |
| `debounce(duration)` | Emits the latest pending item after a quiet period. Needs `std.Io`. |
| `branch(.{ pipe, pipe })` | Terminal. Every item goes to every sub-pipe. |
| `route(.{ when(p, pipe), otherwise(pipe) })` | Each item goes to the first case that takes it. |

Within one item:

| Operator | Effect |
|---|---|
| `each(source_of, sub)` | Runs a fresh `sub` over the source that `source_of(deps..., item)` returns, and emits what `sub` emits, paired with the item. See [each](#each). |
| `attempt(sub, fallback)` | Runs `sub`; when it fails for an item, emits `fallback(deps..., err, item)` in its place. See [Errors](#errors). |

Terminal:

| Operator | Effect |
|---|---|
| `forEach(f)` | Runs `f(deps..., item)` for every item. |
| `drain()` | Discards every item. |
| `print(Role, "fmt")` | Formats every item to a writer and flushes it. |
| `write(Role, "fmt")` | Formats every item to a writer; flushes once, at the end. |

Every handler may also return an error union of the type shown.

### route

Either every case terminates, and so does the route, or every case emits the
same item type and the pipe continues after the route:

```zig
route(.{
    when(isRefund, .{map(negated)}),
    when(isLarge, .{map(withFee)}),
    otherwise(.{map(field(.cents))}),
}),
fold(0, add),
```

An item no case takes is dropped. Each case has its own stage state.

### each

A program has one source. `each` gives every *item* one. For an item,
`source_of(deps..., item)` returns a source; a fresh copy of the sub-pipe
runs over that source to its end; what the sub-pipe emits goes on down the
pipe. Here a path becomes its bytes, the bytes become one digest, and the
pipe carries on with a row:

```zig
const read_bytes = 32 * 1024;

/// The running digest of one file.
const Hash = struct {
    sha: Sha256 = .init(.{}),
    bytes: u64 = 0,

    fn update(hash: Hash, piece: []const u8) Hash { ... }
};

fn bytesOf(path: []const u8) zrx.FileBytes(read_bytes) {
    return fileBytes(path, read_bytes);
}

fn described(file: zrx.Tagged([]const u8, Hash)) Row { ... }

const digest = pipe(.{fold(Hash{}, Hash.update)});

/// path -> its bytes -> one digest -> a row
const hashed = pipe(.{
    each(bytesOf, digest),
    map(described),
});
```

- **State in the sub-pipe lasts one item.** Its stages are constructed when
  the item arrives and finished when the item's source has ended: the `fold`
  above emits once per file, and a `take(3)` there would limit every file to
  three pieces. A sub-pipe that is done ends its item, and the next item
  starts afresh. Only the pipe *after* `each` being done stops the stream.
- **What goes on is `Tagged(Item, T)`**, a struct with the fields `source`
  (the item the sub-pipe ran for) and `item` (what it emitted). `Item` is
  the type `source_of` declares for its parameter, so a pipe written for
  `[]const u8` emits the same type whether it is fed `[]const u8` or the
  `[:0]const u8` of a command line. If that parameter is `anytype`, it is
  the item's own type.
- **Everything for an item happens within its push**, on the task that
  pushed it. The sub-pipe is therefore synchronous: it cannot contain a task
  boundary, and it must emit something (it cannot end in a terminal
  operator). To work on several items at once, put the `each` inside
  `concurrent`.
- **The source is any source**: `fromSlice`, `range`, `fileBytes`, one of
  your own. `source_of` takes dependencies like any handler and may fail. It
  has to name the type it returns: `zrx.FileBytes(n)` for `fileBytes`, and
  for the other built-in sources, whose types have no public name yet,
  `@TypeOf(range(u32, 0, 0))`.
- A failure of `source_of`, of the source or of the sub-pipe fails the run
  like any handler error, and that item's sub-pipe is not finished. To turn
  the failure into a value instead, wrap the `each` in
  [`attempt`](#errors). The full statement is guarantee 14 of
  [the segments spec](spec-segments.md#guarantees).

## Handler combinators

Small handlers so that domain code does not have to restate them. They are
usable wherever a handler is, and forward the dependencies of the handlers
they are built from.

| Combinator | Meaning |
|---|---|
| `not(p)`, `all(.{ p, q })`, `any(.{ p, q })` | Predicate logic; `all` and `any` stop at the first decisive predicate. |
| `compose(.{ f, g })` | `g(f(item))`, left to right. |
| `orElse(f, fallback)` | `f(item)`, or `fallback(deps..., err, item)` when `f` fails. |
| `require(p, err)` | The item when `p(item)` is true, the error `err` when it is not. |
| `reduce(seed, f)` | Folds the elements of an array, slice or batch item with `f(deps..., state, element)`; `seed` for an empty one. |
| `field(.name)` | The field `name` of a struct item. |
| `constant(value)` | `value`, whatever the item. |
| `eq(v)`, `ne(v)`, `lt(v)`, `le(v)`, `gt(v)`, `ge(v)` | Comparison with a comptime value. |

```zig
const isHot = compose(.{ field(.celsius), gt(80) });
const wanted = all(.{ isHot, not(isMuted) });
```

`reduce` is to one item what `fold` is to the stream. After `batch` or
`batchWithin` it turns each group into a summary:

```zig
const windows = pipe(.{
    batchWithin(8, .fromMilliseconds(200)),
    map(reduce(Window{}, Window.add)),
    forEach(save),
});
```

## Errors

A handler that returns an error fails the run: the error comes out of `run`,
after every resource has been released. `run`'s error set is inferred from your
handlers and the operators you used: it is `anyerror` only if a handler's is,
and a program whose handlers cannot fail has an empty one.

There are three ways to handle an error instead. To keep the item as a value
of your choosing, wrap the handler: `map(orElse(parse, rejected))` calls
`rejected(deps..., err, item)` when `parse` fails and passes its result on.
`require` goes the other way, from a value to an error:
`map(require(isPlausible, error.InvalidReading))` fails an item that
`filter(isPlausible)` would drop without a trace.

When what fails is not one handler but several operators, wrap them:
`attempt(sub, fallback)` is `orElse` for a sub-pipe. When `sub` fails for an
item, `fallback(deps..., err, item)` is emitted in its place, with the item
as it was at the `attempt`.

```zig
/// A file that cannot be hashed is still a row.
fn failed(err: anyerror, path: []const u8) Row { ... }

const manifest = pipe(.{
    concurrent(4, .{attempt(hashed, failed)}),
    forEach(save),
});
```

- The rules are `orElse`'s. The fallback returns what the sub-pipe emits.
  Its error parameter must take every error the sub-pipe can fail with
  (`anyerror` always does); `error.Canceled` is never handed to it. What it
  handles is no longer in `run`'s error set.
- What the sub-pipe had already emitted for the item is not taken back, and
  its stages keep whatever state the item gave them.
- A failure of the pipe *after* the `attempt` is not the sub-pipe's. It
  fails the run as it would without the `attempt`, the fallback is not
  asked, and a `recover` inside the sub-pipe does not see it.
- The sub-pipe keeps its state for the whole stream, like a case of a
  `route`. A failure at its end of the stream does not belong to an item and
  fails the run.
- The sub-pipe cannot contain a task boundary: a failure beyond one happens
  on another task.

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
    forEach(save),
})
```

- The handler's error parameter selects what it handles: an error set handles
  its members and lets everything else through; `anyerror` handles everything.
- `error.Canceled` is never given to a handler. A write that was interrupted
  because the run is being cancelled is: `std.Io.Writer` reports it as
  `error.WriteFailed` like any failed write.
- A `recover` guards what comes *after* it, up to the next task boundary
  (`queue`, `batchWithin` or `debounce`). Errors on the far side happen in
  another task and fail the run.
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

To stop a run from outside, cancel the task that called `run`. With a task boundary,
`run` returns `error.Canceled` under the rules in
[what a run guarantees](#what-a-run-guarantees). Without a boundary or a
multi-source `merge`, cancellation is handled by the source and handlers
through their own `Io` calls. To stop
*gracefully*, end the source. Queues drain, timed operators emit their pending
values, and the stream finishes as described in the spec's
[graceful-end guarantee](spec-segments.md#guarantees).

## Concurrency and backpressure

Without a task boundary (and without `merge`, whose sources are tasks), a
program is one loop on the caller's task. The built-in boundaries are
`queue`, `batchWithin`, `debounce` and `concurrent`. With `queue`, the stages
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

A boundary splits the pipe into *segments*. The source with the stages up to the
first boundary is one segment, and each boundary starts the next. With a boundary in
the pipe every segment runs as a task of its own, the source included, and
`run` only waits for them: no item handler runs on the task that called `run`
(a `resource` is still acquired and released there). The
`Io` must be able to run tasks concurrently (`error.ConcurrencyUnavailable`
otherwise).

`branch` itself is a plain loop over its sub-pipes. A sub-pipe becomes
concurrent by starting with a queue:

```zig
branch(.{
    .{
        queue(64),
        map(slowWrite),
        drain(),
    },
    .{
        queue(64),
        batch(10),
        forEach(report),
    },
})
```

- A synchronous chain handles one item at a time. `concurrent` replicates
  its worker pipe; workers take turns pushing into its continuation, as
  sources of a `merge` do. Dependencies shared across workers, segments, or
  programs of a system must be safe for concurrent use.
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
- A `route` case that rejoins the pipe cannot contain a task boundary (the
  pipe after the route would be pushed to from two tasks). Put the boundary
  after the route. The sub-pipes of `each` and `attempt` cannot either: what
  they do for an item is over when the push of that item returns.
- When the stages after a boundary are done, the segment before it finds out
  at its next push. A producer that asks for `zrx.Stop` can also observe that
  its consumers have finished while it waits for input.

### Concurrent worker pipes

```zig
const transform = pipe(.{
    map(expensiveWork),
    filter(isValid),
});
const app = program(source, .{
    concurrent(4, transform),
    fold(0, combine),
    forEach(saveResult),
});
```

Each input goes to one worker, rather than being broadcast as with `branch`.
Output is unordered and passes through one serialized continuation. Here
`fold` combines results across all workers. Operators inside the worker pipe
have separate state: an inner `take(2)` limits each worker to two inputs, and
an inner `fold` emits one final value per worker, including its seed on empty
input. A terminal worker pipe makes `concurrent` terminal too.

`n` is a positive comptime integer. The worker pipe is synchronous: put
`queue`, timed operators, and other `concurrent` operators outside it.
`concurrent(1, ...)` still starts a worker and requires a concurrent `std.Io`.
CPU parallelism depends on the supplied `Io` implementation.

The operator reserves `n` input slots and `n` worker states on the caller's
stack. It starts `n` workers plus a coordinating boundary task; the source
is also a task. Input waits when the slots are full. No output queue or
allocator dependency is added. As with `queue`, slices and pointers retain
their original backing storage; the caller must keep it valid.

Dependencies and program resources are shared according to their existing
types; copying worker state does not create a resource per worker. On
successful early completion, input closes and workers finish normally.
Already-running handlers are not selectively cancelled. Failures and caller
cancellation use the same scope as the other program tasks. The precise
statements and tests are in the [segments spec](spec-segments.md#guarantees).

### Stopping a producer when its consumers finish

Declare `stop: zrx.Stop` among a `fromProducer` handler's dependencies.
`run` supplies it to the source. Use `stop.requested()` between reads or
wait on `stop.wait(io)` alongside the input, for example with `std.Io.Select`.
Once it signals, return normally so the program can finish. Continue to
stop when `out.push` answers `.done`, and propagate cancellation and input
errors. The signal applies to downstream completion across task boundaries.
In a synchronous pipe the producer learns about completion through `push`.

A custom source can declare `pub const zrx_stop_source = true` and get
`zrx.Stop` from its source environment. If sources are merged, each source
that can wait for more input needs to cooperate for the merge to finish
without further input. Built-in line sources continue to discover completion
through `push`.

### What a run guarantees

For one program with a task boundary in its pipe:

- **On success**, each stage's `finish` runs once. The end of the stream
  travels with the items: a segment finishes its stages and ends input to
  its boundary, and the next segment handles its pending values and finishes.
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

### Timed batching and debounce

```zig
const writes = pipe(.{
    batchWithin(1000, .fromSeconds(60)),
    forEach(saveBatch),
});

const searches = pipe(.{
    debounce(.fromMilliseconds(250)),
    forEach(search),
});
```

`batchWithin` starts its deadline when the first item enters an empty batch.
Later items keep that deadline. At 1000 items or 60 seconds the batch is
ready for its worker to push downstream. A producer that sends 900 items
and waits can therefore get a partial batch processed during that wait.
An empty batch has no timer. Output uses the same inline `Batch(T, n)` as
`batch(n)`.

`debounce` retains one pending item. Each push replaces it and restarts the
quiet-period deadline. Its worker takes the latest pending value when it
observes that the quiet period has elapsed. Input can keep replacing that
pending value while a downstream handler is busy.

Both sizes and durations are comptime arguments. Durations are positive
`std.Io.Duration` values, measured using `.awake` (excluding system suspend).
Both operators start a task, use the program's resolved `std.Io`, and require
concurrency. Their workers use a mutex and condition to wait for input or a
deadline and call downstream outside the mutex. Their normal-end behavior
and timing limits are in the [segments spec](spec-segments.md#guarantees).

Timed batching holds one pending batch in the program's stage storage and
one batch being delivered by its worker. A full pending batch backpressures
the producer. Debounce holds one pending item plus any item already being
delivered. Retained slices and pointers need backing storage that lives
through their use, as with `batch` and `queue`.

#### Testing timed operators

A test should not wait 60 seconds for a batch, nor guess how long is long
enough. `zrx.testing.Clock` wraps a `std.Io` and keeps its `.awake` clock
still until the test moves it. The operators take time from the program's
`Io`, so pass `clock.io()` to `run`:

```zig
fn collectWindows(timed: std.Io, input: *Input, windows: *Windows) !void {
    try program(fromProducer(u32, Input.produce), pipe(.{
        batchWithin(8, .fromMilliseconds(200)),
        forEach(Windows.collect),
    })).run(.{ timed, input, windows });
}

test "three readings make one window while the source is open" {
    const io = std.testing.io;
    var clock: zrx.testing.Clock = .init(io);
    // ... `input` feeds the source one item at a time, `windows` is a queue
    var run = try io.concurrent(collectWindows, .{ clock.io(), &input, &windows });
    defer _ = run.cancel(io) catch {};

    for ([_]u32{ 7, 8, 9 }) |reading| try input.send(reading);
    try clock.waitingAt(.fromMilliseconds(200));
    clock.advanceTo(.fromMilliseconds(200));
    try std.testing.expectEqualSlices(u32, &.{ 7, 8, 9 }, (try windows.seen.getOne(io)).slice());
}
```

Times are durations since `Clock.init`. `waitingAt(t)` returns once a task
is in a timed wait whose deadline is `t`: for `batchWithin` that is the
first item of a batch plus its age, for `debounce` the latest item plus the
quiet period. That is the event to wait on, in place of a sleep, before
moving the clock or asserting that nothing has been emitted. `advanceTo(t)`
sets the time, never backwards, and wakes the waits whose deadline has
come; a wait that is not due stays asleep. The whole
test, with `Input` and `Windows`, is in
[`tests/timing.zig`](../tests/timing.zig).

The clock is a value the test owns: declare one per test, keep it in place,
and let it outlive the run. It covers reads of `.awake` and timed waits on
`.awake` made through `clock.io()`, and nothing else:

- `io.sleep`, the other clocks (`.real`, `.boot`) and `std.time` run on real
  time, as does a handler that uses another `Io`.
- A timed wait is woken only through `clock.io()`. A test that sets an event
  some handler waits on with a timeout must set it through the clock's `Io`.
- It does not make a source deterministic. The test still decides when items
  arrive, as `input.send` does above.

## Input and output

Readers and writers are dependencies. A *role* is the type one is keyed by:
`*std.Io.Writer` itself, or a struct with a single `writer: *std.Io.Writer`
field when a program has several (`reader: *std.Io.Reader` for input).

| | |
|---|---|
| `print(Role, "fmt")` | Terminal. Formats and flushes every item. A tuple supplies several format arguments. |
| `write(Role, "fmt")` | Terminal. Like `print`, but flushes only at the end of the stream. |
| `stdout(n)`, `stderr(n)` | Provide `zrx.Stdout` / `zrx.Stderr`, buffered by `n` bytes. |
| `fileWriter(Role, path, n, options)` | Binds a file writer as `Role`. The mode is `.replace` (default), `.create_new` or `.publish`. |
| `ext.json.encode(options)` | Handler: the item as JSON text, to be formatted with `{f}`. |
| `lines(Role, n)` | Source: lines of the reader keyed by `Role`. |
| `fileReader(Role, path, n)` | Binds a file's reader as `Role`, buffered by `n` bytes. |
| `stdinLines(n)`, `fileLines(path, n)` | Sources: lines of standard input or a file; a line is at most `n` bytes, not counting its newline. |
| `fileBytes(path, n)` | Source: the bytes of a file, in pieces of at most `n`. |

`stdout`, `stderr`, `fileWriter` and `fileReader` are bindings: give them
to `provide` or to `run`. A file
closes when the program releases its resources. `print` flushes after each
item and again at normal stream end: use it for output someone reads as it
is produced. `write` leaves items in the writer's buffer and flushes at
normal stream end only: use it for a file, where a flush per item is a
system call per item. Handlers that write directly to a
writer control their own flushing. If multiple tasks use one writer, the
caller must serialize those writes.

`fileWriter` modes:

- `.replace` creates the file, or empties it if it exists.
- `.create_new` fails with `error.PathAlreadyExists` if something is there.
- `.publish` writes to a temporary file in the same directory and gives it
  its name after the work wrapped by the binding succeeds and the writer is
  flushed. A failure before publication leaves the destination untouched.
  If the path already exists at publication, the run returns
  `error.PathAlreadyExists`.

Each file is published atomically. With several published files, the last
one acquired is named first, following resource release order: of the files
in one tuple, the one written last. If naming one
fails, `run` returns that error and the files published earlier stay in place.

```zig
program(source, work).provide(.{
    fileWriter(Summary, summary_path, 4096, .{ .mode = .publish }), // named second
    fileWriter(Archive, archive_path, 4096, .{ .mode = .publish }), // named first
})
```

To write JSON lines, map each item with `json.encode` from the extension
`zrx.ext.json` and format the result with `{f}`:

```zig
const json = zrx.ext.json;

const archive = pipe(.{
    map(json.encode(.{})),
    write(Archive, "{f}\n"),
});
```

`json.encode(options)` is a handler that returns `std.json.fmt(item, options)`,
a value holding a copy of the item. The options are
`std.json.Stringify.Options` and are always given, `.{}` for the defaults:
`json.encode(.{ .emit_null_optional_fields = false })` leaves out optional
fields that are null.

`fileReader` is what lets a program be one constant for production and for
tests. The program reads `lines(Input, n)`; `main` gives it the file, and a
test gives it a reader of its own, which replaces a default:

```zig
const app = program(lines(Input, max_line), work);

// in main:
try app.run(.{ io, fileReader(Input, input_path, max_line + 1), ... });
// in a test:
try app.run(.{ Input{ .reader = &fixed }, ... });
```

The buffer must hold the longest line and its newline, as for any reader
given to `lines`.

Line sources emit `Line(n)`. Each value carries up to `n` bytes inline,
plus its length. Use `line.text()` to inspect the bytes while the line is
alive, or `print(Role, "{f}\n")` to write it. `Line(n).from(text)` copies
text into a line of your own (`error.StreamTooLong` if it does not fit), so
a record that crosses a `queue` can own a name without a slice into someone
else's buffer. A line source accepts arbitrary bytes, and `std.json` formats
a line like a byte slice. By default, valid UTF-8 becomes a JSON string and
invalid UTF-8 becomes an array of numbers. `emit_strings_as_arrays` uses
arrays for both. For `lines(Role, n)`, use a reader buffer of at least
`n + 1` bytes to fit the longest line and its newline. On
`error.StreamTooLong`, the reader stays at the start of the rejected line.
You can retry with a larger limit if the reader has room.

`fileBytes(path, n)` emits `[]const u8`: pieces of the file in order, none
empty and none longer than `n`. A piece is a slice into the source's own
buffer and is valid until the push that carries it returns. Reduce the
pieces as they pass (`fold`), or copy what must be kept: do not send a piece
across a `queue` or keep it in a `batch`. An empty file emits nothing.
`zrx.FileBytes(n)` names the source's type, for a handler that returns one.

When reading a file fails, the run fails with the error the system reported,
such as `error.InputOutput`. That holds for `fileBytes`, `fileLines` and
`stdinLines`, which own their reader. A reader given to `lines(Role, n)`,
one of your own or one bound by `fileReader`, fails the run with what it
reports, which for `std.Io.Reader` is `error.ReadFailed`.

`batch(n)` emits `Batch(T, n)`. Use `group.slice()` while the group is alive,
or `flatten()` to emit its items. Both slice accessors borrow from the value
they are called on. Keep the whole value when storing or queueing it.

## HTTP

`zrx.ext.http` serves HTTP/1.1 with `std.http.Server`. It is an extension: a
source, an operator and some handlers written against the public contracts,
compiled only when a program uses it.

```zig
const http = zrx.ext.http;

const api = pipe(.{
    recover(http.fail),
    route(.{
        when(http.path("/sum"), .{
            map(sum),
            http.text("{d}"),
        }),
        when(all(.{ http.path("/hello"), http.method(.GET) }), .{
            map(constant(hello)),
            http.json(),
        }),
        otherwise(.{http.status(.not_found)}),
    }),
});

const server = program(http.connections(), .{
    concurrent(64, .{
        recover(http.disconnected),
        http.serve(api),
    }),
}).provide(.{http.listen(address, .{ .reuse_address = true })});

try server.run(.{io});
```

There are two pipes. The program's pipe carries connections; the pipe given
to `serve` carries the requests of one connection.

| | |
|---|---|
| `http.listen(address, options)` | Binding. Listens for the run and provides the `http.Listener`; `listener.port()` is the bound port. Options: `pending` (64), `reuse_address`, `kernel_backlog`. Needs `std.Io`. |
| `http.connections()` | Source: the connections accepted from the listener. |
| `http.serve(sub)` | Terminal. Holds the conversation on each connection with `sub`, an operator tuple or `pipe(...)` of `http.Request` items that ends in a terminal operator. |
| `http.reject()` | Terminal. Closes each connection it is given without reading or answering anything. |
| `http.text("fmt")` | Terminal, in `sub`. Answers 200 with the item formatted as `text/plain`; a tuple supplies several arguments. |
| `http.json()` | Terminal, in `sub`. Answers 200 with the item written by `std.json`. |
| `http.status(code)` | Terminal, in `sub`. Answers the final status `code` with an empty body; a 204 or 304 carries no length. |
| `http.path("/x")`, `http.method(.GET)` | Predicates on a request: the exact path before `?`, and the method. Combine them with `all` and `any`. |
| `http.fail` | For `recover`, in `sub`: answers a failed request with the status of its error. |
| `http.disconnected` | For `recover`, before `serve`: drops a connection that broke. |

`serve` constructs `sub` anew for every connection and finishes it when the
connection ends, so its stages hold per-connection state: with an inner
`take(100)`, no more than 100 requests are taken from a connection. The connection's `http.Response`
is added to the dependencies of `sub`. That is how the responders and `fail`
find the request to answer, and why they are rejected outside `serve`. `sub`
is synchronous: put `queue` and `concurrent` around `serve`, not in it.

### Requests

A request points into its connection. Use it during its push; do not keep it.

```zig
fn sum(request: http.Request) !i64 {
    var total: i64 = 0;
    var pairs = request.query();
    while (pairs.next()) |pair| total += std.fmt.parseInt(i64, pair.value, 10) catch 0;
    var buffer: [32]u8 = undefined;
    const body = try request.body(&buffer);
    return total + (std.fmt.parseInt(i64, body, 10) catch 0);
}
```

- `request.method()`, `request.path()`, `request.header(name)` and
  `request.query()`, whose `next()` gives `name` and `value` pairs. Nothing is
  percent-decoded.
- `request.body(&buffer)` reads the whole body and returns it, empty when the
  request has none. It owns the framing: its errors are `BadRequest` (a body
  on a method that takes none, two framings, an invalid chunk),
  `LengthRequired`, `PayloadTooLarge` (more than the buffer holds) and
  `ExpectationFailed`. It answers `Expect: 100-continue` itself.
- Reading the body overwrites the head. Read the path, query and headers
  first; call `body` at most once.

### Answers

Each request is answered once. A request that `sub` let pass without an
answer is answered 500. A second answer writes nothing and closes the
connection. A `HEAD` request gets the head of the answer alone.

To answer in a way the responders do not cover, ask for the `http.Response`:

```zig
fn created(response: http.Response, id: u64) !void {
    var buffer: [32]u8 = undefined;
    try response.send(.created, "text/plain", try std.fmt.bufPrint(&buffer, "{d}", .{id}));
}
```

A 204 and a 304 end with their head. They are written without a body and
without a `content-length`, also when `send` is given content. (A 304 may
carry the length of the representation it stands for; zrx does not know it
and sends none.)

An interim status (1xx) does not answer a request. `http.status` rejects
one at compile time, and `send`, given one at run time, answers 500 in its
place. `100 Continue` is sent by `request.body`, as above.

### Failures

`recover(http.fail)` at the start of `sub` turns a handler's error into an
answer and lets the connection go on:

| Error | Status |
|---|---|
| `error.BadRequest` | 400 |
| `error.NotFound` | 404 |
| `error.MethodNotAllowed` | 405 |
| `error.LengthRequired` | 411 |
| `error.PayloadTooLarge` | 413 |
| `error.ExpectationFailed` | 417 |
| anything else | 500 |

Without it, a handler's error fails the run like any other.

A connection goes on after an answer when the next request can be found: the
body was read to its end, or was not read and can be skipped. It is closed
after an error of `body`, after an answer given while the peer still waits
for `100 Continue`, and when a request declares a body in a way that cannot
be skipped (no framing on `POST`, a body on `GET`).

A head that does not parse is answered 400, and one that does not fit the
connection's read buffer (8 KiB for a socket) 431, by `serve` itself; then
the connection is closed.

A connection that breaks fails its push with `error.ReadFailed` or
`error.WriteFailed`. `recover(http.disconnected)` before `serve` handles
exactly these two, so one lost peer does not end the server and every other
error still does. `fail` does not answer them either: they pass through it.

### Connections and writes

The listener owns a connection from the moment it is accepted until it is
pushed to a `serve`, which closes it when the conversation ends, whatever
ended it, or to `http.reject()`, which closes it at once. A connection that
is still waiting when the run is over (in a queue, or with the source) is
closed by the listener once the run's tasks have returned. The listener has
room for `pending` waiting connections, 64 unless `listen` is told
otherwise, and `connections` accepts no more while it is full.

Every connection has to end in a `serve` or a `reject`. On its way there it
may wait at a boundary (`queue`, `concurrent`) and pass through stages that
hand on every item they are given (`route`, `tap`, `take`). A stage that
drops a connection or keeps it back (`filter`, `batch`, any other terminal,
a `recover` that handles a failure before `serve`) does not close it and
does not free its place: it stays open and counts as waiting until the run
is over. So do not filter connections. Route the ones you will not serve to
`reject`, which frees the place:

```zig
const admitted = route(.{
    when(unwelcome, .{http.reject()}),
    otherwise(.{http.serve(api)}),
});
```

A connection is handed over once. A copy of it that reaches a second
`serve` or `reject` (a `branch` into two of them) fails that push with
`error.ConnectionTaken`, which fails the run like any other error, and the
socket stays with whoever took it.

Answers are collected in a 4 KiB buffer per connection and written before
`serve` reads something that may not have arrived yet (a request head, or a
body, that is not whole in its read buffer) and when the connection ends.
Requests that arrived together and whole (pipelined) are therefore answered
with one write, as long as their bodies have a length. Where a chunked body
ends is not looked for in the buffer: `serve` writes what it has answered
so far before it reads or skips one, also when all of it has arrived. An
answer never waits for the rest of a request that arrived in part.

For a connection that is not a socket, or in a test, give `serve` an
`http.Transport` instead: a reader and a writer of yours, which it flushes
and does not close.

```zig
const connection: http.Transport = .{ .reader = &reader, .writer = &writer };
try program(fromValue(connection), .{http.serve(api)}).run(.{});
```

### Limits

- One worker holds one connection for as long as it is open. An idle
  keep-alive connection occupies its worker, and a peer that connects while
  all are taken waits. Size `concurrent(n, ...)` for the open connections you
  expect, with room to spare.
- `n` is a comptime number. With `std.Io.Threaded`, which is what
  `std.process.Init` provides, every worker is a thread.
- Without `concurrent`, `serve` holds one conversation at a time on the
  task of the source.
- `text` and `json` format the item twice, once to learn its length.
- Accepting stops only when the run does. A failure to accept, other than a
  connection its peer already gave up, fails the run.
- To stop a server, cancel the task that called `run`: it returns
  `error.Canceled`, also from a read that was waiting for a request. Open
  conversations are cut off, not completed.

The [HTTP benchmark app](../examples/apps/http-bench/README.md) compares this
with a server written against `std` alone and records what was measured.

## Lifetimes

A run goes through these steps:

1. Build the environment from the bindings: the values, then each resource
   once what it needs is there.
2. Construct stages and run the source. With queues, each segment runs on
   its own task.
3. On normal input end, finish each segment in stream order. Final values
   from `fold` and `batch` are pushed downstream here.
4. After the tasks have joined, release acquired resources in reverse
   order, including after a failed run or a partial acquisition.

The stages of an `each` sub-pipe go through steps 2 and 3 once for every
item, within the push of that item.

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

**A binding** that acquires something for the run is a value whose type
declares `zrx_resource`, the type it `Provides`, the dependency types it
`needs`, and `bind(self, env, rest) !void`. `env` holds what it needs.
`bind` calls `rest.call(value)` once, and the rest of the run happens inside
that call: what `bind` does after it returns is its release, and that may
fail. `resource(acquire, release)` is the short form for two handlers. This
one keeps a tally for the run and reports it when the run is over:

```zig
const Tallied = struct {
    pub const zrx_resource = {};
    pub const Provides = *Tally;
    pub const needs: []const type = &.{*Report};

    pub fn bind(_: Tallied, env: anytype, rest: anytype) !void {
        var tally: Tally = .{};
        try rest.call(&tally);
        zrx.di.get(env, *Report).total = tally.count;
    }
};
```

Give it to `provide` or to `run` like any other binding. See
[`src/resources.zig`](../src/resources.zig).

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

Every synchronous operator has a fixture. Seventeen are `same`; `take`, `batch`,
the handler combinators and `attempt` are `lean`, each with the reason next
to it.

What this does and does not show: pipelines of the operators covered there
compile to the code of the loop. The comparison is of instruction shape: it
cannot hide an extra call, load, store, branch or comparison, but it does not
check how the instructions are wired together, which is why the behaviour test
exists alongside it. It is evidence for those shapes with this compiler, not
a proof for every pipeline. Task-boundary operators are deliberately outside it.

Two things make it work, and are worth knowing when writing an operator:

- Each stage of a program is its own local variable, so the optimizer keeps
  each in registers independently. Stages inside a `branch` or `route`
  sub-pipe are stored together with it.
- A stage that indexes into an array it owns stays in memory as a whole. Keep
  such a buffer in a stage of its own, away from counters and accumulators:
  `batch` is a counter stage followed by a buffer stage for this reason.

## Not here yet

Stopping a source from outside, so that a signal or a timeout ends a run
gracefully, is proposed in [the segments spec](spec-segments.md).

A resource acquired for one item (opened before the item's sub-pipe and
released after it) is not here. `each` covers the case where the item
becomes a stream.

HTTP is deliberately small for now. Not there: timeouts for idle or slow
peers, graceful shutdown, more connections than workers (no queue of ready
connections, no event loop), response headers of your own, streamed bodies,
path parameters, configurable buffer sizes, TLS and HTTP/2. Parsing is
`std.http.Server`'s; zrx has no parser of its own.

Present in the previous implementation and not ported: signals
(`hold`, `withLatestFrom`), `retryPipe`, `takeLast`, `maxItems`, and one of
the three standalone example applications. The
[record processor](../examples/apps/record-processor/README.md) and the
[HTTP benchmark](../examples/apps/http-bench/README.md) are ported, and
their READMEs list what the ports needed that the library does not have yet.
