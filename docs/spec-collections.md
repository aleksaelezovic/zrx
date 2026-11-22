# Spec: collections

Status: implemented as `zrx.ext.collections` (`src/ext/collections.zig`), in
a first version. Several of its choices are proposals that the owner has not
decided on; they are listed under [Open for decision](#open-for-decision).

This file is the design record of the extension: why it is the way it is,
what was considered and left out, and what was measured. The
[guide](guide.md#collections) says how to use it, and what is named there is
pinned in `tests/collections.zig`. `AGENTS.md` keeps the short rules to know
before editing it and points here for the reasons.

## What it is

Five synchronous operators that keep items in a `std` container:
`distinct`, `foldBy`, `sorted`, `top` and `takeLast`. With them come the
binding that gives them memory (`memory()`, `Memory`), two handlers that
make an order from a key (`ascending`, `descending`) and one that is the
item itself (`itself`).

It is an extension and not core because every one of them needs an
allocator. It is written against the operator, handler and resource
contracts and is analyzed only when it is referenced. None of the operators
is a task boundary, and none adds to the stage contract.

## Memory is a binding

The brief for this extension asked for the allocator as an ordinary
dependency and for memory that is released on every way out, a failed run
included. The stage contract does not allow both in the stage:

- `finish` runs only at a normal end of the stream. When the run fails, is
  cancelled, or fails upstream of the stage, no hook of the stage is called
  (`tests/extending.zig`, "a failed synchronous run skips finish").
- A stage that declares `deinit` is a compile error in `src/pipe.zig`: "bind
  and release resources with `Program.provide`".
- `init` returns nothing, so a stage cannot allocate there either. The
  operators allocate at their first item.

So what has to be given back on every way out is owned by a binding, whose
release runs after a failed run too. `memory()` is a resource that needs
`std.mem.Allocator`, keeps a `std.heap.ArenaAllocator` in the frame of its
`bind`, and provides `Memory`, a pointer to it. The operators ask for
`Memory`, and a missing one is a compile error that says what to bind. As
`Stdout` can be given as a value in place of `stdout(n)`, a `Memory` over an
arena of the caller's own can be given in place of `memory()`.

`Memory` is a type of its own and not `*std.heap.ArenaAllocator`: a handler
of the caller's that resets its arena for every item would otherwise share
it with the operators.

### What was considered instead

- **The operators over the plain allocator, freeing in `finish`.** The
  simplest, exact in what it holds, and it leaks on a failed run unless the
  caller passes an arena. It is what the brief ruled out.
- **A registry of live containers that the binding frees.** Needs a lock,
  since stages behind a `queue` run on other tasks, and 0.17 has no lock
  without a `std.Io` (`std.Thread.Mutex` is gone). It would also put the
  container on the heap behind a pointer, away from the stage's own local.
- **An allocator of our own that tracks what is live** and frees the rest at
  the end. It would give exact memory and no leak, and it is a wrapper
  around a `std` facility of the kind that was tried once for a writer and
  taken out. Not built.
- **A teardown hook in the stage contract.** That is a change to the core
  and not this extension's to make.

`std.heap.ArenaAllocator` says its `Allocator` is thread-safe when its child
is, which is what lets stages on several tasks share one.

### What the arena costs

`sorted`, `top` and `takeLast` hold one buffer and give it back at the end
of their stream (`clearAndFree`, `deinit`). The arena frees only its most
recent allocation, so that room is used again only where nothing was taken
since. One test pins the case that matters: inside `each`, a sub-pipe with
one of the three uses the same room for every item (400 items of 500
numbers held under 100 000 bytes, where all of them at once are 800 000).
With a second operator of this extension in the sub-pipe, what the first
held stays until the run is over.

`distinct` and `foldBy` give nothing back before the run is over. Their map
is several allocations, of which the arena could free one, and a first
version that called `clearAndFree` in `finish` measured the same as without
it: over the same 400 items `distinct` took 4.0 MB from its allocator and
`foldBy` 6.3 MB, where one item takes 25 kB and 44 kB. So inside `each`
these two grow with the number of items. A resource acquired for one item,
which the guide lists as not here yet, would make that an arena per item.

A container that grows leaves its smaller self behind. Measured in
ReleaseFast for a million `u32` items, as the peak of what the arena had
taken from its child against the peak of the same container over that
allocator directly:

| Operator | In the arena | Container alone | Ratio |
|---|---|---|---|
| `sorted` | 17.1 MB | 7.4 MB | 2.3 |
| `distinct` | 61.4 MB | 28.1 MB | 2.2 |
| `foldBy`, `u32` state | 128.3 MB | 31.7 MB | 4.1 |
| `top`, 100 000 kept | 2.4 MB | 1.6 MB | 1.5 |
| `takeLast`, 100 000 kept | 0.6 MB | 0.4 MB | 1.5 |

`top` and `takeLast` allocate once, exactly, at their first item; the half
more is the arena's own. `foldBy` is the worst because its map keeps keys
and states in two arrays and an index, and each of the three grows. These
numbers are the reason to look at the alternatives above again.

## The candidates

Each was checked against what `batch`, `fold`, `scan` and `reduce` can
already write.

- **`distinct(key)`: built.** Nothing in the core writes it. A `filter` with
  a handler that keeps a set of its own does, and then nobody frees the set.
- **`countBy(key)`: not built.** It is `foldBy(key, @as(u64, 0), count)`,
  where `count` is one line. With `foldBy` there it would be a second
  spelling.
- **`foldBy(key, seed, reducer)`: built**, in the place of `countBy`. It is
  what counting, summing and a minimum per key have in common. `fold` cannot
  write it: its state would be a map, which it emits as one item that
  `flatten` does not take apart, and which nobody frees. For keys that are
  the tags of an enum `fold` over a `std.EnumArray` does write it, without
  memory, and the guide says so.
- **`groupBy(key, sub)`: not built.** It would run a sub-pipe of its own for
  every key, as `each` runs one for every item, and `foldBy` would be
  `groupBy(key, .{fold(...)})`. Two things stand in the way. The stages of a
  group either live in the map and move when it grows, which the contract's
  construction in place does not allow for a stage that keeps a pointer to
  itself, or each group is allocated apart, and then counting costs a
  pointer and an allocation per key that the loop by hand does not have.
- **`sorted(before)`: built.** `fold` into a list, `map` to its items and
  `flatten` writes it, with two handlers of the caller's and a list nobody
  frees.
- **`top(n, before)`: built**, although `sorted(before)` followed by
  `take(n)` emits the same. It keeps `n` items where that keeps the stream,
  and that difference is the operator. A test holds the two to the same
  output for every count, with ties.
- **`takeLast(n)`: built.** It was in the previous implementation; the owner
  agreed that it returns here. `n` is a runtime count, as for `take`, and
  the ring is allocated. A ring inline for a comptime `n`, as `batch` has
  its buffer, would need no memory and is not what was built.

### What each pushes at the end of the stream

`distinct` pushes nothing at the end; it passes items as they come. `foldBy`
pushes a `Tagged(Key, State)` for every key, `.source` the key and `.item`
the state, in the order the keys were first seen. `sorted` pushes every
item in order, `top` its `n` in order, `takeLast` its `n` as they came. All
of them stop pushing when a push is answered `.done`. The three that give
their buffer back do so whether the pushes ended, were refused or failed.

`foldBy` reuses `Tagged` because it is how the library pairs a value with
what it belongs to. Its field names, `source` and `item`, were chosen for a
source and read less well for a key and a state.

## Keys

`Keys` is the one place that reads what a key handler returns. There are
three kinds:

- a value with nothing in it that points elsewhere and no float, hashed and
  compared by its parts (`std.array_hash_map.Auto`);
- a `[]const u8`, hashed by its bytes. The first of each is copied into the
  arena: a slice an item carries may point into a buffer the source fills
  again. `tests/collections.zig` has a source that does that;
- a value that reads its text with `text()`, such as a `Line`, hashed by
  that text and kept as the value. It is told by that name, as the pattern
  extension tells it.

The maps are array hash maps, which keep the order keys were first seen in.
That order is what `foldBy` emits in.

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
`sorted` and `take` emit. Its heap is `std.PriorityQueue` with the last of
the kept items at the root, and its context is the bound order by value:
a pointer to the stage's own field would be a stage that points to itself.

## Failures

- `error.OutOfMemory` fails the run like a handler error. A test refuses the
  first allocation, then the second, and so on for each operator, and every
  such run fails with that and leaks nothing.
- `distinct` counts a key as seen before it pushes the item on. If the item
  fails further down and an error path takes it, a later item with that key
  is still a duplicate.
- `foldBy` leaves no trace of an item whose reducer fails: the state of its
  key is as it was, and a key that came with that item is removed again.

## Zero overhead

`same_take_last` holds `takeLast` to the loop over a `std.Deque` in an
arena: the same instructions.

The other four have both variants in `tests/zero_overhead/cases.zig`, and
`behavior.zig` requires equal results of them, but they are not exported
for the comparison. `tools/same_code.zig` cannot compare them as it is:

- a `lean_*` fixture may call nothing, and these call the allocator and
  `std`'s containers;
- a `same_*` fixture compares the names of what is called, and the compiler
  numbers some of them per compilation: `sort.block.block__func_93` for an
  instance of `std`'s sort that stays out of line, and
  `switch.table...1560` for a table LLVM makes in the array hash map. The
  tool erases such numbers for anonymous constants (`__anon_`) only.

Measured once on aarch64-linux with those numbers erased from both files,
outside the build: `top` is the same 317 instructions, `sorted` 3354 against
3353 by hand, `distinct` 910 against 947 and `foldBy` 971 against 1002.
Each of the four has as many loads, stores and stack slots as by hand;
`sorted` and `top` call as often, `distinct` and `foldBy` four times fewer.
What differs is how the optimizer laid out the inlined sort and map. This
is a measurement and not a check: nothing in the build repeats it.

The loop by hand is written over the same container in the same arena.
Where the operator gives its buffer back before the arena is freed, so does
the loop. One would not write that step by hand; it is on both sides so
that what is compared is the operator.

Two things were found on the way:

- `Arena.bind` writes its arena in place. `.init(gpa)` left a copy of the
  arena on the stack that the optimizer did not take out.
- Adding these fixtures made six fixtures of the core fail, with a
  comparison turned into its negation. An error is given its number when
  the compiler first meets it, the two variants met `error.OutOfMemory` at
  different points, and the optimizer chooses between equivalent forms by
  such constants. `cases.zig` now names the errors of the fixtures in a
  `comptime` block at its top, so that both variants number them alike.

## Open for decision

These are proposals of the session that wrote the extension.

- **The arena.** It is what makes a failed run leak nothing without a change
  to the core, and it costs what the table above shows. The alternatives
  are a teardown hook for a stage, or operators over the plain allocator
  that leave a failed run to the caller's arena.
- **`foldBy` in the place of `countBy`**, and no `groupBy`.
- **Orders as handlers of two items**, with `ascending` and `descending`,
  and not a key alone.
- **`itself`** here and not in `src/handlers.zig`.
- **`top`**, although `sorted` and `take` emit the same.
- **`takeLast(n)` with a runtime count** and an allocated ring.
- **The comparison tool.** Erasing the numbers of `__func_N` and of
  `switch.table` names, as it erases those of `__anon_`, would let `top` be
  held as `same`. Letting a `lean` fixture call no more than its loop by
  hand, where it now may call nothing, would cover the other three.
  `AGENTS.md` says not to widen the tool to make a fixture pass, so neither
  was done.

## Not there

`countBy` and `groupBy`, for the reasons above. An order by several keys
other than as a function of the caller's. `distinct` for adjacent items
only, which needs no memory and would belong in the core. A limit on what
`sorted` or `distinct` may hold. Sorting on disk.
