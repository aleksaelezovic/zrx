# Backlog

What zrx does not do yet, what has been left out on purpose, and what is
still to be decided. This is the one list: the guide, the design records
and the apps link here rather than keep lists of their own. The reasons for
an item stay where they were worked out, and each line links there.

An item gets its line in the pull request that finds it, and loses it in
the pull request that does it. Nothing here is added in passing: work on an
item starts when the owner picks it up.

| Status | Meaning |
|---|---|
| **decide** | Built as a proposal; the owner has not decided it |
| **wanted** | The owner wants it; not started |
| **proposed** | Suggested, not decided |
| **gap** | Found missing while writing an app or a test |
| **out** | Left out on purpose; back only by decision |
| **declined** | The owner said no; listed so it is not proposed again |

## Decisions awaiting the owner

- **decide** The seed of `scan`, `fold` and `reduce`: a reducer says its
  state type with `State(Item)` when the seed is a bare number.
  [Math: the seed](spec-math.md#the-seed)
- **decide** The choices of each extension's design record, written as
  proposals and implemented as stated:
  [bytes](spec-bytes.md), [collections](spec-collections.md#open-for-decision),
  [compress](spec-compress.md), [fs](spec-fs.md), [json](spec-json.md)
  (`Line`'s `std.json` hooks, the one change outside the extension),
  [process](spec-process.md), [text](spec-text.md#proposed-not-decided),
  [time](spec-time.md#proposed) (`Stop.waitTimeout`, `ticks`, `stamp`,
  `throttle`). Among them, merged as written for review later: the old
  `{"bytes":...}` JSON form of a `Line` is refused, how long a piece of a
  line lives, the size of `top`'s arrival counter.
- **decide** Whether `zrx.failure` is public. `src/root.zig` exports it
  for what takes failures; the guide does not describe it.
- **decide** Whether `fileReader` reads on from where its descriptor
  stands. It reads from the start of the file, so a descriptor already
  partly read (`/dev/fd/0`) is read again from its start.
  [Record processor](../examples/apps/record-processor/README.md#what-this-port-needed-from-zrx)
- **decide** Whether `fileLines` and `fileBytes` hold a copy of their path,
  as `entries` and `walk` do. They borrow it, so neither may be made from a
  path held inside an item in the `source_of` of an `each`. A copy needs a
  bound for the path, one more parameter on both.
  [Files](spec-fs.md#files)

## Core

- **proposed** Stopping a source from outside, so that a signal or a
  timeout ends a run gracefully: the source is asked to end, and the run
  ends as it does when the source returns. `timeout` and ending a run on
  Ctrl-C wait for it.
  [Segments: stopping from outside](spec-segments.md#stopping-from-outside)
- **wanted** `using(bindings, sub)`: bindings, values and resources alike,
  provided to an inner pipe only, a resource acquired and released for each
  item. Open: how a binding can depend on the item, such as opening the
  file an item names. A first attempt (#30) took one resource made from the
  item and was closed; it is not the design.
- **gap** A worker count for `concurrent` known only when the program
  starts. It is a compile-time count, so `http-bench` takes it as a build
  option. [HTTP benchmark](../examples/apps/http-bench/README.md#what-this-app-needed-from-zrx)
- **gap** One total over the cases of a `route` that terminate. Cases that
  emit one item type rejoin the pipe, and one `fold` after the route counts
  them all; cases that each end in a sink of their own cannot share one.
  `nquads-check` has such cases and counts through `tap` into a
  `*Summary`. [N-Quads check](../examples/apps/nquads-check/README.md#what-this-app-needed-from-zrx)
- **gap** `reduce` over an iterator. It folds an array, a slice or a batch;
  a query's pairs are an iterator, so `http-bench` loops in a handler.
- **gap** A test cannot wait for one item to reach the writer of `write`:
  it flushes when its buffer fills and at the end, so when an item gets
  there depends on the buffer. `offline-telemetry` brings an unbuffered
  writer that signals each row. [Offline telemetry](../examples/apps/offline-telemetry/README.md#what-this-app-needed-from-zrx)
- **gap** A handler that names its failure, `Failed(E, Item)`, serves only
  one item type: a `Failed(anyerror, [:0]const u8)` does not coerce to one
  of `[]const u8`, so `file-integrity-manifest` takes it as `anytype`.
- **out** A meaning for a predicate that finds a value in `filter`,
  `takeWhile`, `not` and `any`. Each rejects one with a compile error that
  says where the value could go. [Guide: route](guide.md#route)
- **out** A source of references into storage of its own, such as lines
  pushed as `*const Line` from the source's buffer: the storage is reused
  for the next item, so such a reference cannot cross a `queue`. A pointer
  into storage that outlives the run needs nothing new, and crosses a
  `queue` as any value does (`same_line_reference`).
- **gap** Nothing checks the binding contract: that `bind` calls
  `rest.call` once. [Guide: writing your own](guide.md#writing-your-own)
- **proposed** A channel between the programs of a system.
  `examples/system.zig` writes a bounded `Mailbox` by hand.
- **proposed** `pairwise`, and `concat` of sources.
- **proposed** `.publish` finding an existing destination before the run
  does its work, not only when it publishes.
- **proposed** A program as a graph: a compile-time walk of a pipe, in
  which every composite operator describes its own shape and an operator of
  a caller's own is one node. The same walk would serve
  - a picture of a program, with its route cases and error paths labelled;
  - facts known at compile time, such as the range of integers a
    `filter(ge(10))` lets through, checked against what a later handler
    needs;
  - rewrites of a pipe, ordered and combinable, which an extension can add
    to: a slice source with `skip` and `take` becomes a narrower slice. Two
    `take`s in a row were measured and gained nothing.
  The owner called the rewrites a nice-to-have.
- **proposed** A compile-time warning for a handler that never looks at
  cancellation, such as a busy loop. Not now.
- **out** From the previous implementation: signals (`hold`,
  `withLatestFrom`), `retryPipe`, `maxItems`.

## Concurrency

- **wanted** Document how to hand chunks over a queue:
  `batch(n), queue(k), flatten()`, which keeps a short last batch, since a
  `Batch` is a value. Measure it again first: the figure in the design
  record (about 5 ns an item, where `queue(256)` alone takes about 35) is
  from the slice-based `batch` that came before. A chunking operator was
  the alternative, not chosen.
  [Segments: costs](spec-segments.md#costs)
- **proposed** `concurrent` that keeps the order of its input. A worker's
  output is pushed on as the worker produces it, one push at a time, so
  items from different workers come out in no particular order.
- **proposed** Interrupting a segment that works for nothing: a source
  that does not ask for `zrx.Stop`, behind a queue whose far side is done,
  waits for its next item before it ends. A source that asks for `Stop`
  and waits on it, as `ticks` does, returns already. Taken out of the first
  version, to return as its own change.
  [Segments: taken out](spec-segments.md#taken-out-interrupting-a-segment-that-works-for-nothing)
- **proposed** Demand for `zrx.Stop` is counted in the chain, where an
  extension's `tasks` are collected (`src/pipe.zig`). If that draws another
  review finding, build the demand tree where segments are enumerated.
- **proposed** Windows by a time in the data (a timestamp field) rather
  than by the clock, for replayed files. A synchronous operator of its own.

## Time

All of these need a task or stopping from outside, and the stage contract
does not grow for them. [Time: not there](spec-time.md)

- **out** `timeout`: it ends a run whose source is waiting, which is
  stopping from outside.
- **out** `delay`: it holds items until their time, so it is a task
  boundary of its own.
- **out** `sample`, and a throttle that emits the last item of a window:
  each emits while its input is silent, as `debounce` does.

## HTTP

Small on purpose for now. [Guide: HTTP](guide.md#http) ·
[Design record](spec-http.md)

- **out** Timeouts for idle or slow peers.
- **out** Graceful shutdown.
- **out** More live conversations than workers. Connections beyond the
  workers are accepted and wait, but a worker holds one connection for as
  long as it is open, idle or not; serving several on one worker needs an
  event loop.
- **out** Response headers of the caller's own, and streamed bodies.
- **out** Chunked request bodies, answered 411 until `std` decodes them
  with checks.
- **out** Configurable buffer sizes, TLS and HTTP/2.
- **decide** A final answer can be lost: a 413 followed by a close, while a
  large body is still arriving, may reach the client as a reset. It needs a
  design, not a patch.
- **decide** A handler's own `WriteFailed`, such as a full log writer, is
  taken by `recover(http.Disconnected, ...)` like a lost peer.
- **proposed** `connections` stopping at once behind a task boundary, by
  waiting for an accept and for `zrx.Stop` together. It would add tasks to
  every server; for now a limit goes before the boundary.
  [Guide: limits](guide.md#limits)
- **proposed** Backpressure on connections that wait for a worker. Not for
  now.
- **proposed** `http.json` taking `std.json`'s options, or being made of
  `json.encode`.
- **proposed** Measuring under `std.Io.Evented`, not only `Threaded`.
- **proposed** A test that sees `connections` stop accepting when its table
  is full; that is pinned only indirectly.

## Text patterns

[Design record](spec-pattern.md)

- **out** Finding the places a pattern matches inside a text; a pattern
  describes the whole of a text.
- **out** Going back, and a format string read backwards
  (`"/items/{id}"` would be a string language of its own).
- **out** A node that only groups the extracts of a part into a struct.
- **proposed** More than one predicate of an `all` finding a value (a path
  and a query): it needs a rule for joining what they find. Only the last
  one may find a value.
- **gap** A string alone is not a handler: matching a literal is
  `seq(.{"exit"})`.
- **proposed** A planning pass, an optimizer, as a separate feature at the
  end. One plan was measured and dropped; another is worth having only if
  it improves every `lean_pattern_*` fixture.
  [Pattern: a plan that was built](spec-pattern.md#a-plan-that-was-built-and-is-not-there)

## JSON

[Design record](spec-json.md)

- **out** A decoder that reads a document as it arrives, and a document
  that spans several items (the pieces of `fileBytes`, one object over
  several lines). A text is whole before it is decoded.
- **out** A `from` contract, or a type that is checked and dropped.
- **gap** A field that is read and not kept. `audit-archive` reads
  `actor`, which is required, and `detail`, which is optional, into
  `Line(1024)` fields it then drops: up to a kibibyte copied per field to
  check that it is text (a string, or an array of byte values).
  [Audit archive](../examples/apps/audit-archive/README.md#what-this-app-needed-from-zrx)
- **out** A default for `.scratch`: what a text needs differs by target.
- **proposed** One place for the rule "a `[]const u8`, or a value with
  `text()`". The JSON, pattern, text and collections extensions each have a
  copy (`isText`, `holdsText`). Review tightened the copy in JSON, which now
  refuses a `volatile` slice and a `text` that takes its receiver at compile
  time; the copy in patterns still takes both.

## Math

A handler of your own over `std.math` is a few lines.
[Design record](spec-math.md)

- **out** Forms that wrap or saturate (`+%`, `+|`).
- **out** A power that is not a whole number, and roots.
- **out** Conversion between integers and floats, such as a `Stats(f64)`
  over integer items without a `map` before it.
- **out** Vectors as items.
- **out** `fold(null, min)`, and a compile error for `fold(0, min)`.

## Text

[Design record](spec-text.md)

- **out** `endsWith` and `contains`. A text that is, or starts with, some
  text is a pattern; until finding inside a text is decided, a handler over
  `std.mem.endsWith` does it.
- **out** Unicode, in the classes or the case.
- **out** A delimiter chosen while the program runs (a `source_of` of your
  own does it), and `std.mem`'s other ways to split.
- **out** Pieces of a line as values.

## Bytes

[Design record](spec-bytes.md)

- **out** Decoding to as many bytes as the text stands for: that length is
  not known at compile time.
- **out** Base64 of a stream of pieces as one text. A group of three bytes
  may begin in one piece and end in the next. Hexadecimal has no groups:
  `write(Role, "{x}")` over the pieces is the text of the whole.
- **out** An operator that feeds a hasher in place.
- **out** A `jsonStringify` on the value that holds an item.
- **out** Ciphers, signatures, keys and constant-time comparison.

## Compression

[Design record](spec-compress.md)

- **out** xz (until `std`'s decoder is bounded), raw deflate, lzma,
  Zstandard compression, archives.
- **out** The cause of a failed read: a corrupt or truncated input is
  `error.ReadFailed`.
- **out** Comparing the checksum of a Zstandard frame; dictionaries for
  Zstandard and preset dictionaries for zlib.
- **out** Reading on past zero padding after a gzip member.

## Directories

[Design record](spec-fs.md)

- **out** Watching a directory for changes.
- **out** Matching names against a glob; a `filter` over `entry.name()`
  does it.
- **out** Following links, and sorting.
- **out** Metadata beyond the kind, such as size and times.
- **out** Going on past an unreadable directory within one walk.

## The process

[Design record](spec-process.md)

- **out** An arguments source: `fromSlice(args[1..])` and
  `fromIterator(&iterator)` are that already.
- **out** A typed parser of options and a usage text, and choosing a
  program for the arguments (a `switch` in `main`).
- **out** A binding chosen when it is acquired, so that "this file, or
  standard input" is one `run`.
- **out** A `refuse`: failing with a given error without a handler of your
  own. `multi-file-log-analyzer` has a one-line handler for it.
  [Log analyzer](../examples/apps/multi-file-log-analyzer/README.md#what-this-app-needed-from-zrx)
- **out** Environment variables, child processes, and a status that is an
  enum.
- **out** Signals: ending a run on Ctrl-C waits for stopping from outside.

## Collections

[Design record](spec-collections.md)

- **out** `countBy` (it is `foldBy` with a reducer) and `groupBy` with a
  sub-pipe per key.
- **out** An order by several keys other than as a function of the
  caller's.
- **out** `distinct` of adjacent items only, which would belong in the
  core.
- **out** Room that grows, room on the heap, sorting on disk; a text key
  that is not a value.

## Other extensions

- **proposed** An HTTP client, a source of the lines of a TCP connection,
  random numbers.

## Testing

- **proposed** Property tests and fuzzing: a program against a loop by hand
  over `std.testing.fuzz`, starting with `batch(3)`, `flatten()`,
  `take(n)`, which is the first `n` items.
- **proposed** A bounded model of one queue between two segments (TLA+ or
  the like), its counterexamples turned into tests in `tests/flow.zig`.
- **gap** `ext.collections` has no test of a cancelled run.
- **gap** No test holds the safeguard in `zrx.testing.Clock.waitingAt` for
  a waiter that was woken and has not left the list.

## Apps and examples

- **gap** No example or app uses `zrx.ext.collections`, `zrx.ext.time`,
  `zrx.ext.text` or `zrx.ext.compress`.
- **decide** A plain Zig version and an end-to-end benchmark for every app.
  The owner wanted it (2026-11-18), and later closed the one-billion-rows
  app because `http-bench` already compares zrx with plain `std`. Only
  `http-bench` has one.
- **wanted** Check the guidance for writing an app: two new agents write
  the same app, one with the guidance and one without, and the results are
  compared.
- **proposed** `record-processor` with a parsed type apart from the
  validated `Record`, which still holds `amount_text` beside
  `amount_cents`.
- **proposed** Measuring how long items wait in a queue, kept in an app
  until something needs it in the library.

## Project

- **wanted** `CONTRIBUTING.md`, and a `SECURITY.md` that says where to
  report a vulnerability (the HTTP extension runs a server).
- **wanted** Once CI has run on Windows, update what the guide and the
  design records say was not run there (paths in `zrx.ext.fs`, stack use).
- **wanted** An independent read of the guide, the design records and the
  app READMEs, on errors, cancellation and teardown, how long borrowed data
  lives and the limits of HTTP; and someone new to zrx following the
  README.
- **wanted** The apps checked on macOS in CI again. They run on Linux and
  Windows only, since GitHub's hosted macOS runners were too few and jobs
  were dropped without one; the library's suites still run on macOS.
  Back when macOS runners are to be had, or by another way to run them.
- **gap** `.github/copilot-instructions.md` is a link to `AGENTS.md` from
  another folder, so its relative links are broken on GitHub.

## Declined

- **declined** A `run` that returns a value or an error. Whatever a program
  produces is an effect of its pipe.
- **declined** The One Billion Row Challenge as an app (#43): one hot loop
  on one core is not what zrx is for.
- **declined** Benchmarks against Go, Rust or Node.
