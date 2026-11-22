# Spec: collections

Status: implemented as `zrx.ext.collections` (`src/ext/collections.zig`), in
its second version. The first kept its items in an arena that a binding
held. The owner decided against that: the library preallocates, and an
extension follows the rule of the core. Some choices of this version are
proposals the owner has not decided on; they are listed under
[Open for decision](#open-for-decision).

This file is the design record of the extension: why it is the way it is,
what was considered and left out, and what was measured. The
[guide](guide.md#collections) says how to use it, and what is named there is
pinned in `tests/collections.zig`. `AGENTS.md` keeps the short rules to know
before editing it and points here for the reasons.

## What it is

Five synchronous operators that keep items: `distinct`, `foldBy`, `sorted`,
`top` and `takeLast`. With them come two handlers that make an order from a
key (`ascending`, `descending`) and one that is the item itself (`itself`).

It is written against the operator and handler contracts and is analyzed
only when it is referenced. None of the operators is a task boundary, none
adds to the stage contract, and none asks for a dependency.

## Room, and no allocator

The core and the extensions merged before this one use no allocator.
`queue(n)`, `Batch(T, n)`, `Line(n)` and `stdout(n)` take a size that is
known at compile time and keep the buffer in the stage or the binding. This
extension does the same:

- The size is written where the operator is written: `sorted(1024, order)`.
  A size of 0 is a compile error.
- The room is part of a stage. Nothing is allocated and nothing is freed, so
  a run that fails has nothing to give back. A stage has no hook for that
  (`finish` is skipped on a failed run, a `deinit` is a compile error in
  `src/pipe.zig`), which is what the first version needed a binding for.
- Running out is an error with a name, for the one item that does not fit.

`takeLast` and `top` are never full: one drops its oldest item, the other
the last of its order. `sorted`, `distinct` and `foldBy` can be.

### What full means

The failure happens in `push`, for the item that does not fit, before
anything is written. So it is an item error like a handler's: the run fails
with it, or a `recover` before the operator takes the item as a
`Failed(error{TooManyItems}, Item)` and the stream goes on. What was kept
stays as it was:

- `sorted` fails every later item with `error.TooManyItems`, and still
  pushes the items it kept, in order, when the stream ends.
- `distinct` fails an item whose key is one more than it has room for with
  `error.TooManyKeys`. An item whose key it has seen is dropped as before.
- `foldBy` fails such an item with `error.TooManyKeys` and does not ask its
  reducer. An item whose key has a state is folded into it as before.

There are two names so that an error path can say which it takes, and two
and not five because the name says what there was too much of. A pipe with
two tables cannot tell them apart by the error; where that matters, each
has a `recover` of its own before it.

### Two stages for each operator

`AGENTS.md` says a stage that indexes into an array it owns cannot be kept
in registers, and to give the buffer a stage of its own. Every operator
here is two stages, spliced as `batch` is:

- `Room` is the first: the arrays and nothing else. It hands each item on
  with a pointer to them.
- The second holds the counters and the bound handlers, and does all the
  work through that pointer. It keeps the pointer for the end of the
  stream, where it is used only if something was kept.

The optimizer then keeps every counter in a register, and the fixtures hold
that: no operator has a load, a store or a stack slot more than its loop by
hand. Three other shapes were built first and measured on aarch64-linux:

- **One stage with the array and its counters.** Every counter was read
  from memory and written back for each item.
- **Counters first, then the array, told what to do in steps** (keep this
  item at this index; at the end, push so many on), as `batch` does. The
  stage with the array is then pushed to from two places, once for an item
  and once for the end. For `takeLast` the optimizer inlined both. For
  `sorted` it took `std`'s sort into that `push` first and then inlined the
  `push` in neither place: 102 instructions against 1889 by hand, because
  every item was a call. `top` did the same.
- **The same, with the end of the stream done in the array stage's own
  `finish`**, which has one caller. Everything was inlined, and the count
  was stored into the array's stage at the end and read back: one store
  more than by hand for `sorted`, four for `takeLast`.

A pointer from one stage into another is safe here because stages are
constructed in place and stay there until the stream has ended. It is given
with every item and not once, since `init` has nothing to give it from; it
is the same every time, and the optimizer takes it out of the loop.

### The table

`distinct` and `foldBy` find a key by its hash. `std`'s hash maps cannot be
used over a buffer in the stage: they take their room from an allocator,
and how many bytes a capacity comes to is private to them (the header of
`std.array_hash_map`'s index, the capacities it rounds to), so a buffer for
a `std.heap.FixedBufferAllocator` could only be sized by a guess that the
next `std` may make wrong, as an `error.OutOfMemory` at run time.

So the table is this extension's own, and it is small. The hash and the
comparison are `std`'s (`std.array_hash_map.AutoContext` for a value,
`hashString` and `std.mem.eql` for a text). The keys are in an array in the
order they were first kept, which is the order `foldBy` emits in. Beside it
is an array of places, at least twice as many as keys and a power of two; a
place holds zero, or one more than the index of its key, in the smallest of
`u8`, `u16`, `u32` that fits. A key is looked for from the place its hash
names, one place after the other, until it or an empty place is found.
Nothing is ever taken out, so there are no markers for that. A room whose
places a `usize` cannot count is a compile error that names the operator;
a review found that the doubling overflowed first, with the compiler's own
message.

How many keys are kept is not in the table: the stage after it counts, and
says which index a new key gets.

`top` does use a `std` container over its room: `std.PriorityQueue`, whose
fields are public, set over the kept entries for each call. Its `push`
takes an allocator for when it has to grow. Here it never has to, and it is
given `std.mem.Allocator.failing`.

### What was rejected

- **The arena of the first version.** A binding `memory()` held a
  `std.heap.ArenaAllocator` for the run and the operators asked for it.
  Measured for a million `u32` items, the arena held 1.5 to 4.1 times what
  the container alone holds, `distinct` and `foldBy` gave nothing back
  before the run was over, and a review found that `foldBy` kept the copy
  of a key whose item its reducer had rejected, until a fixed arena was
  used up. It also made these the only operators that need an allocator.
- **A slice of the caller's in place of a size.** An operator is one value,
  and `concurrent(n, sub)` gives each worker stages of its own made from
  that one value: the workers would share the buffer. A test runs `sorted`
  and `foldBy` in three workers.
- **Growing when full.** That is an allocator again.
- **A teardown hook in the stage contract**, so that a stage could own
  memory. A change to the core, and not needed without an allocator.

## The stack

The stages of a program are locals of `run`, so the room is on the stack of
the task that calls `run`. That holds for a segment behind a `queue` too:
its task works on stages that `run` constructed. The sub-pipes of `branch`
and `route` and the workers of `concurrent` are values inside such a stage.
A sub-pipe of `each` is constructed inside the `push` of its item, on the
stack of the task that runs that segment.

Measured on macOS (aarch64) with `sorted(n, descending(itself))` over `u64`
items, every place of the room written, in Debug and in ReleaseFast, as a
plain program, behind a `queue(4)`, inside `each`, and inside `each` behind
a `queue(4)`:

| Room | Result |
|---|---|
| 1 MiB to 15 MiB | ran, in all eight |
| 16 MiB less 64 KiB (16 320 KiB) | ran (measured for the first and the last shape, in both modes) |
| 16 MiB | faulted in seven; ran to its end in ReleaseFast inside `each` behind a `queue` |
| 32 MiB | faulted (measured in Debug only) |

16 MiB is the stack of the main thread of a Zig executable there and of the
threads of `std.Io.Threaded` (`std.Thread.SpawnConfig.default_stack_size`).
So what fits is the stack less what the calls need, which was under 64 KiB
here, and Debug needs no second copy of the room. Too much is not an error
and nothing checks. In Debug the process faults at the start of the run,
where an undefined stage is filled. Optimized, it faults where the stack is
first touched beyond its end, if that place is not mapped: the one run that
did not fault wrote 16 MiB from a stack of 16 MiB, so some of it was
written to memory that was not the stack's. That is why the guide does not
promise a fault.

How many bytes a room comes to is not written out in the guide: it is
`@sizeOf` of the pipe's stage, which a reader can name through the operator
contract, and the guide shows how. Its first wording, `n` times the size of
an item, was a sixteenth of what a review measured for `top(1_500_000,
...)` over `u8` (24 MB, with a `usize` arrival number padded beside each
byte; 12 MB now, with a `u32`). An entry, padding and a counter's width
are the compiler's to add up.

`sorted` needs more than its room while it sorts: `std.sort.block`, which
is `std.mem.sort`, has a `[512]T` of its own on the stack. For the `u64`
items of the measurement that is 4 KiB; for an item of 4 KiB it is 2 MiB.

Not measured: Linux, where the main thread's stack is raised to what the
linker wrote, and Windows; an `Io` whose tasks have stacks of another size;
a system of programs, whose members each run on a task.

## The candidates

Each was checked against what `batch`, `fold`, `scan` and `reduce` can
already write.

- **`distinct(n, key)`: built.** Nothing in the core writes it.
- **`countBy(key)`: not built.** It is `foldBy(n, key, @as(u64, 0), count)`,
  where `count` is one line. With `foldBy` there it would be a second
  spelling.
- **`foldBy(n, key, seed, reducer)`: built**, in the place of `countBy`. It
  is what counting, summing and a minimum per key have in common. For keys
  that are the tags of an enum `fold` over a `std.EnumArray` writes it, and
  the guide says so.
- **`groupBy(key, sub)`: not built.** It would run a sub-pipe of its own for
  every key, and `foldBy` would be `groupBy(key, .{fold(...)})`. With room
  written out it is `n` times the stages of the sub-pipe, which is possible
  now, and it is a larger operator than the five together. It comes by
  decision.
- **`sorted(n, before)`: built.**
- **`top(n, before)`: built**, although `sorted(m, before)` followed by
  `take(n)` emits the same. It needs room for `n` items where that needs
  room for the stream, and that difference is the operator. Two tests hold
  the two to the same output for every count, with ties and with keys that
  are not numbers.
- **`takeLast(n)`: built.** It was in the previous implementation; the owner
  agreed that it returns here. It is a ring of `n` items.

### What each pushes at the end of the stream

`distinct` pushes nothing at the end; it passes items as they come. `foldBy`
pushes a `Tagged(Key, State)` for every key, `.source` the key and `.item`
the state, in the order the keys were first seen. `sorted` pushes every
item in order, `top` its `n` in order, `takeLast` its `n` as they came. All
of them stop pushing when a push is answered `.done`.

`foldBy` reuses `Tagged` because it is how the library pairs a value with
what it belongs to. Its field names, `source` and `item`, were chosen for a
source and read less well for a key and a state.

`top` puts its heap in order by taking the root off again and again, each
into the place the heap gave up for it. No second sort is needed.

## Keys

`Keys` is the one place that reads what a key handler returns. A key is
kept after its item is gone and nothing is copied for it, so it is a value:

- A type with a pointer anywhere in it is a compile error that says to
  return a value, for text a `Line(n)`. The type is read as the pattern
  extension reads it (`holdsPointer`); the function is written out here,
  since one extension does not import another. The first version copied a
  `[]const u8` key into the arena.
- A value with no float in it is hashed and compared by its parts.
- A value that reads its text with `text()`, such as a `Line`, is hashed
  and compared by that text: the bytes behind the text are not part of it.
  A test fills them differently for every line.

`itself` is the identity handler. Without it `distinct`, `foldBy` and the
orders would each need a second form for an item that is its own key. It is
not about collections and would sit as well beside `field` and `constant`.

## Orders

`sorted` and `top` take an order: a handler of two items that answers
`bool`. `ascending(key)` and `descending(key)` make one from a key. An
operator that took a key alone was considered: it is shorter for the common
case, and it cannot sort by two fields or largest first without an option.

An order cannot fail. `std`'s sort and heap ask it in the middle of their
work and have nowhere to send an error, so a fallible order is a compile
error that says to do what can fail in a `map` before.

`sorted` uses `std.mem.sort`, which is stable. `top` keeps an arrival number
with each item and orders ties by it, so that it emits exactly what
`sorted` and `take` emit.

### When the arrival numbers run out

The first version counted arrivals in a `usize`. A review found that the
count overflows: a trap in Debug, and ties in the wrong order optimized. On
a 32-bit target that is after some 4.29 billion items, whatever the room. A
`u64` would make it unreachable in practice, at eight bytes for every entry
on every target, and still be a count that runs out.

Only the order of two numbers is ever read, and only for two entries that
tie. So when the numbers run out, `top` puts the kept entries in order (as
it does at the end of the stream), numbers them from 0 along that order,
and reverses them, which leaves them a heap again, the last at the root.
Two entries that tie are next to each other in that order, the earlier
first, so they keep their order; the next item is numbered after all of
them.

That makes the type of the number free. It is the smallest of `u16`, `u32`
and `u64` that counts to 256 times the room, so the entries are numbered
again once in at least 255 times the room items, which costs fewer than one
call of the order per item on average. A small type keeps an entry small,
and it lets a test run the numbers out: `top(3, ...)` does after 65535
items.

### A float that is not a number

A review found that for `3, NaN, 1` `sorted` followed by `take(1)` emitted
`3` and `top(1)` emitted `1`. The order compared keys with `<`, and a NaN is
neither smaller nor larger than anything. So it tied with `3` and with `1`,
which do not tie with each other, and that is not an order: a stable sort
left the three as they came, and the heap dropped the `3`.

`keyBefore` is now the one place that compares two keys, for both orders.
A NaN comes after every number, in `ascending` and in `descending` alike,
and no NaN before another. It is last both ways and not "largest", so that
`top(n, descending(key))` is the `n` largest numbers and not the NaNs.

An order of the caller's own is not checked, and cannot be: the guide says
what it has to hold to.

## Failures

- An item that does not fit: see [What full means](#what-full-means).
- `distinct` counts a key as seen before it pushes the item on. If the item
  fails further down and an error path takes it, a later item with that key
  is still a duplicate.
- `foldBy` leaves no trace of an item whose reducer fails. The first
  version took a place for the key, copied it, then asked the reducer, and
  on a failure took the place back but not the copy; a review found the
  copies. This version has nothing to take back: it looks the key up, then
  looks whether there is room, then asks the reducer, and only then writes.
  A test rejects one key six times with room for two keys, and two keys
  that come after it fit.
- An item whose key handler fails has not been looked up at all.

## Zero overhead

All five have a fixture in `tests/zero_overhead/cases.zig`. The loop by
hand has arrays of the same size on its stack and its counters in locals;
it calls `std`'s sort, heap and hash where the operator does, and walks a
table written out there where the operator walks its own. With the small
items of the fixtures the optimizer takes all of `std`'s code into both
variants, so neither calls anything. On aarch64-linux and x86_64-linux:

| Fixture | With zrx | By hand |
|---|---|---|
| `same_take_last` | 41, 103 | the same |
| `lean_sorted` | 1890, 3295 | 1889, 3294 |
| `lean_top` | 311, 445 | 329, 463 |
| `lean_distinct` | 75, 75 | 74, 74 |
| `lean_fold_by` | 98, 131 | 100, 133 |

- `takeLast`: the same instructions. The loop keeps its array in a struct
  of one field, because the comparison reads the type a stack slot is
  declared with and the stage's is a struct.
- `sorted`: what differs is inside `std`'s sort, where the optimizer counts
  from zero in one variant and from one in the other.
- `top`: the optimizer lays out the sifting of the heap differently, and
  the pipeline is the shorter one. The loop numbers its arrivals in a `u16`
  and numbers them again when they run out, as the operator does.
- `distinct` and `foldBy`: the keys and the places of the stage are one
  stack slot, and an array each by hand.

A `lean` fixture has no call, and no more loads, stores or stack slots than
its loop. These fixtures can fail with `error.TooManyItems` and
`error.TooManyKeys`, which are named in the `comptime` block at the top of
`cases.zig` so that both variants number them alike.

In a program with larger items or a larger room `std`'s sort may stay out
of line. Nothing here says what the optimizer does then.

## Open for decision

These are proposals of the session that wrote the extension.

- **The names of the two errors**, `TooManyItems` and `TooManyKeys`, and
  that there are two.
- **Where a NaN sorts**: last in both orders.
- **A table of this extension's own**, since `std`'s cannot be sized
  without an allocator.
- **`std.PriorityQueue` given `Allocator.failing`** for `top`, in place of a
  heap written out here.
- **`foldBy` in the place of `countBy`**, and no `groupBy`.
- **Orders as handlers of two items**, with `ascending` and `descending`,
  and not a key alone.
- **`itself`** here and not in `src/handlers.zig`.
- **`top`**, although `sorted` and `take` emit the same.

## Not there

`countBy` and `groupBy`, for the reasons above. An order by several keys
other than as a function of the caller's. `distinct` for adjacent items
only, which needs no room and would belong in the core. Room that grows,
room on the heap, sorting on disk. A text key that is not a value.
