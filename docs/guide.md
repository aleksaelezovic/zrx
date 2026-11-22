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
- [Time](#time)
- [Input and output](#input-and-output)
- [Compressed input and output](#compressed-input-and-output)
- [Directories](#directories)
- [Text patterns](#text-patterns)
- [Math](#math)
- [Text](#text)
- [Bytes](#bytes)
- [HTTP](#http)
- [The process](#the-process)
- [Collections](#collections)
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
app.run(.{ io, logger });
```

`program` describes the work. `run` constructs fresh stage state each time
and uses the source and dependencies supplied by the caller.

`run` returns nothing. What a program produces is an effect of a stage in
its pipe, and what fails it is taken inside it: by an error path in the
pipe, or by the [`rescue`](#the-failure-of-a-run) among its bindings. A run
that could still fail with something nobody takes does not compile, and the
error names what is left.

```zig
const report = program(source, .{
    queue(32),
    fold(0, add),
    print(Report, "{d}\n"),
}).provide(.{
    fileWriter(Report, path, 4096, .{ .mode = .create_new }),
});

report.run(.{ io, rescue(fatal) });
```

`provide` gives a program *defaults*: bindings that `run` uses unless it is
given one that provides the same type. It is not a second kind of
dependency: `p.provide(a).run(b)` runs with everything in `b` and with the
bindings of `a` whose type `b` does not provide. Among the defaults, and among what `run` is
given, a type has one provider; a second one is a compile error. The
resulting environment is shared by the source and all stages, including
branch and route cases.

A binding is a value, which provides its own type, a *resource*, or a
[`rescue`](#the-failure-of-a-run).
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
app.run(.{ io, config });
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
system(.{ ingest, report }).run(.{ io, &mailbox, rescue(fatal) });
```

`system` runs its programs together with the same bindings and returns when
all have finished. What it is given replaces a default of the same type in
each program, and a resource among it is acquired once, around all of them. The first failure cancels the others and ends the system; a
program that had ended before that has released its resources. A system is itself runnable,
so systems nest. With more than one program, each runs as a task of its own,
so the `Io` must be able to run tasks concurrently; with one that cannot,
the run fails with `error.ConcurrencyUnavailable`. A system of several
programs can therefore always fail, and is run with a rescue.

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
| `recover(E, path)` | | A failure of the operators after it, with an error in `E`, goes down `path` as a `Failed(E, T)`. |

The state of `scan` and `fold` has the type its reducer declares for it.
Where the reducer declares none (an `anytype` parameter, a composite
handler), the state has the type of the seed: `fold(@as(u64, 0), total)`
accumulates in a `u64`. A number written without a type, `0`, has none to
give. A composite reducer can say what it accumulates the items in (see
[Writing your own](#writing-your-own)), as those of [`ext.math`](#math)
do, and `0` is then a value of that;
with any other reducer it is a compile error that says to write
`@as(T, seed)`. `reduce` reads its seed the same way.

Flow:

| Operator | Effect |
|---|---|
| `queue(n)`, `queue(&slots)` | Bounded buffer between two tasks. Pass a comptime capacity or a mutable array pointer. Needs `std.Io`. |
| `concurrent(n, sub)` | Shares items among `n` worker-local copies of a synchronous pipe, with serialized unordered output. Accepts an operator tuple or `pipe(...)`; needs `std.Io`. |
| `batchWithin(n, duration)` | Emits `Batch(T, n)` when full or after the first item's maximum age. Needs `std.Io`. |
| `debounce(duration)` | Emits the latest pending item after a quiet period. Needs `std.Io`. |
| `branch(.{ pipe, pipe })` | Terminal. Every item goes to every sub-pipe. |
| `route(.{ when(p, pipe), otherwise(pipe) })` | Each item goes to the first case that takes it. A case whose predicate finds a value is given it with the item. |

Within one item:

| Operator | Effect |
|---|---|
| `each(source_of, sub)` | Runs a fresh `sub` over the source that `source_of(deps..., item)` returns, and emits what `sub` emits, paired with the item. See [each](#each). |
| `attempt(sub, E, path)` | Runs `sub`; when it fails for an item with an error in `E`, what `path` makes of the `Failed(E, T)` goes on in its place. See [Errors](#errors). |

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

A predicate answers `bool`, or an optional when it *finds* something in the
item. An optional is read as the condition of `if (x) |found|` is: null is
no, and a value is yes, with what was found. The pipe of such a case is
given a `Found(T, Item)`: `.found` is the value and `.item` the item it was
found in.

```zig
/// What an order saves when it has a discount, or nothing.
fn discount(order: Order) ?u32 { ... }

fn reduced(discounted: zrx.Found(u32, Order)) u32 {
    return discounted.item.cents - discounted.found;
}

route(.{
    when(discount, .{map(reduced)}),
    otherwise(.{map(field(.cents))}),
}),
fold(0, add),
```

An optional has this meaning where a predicate is asked for a case, and in
`require` and at the end of `all` (see
[Handler combinators](#handler-combinators)). Elsewhere it is a value like
any other: `map` with a handler that returns `?T` emits optionals, and
nothing is dropped. `filter`, `takeWhile`, `not` and `any` have nowhere to
send what was found and reject such a predicate.

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
| `not(p)`, `all(.{ p, q })`, `any(.{ p, q })` | Predicate logic; `all` and `any` stop at the first decisive predicate. `all` answers what its last predicate answers: when that one finds a value, so does `all`. |
| `compose(.{ f, g })` | `g(f(item))`, left to right. |
| `orElse(f, fallback)` | `f(item)`, or `fallback(deps..., err, item)` when `f` fails. |
| `require(p, err)` | The item when `p(item)` is true, the error `err` when it is not. With a predicate that finds a value: what it found, or `err`. |
| `reduce(seed, f)` | Folds the elements of an array, slice or batch item with `f(deps..., state, element)`; `seed` for an empty one. |
| `field(.name)` | The field `name` of a struct item. |
| `constant(value)` | `value`, whatever the item. |
| `eq(v)`, `ne(v)`, `lt(v)`, `le(v)`, `gt(v)`, `ge(v)` | Comparison with a comptime value. |

```zig
const isHot = compose(.{ field(.celsius), gt(80) });
const wanted = all(.{ isHot, not(isMuted) });
```

A predicate that finds a value (see [route](#route)) goes last in `all`, with
the predicates that must be true first before it, and `require` turns
"nothing found" into an error:

```zig
/// The discount of an order that is paid: for `when`.
const paidDiscount = all(.{ isPaid, discount });
/// The discount, or a failure for an error path to take: for `map`.
const discountOf = require(discount, error.NoDiscount);
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

A handler that returns an error fails the run. `run` returns nothing, so
somebody has to take that error, and the compiler checks that somebody does.
What a run can fail with is inferred from your handlers and the operators
you used: a program whose handlers cannot fail and that starts no task can
fail with nothing, and is run as it is.

There are three ways to handle an item's error instead, and one for a
failure of the run itself (see [below](#the-failure-of-a-run)). To keep the item as a value
of your choosing, wrap the handler: `map(orElse(parse, rejected))` calls
`rejected(deps..., err, item)` when `parse` fails and passes its result on.
`require` goes the other way, from a value to an error:
`map(require(isPlausible, error.InvalidReading))` fails an item that
`filter(isPlausible)` would drop without a trace.

When what fails is not one handler but several operators, the failure
becomes an item and is sent down an *error path*, a pipe of its own. A
`Failed(E, Item)` is that item: `.err` is the error, and `.item` the item as
it was where the failure was caught. Two operators catch one.

`attempt(sub, E, path)` keeps the item. When `sub` fails for an item with an
error in `E`, the failure goes down `path`, and what the path emits goes on
in place of what `sub` would have.

```zig
/// A file that cannot be hashed is still a row.
fn failed(failure: zrx.Failed(anyerror, []const u8)) Row { ... }

const manifest = pipe(.{
    concurrent(4, .{attempt(hashed, anyerror, .{map(failed)})}),
    forEach(save),
});
```

- `E` selects what the path takes: an error set takes its members and lets
  every other error of `sub` fail the run; `anyerror` takes everything.
  `error.Canceled` is never taken, so a set that holds nothing else is a
  compile error, as is one none of whose errors `sub` can fail with. What
  the path takes is no longer among what the run can fail with.
- The path emits what the sub-pipe emits. It keeps its state for the whole
  stream and has an end of the stream of its own, after the sub-pipe's. A
  path that wants no more ends the stream; a path that fails fails the run.
- A handler that names its failure names it exactly: the `E` of the
  operator and the item's own type. `anytype` takes any.
- What the sub-pipe had already emitted for the item is not taken back, and
  its stages keep whatever state the item gave them.
- A failure of the pipe *after* the `attempt` is neither the sub-pipe's
  nor the path's. It fails the run as it would without the `attempt`,
  whichever of the two was emitting, for an item or at the end of the
  stream; the path is not asked, and a `recover` inside either does not
  see it.
- The sub-pipe keeps its state for the whole stream, like a case of a
  `route`. A failure at its end of the stream does not belong to an item and
  fails the run.
- Neither the sub-pipe nor the path can contain a task boundary: a failure
  beyond one happens on another task.

`recover(E, path)` takes the item out of the pipe. Put it before the
operators that may fail: when one of them fails for an item with an error in
`E`, the item leaves the pipe and the failure goes down `path` instead, a
terminated pipe with stages, state and an end of the stream of its own.

```zig
const Rejected = zrx.Failed(ParseError, []const u8);

fn described(rejected: Rejected) Rejection { ... }

/// Where a line that did not parse goes instead.
const rejections = pipe(.{
    map(described),
    print(zrx.Stderr, "{f}\n"),
});

pipe(.{
    recover(ParseError, rejections),
    map(parse),
    map(validate),
    forEach(save),
})
```

What the path does with a failure decides how it ends:

| The path | The stream |
|---|---|
| takes the failure | goes on without the item. |
| wants no more (a `take(1)` at its start: report the first failure) | ends as it ends anywhere, and the run succeeds. See "Stopping early". |
| fails (a handler in it returns an error, its own or `failed.err`) | fails the run with that error. |

- `E` selects what the path takes: an error set takes its members and lets
  everything else through; `anyerror` takes everything. What the path takes
  is no longer among what the run can fail with.
- `error.Canceled` is never sent down a path. A write that was interrupted
  because the run is being cancelled is: `std.Io.Writer` reports it as
  `error.WriteFailed` like any failed write.
- The path cannot contain a task boundary.
- A `recover` guards what comes *after* it, up to the next task boundary
  (`queue`, `batchWithin` or `debounce`). Errors on the far side happen in
  another task and fail the run.
- A value that a stage *before* the `recover` emits at the end of the stream
  (a final `fold` value) is an item like any other. Errors of a later
  stage's own end of stream do not belong to an item and
  fail the run.
- Nothing is rolled back: stages between the `recover` and the failure keep
  whatever state the item already gave them.

### The failure of a run

Some failures belong to no item: a source that cannot read, a flush at the
end of the stream, a resource that cannot be acquired, anything beyond a
task boundary. An error path cannot take them. They go to the `rescue`
among the bindings:

```zig
const Exit = enum(u8) { ok, failed };

/// Whatever ends the run: a line on stderr and a status for `main`.
fn fatal(diagnostics: zrx.Stderr, exit: *Exit, err: anyerror) void {
    exit.* = .failed;
    diagnostics.writer.print("fatal: {s}\n", .{@errorName(err)}) catch return;
    diagnostics.writer.flush() catch {};
}

const app = program(source, records).provide(.{
    rescue(fatal).provide(.{stderr(256)}),
    fileWriter(Accepted, path, 4096, .{ .mode = .create_new }),
});
```

`rescue(handler)` is a binding, the third kind beside a value and a
resource. `handler(deps..., err)` is called once with the failure and
returns nothing: it is the last to be given it. What a failed run leaves
behind is an effect of the handler, such as the status above, which `main`
returns:

```zig
pub fn main(init: std.process.Init) u8 {
    var exit: Exit = .ok;
    app.run(.{ init.io, &exit });
    return @intFromEnum(exit);
}
```

- A rescue stands outside the run. It is called when the run is over and
  everything the run acquired has been released, whichever resource or
  stage failed, and wherever the rescue is written among the bindings:
  above, the file is closed before `fatal` is called.
- Its handler is given the plain values of the run (`io` and `&exit`
  above) and what the rescue is given for itself with `provide`, which is
  acquired for the call and released after it. A resource of the run is
  gone by then: a handler that asks for one is a compile error, which says
  to give the rescue its own.
- What the rescue is given for itself must be there when it is needed: if
  acquiring it could fail, that failure would be left over, and the run
  would not compile. A value given to `run` replaces it like any default,
  so a test hands the handler a writer of its own.
- The handler's error parameter says what it takes: `anyerror`, an error
  set that holds every error the run can fail with, or `anytype`, with
  which it is given exactly those errors, so that a `switch` over them is
  checked by the compiler. For a run that cannot fail it is not checked
  at all: a program's rescue stays valid when a test replaces the one
  resource that could fail.
- A cancellation is given to it like any failure. An error path never takes
  one, because it is no item's, but this is where the run ends. The request
  to cancel is used up by then: a handler whose caller is itself a task that
  must stay cancellable calls `io.recancel()` for it.
- A run has one rescue. Given to `run`, it replaces the one a program
  provides; given to a `system`, it takes the failure that ends the system,
  in place of the members' own.

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
the run fails with `error.Canceled` under the rules in
[what a run guarantees](#what-a-run-guarantees), and its rescue is given that. Without a boundary or a
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
Pass the `std.Io` the producer is given: `run` signals through that one,
and a wait on another may not be woken.
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
- **On an error**, the run fails with it: its rescue is given the error. A
  segment may already have finished or may be cancelled part-way through
  finishing.
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

## Time

`zrx.ext.time` holds what can be said about time without a task: a source
that ticks, a handler that gives an item its time, and an operator that
drops the items that come too soon. It is an extension: written against the
source, handler and operator contracts, and compiled only when a program
uses it.

```zig
const time = zrx.ext.time;

const heartbeat = program(time.ticks(.fromSeconds(30)), .{
    map(time.stamp(.real)),
    forEach(report),
});

const alerts = pipe(.{
    time.throttle(.fromSeconds(5)),
    forEach(notify),
});
```

| | |
|---|---|
| `time.ticks(period)` | Source: a count, `u64`, every `period`. |
| `time.stamp(clock)` | Handler: the item with the time on `clock`, as `time.Stamped(T)`. |
| `time.throttle(window)` | Operator: passes an item, then drops the ones within `window` of it. |

All three take the time from the `std.Io` of the run. Periods and windows
are positive comptime `std.Io.Duration` values measured on `.awake`, as for
`batchWithin` and `debounce`.

### ticks

`ticks(period)` pushes 0 one period after it starts, 1 a period after that,
and so on: tick `n` is due `n + 1` periods after the start. Those times are
fixed when the source starts, so a pipe that takes its time does not make
them drift.

- **A late tick is skipped, not caught up.** A push returns when the pipe is
  through with the tick. A tick whose time has passed by then is not pushed,
  and its number is missing from the count: 0, 3, 4 says that two were
  skipped. One that is due just then is pushed at once.
- **It pushes the count, not the time.** `map(time.stamp(clock))` gives a
  tick its time, on the clock you choose.
- **It has no end of its own.** It ends when a push answers `.done`, as
  after `take(n)`. It also asks for [`zrx.Stop`](#stopping-a-producer-when-its-consumers-finish),
  so behind a task boundary it ends where it waits once its consumers are
  done, without another tick. Cancelling the run interrupts the wait, or
  the next push where every tick is due and there is no wait, and
  `error.Canceled` is all the source can fail with.
- **It starts no task.** Without a boundary the program is one loop on the
  task that called `run`, and that task is the one that waits.

Its wait is `stop.waitTimeout(io, timeout)`: `stop.wait` with an end,
`error.Timeout` when the time is over or it was woken for nothing. A
producer of your own that waits for a deadline can use it the same way,
with the deadline read from the same `io`.

### stamp

`map(time.stamp(.real))` emits `time.Stamped(T)`: the fields `at`, a
`std.Io.Timestamp`, and `item`. The clock is always given. `.real` is the
time of day, as nanoseconds since 1970, and can jump when the system's clock
is set; `.awake` only goes forward and is the one to measure with.

```zig
fn report(log: *Log, beat: time.Stamped(u64)) void {
    log.add(beat.item, beat.at.toSeconds());
}
```

The time is read when the item reaches the `map`. Behind a `queue` that is
when the item is taken out, not when it was put in: stamp before the
boundary to say when an item arrived. It is not a `Tagged`, whose field
says where an item came from.

### throttle

`throttle(window)` passes an item and drops the ones that arrive within
`window` of it. The window starts with an item that passed: a dropped item
does not extend it, and an item that arrives just as it ends passes and
starts the next. The first item of a run always passes.

It keeps nothing, so the last item of a burst is dropped and nothing is
emitted at the end of the stream. That is what tells it from `debounce`,
which keeps the latest item and emits it once the input has been quiet, and
needs a task to do so. `throttle` has no task and no buffer: it reads the
clock once per item, on the task that pushes. Each place it is written has a
window of its own, so each case of a `route` and each worker of a
`concurrent` throttles by itself.

### How far time is counted

`ticks` and `throttle` count time in 63 bits of nanoseconds on `.awake`:
from 0 to about 292 years of a clock that starts with the system. Nothing
at the ends of that range is a fault, and nothing there fails the run.

- **A period or window longer than the range is a compile error.**
- **A clock outside the range is read as its nearest end.** Past the limit
  the clock stands still for both.
- **A time later than the limit never comes.** A window that would end
  later never ends: nothing passes after the item that started it. A tick
  due later is never pushed: `ticks` waits for it as for any tick, until
  its consumers are done or the run is cancelled. A window that ends at the
  limit ends there, and a tick due at the limit is pushed.

`stamp` counts nothing: it hands on what the clock says, in the 96 bits of
`std.Io`.

### Testing with a clock

[`zrx.testing.Clock`](#testing-timed-operators) covers these: `ticks` waits
on `.awake` with a timed wait, which `waitingAt` sees, and `stamp(.awake)`
and `throttle` read `.awake`. `stamp(.real)` reads the real clock.

```zig
try clock.waitingAt(.fromSeconds(10));
clock.advanceTo(.fromSeconds(10));
try std.testing.expectEqual(0, try seen.ticks.getOne(io));
```

A program without a boundary runs on the test's own task, so a handler can
set the time each item arrives at: `tap(arrive)`, with the clock among the
dependencies and `clock.advanceTo` in the handler.
[`tests/time.zig`](../tests/time.zig) does both.

### What it costs

`stamp` and `throttle` each have a fixture (`same_time_stamp`,
`same_time_throttle`): the same instructions as a loop by hand that reads
the same clock. Reading the clock is a call through the `std.Io` in both.
`throttle` keeps the time of the item that passed in 64 bits, and holding
the clock to [the range](#how-far-time-is-counted) is two comparisons for
each item, in the loop by hand as well. The reasons, and what was measured,
are in [the time spec](spec-time.md).

### Not here

`timeout`, `delay` and `sample` are not here. A timeout has to end a run
whose source is waiting, which is stopping it from outside: that is proposed
in [the segments spec](spec-segments.md#stopping-from-outside) and not
there yet. `delay` holds items until their time and `sample` emits while
its input is silent, so each is a task boundary of its own, and the stage
contract is not to grow for them. A throttle that emits the last item of a
window instead of the first is `debounce`'s kind of operator for the same
reason. The time between two items needs nothing new: `map(time.stamp(.awake))`
and a `scan` over the pairs.

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
| `ext.json.decode(T, options)` | Handler: the `T` a text is the JSON of. See [Decoding JSON](#decoding-json). |
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
  If the path already exists at publication, the run fails with
  `error.PathAlreadyExists`.

Each file is published atomically. With several published files, the last
one acquired is named first, following resource release order: of the files
in one tuple, the one written last. If naming one
fails, the run fails with that error and the files published earlier stay in place.

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
app.run(.{ io, fileReader(Input, input_path, max_line + 1), ... });
// in a test:
app.run(.{ Input{ .reader = &fixed }, ... });
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

### Decoding JSON

`json.decode(T, options)` from the extension `zrx.ext.json` is the handler
that goes the other way: `map` a text with it and the item is the `T` that
text is the JSON of.

```zig
const json = zrx.ext.json;

const Record = struct { id: u64, action: Action, resource: zrx.Line(96) };

/// Where a line that is not a record goes instead.
const rejections = pipe(.{
    map(described),
    print(zrx.Stderr, "{f}\n"),
});

const archive = pipe(.{
    recover(json.DecodeError, rejections),
    map(json.decode(Record, .{ .scratch = 2048 })),
    map(json.encode(.{})),
    write(Archive, "{f}\n"),
});
```

The item is a text: a `[]const u8`, or a value that reads its text with
`text()`, as a `Line` does. Where the text is part of an item, put the
handler that yields it first: `compose(.{ field(.body), json.decode(T, options) })`.
A text is one whole document. Reading is `std.json.parseFromSlice`'s, with
what that takes and refuses: a number may be written as a string, an enum
by its name or its number, a field that is absent takes its default, and a
field `T` does not have is an error unless the options say otherwise.

The options are always given. `.scratch` has no default; `.parse` is
`std.json.ParseOptions`, as in
`json.decode(Record, .{ .scratch = 2048, .parse = .{ .ignore_unknown_fields = true } })`.

**What is decoded is a value.** An item goes from stage to stage as a
value, so nothing in a `T` may point into the text, nor into the memory
`std.json` read it with: both are gone when the handler returns. A `T`
with a pointer anywhere in it does not compile. Write

- text as a `zrx.Line(n)`, a copy of at most `n` bytes. `std.json` reads a
  line as it writes one, like a byte slice: from a string, or from an array
  of numbers. A text of more than `n` bytes is `error.LengthMismatch`;
- several values as an array, `[3]f32`, of exactly that many;
- a type of your own with `std.json`'s hook, `jsonParse`. It must be a
  value as well.

A `Line` is read so by `std.json` itself, wherever it is used: from text
(`parseFromSlice`, through `jsonParse`) and from a `std.json.Value`
(`parseFromValue`, through `jsonParseFromValue`). It was read before as
the object of its two fields, `{"bytes":[...],"len":3}`, which is now
`error.UnexpectedToken`; write such a line as its string or as the array
of its bytes.

**The scratch memory is bounded, and you say by how much.** `.scratch` is a
number of bytes on the stack that `std.json` may use while it reads one
text; every text is read with all of it. One that needs more fails with
`error.OutOfMemory`, an error of that item like any other. How much a text
needs depends on the text and on the target: `std.json` keeps a bit for
each level of nesting in a list that begins at about a cache line (64 or
128 bytes), and copies there every text that is written with an escape or
as an array of numbers, in a list that begins as large again. A number
alone needs none. When in doubt, give it a few hundred bytes and twice the
longest text.

**Its errors are `std.json`'s**, and `json.DecodeError` names them all, so
`recover`, `attempt` and `orElse` take them by name:

| | |
|---|---|
| `SyntaxError`, `UnexpectedEndOfInput` | The text is not one JSON document. An empty text ends too early; anything after the document is a syntax error. |
| `UnexpectedToken`, `MissingField`, `UnknownField`, `DuplicateField` | It is JSON, and not the shape of a `T`. |
| `InvalidEnumTag`, `InvalidNumber`, `InvalidCharacter`, `Overflow`, `LengthMismatch`, `ValueTooLong` | A value in it is not one the field holds: a name the enum does not have, a fraction or a word where an integer goes, a number that does not fit, a string that is not the length of its array or too long for its line, a value longer than `.parse.max_value_len`. |
| `OutOfMemory` | The text needs more scratch memory than `.scratch`. |

`decode` costs what `std.json` costs: its parser is called once for an
item and is not inlined, so `decode` is not among the handlers the
[zero-overhead check](#how-zero-overhead-is-checked) compares.

Not there: a decoder that reads a document piece by piece as it arrives, a
document that spans several items (the pieces of `fileBytes`, or one
object written over several lines), and any format but JSON. A text is
whole before it is decoded.

## Compressed input and output

The extension `zrx.ext.compress` makes a compressed stream a matter of
bindings. A program reads `lines(Input, n)` and writes `write(Output, ...)`
as before; what is bound to those roles decides whether the bytes on the
other side are plain or compressed.

```zig
const compress = zrx.ext.compress;

const Input = struct { reader: *std.Io.Reader }; // what the pipe reads
const Packed = struct { reader: *std.Io.Reader }; // the compressed bytes

const app = program(lines(Input, max_line), work);

// a plain file:
app.run(.{ io, fileReader(Input, "access.log", max_line + 1), ... });
// a gzip file:
app.run(.{
    io,
    fileReader(Packed, "access.log.gz", 4096),
    compress.gzipReader(Input, Packed, max_line + 1),
    ...
});
```

| | |
|---|---|
| `gzipReader(Role, From, n)` | Binds as `Role` the plain bytes of the gzip stream read from `From`, buffered by `n` bytes. |
| `zlibReader(Role, From, n)` | The same for a zlib stream (RFC 1950). |
| `zstdReader(Role, From, n, window)` | The same for a Zstandard stream. `window` is a `[]u8` of yours that the decoder works in. |
| `gzipWriter(Role, Into, options)` | Binds as `Role` a writer whose bytes reach `Into` as a gzip stream. `options.level` is `.default`, `.fastest`, `.best` or `.level_1` to `.level_9`. |
| `zlibWriter(Role, Into, options)` | The same for a zlib stream. |

Each of these is a [resource](#programs-and-systems) that needs one role and
provides another, so it is acquired after whatever provides the role it
needs, wherever the two are written. Two roles are needed because a type has
one provider: the same role on both sides is a compile error that says so.
What provides the compressed side is anything that provides a reader or a
writer: `fileReader`, `fileWriter`, `stdout`, or a value of your own in a
test. `n` is what it is for `fileReader`: for `lines`, the line limit plus
one. The reader of the compressed bytes may have any buffer. Nothing here
allocates.

Reading:

- Every member of a gzip stream is read, one after another, as `gzip -d`
  does, and every frame of a Zstandard stream: both are read to the end of
  their input.
- A zlib stream is one stream, and what follows it is not read. Once the
  stream has been read to its end, what follows is still in a reader of
  your own if that reader has a buffer of 4 bytes or more. One with less is
  read 4 KiB at a time, and what was read past the end of the stream is
  gone.
- A header is checked before anything after it is decoded. A gzip header
  with a reserved flag set, and a zlib header whose check bits are wrong or
  that asks for a preset dictionary, fail the read.
- Once a gzip member or a zlib stream has been read to its end, the
  checksum, and for gzip the length, that it declares are compared with
  what was read.
- A pipe that is done before its input ends, after `take(1)` say, reads no
  further. What it did not read is not checked, and where the reader of
  the compressed bytes then stands is not said.
- A stream that is cut short, is corrupt, does not match its checksum, or
  (gzip) is followed by bytes that are no member fails the read, and with it
  the run, with `error.ReadFailed`: the error of any reader given to
  `lines`, so a gzip or zlib input adds no error to a run. The lines decoded
  before the failure have been delivered. A file of no bytes is no gzip and no
  zlib stream.
- A line longer than `n - 1` bytes is `error.StreamTooLong`, as for a file.
- A Zstandard frame that needs a larger window than `window` has room for,
  or a dictionary, fails the read. The checksum of a frame's content is not
  compared, because `std` does not do it yet: content that was altered and
  still decodes is delivered as it is.

The memory a Zstandard decoder works in is too large for the stack, so it
is yours to give, and it is not allocated for you. It holds one block,
`std.compress.zstd.block_size_max` (128 KiB), and in what is left the
window: the largest a frame may ask for.
`std.compress.zstd.default_window_len`, 8 MiB, is what the format
recommends every decoder to accept; `zstd --long` writes frames that need
more.

```zig
const zstd = std.compress.zstd;

var window: [zstd.block_size_max + zstd.default_window_len]u8 = undefined;

app.run(.{
    io,
    fileReader(Packed, "access.log.zst", 4096),
    compress.zstdReader(Input, Packed, max_line + 1, &window),
    ...
});
```

A slice with no room for a window, one of `block_size_max` bytes or less,
fails the run with `error.ZstdWindowTooSmall` before anything is read: the
one error a Zstandard input adds to a run. The slice is the binding's while
a program runs, so two runs at the same time need two.

Writing:

- The end of the stream, with its checksum, is written once everything the
  binding wraps has returned without an error, and `Into` is then flushed.
  Writing it can fail, so it is part of the run and not of a release: the
  run fails with `error.WriteFailed`.
- When what the binding wraps fails, the stream is left without its end,
  and reading it back fails. A failure after that, in writing the end or in
  another binding, may leave the whole stream behind.
- Under a `fileWriter` in `.publish` mode the end is written before the
  file is given its name, so a file that was named holds the whole stream.
  Publication is atomic per file, not per run, as for any
  [published file](#input-and-output).
- Use `write`, not `print`. A flush of the compressed role ends a block and
  does not reach `Into`, so flushing every item costs compression and shows
  nobody the item.
- `Into` needs a buffer of at least 9 bytes; with less, the run fails with
  `error.CompressedBufferTooSmall` before anything is written.

```zig
const Output = struct { writer: *std.Io.Writer };
const Archive = struct { writer: *std.Io.Writer };

program(source, .{
    map(json.encode(.{})),
    write(Output, "{f}\n"),
}).provide(.{
    fileWriter(Archive, "events.jsonl.gz", 4096, .{ .mode = .publish }),
    compress.gzipWriter(Output, Archive, .{}),
});
```

What each binding holds while the program runs, beside the buffer of `n`
bytes:

| | |
|---|---|
| `gzipReader`, `zlibReader` | 64 KiB of window and 4 KiB of compressed bytes, on the stack. |
| `zstdReader` | The slice it is given, and 4 KiB of compressed bytes on the stack. `std`'s decoder puts another 256 KiB on the stack of the task that reads. |
| `gzipWriter`, `zlibWriter` | 64 KiB of window, which is the writer's buffer, and 225 KiB of compressor state, on the stack. A Debug build copies the compressor as it is made and was measured at 741 KiB. |

The codecs are `std.compress`'s, and zrx has none of its own. So there is
no Zstandard compression, which `std` does not have, and no xz: `std`'s
decoder keeps the whole decompressed stream in memory (22 MB for a text of
14.6 MB when it was measured) and compares no checksum. Raw deflate and
LZMA streams, which are rarely files of their own, are left out. Archives
(`tar`, `zip`) are a different thing, a stream of files and not of bytes,
and are not part of this extension.

Why it is built this way, and what was measured, is in
[the design record](spec-compress.md).

## Directories

`zrx.ext.fs` makes a directory a source, so that "every file under this
directory" is where a program begins and not a loop before it. It is an
extension: two sources written against the public contract, compiled only
when a program uses them.

```zig
const fs = zrx.ext.fs;

const max_path = 1024;
const max_depth = 16;
const isFile = compose(.{ field(.kind), eq(.file) });

const files = program(fs.walk("src", max_path, max_depth), .{
    filter(isFile),
    map(field(.path)),
    print(Stdout, "{f}\n"),
});

files.run(.{ io, stdout(4096) });
```

| | |
|---|---|
| `fs.entries(path, n)` | Source: the entries of the directory at `path`. Needs `std.Io`. |
| `fs.walk(path, n, depth)` | Source: the entries under it, through at most `depth` directories one inside the other. Needs `std.Io`. |
| `fs.Entry(n)` | The item of both: `path`, a `Line(n)`, and `kind`, a `std.Io.File.Kind`. `entry.name()` is the last name of the path. |

- **The directory is named by its path**, as a file is for `fileLines`. It
  is opened when the source runs and closed when the source ends: at the
  end of the listing, when the pipe is done, and when something fails. A
  `walk` closes every directory it is inside of on each of those ways out.
  The source keeps a copy of the path, so the text it was made from need
  not outlive the call.
- **An entry holds its path**, up to `n` bytes inline, so it may cross a
  `queue` or wait in a `batch`. The path begins with the directory's as it
  was given, then the system's separator and the names below:
  `fs.walk("src", n, depth)` gives `src/ext/fs.zig`. It therefore opens from
  where the directory was opened: `Io.Dir.cwd().openFile(io, entry.path.text(), .{})`
  in a handler. `.` and `..` are not entries, and neither is the directory
  itself. No separator is put after one (`src/` gives `src/ext`), nor on
  Windows after a drive alone: `C:` is the directory the process is in on
  that drive, so it gives `C:name` and not `C:\name`, which is in the
  drive's root.
- **`n` is the longest path.** A longer one fails the run with
  `error.PathTooLong`; so does a directory whose own path is longer, before
  it is opened. A handler is given its entry as a value, which is a copy of
  those `n` bytes, so choose `n` for the paths you expect and not the
  longest the system allows.
- **A path too long to open fails the run.** A `walk` goes into one
  directory at a time and can reach deeper than a path can name. An entry
  whose path `std` would not open, of `std.fs.max_path_bytes` bytes or
  more, fails the run with `error.NameTooLong`, as opening it would, so an
  `n` beyond that buys nothing. On Linux and macOS every entry given before
  it opens; on Windows, which counts a path in UTF-16, that is not tested.
- **`kind`** is what the listing says the entry is: `.file`, `.directory`,
  `.sym_link` and the rest of `std.Io.File.Kind`. Where a file system's
  listing does not say, the source asks the entry itself, at one more system
  call for it, so a directory is not missed for want of an answer.
- **The order is the system's.** It is not sorted, and it need not be the
  same on another system or after a change to the directory. One thing
  holds in a `walk`: a directory comes before what is in it.
- **A symbolic link is an entry of kind `.sym_link` and is not followed**,
  whatever it points to, so a walk stays under its directory and cannot go
  round in a circle. The directory the source is given may itself be a
  link. On Linux and macOS a directory that has become a link by the time
  the walk opens it fails the run (`error.SymLinkLoop` or `error.NotDir`,
  as the system has it). On Windows that is not tested.
- **`depth` is how many directories a `walk` may be inside of at once**,
  the one it is given being the first: `fs.walk(path, n, 1)` lists that
  directory and has no room for one in it. A directory deeper than that
  fails the run with `error.TooDeep`, after it was given as an entry, so a
  pipe that is done at that entry does not fail. A depth of 0 is a compile
  error.
- **Neither source allocates.** A `walk` keeps the listing of each directory
  it is inside of on the stack of the task that runs the source, with room
  for `depth` of them from the start: 2096 bytes each on Linux and macOS and
  2104 on Windows with Zig 0.17.0, so about 34 kilobytes for a `depth` of
  16, however deep the tree turns out to be. Nothing is kept for an entry.
- **A source that nothing more is wanted of ends**: when a push answers
  `.done`, and also when the pipe has completed beyond a task boundary and
  no push is there to say so (it asks for [`zrx.Stop`](#stopping-a-producer-when-its-consumers-finish)),
  as when a `filter` before a `queue` lets nothing more through.

A directory that cannot be opened or read fails the run with what the system
reported, such as `error.AccessDenied`, or `error.FileNotFound` for one that
was removed meanwhile. In a `walk` that is after the directory itself was
given as an entry. Nothing is left out silently: a walk that skipped a
directory would look like a whole one. This is a failure of the source, so
it belongs to no item and goes to the [rescue](#the-failure-of-a-run), not
to an error path.

To have an error path take one directory, make the directory an item. Both
sources can be the source of an [`each`](#each), and may be made from an
entry. Here every directory at the top is walked for itself, and one that
cannot be is a row like the others:

```zig
const isDirectory = compose(.{ field(.kind), eq(.directory) });

fn under(directory: fs.Entry(max_path)) fs.Walk(max_path, max_depth) {
    return fs.walk(directory.path.text(), max_path, max_depth);
}

fn sized(directory: zrx.Tagged(fs.Entry(max_path), usize)) Row { ... }

fn unread(failure: zrx.Failed(error{AccessDenied}, fs.Entry(max_path))) Row { ... }

/// directory -> everything under it -> how many -> a row
const counted = pipe(.{
    each(under, .{fold(@as(usize, 0), count)}),
    map(sized),
});

const rows = program(fs.entries(root, max_path), .{
    filter(isDirectory),
    attempt(counted, error{AccessDenied}, .{map(unread)}),
    forEach(report),
});
```

What fails is then the item's whole walk: a directory that cannot be read
three levels down fails the top directory it is under. Going on past it
within one walk is not there.

`fileLines` and `fileBytes` borrow the path they are given, where these two
sources copy it. Do not make one of them from `entry.path.text()` in a
`source_of`: that handler is given a copy of the entry, which is gone when
it returns. Open the file in a handler instead.

Not there: watching a directory for changes, matching names against a glob
(a `filter` whose handler looks at `entry.name()` does it), following
links, sorting, and anything about an entry beyond its kind, such as its
size or its times.

## Text patterns

`zrx.ext.pattern` says what a text looks like, as a value built from parts,
and what to take out of it. It is an extension: handlers written against the
public contract, compiled only when a program uses them.

```zig
const pattern = zrx.ext.pattern;
const seq = pattern.seq;
const oneOf = pattern.oneOf;
const repeat = pattern.repeat;
const optional = pattern.optional;
const extract = pattern.extract;
const int = pattern.int;

/// A line of the log: four columns between tabs.
const record = seq(.{
    extract(.ts_ms, int(u64)),
    "\t",
    extract(.level, oneOf(.{ "info", "warn", "error" })),
    "\t",
    extract(.service, repeat(oneOf(.{ pattern.alnum, pattern.set("-_") }), .{ .min = 1 })),
    "\t",
    extract(.latency_ms, int(u32)),
    optional("\r"),
});

fn slowest(worst: u32, entry: pattern.Extracted(record)) u32 {
    return @max(worst, entry.latency_ms);
}

const report = pipe(.{
    recover(error{InvalidRecord}, rejections),
    map(require(record, error.InvalidRecord)),
    fold(@as(u32, 0), slowest),
    print(zrx.Stdout, "{d}\n"),
});
```

A pattern is a handler, as `gt(80)` is: a predicate on one item that is
text, a `[]const u8` or a [line](#lines-and-values). It holds when the
pattern describes the *whole* text, not a part of it. What it answers
depends on whether it extracts:

- A pattern without `extract` answers `bool`: `filter(service_name)`.
- A pattern with `extract` finds a value (see [route](#route)). It answers
  `?Extracted(pattern)`, a struct with a field for each `extract`. `require`
  turns that into the struct or an error, as above. A case of a `route` is
  given it with the text: `when(record, .{ ... })`. It goes last in `all`,
  and after the handler that yields the text in `compose`.

| | |
|---|---|
| `"text"` | A string among the parts of a pattern is that text. |
| `set("-_")`, `between('a', 'f')`, `except(set)` | One byte: any of those named, any from the first to the last, any that the set is not. |
| `byte`, `digit`, `lower`, `upper`, `alpha`, `alnum` | One byte: any, or of that ASCII class. |
| `seq(.{ a, b })` | Each part, one after the other. |
| `oneOf(.{ a, b })` | The first choice that matches. |
| `oneOf(.{ .x = a, .y = b })` | The same, with [names](#choices-with-names): extracted, a tagged union that says which one matched. |
| `repeat(p, .{ .min = 1, .max = 3 })` | `p` as often as it matches, between `min` (0 unless given) and `max` (no limit unless given) times. |
| `optional(p)` | `p`, or nothing where it does not match. |
| `int(T)` | A decimal number that fits the integer type `T`, with a `-` before it when `T` is signed. |
| `as(T, p)` | `p`, kept as a `T` that `T.from(text)` makes: a `Line(32)`, or a type of your own. A text `from` fails for does not match. |
| `extract(.name, p)` | `p`, with what it matched kept under `name`. |
| `recursive(rule, .{ .depth = 4 })` | A [rule that holds itself](#a-rule-that-holds-itself), to a depth of 8 unless one is given. |
| `Extracted(pattern)` | The type of what a pattern extracts. A handler that names its item writes it; `anytype` takes it too. |

The struct is read off the pattern. A field is the matched text
(`[]const u8`), or a `T` where the part is an `int(T)` or an `as(T, ...)`.
It is optional where
its `extract` is inside `optional` or `oneOf`, and null when that part is not
in the text. The text of a field points into the item: use it while the item
lives.

A number that does not fit its type does not match. So a pattern never
holds for a text whose numbers it could not hand out.

### Lines and values

Text extracted from a `[]const u8` points into it. That is right for a text
that stays where it is, and wrong for a `Line`: a line is a value that holds
its bytes, a handler is given it by value, and a piece of its text lives
no longer than the call. So a pattern put to a line extracts values, and an
`extract` that would keep a piece of its text does not compile.

`as(T, p)` keeps what `p` matched as a `T`, made by `T.from(text)`.
`Line(n).from` copies up to `n` bytes, which makes `as(Line(32), p)` a text
of at most 32 bytes held as a value. A text that is longer does not match,
as a number that does not fit does not.

```zig
const Service = zrx.Line(32);

/// The words of the format, as what they stand for.
const Level = enum {
    info,
    warn,
    failure,

    pub fn from(word: []const u8) error{UnknownLevel}!Level { ... }
};

const record = seq(.{
    extract(.ts_ms, int(u64)),
    "\t",
    extract(.level, as(Level, repeat(pattern.lower, .{ .min = 1 }))),
    "\t",
    extract(.service, as(Service, repeat(oneOf(.{ pattern.alnum, pattern.set("-_") }), .{ .min = 1 }))),
    "\t",
    extract(.latency_ms, int(u32)),
    optional("\r"),
});

/// What a record holds, read off the pattern: `{ ts_ms: u64, level: Level, service: Service, latency_ms: u32 }`.
const Entry = pattern.Extracted(record);

const report = pipe(.{
    recover(error{InvalidRecord}, rejections),
    map(require(record, error.InvalidRecord)),
    queue(64),
    fold(@as(u32, 0), slowest),
    print(zrx.Stdout, "{d}\n"),
});

program(fileLines(path, 128), report)
```

- Every field is a value, so what was extracted crosses a `queue`, waits in
  a `batch` and is kept by a `fold` like any item.
- `T` is any struct, enum or union with
  `pub fn from(text: []const u8) !T` (or one that returns a `T` and cannot
  fail). Use it for the words of a format, as `Level` above.
- The text `from` is given lives only as long as the item. A `T` with a
  pointer anywhere in it is taken to point into that text, whatever its
  `from` does: it can be extracted from a `[]const u8`, and from a `Line`
  it does not compile. A `T` that is to be a value has no pointer in it.
- `as` is not only for lines. It makes a value of text from any item, such
  as a name from a request's path that has to outlive the request's head.
- A case of a `route` is given the values with the line they were taken
  from: `.found` and `.item`.
- A line that came with something else, such as the `Tagged` of
  `mergeTagged`, is reached through its field:
  `when(compose(.{ field(.item), record }), .{ ... })`.
- Any value that reads its text with `pub fn text(*const T) []const u8` is
  taken as a `Line` is.

A copy costs what it copies. An item goes from stage to stage as a value,
and whether the optimizer takes a copy out depends on the pipe. There is no
rule to give, only what was measured: the copies of a `Line(120)` in the
code of these pipes over a slice of lines, compiled optimized for aarch64.

| Pipe | Copies |
|---|---|
| `filter`, `map`, `forEach`, the handlers reading only the length | none |
| The same with one handler that scans the bytes, a function or a pattern | the line, once |
| The same with three handlers that read the bytes | the line once, and once more for an item the first filter lets through |
| `batch(128)`, `flatten()`, then a handler reading only the length | the line once, into the buffer, and the buffer once for each batch that is emitted |
| Items that are references, `*const Line(120)`, with a handler that scans | none |

Another pipe may differ. No test holds these counts. Two fixtures are
related examples, each with a `Line(32)`: `lean_pattern_line` is a pipe of
the second kind, with its copy on both sides of the comparison, and
`same_line_reference` one of the last kind. What a fixture holds is said
under [How zero overhead is checked](#how-zero-overhead-is-checked).

A pattern is put to text, not to a pointer. Where the items are references
to lines, put the handler that yields the text before it:

```zig
const Row = zrx.Line(120);

// The items are `*const Row`.
filter(compose(.{ Row.text, service_name }))
```

A reference is good only while what it names is there, which is why the
line sources push values: a value can cross a `queue`.

### Choices with names

`extract(.name, oneOf(.{ a, b }))` keeps the text that matched, whichever
choice it was. Give the choices names and what is kept says which one:

```zig
const Word = zrx.Line(16);

const token = extract(.token, oneOf(.{
    .number = int(u32),
    .word = as(Word, repeat(lower, .{ .min = 1 })),
    .dash = "-",
}));

// Extracted(token) is:
//   struct { token: union(enum) { number: u32, word: Word, dash: void } }

fn describe(found: pattern.Extracted(token)) u32 {
    return switch (found.token) {
        .number => |number| number,
        .word => |*word| @intCast(word.len),
        .dash => 0,
    };
}
```

A choice holds what it keeps: its value where it is one (`int`, `as`), a
struct of its own where it has `extract`s inside, and nothing (`void`)
otherwise. A choice that is only text, such as `"-"`, holds nothing: wrap
it in `as` to keep it. Matching is what it is without names: the first
choice that matches is taken for good. Not extracted, choices with names
only match.

### A rule that holds itself

A group in parentheses may hold another group; a triple term may hold
another triple term. Such a rule is written as a function of `self`, the
rule one level further in, and `recursive` makes the pattern of it:

```zig
const recursive = pattern.recursive;

/// `(a(b(c)))`: letters, and groups of them in parentheses.
fn group(comptime self: type) type {
    return seq(.{
        "(",
        repeat(oneOf(.{ lower, self }), .{}),
        ")",
    });
}

const nested = recursive(group, .{ .depth = 4 });
```

A pattern is a value and cannot contain itself, and nothing here calls
itself as deep as a text asks. `recursive` builds the rule `depth` times,
each from the one further in, and the innermost `self` describes nothing.
So the depth is written, 8 unless you say otherwise, and it is not the
text's to choose: a text nested deeper does not match, and the rule does
not call itself, so how deep a text nests does not decide how much stack
is used.

**What a level extracts is a struct of its own.** An `extract` in the rule
is a field of its level, not of the pattern around it, so the same names
at every level do not clash. `self` is a value like an `int`: as a choice
with a name it is the level further in.

```zig
/// `<a b>`, or `<a <b c>>`: a name, then a word or another of these.
fn term(comptime self: type) type {
    return seq(.{
        "<",
        extract(.name, as(Word, repeat(lower, .{ .min = 1 }))),
        " ",
        extract(.object, oneOf(.{
            .inner = self,
            .word = as(Word, repeat(lower, .{ .min = 1 })),
        })),
        ">",
    });
}

const nested_term = recursive(term, .{ .depth = 3 });

// "<a <b c>>" is found as:
//   .name = "a",
//   .object = .{ .inner = .{ .name = "b", .object = .{ .word = "c" } } }
```

- A rule is a part like any other. `extract(.said, nested_term)` keeps its
  outermost level under `said`; without an `extract` it is matched and
  nothing of it is kept; `as(Line(64), nested_term)` keeps its text.
- Put to a text alone, a rule that extracts answers the struct of its
  outermost level, which is also `Extracted(nested_term)`.
- The struct has a size, known when the program is compiled: nothing is
  allocated. Each level holds the next, so the size grows with the depth,
  and doubles with each level where a rule holds itself in two places.
- Each level is a type of its own. A handler that walks them is generic,
  and at the innermost level the choice of `self` holds a `void` and is
  never the one that matched. Take a pointer, so that the text of a value
  is read where the value is:

  ```zig
  /// The word a term ends in, however deep.
  fn lastWord(level: anytype) []const u8 {
      if (@TypeOf(level.*) == void) return "";
      return switch (level.object) {
          .word => |*word| word.text(),
          .inner => |*inner| lastWord(inner),
      };
  }
  ```
- `self` can be extracted by itself too, `extract(.inner, self)`: inside a
  `oneOf` without names that is an optional field of the level.
- A rule needs a way to end. One that holds itself whatever it describes,
  such as `seq(.{ "(", self, ")" })`, does not compile.
- The depth is a bound set when the program is compiled: a deeper rule is
  a larger program, each level being code of its own. What it costs in
  time has been measured on one kind of text only, where eight levels took
  what three did. That is a measurement, not a promise for every rule.

The [N-Quads check](../examples/apps/nquads-check/README.md) reads the
triple terms of RDF 1.2 this way.

### How a pattern matches

From left to right, and what has matched is not given back:

- `repeat` takes as much as it can and gives nothing back.
- `oneOf` takes its first choice that matches, for good.

That is the scanner one writes by hand. It is *not* a regular expression,
which goes back and tries again:
`seq(.{ repeat(lower, .{ .max = 3 }), "x" })` does not hold for `abx`,
because the `repeat` took the `x`. End a `repeat` before the byte that
follows it: `repeat(except(set("/")), .{})`.

Where a pattern can be seen never to match for that reason, it does not
compile: a part that begins only with bytes the `repeat` before it has
taken, a choice behind another that is its beginning (`"info"` before
`"information"`), a choice behind one that always matches.

Patterns work on bytes. A string holds whatever bytes it holds, UTF-8
included; the sets and classes are single bytes.

### What a pattern costs

What follows a part that matches begins where that part ended. A part that
does not match has been read for nothing: the next choice of a `oneOf`, and
what follows an `optional`, begin where it began. Mostly that is a byte or a word. It adds up where such
a part reads far before it fails and stands inside a `repeat`, which reads
it again in every round:

```zig
const shout = seq(.{ repeat(lower, .{ .min = 1 }), "!" });
const slow = repeat(oneOf(.{ shout, lower }), .{});
```

On a text of letters, `shout` reads to the end, finds no `!`, and `lower`
takes one letter; the next round does the same from one letter further.
That is the square of the length: twice the text takes four times as long.
Nothing rewrites a pattern for you, so write what the choices share once:

```zig
const fast = repeat(seq(.{ repeat(lower, .{ .min = 1 }), optional("!") }), .{});
```

It describes the same texts in linear time: twice the text takes twice as
long. Where the shared part cannot be written once, bound how far the choice reads before it fails.
`.max` does that only where what is repeated has a length of its own, a
byte or a string: it counts rounds, not bytes.

```zig
// Fails after at most 17 bytes: 16 letters, and the one that is no `!`.
const short = seq(.{ repeat(lower, .{ .min = 1, .max = 16 }), "!" });
// One round, which still reads to the end of the letters.
const long = repeat(shout, .{ .min = 1, .max = 1 });
```

Either way, bound the length of a text that comes from outside before a
pattern is put to it.

## Math

`zrx.ext.math` is arithmetic on the items of a pipe. It is an extension:
handlers over `std.math`, written against the public contract and compiled
only when a program uses them. It has no operator.

```zig
const math = zrx.ext.math;

/// Latencies in milliseconds: the total of the seconds, none over an hour.
const report = pipe(.{
    map(math.div(1000)),
    map(math.clamp(0, 3600)),
    fold(0, math.sum),
    print(zrx.Stdout, "{d}\n"),
});
```

Items are integers or floats. For a number inside a struct, take it out
first: `compose(.{ field(.cents), math.div(100) })`.

### Transforms

A transform changes one item. Its operand is known at compile time, as the
value of `gt(80)` is, and has to be a value of the items' type. An integer
is never converted: `add(-1)` does not compile for unsigned items, nor
`mul(100000)` for `f16` items, which hold no whole number that large. A
float is rounded to a float type as Zig rounds a literal, so `add(0.1)` is
what it is for an `f32`.

| | |
|---|---|
| `add(n)`, `sub(n)`, `mul(n)` | `item + n`, `item - n`, `item * n`. |
| `div(n)` | The item divided by `n`. Between integers the result is rounded toward zero (`@divTrunc`), which is what `/` does where Zig takes it. |
| `mod(n)` | `@mod(item, n)`: what is left over a multiple of `n`, never negative. `n` is greater than 0. |
| `pow(n)` | The item multiplied by itself `n` times over. `n` is a whole number that is not negative; `pow(0)` is 1. |
| `clamp(lo, hi)` | The item, or the bound it is beyond. |
| `abs` | `@abs(item)`: of a signed integer, the unsigned integer of its size, so the smallest value has a result. |
| `neg` | `-item`, for signed integers and floats. |

`div` and `mod` are not a pair for a negative item: `-7` divided by 2 is
`-3`, and `-7` modulo 2 is `1`.

An operand that can never work does not compile: `div(0)`, `mod(0)`, a
bound of `clamp` above the other, NaN. That is asked of the operand as the
items' type has it and not as it was written: `div(1e-10)` does not compile
for `f16` items, for which it is 0, nor `add(1e300)` for `f32` items, for
which it is infinite.

These are the plain operators, and an overflow is what it is for `+`: a bug
that a safe build stops at and a fast one does not look for. Where an
overflow is a possibility of the data, use the [checked](#checked) forms.

### Reducers

A reducer takes the state and an item and returns the state. One reducer
serves three places:

```zig
fold(0, math.sum)          // one total, at the end of the stream
scan(0, math.sum)          // the running total, after every item
map(reduce(0, math.sum))   // the total of each array, slice or batch
```

That is why there is no operator that adds up a stream: it would be a
second way to write the first line, and none for the other two.

| | |
|---|---|
| `sum`, `product` | The items added up, or multiplied: `fold(0, sum)`, `fold(1, product)`. |
| `min`, `max` | The smallest and the largest. |
| `count` | How many items there were, whatever they are. |

The state has the type of the seed. A seed written without a type takes
the reducer's: the type of the items, and a `usize` for `count`. To
accumulate in a wider type, give the seed one. It has to hold every item:

```zig
fold(@as(u64, 0), math.sum)   // u32 items, a u64 total
```

**The seed takes part like an item, and it is what a stream without items
comes to.** For `sum` and `product` that is unremarkable: 0 and 1 change
nothing. For `min` and `max` it decides the answer:

```zig
fold(0, math.max)                        // right for items that are not negative
fold(std.math.maxInt(u32), math.min)     // the largest value changes no minimum
fold(0, math.min)                        // always 0: the seed is the smallest
fold(@as(?u32, null), math.min)          // null until there is an item
```

With a state that is an optional, `min` and `max` have no value before the
first item, and a stream without items comes to null. That optional is a
value like any other (see [route](#route)): nothing is dropped, `scan` emits
every state, and what comes after decides what null means.

### Checked

`math.checked` holds the forms that can overflow, returning
`error.Overflow` where the plain form would overflow: `add(n)`, `sub(n)`,
`mul(n)`, `pow(n)`, `neg`, `sum` and `product`. Their items are integers. The error is the item's, so
everything in [Errors](#errors) applies to it:

```zig
const checked = math.checked;

fn largest(_: error{Overflow}, _: u32) u32 {
    return std.math.maxInt(u32);
}

map(orElse(checked.mul(1000), largest))   // kept, as the largest value

pipe(.{
    recover(error{Overflow}, rejections), // or sent down a path, with the item
    map(checked.mul(1000)),
    fold(0, checked.sum),
    print(zrx.Stdout, "{d}\n"),
})
```

Nothing else is there, because nothing else can fail. A division by zero
does not compile, `abs` returns a type that holds every result, and the
one division that overflows, the smallest value of a signed type by -1, is
`checked.neg`.

### Stats

`Stats(T)` keeps four values as items of type `T` pass: `count`, `min`,
`max` and `mean`. `T` is a float or an integer of at most 128 bits. It is
a state with a reducer of its own, used like any:

```zig
const Latency = math.Stats(u32);

const summary = pipe(.{
    fold(Latency{}, Latency.add),
    map(json.encode(.{})),
    print(zrx.Stdout, "{f}\n"),
});
```

`mean` is a float (`f64` for integer items) and is the running mean, which
no number of items overflows. Before the first item `count` is 0, `mean` is
0, and `min` and `max` are the values every item replaces: the largest and
the smallest value of `T`, infinity for a float. Ask `count` whether there
was an item.

The mean of finite items is finite, also where two of them are too far
apart for their difference: the largest `f64` and its negative come to 0,
as do the smallest and its negative.
The mean of items that are all the same is that item. Otherwise it is
close to the sum divided by the count and not that to the last digit: it
is rounded once for each item, in its own type. That type decides how far
off it can be, so a `Stats(f32)` of many items is a rough mean, and
[the record](spec-math.md#stats) has what was measured. An integer item
beyond what an `f64` holds exactly is rounded before it is taken in.

Items that are not finite are counted like any. A NaN makes the mean NaN
from then on, and `min` and `max` pass over it. An infinity is the `min` or
the `max` and the mean, and the item after it makes the mean NaN.

### What it costs

The plain transforms, the reducers in all three places, the checked forms
and `Stats` have fixtures that are the same instructions as the loop by
hand; see [How zero overhead is checked](#how-zero-overhead-is-checked).
`abs` is `lean`: the same instructions, with a note about the range of its
result that the loop does not carry.

Not there: forms that wrap or saturate, a power that is not a whole
number, conversion between integers and floats, and vectors. A handler of
your own over `std.math` is a few lines; these return when something needs
them.

## Text

`zrx.ext.text` tidies a text item and takes it apart, with `std.mem` and
`std.ascii`. It is an extension: handlers and a source written against the
public contracts, compiled only when a program uses them.

```zig
const text = zrx.ext.text;

const Name = zrx.Line(32);

/// A row taken column by column: `name, cents`.
const Entry = struct {
    columns: u8 = 0,
    name: Name = undefined,
    cents: u32 = 0,

    fn column(entry: Entry, piece: []const u8) !Entry {
        var next = entry;
        switch (entry.columns) {
            0 => next.name = try .from(piece),
            1 => next.cents = try std.fmt.parseInt(u32, piece, 10),
            else => return error.TooManyColumns,
        }
        next.columns += 1;
        return next;
    }

    fn isWhole(entry: Entry) bool {
        return entry.columns == 2;
    }
};

const entries = pipe(.{
    recover(anyerror, rejections),
    each(text.split(","), .{
        map(text.trim(" \t")),
        fold(Entry{}, Entry.column),
    }),
    map(field(.item)),
    map(require(Entry.isWhole, error.MissingColumn)),
    forEach(save),
});

program(fileLines(path, 128), entries)
```

A line becomes a stream of its columns, and the columns one record. A line
that breaks a rule fails with the name of that rule, a name that is too long
(`StreamTooLong`) or an amount that is no number (`InvalidCharacter`) among
them, which the error path is given with the line.

| | |
|---|---|
| `text.trim(bytes)` | Handler: the item without the bytes named in `bytes` at its start and at its end. |
| `text.trimStart(bytes)`, `text.trimEnd(bytes)` | The same, at one end. |
| `text.toUpper`, `text.toLower` | Handlers: a line with its ASCII letters in that case. |
| `text.split(delimiter)` | For `each`: a source of the pieces between each `delimiter` and the next, the empty ones included. A text with `n` delimiters has `n + 1` pieces. |
| `text.tokenize(delimiters)` | For `each`: a source of the pieces that hold none of the bytes in `delimiters`. None is empty. |
| `text.whitespace` | The bytes `std.ascii` counts as whitespace, for `trim` and `tokenize`. |

The bytes to strip are always named: `text.trim(" \t")`, or
`text.trim(text.whitespace)`. A delimiter is a string also when it is one
byte. For `split`, several bytes are that sequence: `text.split(", ")`
divides `a, b,c` into `a` and `b,c`. For `tokenize` they are bytes any of
which separates: `text.tokenize(", ")` makes `a`, `b` and `c` of it.

Everything here works on bytes. The case is ASCII's: a byte that is no ASCII
letter is left as it is, the bytes of UTF-8 included.

### What a handler is put to

Where the bytes are decides what a handler takes and what it answers.

- A `[]const u8` points at bytes that stay where they are. `trim` answers a
  slice of the same bytes, which lives as long as they do.
- A [line](#lines-and-values) is a value that holds its bytes, a handler is
  given it by value, and a piece of its text lives no longer than the call.
  So `trim` put to a `Line(n)` answers a `Line(n)`: what is made of a value
  is a value, which crosses a `queue` like any other.
- Changing bytes needs bytes of one's own. `toUpper` and `toLower` are put
  to a line and answer a line. Put to a `[]const u8` they do not compile:
  copy the text into a line first.
- Where the items are references to lines (`*const Row`), put the handler
  that yields the text first, as [for a pattern](#lines-and-values):
  `compose(.{ Row.text, text.trim(" ") })` answers a slice of the line
  where it is.

```zig
/// A name from a slice, in upper case: `error.StreamTooLong` if it is longer.
const shouted = compose(.{ Name.from, text.toUpper });
```

A copy costs what it copies. [Lines and values](#lines-and-values) has what
was measured of the copies of a line, pipe by pipe, and that there is no
rule to give. Two fixtures are further examples, each with a `Line(32)`
and with its copies on both sides of the comparison: `same_text_trim_line`
and `same_text_upper`. Put to a `[]const u8`, nothing is copied:
`same_text_trim` is the loop over `std.mem.trim`.

### Pieces

`split` and `tokenize` are for [`each`](#each): what they answer for an item
is a source, and the sub-pipe runs over its pieces.

- The item is a `[]const u8`, or a struct `T` that reads its text with
  `pub fn text(*const T) []const u8`, as a `Line` does. Only a struct is
  taken: a union or an enum with such a `text` is a compile error. Text
  that is a field of the item is reached through it:
  `each(compose(.{ field(.tags), text.tokenize(" ") }), sub)`.
- A piece is a `[]const u8` that points into the item. For a `[]const u8`
  item that is its bytes, and the piece lives as long as they do. For a
  struct, such as a line, it is the struct as `each` holds it while it
  works on that item.
- **A piece of a struct is valid until the push of that item has returned,
  and no longer.** It is there in the sub-pipe; in what the `each` emits
  for the item, the last emission included, such as the final value of a
  `fold` in the sub-pipe that kept a piece; and in the stages after the
  `each` that the push runs through, up to the next task boundary. A
  caller that keeps a piece beyond that copies it.
- So, like a piece of [`fileBytes`](#input-and-output), it is not sent
  across a task boundary after the `each` (`queue`, `batchWithin`,
  `debounce`, `concurrent`), nor kept in a `batch` or in the state of a
  `fold` there. Nothing checks this. A boundary *inside* the sub-pipe is a
  compile error, as for any `each`.
- Make a value of what has to stay: a copy (`map(Name.from)`), a number, or
  a `fold` in the sub-pipe that puts the columns into a struct, as `Entry`
  above.
- What goes on after the `each` is a `Tagged(Item, T)`, the line with what
  the sub-pipe emitted: a `Line(n)` goes along with every value, until
  `map(field(.item))` leaves it behind.

### What is not here

A test of what a text looks like is a [text pattern](#text-patterns), which
describes the whole of it, and is not written a second time here:

```zig
const byte = pattern.byte;

/// The text is `GET`.
const is_get = seq(.{"GET"});
/// The text starts with `/items/`.
const under_items = seq(.{ "/items/", repeat(byte, .{}) });
```

Whether a text *ends* with some text, or holds it somewhere, is neither: a
`repeat` gives nothing back, so `seq(.{ repeat(byte, .{}), ".zig" })` does
not compile, and finding the places a pattern matches inside a text is not
there. Until one of the two is decided, that test is a handler of your own
over `std.mem.endsWith`. [The design record](spec-text.md) has the reasons.

Also not here: Unicode, in the classes or the case; a delimiter chosen while
the program runs (write a `source_of` of your own for it); and the other
forms `std.mem` has, such as splitting at any of several bytes while keeping
the empty pieces, or from the end.

## Bytes

`zrx.ext.bytes` is what a stream of byte pieces is turned into: a digest,
and the text of bytes. It is an extension: handlers written against the
public contract, on top of `std.crypto.hash`, `std.hash`, `std.fmt` and
`std.base64`, compiled only when a program uses them. It is not named after
cryptography: a CRC is none, and there are no ciphers, signatures or keys
here, and nothing that compares in constant time.

```zig
const bytes = zrx.ext.bytes;

const Sha256 = bytes.digest(std.crypto.hash.sha2.Sha256.init(.{}));

fn bytesOf(path: []const u8) zrx.FileBytes(read_bytes) {
    return fileBytes(path, read_bytes);
}

/// The pieces of a file -> one digest -> its 64 hexadecimal digits
const checksum = pipe(.{
    fold(Sha256{}, Sha256.update),
    map(Sha256.final),
    map(bytes.hex(.lower)),
});

/// path -> its bytes -> their checksum -> a row
const hashed = pipe(.{
    each(bytesOf, checksum),
    map(described), // is given a zrx.Tagged([]const u8, [64]u8)
});
```

| | |
|---|---|
| `digest(start)` | A type: the state of a `fold` over pieces, for the hasher `start`. `State{}` is the seed, `State.update` the reducer, and `State.final` the handler that finishes a state into its digest. |
| `hex(.lower)`, `hex(.upper)` | Handler: bytes as hexadecimal digits. |
| `base64(codecs)` | Handler: bytes as Base64, in an alphabet of `std.base64` such as `std.base64.url_safe_no_pad`. |
| `fromHex(n)` | Handler: the `n` bytes that `2 * n` hexadecimal digits stand for, or a `HexError`. |
| `fromBase64(codecs, n)` | Handler: the `n` bytes a Base64 text stands for, or a `Base64Error`. |

### Digests

`digest` is given the hasher as its own `init` starts it, because hashers
are started in different ways: `Sha256.init(.{})` takes options,
`std.hash.XxHash64.init(seed)` a seed, `std.hash.Crc32.init()` nothing. What
it returns is a struct with one field, `hasher`, that begins as `start`.

- **A hasher is told by its shape**, not by a list of names: it has
  `update(*H, []const u8)`, and a `final` that returns the digest, an
  unsigned integer, or fills it into a `*[n]u8`, or into a `[]u8` that is
  given `digest_length` bytes. Nothing else is a digest: a `final` that
  returns a `bool` or a signed number, or one that can fail, is refused, and
  so is an `update` that returns something, and an output with a sentinel,
  an alignment or a qualifier of its own. That is, of `std.crypto.hash`:
  `Md5`, `Sha1`, the hashers of `sha2` and `blake2`, `Blake3`,
  `AsconHash256`, and of `sha3` `Sha3_224` to `Sha3_512`, `Keccak256`,
  `Keccak512`, `Shake128`, `Shake256`, `TurboShake128`, `TurboShake256`,
  `CShake128`, `CShake256`, `TupleHash128`, `TupleHash256`, `KT128` and
  `KT256`; and of `std.hash` the CRCs, `Fnv1a`, `Wyhash` and the three
  `XxHash`. A hasher of your own with that shape is taken too.
- **A `TupleHash` hashes a tuple**: every piece is one element of it, so its
  digest is of the pieces as they came, and not of their bytes alone.
- **Not a hasher here**: `std.hash.Adler32`, which has no `final`;
  `Murmur` and `CityHash`, which hash one text and are not fed in pieces;
  `AsconXof128`, which squeezes an output of any length and has no
  `final`; and
  `sha3.KMac128` and `KMac256`, whose length is a `mac_length` and not a
  `digest_length`.
- **The digest is what the hasher's own `final` returns or fills**: an
  array of bytes for those of `std.crypto.hash`, an unsigned integer for
  those of `std.hash`. An
  integer is written in hexadecimal by its format, not by `hex`:

  ```zig
  const Crc32 = bytes.digest(std.hash.Crc32.init());

  const crc32 = pipe(.{
      fold(Crc32{}, Crc32.update),
      map(Crc32.final),
      print(zrx.Stdout, "{x:0>8}\n"),
  });
  ```
- **A stream without pieces has a digest too**: `fold` emits its seed, and
  the digest is that of no bytes. Inside `each`, every item has a state of
  its own, as with any `fold` there.
- **The state is a value.** A struct of your own can hold one and update it
  with the reducer, to keep something else along with it:

  ```zig
  /// The running digest of one file, and how many bytes it had.
  const Hash = struct {
      sha: Sha256 = .{},
      bytes: u64 = 0,

      fn update(hash: Hash, piece: []const u8) Hash {
          return .{ .sha = Sha256.update(hash.sha, piece), .bytes = hash.bytes + piece.len };
      }
  };
  ```
- **A reducer is given its state as a value and returns one.** For a hasher
  whose state is a number, such as a CRC, nothing is left of that: the
  fixture `same_checksum` is the instructions of the loop by hand. For one
  that holds bytes it has yet to hash, the state is copied out and back for
  every piece: `same_digest` shows two copies of the 112 bytes of a SHA-256
  for each piece, and has them in the loop by hand as well so that it
  compares the rest. That is paid per piece, not per byte, so read large
  pieces, and look at the size of the state: measured on aarch64, a
  `Blake3` state is 1920 bytes and a `KT128` state 82560.

### The text of bytes

`hex` and `base64` are `map` handlers. What they return depends on whether
the length of the item is known when the program is compiled:

- **An array becomes an array**: a `[32]u8` becomes a `[64]u8` with `hex`,
  and with `base64` an array as long as the alphabet makes it. It is a value:
  it crosses a `queue`, and as a field of a row `std.json` writes it as a
  string.
- **A `[]const u8` or a [line](#lines-and-values) becomes a value that holds
  the item** and is written with `{f}`, as what `json.encode` returns is.
  Nothing is allocated. A line is held as a copy, so the value crosses a
  `queue`; a `[]const u8` is still that slice, and lives as long as it did.

```zig
const names = pipe(.{
    map(bytes.base64(std.base64.url_safe_no_pad)),
    write(Names, "{f}\n"),
});
```

`std` formats bytes by itself where they are the item that is printed: a
`[n]u8` or a `[]const u8` is written in hexadecimal by `{x}` or `{X}` and in
standard Base64 by `{b64}`, so a digest that is only printed needs no
`hex`: `print(Role, "{x}\n")`. The handlers are for the text as a value, for
a line, and for another alphabet.

### Decoding

`fromHex(n)` and `fromBase64(codecs, n)` return a `[n]u8`: the number of
bytes is written, so the result is a value. The item is text: a
`[]const u8`, a line, or an array.

| Error | When |
|---|---|
| `error.InvalidLength` | The text is not as long as `n` bytes make it. Its length is looked at before its characters are. |
| `error.InvalidCharacter` | It holds a byte that is no hexadecimal digit (of either case), or not of the alphabet. |
| `error.InvalidPadding` | Base64 only: the text has a length no text of its alphabet has, is not padded as the alphabet has it, or its last character leaves bits over. |

`bytes.HexError` and `bytes.Base64Error` name those sets, for an error
path:

```zig
const expected = pipe(.{
    recover(bytes.HexError, rejections),
    map(bytes.fromHex(32)),
    forEach(compare),
});
```

An array item whose length can never be `n` bytes does not compile.

Not there: decoding a text into as many bytes as it happens to stand for.
That result has no length known when the program is compiled, so it would
be a slice into a buffer somebody has to own. Encoding the pieces of a
stream as one Base64 text is not there either: three bytes make four
characters, and a group may begin in one piece and end in the next.
(Hexadecimal has no such groups: `write(Role, "{x}")` over the pieces of a
file is the hexadecimal text of the file.)

## HTTP

`zrx.ext.http` serves HTTP/1.1 with `std.http.Server`. It is an extension: a
source, an operator and some handlers written against the public contracts,
compiled only when a program uses it.

```zig
const http = zrx.ext.http;

const api = pipe(.{
    recover(anyerror, .{http.fail()}),
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
        recover(http.Disconnected, .{drain()}),
        http.serve(api),
    }),
}).provide(.{http.listen(address, .{ .reuse_address = true })});

server.run(.{ io, rescue(fatal) });
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
| `http.path(predicate)` | The path before `?`, put to a predicate of text such as a [text pattern](#text-patterns). See [Paths with parameters](#paths-with-parameters). |
| `http.fail()` | Terminal, in an error path in `sub`: answers a failed request with the status of its error. |
| `http.Disconnected` | The errors a connection that broke fails with. `recover(http.Disconnected, .{drain()})` before `serve` drops such a connection. |

`serve` constructs `sub` anew for every connection and finishes it when the
conversation ends without an error, so its stages hold per-connection state: with an inner
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
  request has none. A body has a length (see below for chunked ones). Its
  errors are `BadRequest` (a body on a method that takes none),
  `LengthRequired`, `PayloadTooLarge` (more than the buffer holds) and
  `ExpectationFailed`. It answers `Expect: 100-continue` itself, in any
  casing of that token.
- Reading the body overwrites the head. Read the path, query and headers
  first; call `body` at most once. Nothing else overwrites it while the
  push runs: an item that points into the head, such as the path, is still
  that when it is answered, and after.

### Paths with parameters

`http.path` takes a string, or a predicate of text that the path is put to.
With a [text pattern](#text-patterns) that extracts, the case is given what
the pattern found together with the request, as a `Found` (see
[route](#route)): `.found` is what was extracted and `.item` the request.

```zig
const pattern = zrx.ext.pattern;

/// `/items/42`
const item_path = pattern.seq(.{ "/items/", pattern.extract(.id, pattern.int(u32)) });

fn stored(item: anytype) !Receipt {
    var buffer: [4096]u8 = undefined;
    return store(item.found.id, try item.item.body(&buffer));
}

route(.{
    when(all(.{ http.method(.GET), http.path(item_path) }), .{
        map(compose(.{ field(.found), field(.id) })),
        map(lookup),
        http.json(),
    }),
    when(all(.{ http.method(.PUT), http.path(item_path) }), .{
        map(stored),
        http.json(),
    }),
    otherwise(.{http.status(.not_found)}),
})
```

- The predicate that finds goes last in `all`: the method is tested first,
  and the path is taken apart only for a request the case could take.
- A path that the pattern does not describe is the next case's. That
  includes a number that does not fit its type: `/items/4294967296` is not
  an item here, and is answered 404 like any path nobody takes.
- Text extracted from a path points into the head, as the path does. Read
  it before the body: reading the body overwrites the head (see
  [Requests](#requests)). A number is a value and stays.
- Nothing is percent-decoded before the path is put to the predicate.
- A string is a literal, a `[]const u8`, or a list of bytes
  `&.{ '/', 'x' }`. `http.path` took only a string before and gave its
  argument that type. It no longer does, so an expression that takes its
  type from where it stands has to name it: `http.path(@ptrCast(&chars))`
  is now `http.path(@as([]const u8, @ptrCast(&chars)))`.
- A path is as long as the request head allows, 8 KiB for a socket, and
  whoever sends the request chooses it. [What a pattern
  costs](#what-a-pattern-costs) says which patterns read such a text more
  than once.

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
and sends none.) A 205 has no content either: it is written with a length
of zero, whatever `send` was given.

An interim status (1xx) does not answer a request. `http.status` rejects
one at compile time, and `send`, given one at run time, answers 500 in its
place. `100 Continue` is sent by `request.body`, as above.

### Failures

`recover(anyerror, .{http.fail()})` at the start of `sub` turns a handler's
error into an answer and lets the connection go on:

| Error | Status |
|---|---|
| `error.BadRequest` | 400 |
| `error.NotFound` | 404 |
| `error.MethodNotAllowed` | 405 |
| `error.LengthRequired` | 411 |
| `error.PayloadTooLarge` | 413 |
| `error.ExpectationFailed` | 417 |
| anything else | 500 |

Without it, a handler's error fails the run like any other. The answers
that were completed before it are still written to the peer, unless the
error is a cancellation or the connection itself has failed.

A socket whose read or write failed is not read from or written to again,
also when nobody reported the failure: a handler took the error of `send`
or `body` and went on. An answer is not started on it either, however
large: `send` and the responders return the failure and write nothing. The
conversation ends there with `error.ReadFailed` or `error.WriteFailed`, or
with `error.Canceled` if that is what interrupted it. An `http.Transport`
has no such record: a failure that a handler took is not known to `serve`.

A connection goes on after an answer when the next request can be found: the
body was read to its end, or was not read and has a length. Such a body is
skipped once the pipe is through with the request, and its answer is
written first if the rest of the body has yet to arrive. A read that fails
there ends the conversation with `error.ReadFailed`, for a socket and an
`http.Transport` alike.

The connection is closed after an error of `body`, after an answer given
while the peer still waits for `100 Continue`, after any answer to an
HTTP/1.0 request (whose `Expect` is ignored), when the peer asks for it
with `close` among its `Connection` options, and when a body was left
unread that cannot be skipped: one without a length on `POST`, and one on
`GET`.

A head that does not parse is answered 400, and one that does not fit the
connection's read buffer (8 KiB for a socket) 431, by `serve` itself; then
the connection is closed. The same goes for a request whose `Host` is not
in order, before any handler sees it: an HTTP/1.1 request has exactly one
`Host`, an HTTP/1.0 request at most one, and its value is a host with an
optional port, or empty. The host is a name, in which a `%` introduces two
hexadecimal digits, or an IP address, which in brackets is an IPv6 address
without a zone.

`serve` also refuses, with 400 and before any handler sees it, a head
that a proxy in front of it could read differently, since the two would
then disagree on where the next request begins:

- a field name that is not a token, such as one with a space before its
  colon, and a line without a colon;
- a CR, LF or NUL inside a field value;
- an empty target, and a space or control character in one;
- a `Content-Length` that is not digits only;
- both a `Content-Length` and a `Transfer-Encoding`.

A request with a `Transfer-Encoding` is answered 411, before any handler
sees it: chunked request bodies are not read. Decoding them is `std`'s,
and its chunk reader accepts sizes that are no hexadecimal number and
overflows on one of 2^64 - 2 or more, which stops a program built with
safety checks. A client has to send a `Content-Length`. (A coding whose
name `std` does not know is a head that does not parse: 400.)

A connection that breaks fails its push with `error.ReadFailed` or
`error.WriteFailed`. `recover(http.Disconnected, .{drain()})` before `serve`
takes exactly these two, so one lost peer does not end the server and every other
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
a `recover` taking the failure of a stage the connection had not yet
left for `serve`) does not close it and does not free its place: it stays
open and counts as waiting until the run is over. So do not filter connections. Route the ones you will not serve to
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
with one write. An answer never waits for the rest of a request that
arrived in part.

For a connection that is not a socket, or in a test, give `serve` an
`http.Transport` instead: a reader and a writer of yours, which it flushes
and does not close.

```zig
const connection: http.Transport = .{ .reader = &reader, .writer = &writer };
program(fromValue(connection), .{http.serve(api)}).run(.{rescue(note)});
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
- `connections` finds out that the pipe is done at its next push, like any
  source. Behind a task boundary that can be late: after
  `queue(1), take(1), ...` has taken its one connection, the source still
  waits to accept another before it ends. Put a limit on connections before
  the boundary, where it ends the source at once: `take(n), concurrent(...)`.
  A failure to accept, other than a connection its peer already gave up,
  fails the run.
- To stop a server, cancel the task that called `run`: it returns
  `error.Canceled`, also from a read that was waiting for a request. Open
  conversations are cut off, not completed.

The [HTTP benchmark app](../examples/apps/http-bench/README.md) compares this
with a server written against `std` alone and records what was measured.

## The process

`zrx.ext.process` is the process a program runs in: its three standard
streams as bindings, and the status `main` returns. It is an extension:
bindings, a type and two handlers written against the public contract,
compiled only when a program uses them. Nothing in it allocates, and
nothing in it ends the process.

```zig
const process = zrx.ext.process;
const Stderr = process.Stderr;

const fatal = process.fail(.{ .status = 2, .prefix = "fatal" });

const app = program(lines(Input, max_line), .{
    recover(error{InvalidRecord}, .{forEach(process.status(1))}),
    map(parsed),
    print(Output, "{f}\n"),
}).provide(.{
    process.stdout(Output, 4096),
    rescue(fatal).provide(.{process.stderr(Stderr, 256)}),
});

pub fn main(init: std.process.Init) u8 {
    var exit: process.Exit = .{};
    if (input_path) |path| {
        app.run(.{ init.io, &exit, fileReader(Input, path, max_line + 1) });
    } else {
        app.run(.{ init.io, &exit, process.stdin(Input, max_line + 1) });
    }
    return exit.code;
}
```

### The standard streams

| | |
|---|---|
| `process.stdin(Role, n)` | Binds a reader of standard input as `Role`, buffered by `n` bytes. |
| `process.stdout(Role, n)` | Binds a writer to standard output as `Role`, buffered by `n` bytes. |
| `process.stderr(Role, n)` | Binds a writer to standard error as `Role`, buffered by `n` bytes. |
| `process.Stdin`, `process.Stdout`, `process.Stderr` | The roles the streams usually have: `stdout(Stdout, 4096)`. |

A stream is a binding like a file, and names its
[role](#input-and-output) first, as `fileReader` and `fileWriter` do. So
"this file, or standard input" is one program and a choice of binding:
`app` above reads `lines(Input, max_line)`, and `main` runs it with a
`fileReader(Input, ...)` or with `process.stdin(Input, ...)`. A program
that writes with `print(Output, ...)` goes to a file or to standard output
the same way. A test gives `run` a value of the role, an
`Input{ .reader = &reader }`, which replaces either.

- The choice is still an `if` around two runs. A binding is a type, so two
  of them cannot be one value. What is one is the program.
- With `lines`, the buffer of `stdin` needs room for the longest line and
  its newline, as with `fileReader`. A read that fails fails the run with
  `error.ReadFailed`, as with any reader given to `lines`.
- Nothing is flushed by the binding. `print` and `write` flush what they
  wrote, and `fail` flushes its line.
- The buffer is in the binding, for as long as the run lasts. `n` is a
  comptime size, and `0` is a writer without a buffer.
- The reader of `stdin` reads ahead, and what it has read past where the
  pipe stopped goes with the binding. A second run with a `stdin` of its
  own starts where the first one's reads stopped, not where its pipe did:
  after a `take(1)`, the next line may be gone in part or whole. Runs that
  read on from one another share a reader `main` makes, given to each as a
  value of the role:

```zig
var buffer: [max_line + 1]u8 = undefined;
var reader = std.Io.File.stdin().readerStreaming(init.io, &buffer);
header.run(.{ init.io, &exit, Input{ .reader = &reader.interface } });
body.run(.{ init.io, &exit, Input{ .reader = &reader.interface } });
```

The core has `stdout(n)`, `stderr(n)` and `stdinLines(n)` from before this
extension, and the roles are the same types under both names:
`zrx.stdout(n)` is `process.stdout(Stdout, n)`, and `zrx.stdinLines(n)` is
`lines(Stdin, n)` run with `process.stdin(Stdin, n + 1)`. One difference:
`stdinLines` owns its reader and fails with what the system reported,
where a failed read through a binding is `error.ReadFailed`.

### The exit status

`process.Exit` is `struct { code: u8 = 0 }`. A run returns nothing, so the
status is an effect: `main` gives `run` a `*process.Exit`, and whoever has
something to say about the outcome asks for it. Two handlers do:

| | |
|---|---|
| `process.status(n)` | Raises the status to at least `n` when an item reaches it. For `tap` or `forEach`, usually on an error path. |
| `process.fail(options)` | For the [rescue](#the-failure-of-a-run): sets the status and writes one line that names the error. |

`status(n)` says that the program finished, and not with everything: in
`app` above a record that is refused leaves status 1 and the run goes on.
It never lowers a status, so the order in which two of them are reached
does not matter. It writes through the `*Exit` like any handler that writes
through a dependency: put it where one task calls it, after a `concurrent`
and not in its workers. A status that depends on more than an item getting
there is a handler of your own:

```zig
fn judge(exit: *process.Exit, summary: Summary) void {
    if (summary.rejected * 2 > summary.seen) exit.code = 3;
}
```

`fail(options)` is given the failure of the run. It sets the status, writes
one line that names the error to `process.Stderr`,
`fatal: PathAlreadyExists` above, and flushes it. The options are always
given, `.{}` for the defaults:

| Option | Default | |
|---|---|---|
| `.status` | `1` | The status left in the `*process.Exit`, from 1 to 255. |
| `.prefix` | `"error"` | What the line begins with, as plain text. `null` writes nothing, and the handler then asks for no `Stderr`. |

The defaults are what Zig does with an error returned from `main`:
`error: OutOfMemory` and status 1.

- The status is set first, and it is set, not raised: the failure of the
  run decides it, whatever a `status` left. The line is best effort: a
  write or a flush that fails is dropped, and the status stands.
- The stderr is one the rescue is given for itself, as above: the run's own
  is released by the time a rescue is called, and asking for that one is a
  compile error. A test gives `run` a `Stderr{ .writer = &writer }`, which
  replaces it.
- The line holds the prefix, the name of the error and nothing else. A
  prefix with a control byte in it, such as a newline, is a compile error.
  A name declared in quotes can hold one, so every byte of the name that
  is not printable ASCII is written as `\xNN` (`std.ascii.hexEscape`): a
  newline in it as `\x0a`. An identifier is written as it is.
  A failure that should say more (which file, which line) is an item's:
  take it in the pipe with an error path, where the item is at hand.
- A cancellation is given to it like any failure and is written as
  `Canceled`. Nothing here calls `io.recancel()`, and nothing ends the
  process: `main` returns the status.

`fail` is a handler of one error, so it also ends a pipe whose item is one.
That is how a program says the same of what failed before there was a run,
such as a wrong number of arguments:

```zig
fn refuse(io: std.Io, exit: *process.Exit, err: anyerror) void {
    program(fromValue(err), .{forEach(fatal)}).run(.{ io, exit, process.stderr(Stderr, 256) });
}
```

`status` raises with the `@max` one writes where the item is seen. Bound as
a rescue, `fail` compiles to the store a loop by hand makes where it fails,
and its line to the `print` and `flush` one writes there
(`same_process_status`, `same_process_fail_silent` and `same_process_fail`
among the [fixtures](#how-zero-overhead-is-checked)).

### What is not in it

- The arguments. They are a source as they are: `fromSlice(args[1..])` for
  the slice `init.minimal.args.toSlice(arena)` returns, or
  `fromIterator(&iterator)` for `init.minimal.args.iterate()`. Which
  program to run for them is decided once, before any run, and is a
  `switch` in `main`. A typed parser of options and a usage text are a
  design of their own, and are not here.
- Environment variables. `init.environ_map` is a value `main` has: pass
  what a handler needs of it to `run`.
- Child processes.
- Signals. Ending a run on Ctrl-C needs a source that can be stopped from
  outside, which is [proposed](spec-segments.md#stopping-from-outside) and
  not there.

## Collections

`zrx.ext.collections` holds the operators that have to keep items: the keys
seen so far, a state for every key, the whole stream to put it in order.
Each keeps them in room whose size is written with it, as `queue(n)` and
`batch(n)` have theirs. None of them uses an allocator.

```zig
const collections = zrx.ext.collections;
const foldBy = collections.foldBy;
const top = collections.top;
const descending = collections.descending;

const Request = struct { service: Service, millis: u32 };

fn count(total: u64, _: Request) u64 {
    return total + 1;
}

/// The three services with the most requests, the busiest first.
const busiest = pipe(.{
    foldBy(64, field(.service), @as(u64, 0), count),
    top(3, descending(field(.item))),
    forEach(report),
});

program(requests, busiest).run(.{rescue(fatal)});
```

| Operator | Effect | Holds room for | When it is used up |
|---|---|---|---|
| `distinct(n, key)` | Passes an item the first time its key is seen. | `n` keys. | An item with one key more fails with `error.TooManyKeys`. |
| `foldBy(n, key, seed, f)` | `fold`, once for every key. When the stream ends, each key goes on with its state as a `Tagged(Key, State)`, in the order the keys were first seen. | `n` keys and a state for each. | An item with one key more fails with `error.TooManyKeys`. |
| `sorted(n, before)` | When the stream ends, every item, in order. | `n` items. | One item more fails with `error.TooManyItems`. |
| `top(n, before)` | When the stream ends, the first `n` items of the order, in order. | `n` items, and an arrival number with each. | Never: an item that comes before the last one kept takes its place. |
| `takeLast(n)` | When the stream ends, the last `n` items, as they came. | `n` items. | Never: an item takes the place of the oldest. |

`n` is known at compile time and is at least 1. `key` is a handler
`fn (deps..., item) Key`, `before` one that says which of two items comes
first, and `f` a reducer as `fold` takes one. None of the five is a task
boundary. `distinct` passes items on as they come; the other four push
nothing before the stream has ended, so the source runs to its end whatever
follows them, and a `take` after them stops what they push.

### Room

An item that does not fit fails where it is pushed, as it fails when a
handler returns an error for it. So the run fails with `error.TooManyKeys`
or `error.TooManyItems`, or an error path before the operator takes the
item and the stream goes on:

```zig
const unique = pipe(.{
    recover(error{TooManyKeys}, .{forEach(reportUnseen)}),
    distinct(1024, field(.id)),
    forEach(report),
});
```

What was kept stays as it was. After that, `distinct` still drops an item
whose key it has seen and `foldBy` still folds into a key that has a state;
every item that brings another key fails the same way. `sorted` fails every
later item, and pushes the `n` it kept in order when the stream ends.

The room is part of the operator's stage, and nothing is allocated for it.
It is `n` items for `sorted` and `takeLast`; `n` items for `top`, each with
an arrival number of two, four or eight bytes beside it; and for `distinct`
and `foldBy` `n` keys (and states) and between `2n` and `4n` places of one,
two or four bytes. It is there whole from the start of the run, used or
not, and a run that fails leaves nothing of it behind.

What that comes to in bytes depends on alignment and padding: an item of
`top` and its number take the alignment of the larger, so `top(1_500_000,
...)` over `u8` holds 12 MB where its items are 1.5 MB. Do not add it up;
ask the compiler. A pipe's stage is a type, by the operator contract
([Writing your own](#writing-your-own)), and its size is the room of its
operators with their counters:

```zig
const ranking = pipe(.{top(1_500_000, ascending(itself))});

// The tuple holds the types the handlers ask for: none here.
const bytes = @sizeOf(@TypeOf(ranking).Stage(@Tuple(&.{}), u8));
```

The stages of a program are on the stack of the task that calls `run`, also
those of a segment behind a `queue`: the tasks of the other segments work
on them there. The sub-pipes of `branch` and `route` and the workers of
`concurrent` have room of their own each, in the same place. Only a
sub-pipe of `each` is constructed where its item is pushed, on the stack of
the task that runs that segment.

All of that room has to fit on that stack, and nothing checks that it
does. Too much is not an error: the process usually ends with a fault where
the stack is first touched beyond its end, and even that is not promised.
Measured on macOS (aarch64), in Debug and in ReleaseFast, with
`sorted(n, ...)` over `u64` items, as a plain program, behind a `queue`,
inside `each`, and inside `each` behind a `queue`: room of 15 MiB ran in
all eight, and room of 16 MiB faulted in seven. The eighth, ReleaseFast
inside `each` behind a `queue`, ran to its end. 16 MiB is the stack Zig
gives the main thread of an executable there, and the one
`std.Io.Threaded` gives its threads
(`std.Thread.SpawnConfig.default_stack_size`). So the room of all the
operators of a program together stays well under the stack of the thread
that calls `run`: the size of each operator's stage, once for every copy of
it (every sub-pipe of a `branch` or `route` and every worker of
`concurrent` that holds it), and for `sorted` 512 items more, which `std`'s
sort keeps on the stack for itself while it sorts. For more, give the
executable a larger stack (`stack_size` in `build.zig`) or the threads of
the `Io` (`stack_size` in the options of `std.Io.Threaded`). Linux and
Windows were not measured, nor an `Io` that runs tasks on stacks of another
size.

### Keys

A key is kept after its item is gone and nothing is copied for it, so it is
a value:

- an integer, an enum, a `bool`, or a struct, array or optional of those,
  told apart by all of its parts;
- a value that reads its text with `text()`, such as a `Line`, told apart
  by that text.

A key with a pointer anywhere in it is a compile error, a `[]const u8`
included: what it points at may be gone when the next item comes. Key a
text by a value that holds it, `Line(64).from(text)`. A float is a compile
error as well. `collections.itself` is the key of an item that is its own
key: `distinct(1024, itself)`.

For `distinct`, a key counts as seen whatever became of its item further
down: if the item fails there and an error path takes it, a later item with
that key is still a duplicate. For `foldBy`, an item whose reducer fails
leaves no trace: its key keeps the state it had, and a key that had none
takes no room, however often it comes and is rejected.

When the keys are the tags of an enum, `fold` over a `std.EnumArray` does
what `foldBy` does.

### Orders

An order is a handler of two items that answers whether the first comes
before the second. It cannot fail: it is asked while items are put in
order, where a failure has nowhere to go.

```zig
sorted(1024, ascending(field(.millis))), // by a key, smallest first
sorted(1024, descending(itself)), // by the item, largest first
sorted(1024, nearer), // fn (deps..., a: Item, b: Item) bool
```

`ascending(key)` and `descending(key)` order by a key that is an integer, a
float, an enum (by the values of its tags) or text (byte by byte). Items of
which neither comes before the other keep the order they arrived in, in
`sorted` and in `top` alike.

A float that is not a number comes after every number, in `ascending` and
in `descending` alike: it is last both ways, not largest. Two of them keep
the order they arrived in. An order of your own has to be as consistent: if
neither of two items comes before the other, they have to stand at the same
place towards every third. `a < b` on floats is not that when a NaN can
come, and `sorted` and `top` then disagree.

`top(n, before)` emits what `sorted(m, before)` followed by `take(n)` emits.
It is there because it needs room for `n` items where that needs room for
all of them.

### What they cost

These operators hold a real buffer, as `queue` does:

- The room is as large as `n` says from the first item to the last. A
  table marks its places empty when its stage is constructed, which inside
  `each` is once for every item.
- An item is kept as the value it is. One that points elsewhere, such as a
  slice, is kept as that pointer, and what it points to has to live until
  the stream has ended.
- An order is a handler, so it is given its two items as values: for an
  item that holds its bytes, such as a `Line(n)`, that is two copies for
  each comparison.
- `distinct` and `foldBy` hash a key and walk a table for every item.
  `sorted` sorts once, at the end. `top` compares every item with the last
  one it keeps, and sifts a heap of `n` when the item takes that one's
  place.

All five are held to a loop by hand by
[`zig build zero-overhead`](#how-zero-overhead-is-checked): a loop with
arrays of the same size on its stack and its counters in locals. `takeLast`
is the same instructions. The other four are `lean`: `sorted` is one
instruction apart, inside `std`'s sort; `top` is the shorter of the two;
`distinct` and `foldBy` have their keys and places in one stack slot where
the loop has an array for each.

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
[`src/handlers.zig`](../src/handlers.zig). One that is a reducer may also
declare `State(Item) type`, the type it accumulates items of type `Item`
in. `scan`, `fold` and `reduce` ask for it when the seed is a number
without a type, as in `fold(0, total)`; a seed that has a type is the
state, and the declaration is not asked.

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
  no calls, no more stack slots, loads or stores than the hand-written one,
  and at most a quarter more instructions. Stack slots the hand-written
  loop has too are allowed, as in `lean_pattern_line`;
- a function that exists in only one variant fails, which is how a stage that
  was not inlined shows up.

[`behavior.zig`](../tests/zero_overhead/behavior.zig) runs both variants of each
case and requires equal results. The targets are fixed so the outcome does not
depend on the machine running the build.

Every synchronous operator has a fixture, and so have `rescue`,
`process.fail` and `process.status`. Forty-five are `same`; `take`,
`batch`, the handler combinators, `attempt`, a `recover` whose path has
stages of its own, the text patterns, `abs` of [`ext.math`](#math), `hex`
of [`ext.bytes`](#bytes) and four of the [collections](#what-they-cost) are
`lean`, each with the reason next to it.

The fixtures carry small items. An item goes from stage to stage as a
value, and for one that holds its bytes, such as a `Line(n)`, the
optimizer does not take every copy out: [Lines and values](#lines-and-values)
has what was measured, pipe by pipe. `lean_pattern_line` is one of those
pipes, and has its copy in the loop by hand as well, so that it compares
the pattern. `same_line_reference` is the pipe over references to lines,
which has none, as the loop one would write over pointers has none.

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

Finding every place a text pattern matches within a text is not there; a
pattern describes the whole of it.

HTTP is deliberately small for now. Not there: timeouts for idle or slow
peers, graceful shutdown, more connections than workers (no queue of ready
connections, no event loop), response headers of your own, streamed bodies,
chunked request bodies (answered 411 until `std` decodes them with checks;
see [Answers](#answers)), configurable buffer sizes, TLS and HTTP/2. Parsing is `std.http.Server`'s; zrx has no parser of its own.

Present in the previous implementation and not ported: signals
(`hold`, `withLatestFrom`), `retryPipe`, `maxItems`, and one of
the three standalone example applications. The
[record processor](../examples/apps/record-processor/README.md) and the
[HTTP benchmark](../examples/apps/http-bench/README.md) are ported, and
their READMEs list what the ports needed that the library does not have yet.
