# Spec: directories

Status: implemented as `zrx.ext.fs` (`src/ext/fs.zig`), in a first version
of two sources, `entries(path, n)` and `walk(path, n, depth)`. That nothing
here allocates is the owner's decision. Everything else in this file is a
proposal until the owner has reviewed it.

This file is the design record of the extension: why it is the way it is,
and what was considered and not done. The [guide](guide.md#directories)
says what it does, and every behavior named there is pinned in
`tests/fs.zig`. `AGENTS.md` keeps the short rules to know before editing it
and points here for the reasons.

## An extension, not core

It is written against the public source contract and is analyzed only when
`zrx.ext.fs` is referenced. The core knows nothing of it and still compiles
freestanding. Listing and opening stay `std.Io.Dir`'s.

Neither source can be written with what was there. `fromIterator` takes an
iterator whose `next` has no arguments, and `std.Io.Dir.Iterator.next` takes
an `Io`; and the names it returns are borrowed. `fromProducer` could hold
the loop by hand, which is what the extension is there to replace.

## How the directory is given

By path, as a file is for `fileLines` and `fileBytes`. The other convention
of `src/io.zig`, a role bound by a resource (`lines(Role, n)` with
`fileReader`), was considered and not taken:

- An entry's path begins with the directory's as it was given, so it opens
  with everything else in zrx that opens a path. A source over a role would
  give paths below a directory handle, and nothing in zrx opens a path
  against one. That would have called for a third convention later.
- A source by path can be the source of an `each`. A role is one for the
  run and cannot change with the item. That is what lets an error path take
  one directory (see [What fails](#what-fails)).

The directory is opened when the source runs and closed when the source
ends, by `defer`: at the end of the listing, when the pipe is done, and
when something fails.

**A name is joined by the path rules of the system.** One separator goes
between the directory's path and a name in it, and none where the path
already ends in one. On Windows none goes after a drive alone either: `C:`
is the directory the process is in on that drive, and a separator would
make it the root of the drive, so the entries of one directory would be
given the paths of another. An external review of the first version found
that by inspection. The neighbouring cases were gone through with it: a
path that ends in a separator, a bare `\`, the root of a share with and
without a separator after it, a path that begins `\\?\`, and a drive with
a directory (`C:dir`). Only the drive alone was wrong.

The join is `joinAs(rules, ...)`, and the sources call it with the rules of
the system they are compiled for. It is public for one reason: the suites
import only the public module, the rules are chosen at compile time, and
Windows is not a system the tests are run on here. So `tests/fs.zig` holds
the join by both sets of rules, whichever system it runs on. That pins the
join and not the walk: behavior on Windows is still not run.

**A source holds a copy of its path**, a `Line(n)`, where `fileLines`
borrows. `each` calls `source_of` with a copy of its item, so a source made
there from `entry.path.text()` would point into that handler's copy, which
is gone when the handler returns. The copy is made in `entries` and `walk`
themselves, which cannot fail: a path that does not fit is kept as null and
fails the run with `error.PathTooLong` when the source runs.

The same trap is open for `fileLines` and `fileBytes`, in the core, for any
item that holds its text. It is not closed here; the guide warns of it in
this section.

## What an item is

`Entry(n)`: `path`, a `Line(n)`, and `kind`, a `std.Io.File.Kind`.

- `std`'s iterator reuses its name buffer, and an item may cross a `queue`
  to another task. So the item owns its path, as a `Line(n)` owns its text.
  `Line(n)` is reused and no new type made: it is what the guide already
  gives as owned text of bounded length, it formats with `{f}`, and a
  pattern can be put to it.
- A path that does not fit fails the run with `error.PathTooLong`. Not
  `error.StreamTooLong`, which `Line(n).from` returns: a program that walks
  a directory and reads the lines of its files has both, and they call for
  different remedies. Not `error.NameTooLong` either, which is `std`'s for
  a path the system refuses.
- **A path too long to open fails the run before it is given.** A walk
  opens each directory inside the one before, so it can reach a path
  longer than the system takes. A review found one on macOS: the walk gave
  a path that fit the caller's `n`, and opening it by that path, as the
  guide says a handler may, failed with `error.NameTooLong`. So a path of
  `std.fs.max_path_bytes` bytes or more fails the run with that error, the
  one `std` returns for opening it: it is the system that has no room, and
  no other `n` helps. Skipping the entry was not taken, for the reason
  under [What fails](#what-fails). The bound is `std`'s, and the test
  builds its tree from it and runs on Linux and macOS. On Windows the
  system counts a path in UTF-16, and `std` converts it into a buffer of
  `PATH_MAX_WIDE` (32767) units without checking its length first: a
  path of more units would write past the buffer when it is opened, a
  panic in a safe build. A review found that `std.fs.max_path_bytes`,
  three bytes for each of those units, let such a path through. So by
  Windows rules the bound is the units. They are counted only for a path
  of more bytes than that, since a unit takes at least one byte. The
  join's test holds that rule on every host, a path of
  ASCII and one of two-byte letters on each side of the bound; the tree is
  not built on Windows. The next review found the directory a source is
  given still opened by that path unchecked, so it is held to the same
  bound before it is opened. A test `Io` counts the directories asked to
  be opened, which shows on any system that it was never asked: elsewhere
  `std` refuses such a path itself, with the same error.
- The directory's own path must fit too, and is checked before it is
  opened. Otherwise whether a bound is too small would depend on whether
  the directory happens to be empty.
- `name()` is `std.fs.path.basename` of the path. There is no `text()` on
  an entry: whether that would mean the path or the name is not obvious,
  and `field(.path)` already gives a value that has one.

**The kind is asked for where the listing does not say.** Some file systems
report `.unknown` (Linux `DT_UNKNOWN`). `std`'s walker then does not go
into the entry, so a walk would silently stop at the first level there, and
a `filter` on the kind would drop everything. The source asks with one
`stat` that does not follow a link.

## The walk

**Its own levels, not `std`'s `Walker`.** `std.Io.Dir.Walker.deinit` and
`SelectiveWalker.deinit` in 0.17.0 free memory and leave the directories
open; the doc comment says otherwise. A walk here ends early whenever the
pipe is done, and would leak every directory it was inside of. `std`'s
walker also allocates, for its stack and for a name buffer without a bound.
Here the path is built once, in the bounded one.

**Depth is written out, and nothing is allocated.** `walk(path, n, depth)`
keeps a `[depth]Level` in the frame of its `run`: a `Dir.Iterator` and the
length of its directory's path for each directory the walk is inside of.
That is the rule the core and the other extensions follow: `queue(n)`,
`Batch(T, n)`, `Line(n)` and `stdout(n)` take a size at compile time and
hold the buffer, and running out has a name.

- A level is `@sizeOf(Dir.Iterator)` and a `usize`: 2096 bytes for the
  Linux targets of the catalog and for macOS, 2104 for Windows, read off
  the type for each target with Zig 0.17.0. The whole array is there from
  the start, used or not, on the stack of the task that runs the source.
  The guide says so, for a reader to choose the depth by.
- **The directory given counts**: it is depth 1. `depth` is then the
  number of listings held, which is what it costs, and a depth of 0 holds
  nothing and is a compile error. Counted from below the directory, 0
  would have been a second spelling of `entries`.
- A directory deeper than that fails the run with `error.TooDeep`. Not
  `error.PathTooLong`: the remedy is another number. As for a directory
  that cannot be opened, the entry is pushed first, so a pipe that is done
  at that entry does not fail.
- Room is counted for the directories the walk is inside of, not for those
  it has been in: a level is free again when its listing ends.

*Rejected: a list that grows.* The first version kept the levels in an
`ArrayList` and asked for `std.mem.Allocator`. It walked a tree of any
depth, and that was all it had for it. It made `walk` the one thing in a
program that needs an allocator, with a failure (`error.OutOfMemory`) that
says nothing a caller can act on, where `error.TooDeep` names the number to
change. It also needed care that the array does not: a name read from a
listing lies in the listing, which lay in the list, so room for the next
level had to be reserved before the name was read.

*Rejected: a function that calls itself for each level.* The file system
would choose the depth of the call stack, at two kilobytes a level, and
running out of that has no error at all.

**A directory is pushed before it is opened.** A pipe that is done with the
directory's entry does not have it opened, and a directory comes before
what is in it. That is the one statement about order; everything else is
the system's.

**Links are never followed.** A link is an entry of kind `.sym_link`. Every
open below the directory the source was given has `follow_symlinks =
false`, so a link put in a directory's place since it was listed is not
gone through either: the run fails. The directory the source is given may
be a link; it is what the caller named.

That the run fails is tested on Linux and macOS only. On Windows `std`
opens with `FILE_OPEN_REPARSE_POINT`, which opens a reparse point rather
than refusing it, and a review found nothing that checks what was opened.
Checking the handle was considered: it would be code that no test here
runs, behind a promise only a cross-compilation stands for. So the guide
narrows the promise to the systems it is tested on instead.

## Stopping

Both sources return when a push answers `.done`. Both also declare
`zrx_stop_source` and look at `zrx.Stop` before each read.

A walk never waits for input, so the signal is not needed to wake it. It is
needed where no push reaches the boundary that would answer `.done`:
`walk, filter(rare), queue(n), take(1)` would otherwise read the whole tree
after the one entry was taken.

A source run by something that does not pass the signal on (a wrapper of a
caller's own) has none, and learns through its pushes alone.

## What fails

A directory that cannot be opened or read fails the run with what the
system reported. Nothing is skipped: a walk that left out a directory would
look like a whole one.

This is the failure of a source. `AGENTS.md` has it that such a failure
belongs to no item and is outside every pipe, and that rule is not bent
here. So an error path cannot take it. What an error path can take is a
directory that is an item: `each` over either source, under `attempt`. Both
are tested, with paths as items and with the entries of an outer listing as
items.

The brief for the extension preferred a rule that lets `attempt` or an
error path deal with one bad entry. The composition above is that for one
directory per item. It is not that for a directory deep inside one walk:
there the item's whole walk fails.

**Going on past an unreadable directory within one walk was considered and
is not there.** A source has one way to hand the pipe something: an item.
So the failure would travel in the item, as a field or as a variant of a
union:

- As a field, the quiet case is the default: a `filter` on the kind drops
  the entry and its failure unseen. That is the silent skip the rule above
  refuses.
- As a union, every pipe over a walk has to `route` first, including the
  ones that want the failure to end the run.
- A source that holds an error path of its own, as `attempt` does, would
  construct stages inside a source. That is a new shape for the scope.

If it returns, it returns by decision, and the union is the form that
keeps a failure from being lost.

A tree that changes while it is walked gets no promise. An entry may be
seen or missed as the system lists it, and a directory removed before the
walk opens it fails the run with `error.FileNotFound`.

## Tests

`tests/fs.zig` runs over `std.testing.tmpDir`.

- **No test depends on the order of a listing.** What was seen is compared
  as a set, or the tree is a chain of directories with one entry each,
  which has one order.
- **No test depends on permissions**, which a privileged user and Windows
  do not enforce. A test `Io` (`Dirs`) wraps the vtable of
  `std.testing.io`: it counts opens, closes and reads, refuses a directory
  by name, lists without kinds, lists a link as a directory, and lists
  without end.
- "Closed on every way out" is opens equal to closes after the run. "Ended
  when done" is the number of reads, not a length of time.
- That the signal ends a source is shown with a listing that has no end
  and a filter that lets one entry through. The run returns only if the
  source looks at the signal. Without that it hangs, as the tests of
  `fromProducer` with `Stop` do.
- The join is tested by itself, by the rules of both kinds of system (see
  [How the directory is given](#how-the-directory-is-given)).
- Each safeguard was removed in turn (twenty-nine mutants) and a test
  failed for each; none failed to compile.

The directory is given as `.zig-cache/tmp/<sub_path>`, built from
`TmpDir.sub_path`, since a source takes a path and `tmpDir` gives a handle.
Its length is known at compile time, which lets a test choose a bound that
a path just fits.

## No zero-overhead fixture

There is none, and no claim of zero overhead. A source of system calls
through `std.Io` has no loop by hand to be the same as. The fixtures are
also compiled for the freestanding targets, where `std.Io.Dir` does not
compile (`NAME_MAX not implemented for freestanding`).

What it costs is said in the guide: an entry is `n` bytes, and a handler is
given a copy of it.

## Not there

Back only by decision:

- watching a directory for changes;
- matching names against a glob;
- following links;
- sorting;
- metadata beyond the kind, such as size and times;
- going on past an unreadable directory within one walk.
