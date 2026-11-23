# Agent instructions

Canonical agent guidance for zrx. Agent-specific instruction files are symlinks
to this file; edit `AGENTS.md`, not copies.

## Scope and workflow

- zrx is a declarative push-stream library for Zig with type-keyed dependency
  injection. A system is several programs; a program is one source and one
  terminated pipe; a pipe is a composition of operators; operators take
  handlers. `program.run(deps)` and `system.run(deps)` are the only execution
  boundaries. [docs/guide.md](docs/guide.md) is the user-facing reference.
- Develop in reviewable increments and stop at agreed review points. Recommend
  a concrete next step after each task. Distinguish accepted design decisions
  from proposals. Keep human-facing README content minimal; put detail in the guide.
- One way to write each thing. Before adding an operator, option or accepted
  form, check that it cannot already be written with what exists; if it can,
  do not add a second spelling. Prefer rejecting an ambiguous form with a
  compile error that says what to write instead. Pipe-taking APIs explicitly
  accept both operator tuples and constructed `pipe(...)` values; normalize
  tuples to the existing pipe representation at those API boundaries.
- Build from core principles upward: new behavior is composed from the
  operator, source and handler contracts, not special-cased in the core.
  `src/pipe.zig` (chain), `src/di.zig` (injection) and `src/program.zig` stay
  small and know nothing about individual operators.
- The feature set of the previous implementation is an upper bound, not a
  backlog. Signals, retry and the standalone apps were dropped in the
  rewrite and return only by explicit decision. HTTP has returned by such a
  decision, as the extension `zrx.ext.http` (see below).
- Exactly Zig 0.17.0 (`.zigversion`). Reuse `std.Io`, `std.mem.Allocator` and
  std containers; no scheduler or runtime of our own.

## Design decisions

- **Push with a flow answer.** `down.push(item)` returns `E!Flow` (`.more` or
  `.done`). Early stop is a value, never an error.
- **"Done" is a hint, sticky where it originates.** A stage that answered
  `.done` of its own accord may still be pushed to and keeps answering
  `.done`; whoever is answered `.done` stops pushing items. Final values
  (`fold`, `batch`) are still pushed and refused there. Only an operator
  that pushes into several places keeps track of them (`branch` and `route`
  of their sub-pipes, a rejoining `route` of the pipe after it, `merge` of
  its gate); the synchronous chain remembers nothing, and no promise is made that no
  handler runs for a value nobody takes. PR 3 tried to make that a guarantee and
  needed machinery in the chain, across tasks, that kept regressing.
- **Operators are values; state is separate.** An operator declares
  `Out(Env, In)` and `Stage(Env, In)`. Pipeline type checks happen in `Out`.
  A pipe is an operator and nesting is associative.
- **Dependencies are resolved once.** The environment is a tuple keyed by exact
  type. A stage copies what its handler asked for at `init`; nothing is looked
  up per item. `std.Io` and the allocator are ordinary dependencies.
  The source and all stages use one environment.
- **`provide` and `run` are one concept.** `run` takes bindings: values and
  resources alike. `provide` only gives a program defaults for them:
  `p.provide(a).run(b)` runs with `b` and with what of `a` it does not
  replace. (It is not `p.run(a ++ b)`: within one tuple a type may not have
  two providers.) A binding given to `run` replaces a default that provides
  the same type, and a replaced resource is not acquired. A system hands
  what it resolved to this library's programs as values and to any other
  `zrx_program` as the tuple it is. It tells the two apart by a mark of a
  type private to `src/program.zig`, not by a name: a runnable of a
  caller's own may declare anything. Within either tuple a type has one provider. The order bindings
  are written in decides nothing but ties: a resource declares `Provides`
  and `needs`, and `src/resources.zig` orders acquisition at compile time
  (values, then again and again the first resource in written order whose
  needs are there). Nothing of the graph exists at run time. There is no
  shadowing and no left-to-right application: that made `provide` and `run`
  two things that behaved differently, and a resource given to `run` a
  confusing compile error.
- **Handlers** are comptime-known functions: leading parameters are
  dependencies, trailing parameters are the operator's data and may be
  `anytype`. Composite handlers (`all`, `compose`, ...) are struct types that
  forward their children's requirements. No closures, no runtime function pointers.
- **A seed that has a type is the state; a number without one asks the
  reducer.** `scan`, `fold` and `reduce` take the type of the state from
  the parameter a reducer function declares, else from the seed. A
  `comptime_int` or `comptime_float` seed has none to give, and then a
  composite reducer says it with `State(Item) type`: `fold(0, sum)`
  accumulates in the item's type, `fold(0, count)` in a `usize`, and
  `fold(@as(u64, 0), sum)` in a `u64` whatever is declared. `State` and
  `Inferred` in `src/ops/transform.zig` are the one place that reads a
  seed, for all three; `src/di.zig` knows nothing of it. A reducer that
  declares nothing is a compile error that says to write `@as(T, seed)`.
  The rule is decided; `State(Item)` is the shape proposed for it, a
  decision that awaits the owner's approval, and
  [docs/spec-math.md](docs/spec-math.md#the-seed) has what else was
  weighed.
- **An optional is the answer of a predicate, nowhere else.** Zig says
  "maybe" three ways. `bool` and `E!T` mean something everywhere; `?T` means
  something only where a predicate is asked, and there it means what the
  condition of `if (x) |found|` means: null is no, a value is yes with what
  was found. Three places take one. `when` gives its case `Found(T, Item)`,
  the value with the item, as an error path is given `Failed(E, Item)`: the
  operator is the one that holds the item, so it is the one that pairs.
  `require` returns what was found, or the error. `all` answers what its
  last predicate answers, so a finding predicate goes last and the ones
  before it are tested first; it does not pair, or a predicate would mean
  one thing alone and another inside `all`. `Finds` in
  `src/ops/transform.zig` is the one place that reads a predicate's answer.
  Everywhere else an optional is a value: `map` does not drop a null.
  `filter`, `takeWhile`, `not` and `any` reject a finding predicate with a
  compile error that says where the value could go; each has an obvious
  meaning (`any` of two is `orelse`) and returns when something needs it.
  An earlier draft handed the case its value as a dependency, a pointer the
  route wrote to for every item: it could not be `anytype`, forbade a task
  boundary in the case, and measured 110 instructions where the loop has 71.
- **Errors are Zig errors; one that is taken becomes an item.** A handler
  error fails the run after teardown. `recover(E, path)` guards the
  operators after it per item: a failure with an error in `E` leaves the
  pipe and goes down `path` as a `Failed(E, Item)`. The path is a
  terminated sub-pipe that the stage holds as one value, as `branch` holds
  its own, and that is finished where the `recover` is. `error.Canceled`
  is never taken. A path that answers `.done` ends the stream, so the
  stage remembers nothing; a path that fails fails the run. Errors the
  path does not take are returned by name, so what is left for the run
  to fail with is only those. A final value from a stage before the `recover` is an item
  like any other; errors of a later stage's own finish, or beyond a
  `queue`, are not item errors. The error still comes back up the call
  stack to the `recover` as a Zig error: nothing is carried through the
  chain beside the items, and nothing is rolled back. `recover` took a
  handler before; that is a path of `forEach(handler)`, and there is no
  second spelling. A path cannot contain a task boundary: that would make
  `recover` one more shape for the scope to be tested with.
- **Which errors are taken is decided in one place**: `src/failure.zig`.
  `recover`, `attempt` and `rescue` all take some errors and leave the
  rest, and each of them once had that logic of its own, in two branches
  (the names known, or `anyerror`). They disagreed: two of them returned
  the whole `anyerror` where only a cancellation could be left. `take`
  sorts an error into taken or left, and `Left` is the type of what is
  left, written out and not inferred, so a wrong answer does not compile.
  `Cancellation` says what a cancellation is to the one who asks: nothing
  to an error path (`.passes`), a failure like any to a rescue (`.taken`).
  A new thing that takes failures calls `take`; it does not compare
  errors itself. `tests/failure.zig` holds the table of every combination.
- **The failure of a run goes to a rescue, which stands outside the run.**
  Failures that belong to no item (a source, the end of the stream, a
  resource, another task) are outside every pipe. `rescue(handler)` is
  the third kind of binding: it provides nothing and is not acquired.
  `resources.run` takes it out of the bindings, runs everything else, and
  hands it what that failed with after the last release. Its handler is
  given the plain values of the run and the bindings the rescue was given
  for itself (`rescue(fatal).provide(.{ stderr(Stderr, 256) })`), which are
  resolved by the same `run`, with the values as a resolved environment,
  only when it is called. So the planner knows nothing of it, where it
  is written decides nothing, and nothing of it is in the environment.
  An earlier version made it a resource that provided a marker type and
  was acquired "first". Review found three defects in that one idea: a
  fallible resource written before the rescue's own prerequisite escaped
  it, the marker reached the tuple a custom runnable is given, and its
  validation sat in code a run that cannot fail never reaches. Do not go
  back to placing a rescue among the resources. Whether a rescue stands
  outside is passed down a system as a comptime flag (`rescued`), not as
  a value. It takes a handler and not a pipe on purpose: it is given one
  value once. Its handler returns `void`: it is the last to be given the
  failure. It is given `error.Canceled` like any failure, where an error
  path never takes one: a cancellation is no item's, but it does end the
  run, and `run` has no other way to say so.
- **Check what a user wrote where they wrote it.** A `@compileError` for a
  handler or a binding belongs in the type function that takes it, or in
  code every run reaches. Inside a `catch`, or a branch a particular
  program never takes, it is not a check: a rescue whose handler returned
  a value compiled on every run that could not fail.
- **Check by reading a type, not by calling the handler into being.** The
  fix for the above asked a generic handler for its result with the
  errors of the run, and for a run that cannot fail those are none: the
  handler's body was then checked against an empty set, and a valid
  `switch` over the one error it was written for no longer compiled.
  `declaredReturn` reads the return type off the function type. Only a
  return type that depends on the argument is asked for by a call, and
  only with errors that can occur.
- **What only this library makes is marked by a private type, not a
  name.** A rescue and a resolved environment carry a declaration of the
  type `Mark`, private to `src/resources.zig`, as a program carries
  `Own`. A declaration merely named `zrx_rescue` on a caller's
  dependency once had that dependency taken out of the environment.
  `zrx_resource`, `zrx_operator` and the like are told by name because
  they are contracts a caller writes against.
- **A set that can take nothing is refused where it is written.**
  `recover(error{Canceled}, ...)` and `attempt(sub, error{Canceled}, ...)`
  have a path nobody can reach, since a cancellation always passes. The
  overlap check of `attempt` used to say "it may" whenever the sub-pipe
  could fail with anything; `takesAny` now asks whether the set takes
  anything at all.
- **Task boundaries are `queue`, `batchWithin`, `debounce` and `concurrent`.**
  Timed operators buffer input and wait for deadlines within that contract.
  `branch` is terminal direct fan-out and
  `route` is exclusive direct dispatch; either becomes concurrent only through
  a boundary in a sub-pipe. A rejoining route case cannot contain a boundary.
- **Time is an extension without a task.** `src/ext/time.zig`
  (`zrx.ext.time`) holds a source (`ticks`), a handler (`stamp`) and a
  synchronous operator (`throttle`), each written against its public
  contract. [docs/spec-time.md](docs/spec-time.md) is its design record:
  the reasons, what was rejected and what was measured, and the choices
  that are proposals until the owner decides. Read it before changing the
  extension. The rules it gives:
  - Nothing here keeps an item or starts a task. An operator that has to
    emit while its input is silent is a boundary and belongs with
    `debounce` and `batchWithin`.
  - `ticks` pushes the count; the time is `map(time.stamp(clock))`. A
    late tick is skipped, not caught up.
  - `ticks` waits on `Stop.waitTimeout`, the one addition outside the
    extension, and not with `sleep`. A wake is not the deadline: look at
    the stop and the clock again.
  - `stamp` is always called with its clock.
  - Keep a stage's state in integers the size of a register: `throttle`
    keeps 64 bits of nanoseconds, not the 96 of `std.Io`.
  - Time is counted in 63 bits. A clock comes in through `reading` and a
    period or window through `span`; `after` is the one place that adds
    two times, and it says when the sum does not fit. `throttle` keeps
    when an item passed, not when its window ends. A time past the limit
    never comes: it is not an error and not a panic.
  - Not there, and back only with stopping from outside or by decision:
    `timeout`, `delay`, `sample`, a throttle that emits the last item.
    The stage contract does not grow for them.
- **Concurrent worker pipes are synchronous.** `concurrent(n, sub)` gives
  each worker its own pipe state and serializes pushes into the continuation.
  The boundary registers workers through `Tasks` and `tasks` in the existing
  scope. Its `work` coordinates their ends; no nested supervisor or selective
  cancellation is used for successful completion.
- **A sub-pipe may live for one item.** `each(source_of, sub)` is a nested
  program per item: its stage keeps the environment and a pointer to its
  operator, and for every item constructs `sub`'s stages, runs the item's
  source into them and finishes them, all inside that item's `push`. That is
  construction per item, not a lookup per item: a stage still copies what it
  asked for when it is constructed. `attempt(sub, E, path)` keeps a failed
  item, as whatever its error path makes of the `Failed(E, Item)`: the
  path rejoins, where the path of a `recover` terminates, and both select
  by `E` with the same code. It took a fallback handler before; that is a
  path of `map(fallback)`, and there is no second spelling. `E` is written
  out although the sub-pipe's own errors are known: a path handler has to
  be able to name its item, and an inferred set has no name. A `Seal`
  stands between each of its sub-pipes and the pipe after it: it puts a
  failure of that pipe aside, answers `.done`, and the failure is
  returned once the sub-pipe has returned. Inside the sub-pipe it could
  not be told from the sub-pipe's own, and a flag for it goes stale when
  a `recover` in there swallows it. There are four ways from an
  `attempt` into the pipe after it (either sub-pipe, for an item or at
  the end of the stream) and all four go through a seal. The error path
  once pushed straight on, and a `recover` in it took the failure of the
  final sink. A sub-pipe that rejoins is sealed or it is not: do not
  seal some of its ways out. Neither may contain a task boundary, neither adds to the
  stage contract, and both live in `src/ops/nested.zig` on the operator and
  source contracts. `each` pairs what it emits with the item as
  `Tagged(Item, T)`, where `Item` is the parameter type `source_of`
  declares, as `fold` takes its state type from its reducer.
- **A boundary splits a pipe into segments, each with a task.**
  [docs/spec-segments.md](docs/spec-segments.md) is the design record.
  Segment 0 is the source and the stages up to the first boundary. A program
  with neither a boundary nor a `merge` is a plain loop on the caller's task.
- **What a run guarantees is written in one place**: the "Guarantees" list
  of the spec, where every line names the tests that pin it. A sentence
  nobody has a test for is not a guarantee: the first version of that list
  was written from the design and an independent review found four lines of
  it false (writers flush at teardown, a failing flush, a system, the
  moment cancellation is looked at). The guide repeats it in short and links there; this file and
  the comments in `src/` say how it is done, not what is promised. Do not
  restate a guarantee anywhere else. Each review of PR 5 found a copy that
  had drifted or had been worded more strongly than the code.
- **Promise only what a caller can observe**: what the run fails with (what
  its rescue is given), what was flushed, what has been torn down, whether
  `run` returns. Never a moment
  inside the run, and never "always", "never after" or "whatever else"
  about two tasks: between a look and the act that follows it, the other
  task can move. The caller's cancellation is looked at once the run has
  joined its tasks, and the guarantee says exactly that.
- **The end of the stream travels with the data.** `finish` runs in order up
  to and including a boundary, on the task of the segment before it; the
  boundary's task finishes what follows. No task finishes, joins or waits
  for another segment's stages. The caller constructs stages and owns program
  resources. Resource release wraps the run that joins the tasks.
- **One scope supervises every group of tasks** (`tasks.Scope`): the segments
  of a program, the sources of `merge`, the programs of `system`. Members are
  started as tasks of an `Io.Group`, each on its own `Io`, and never run on
  the supervising task. That task waits in one place, which can be cancelled.
  When the run is over without success it tells everyone at once: every
  member is retired (queues close, so nobody waits on one whatever became
  of its request to cancel) and all members on one `Io` are asked to cancel
  together (one `Io.Group`). Then it joins them and looks at its own
  cancellation once more before it returns. Do not go back to asking tasks
  one after another, nor rely on a request to cancel arriving as
  `error.Canceled`: `std.Io.Writer` reports it as a failed write, and the
  request is used up. That is `std`'s behaviour and stays on the spec's
  "not promised" list. Do not wrap `std` writers to change it: one attempt
  corrupted short writes and dropped `sendFile`. A failure is a task's return value: nothing is
  reported on the side, and nothing is cast from `anyerror`. There is no
  sequential fallback; a `merge` or `system` of one runs that one in place.
- **Every task ends its work in one place** (`Scope.Runner`), in a fixed
  order: `run`; under the mutex, put a failure on record; `retire` (nobody
  waits on it again: a queue closes); under the mutex, as the last thing
  before it, decide whether to end; `end` (finish the segment's stages). A
  segment and an operator only say what each step is. A decision that turns
  out to be taken at the wrong moment is moved in that sequence, not patched
  where the symptom showed.
- **Successful completion can notify a cooperating producer.** A producer
  that asks for `zrx.Stop` gets a signal owned by the run. Segment and fan-out
  demand is wired at setup for that producer. A completed consumer withdraws
  demand, and a producer that observes the signal returns normally. Selective
  task cancellation remains out of scope. The spec records the problems in
  PR 5 with cancelling a task that still had to finish its stream.
- **Do not add to the stage contract for concurrency.** A boundary stage has
  `zrx_boundary`, `work`, `retire` and `taskIo`; a stage with sub-pipes has
  `has_boundary`, `Tasks` and `tasks`. A review finding against something
  the spec lists as not promised is answered by pointing there, not by a
  change.
  A boundary can combine its existing hooks with `Tasks` and `tasks` to
  register auxiliary members in that same scope; these share its demand node.
- **`merge` forgets the source; `mergeTagged` is how it is kept.** An enum
  for sources of one item type (`Tagged(Enum, Item)`), a tagged union for
  different types. A union whose variants all hold one type is rejected in
  favor of the enum, so there is one spelling. It is `merge` over sources
  wrapped to mark what they push; the scope knows nothing of it. Do not
  add a way to put operators on a source before a merge: operators live in
  the program's pipe.
- **JSON is an extension named after its format.** `src/ext/json.zig`
  (`zrx.ext.json`) holds two handlers over `std.json`, `encode` and
  `decode`, and is analyzed only when referenced.
  [docs/spec-json.md](docs/spec-json.md) is its design record: the
  reasons, what was rejected and what was measured. Read it before
  changing the extension. The rules it gives:
  - One spelling each: `map(json.encode(.{}))`, formatted with `{f}`, and
    `map(json.decode(T, options))`. Both are always called with their
    options. There is no sink that hides `write(Role, "{f}\n")`, and no
    general serialization layer for one format.
  - `decode` is put to text, a `[]const u8` or a value with `text()`, and
    reads one whole document. Parsing stays `std.json`'s.
  - What is decoded is a value. Whether a `T` is one is read off the
    type: a pointer anywhere in it is refused where `decode` is written.
    No `from` contract and no shadow type built from `T`.
  - Text in a value is a `Line(n)`, which has `jsonParse` and
    `jsonParseFromValue` beside its `jsonStringify` in `src/io.zig`.
    Those are `std.json`'s hooks and all the core has of this. Both read
    the same, a string or an array of numbers: one way to read a `Line`
    at either of `std.json`'s ways in. A hook can fail only with what
    `std.json` already fails with from where it is called.
  - The scratch memory is a size in the options, on the handler's stack
    and new for every item, not an allocator dependency. It has no
    default: what a text needs differs by target.
  - `DecodeError` is written out, so that an error `std` adds does not
    compile.
  - `decode` has no fixture and no claim of zero overhead: the parser is
    called, not inlined. Do not widen `tools/same_code.zig` for it.
  - Not there, and back only by decision: a decoder that reads as the
    text arrives, and a document that spans items.
- **A text pattern is a handler, and it does not go back.**
  `src/ext/pattern.zig` (`zrx.ext.pattern`) is written against the handler
  contract alone and has no operator.
  [docs/spec-pattern.md](docs/spec-pattern.md) is its design record: the
  reasons, what was rejected and what was measured. Read it before
  changing the extension. The rules it gives:
  - A pattern is a composite handler, a predicate on one item of text.
    One that extracts answers `?Extracted(p)`. There is no `match(p)`.
  - Matching goes left to right and gives nothing back. Do not soften
    that, and do not call it a regular expression.
  - Do not say that nothing is read twice, or that a pattern costs what
    the hand-written scanner costs on any text. Give the measurements.
  - A pattern that can be seen never to match is a compile error. Where
    it cannot be seen, say nothing rather than guess.
  - Bytes only, no Unicode classes.
  - What is taken out of a value, such as a `Line`, is a value. Whether a
    `T` is one is read off the type: a pointer anywhere in it borrows.
  - That a part can match nothing (`nullable`) is not that it always
    matches: what it matched may still be refused (`refuses`). It always
    matches where it is `nullable` and does not refuse. Nor is it that it
    never matches (`never`). `oneOf` and `optional` ask whether it always
    matches, `repeat` whether it can match nothing.
  - `recursive` builds its levels at compile time. Nothing calls itself
    as deep as a text asks.
  - A rule has no fixture and no claim of zero overhead. A second way to
    match is worth having only if it improves every `lean_pattern_*`
    fixture.
  - Not there, and back only by decision: a format string read
    backwards, going back, finding the places a pattern matches inside a
    text, a node that only groups extracts.
- **Math is handlers over `std.math`, and has no operator.**
  `src/ext/math.zig` (`zrx.ext.math`) is written against the handler
  contract alone. [docs/spec-math.md](docs/spec-math.md) is its design
  record: the reasons, what was rejected and what was measured. Read it
  before changing the extension. The rules it gives:
  - A transform changes one item and has an operand known at compile
    time. A reducer takes a state and an item, and one reducer serves
    `fold`, `scan` and `reduce`: there is no operator that adds up a
    stream.
  - The plain forms are the plain operators. Do not make them check, wrap
    or saturate.
  - `checked` holds only what can fail, and fails with nothing but
    `error.Overflow`. Do not add a checked form of what cannot fail
    (`div`, `mod`, `abs`, `clamp`, `min`, `max`, `count`).
  - An operand is a value of the items' type, and is judged as that type
    has it, never as it was written: `1e-10` is 0 for `f16` items.
    `operand` is the one function that makes an operand a `T`. One that
    can never work is a compile error.
  - The mean of `Stats` divides the item and the mean by the count before
    it subtracts them. Do not put back the update with one division: the
    difference of two finite items can be infinite.
  - The seed takes part like an item, and it is what a stream without
    items comes to. `min` and `max` have no value before the first item
    only in a state that is an optional, which is then a value: a reducer
    drops nothing and skips nothing.
  - Not there, and back only by decision: forms that wrap or saturate, a
    power that is not a whole number, conversion between integers and
    floats, vectors, `fold(null, min)`.

- **A text handler answers what the bytes allow.** `src/ext/text.zig`
  (`zrx.ext.text`) is handlers and one source over `std.mem` and
  `std.ascii`, written against the handler and source contracts, with no
  operator. [docs/spec-text.md](docs/spec-text.md) is its design record:
  the reasons, what was rejected, what was measured, and which of its
  choices are proposals still to be decided. Read it before changing the
  extension. The rules it gives:
  - `trim`, `trimStart` and `trimEnd` put to a `[]const u8` answer a
    slice of the same bytes; put to a `Line(n)` they answer a `Line(n)`.
    What is made of a value is a value, as for a pattern.
  - `toUpper` and `toLower` are put to a line. Put to a `[]const u8`
    they are a compile error that says to copy first; do not add a
    second spelling for `compose(.{ Line(32).from, text.toUpper })`.
  - The bytes to strip are always named. There is no bare `trim`.
  - The one value made here is a `Line(n)`, told by identity. What only
    reads a text takes what a pattern takes.
  - `split` and `tokenize` are handlers that answer a source, for `each`.
    The source keeps the item and reads its text in `run`: a slice taken
    in the handler would live no longer than that call.
  - A piece of a line lives no longer than the push of that line. That
    is not checked and cannot be from an extension; say so, as for
    `fileBytes`, and do not promise more.
  - Bytes only: ASCII classes and case, no Unicode.
  - Give the copies of a line as measurements of the fixtures, not as a
    rule (see "Zero overhead").
  - Not there, and back only by decision: predicates. A text that is, or
    starts with, some text is a pattern. `endsWith` is not one and is
    left out with `contains`; do not add either in passing.
- **Text sinks differ only in when they flush.** `print` flushes every
  item, `write` once at the end. `fileWriter`'s `.publish` mode names the
  file after the run has succeeded; it can fail, which a resource `release`
  cannot, so it happens in the binding after the rest of the run returns.
  That makes it atomic per file and not per run: say so wherever it is
  described. The first wording promised that a failed run leaves no file,
  and a review showed two published files where it did.
- **Bytes are an extension named after what it works on, not after
  cryptography.** `src/ext/bytes.zig` (`zrx.ext.bytes`) is written against
  the handler contract alone and has no operator.
  [docs/spec-bytes.md](docs/spec-bytes.md) is its design record: the
  reasons, what was rejected and what was measured. Read it before
  changing the extension. The rules it gives:
  - Digests of `std.crypto.hash` and of `std.hash` alike, and the text of
    bytes. No ciphers, signatures, keys or constant-time comparison.
  - `digest(start)` is a type, the state of a `fold`:
    `fold(State{}, State.update)`, then `map(State.final)`. Plain
    functions, so that a state of a caller's own can hold one.
  - It takes the hasher as its own `init` starts it, a value and not a
    type. Do not guess how a hasher is started.
  - A hasher is told by shape (`Finish.of`), not by a list of names:
    `update`, and a `final` that returns the digest, an unsigned
    integer, or fills an array of bytes with it. What is a digest is
    said in `finished` and nowhere else; what does not have that shape
    is refused, not worked around.
  - Do not call the digest zero overhead without saying what the state
    costs: a reducer is given its state as a value, and a hasher that
    holds a block is copied out and back for each piece. Do not remove
    the copies by another way of calling a reducer without a decision.
  - `hex` and `base64` make an array of an array. Of an item whose length
    is not known at compile time they make a value that holds the item
    and is written with `{f}`, as `json.encode` does.
  - Decoding returns `[n]u8`: the length is written, so the result is a
    value. A text of another length is `error.InvalidLength`.
  - A fixture here brings no error names of its own into `cases.zig`:
    one did, and five fixtures of other operators stopped matching.
  - Not there, and back only by decision: decoding to a length the text
    chooses, Base64 of a stream of pieces, an operator that feeds a
    hasher in place.
- **HTTP is an extension, not core.** `src/ext/http.zig` (`zrx.ext.http`)
  is written against the public source, operator and handler contracts,
  and the core knows nothing of it (it still compiles freestanding).
  [docs/spec-http.md](docs/spec-http.md) is its design record: the
  reasons and what review found. Read it before changing the extension.
  The rules it gives:
  - What it does is described in the guide's HTTP section and pinned in
    `tests/http.zig`: a behavior goes into that section together with its
    test. Performance is stated only in the benchmark app's README, with
    the measurement behind it.
  - `serve` holds a synchronous sub-pipe per connection. A boundary
    inside it is a compile error.
  - `reject` is the one way to let go of a connection. Do not make the
    table evict, or the source guess, to hide a pipe that drops one.
  - A connection is handed over once, checked by a generation per slot.
    Do not compare sockets: the system reuses their handles.
  - Responders write unflushed and `serve` flushes before a read that may
    wait for the peer. Do not flush per response.
  - Every head is written by `Exchange.begin`. Do not use `std`'s
    `respondStreaming`.
  - An unread body is skipped only once the pipe is through with the
    request: the read overwrites the head an item may point into.
  - A socket on which `std` recorded a failure is not read from or
    written to again.
  - A request is refused before any handler sees it where a proxy could
    read its head differently. No body framed by a transfer coding is
    read: chunked request bodies return by decision.
  - Parsing stays `std.http.Server`'s. HTTP imports nothing of the
    pattern extension and has no router of its own; do not give it one.
- **Compression is bindings, and the codecs are `std`'s.**
  `src/ext/compress.zig` (`zrx.ext.compress`) is written against the
  public resource contract and has no operator, source or handler.
  [docs/spec-compress.md](docs/spec-compress.md) is its design record: the
  reasons, what was rejected and what was measured. Read it before
  changing the extension. The rules it gives:
  - A binding needs one role and provides another, and the planner knows
    nothing of it. Two roles, because a type has one provider: the same
    role on both sides is a compile error where it is written.
  - No codec of zrx's own. What is there is what `std.compress` can do
    within a memory the caller sizes: gzip and zlib both ways, Zstandard
    read only. xz returns when `std`'s decoder is bounded.
  - Nothing is allocated. The Zstandard window is a slice of the
    caller's, and its length says how much window there is.
  - A program is not handed a `std` decoder's own reader: it asserts. Do
    not remove the buffer in front of it to save a copy.
  - A flate decoder reads the caller's reader itself where that reader
    can hold what the decoder asks for. Do not put a buffer of the
    binding's between them: it takes from the caller's reader what
    follows a zlib stream.
  - `std` compares no gzip or zlib checksum, checks only part of a
    header, and reads one gzip member. The extension does all three. A
    decoder that failed is not asked again.
  - A checksum is compared, and what follows a zlib stream is left, only
    once the stream is read to its end: a pipe that is done early reads
    no further.
  - A corrupt or truncated input is `error.ReadFailed` and nothing more
    specific, so a rescue written for the plain program still fits.
  - The end of a compressed stream is written in the binding after
    everything it wraps has returned without an error, as `.publish`
    names its file, and the writer below is flushed there. A failure of
    what the binding wraps leaves the stream without its end on purpose;
    nothing more is said of a failed run, and publication is atomic per
    file.
  - Do not wrap `std` writers. What cannot be said at compile time, a
    writer below or a Zstandard slice that `std` would assert on, is an
    error at acquisition.
  - Say what each window costs, and give stack use as a measurement.
  - There is no zero-overhead fixture: nothing here is in the item loop.
- **Collections keep their items in room that is written with them.**
  `src/ext/collections.zig` (`zrx.ext.collections`) is written against the
  operator and handler contracts: `distinct`, `foldBy`, `sorted`, `top` and
  `takeLast`. [docs/spec-collections.md](docs/spec-collections.md) is its
  design record: the reasons, what was rejected, what was measured and
  what is still open for decision. Read it before changing the extension.
  The rules it gives:
  - No allocator, as in the core. Every count is known at compile time
    and the room is part of a stage. Do not bring back an arena or a
    binding for memory, and do not let an operator hold a slice of the
    caller's in place of a size: `concurrent` makes the stages of every
    worker from one operator value, and they would share it.
  - An item that does not fit fails in `push`, before anything is
    written, with `error.TooManyItems` or `error.TooManyKeys`, so that a
    `recover` before the operator can take it. `top` and `takeLast` are
    never full.
  - Look first, write last. `foldBy` looks the key up, looks whether
    there is room, asks the reducer and only then writes: an item that is
    rejected leaves the table exactly as it was. An earlier version took
    a place first and gave it back on a failure, and did not give back
    all of it.
  - Every operator is two stages: `Room`, which is the arrays and
    nothing else, and one that holds the counters and works through a
    pointer `Room` hands on with each item. Do not put a counter beside
    an array, and do not have a stage pushed to from two places when
    what it does for an item is large: the spec has what each of those
    measured.
  - The table of `distinct` and `foldBy` is this extension's own, with
    `std`'s hash and comparison: `std`'s maps cannot be sized without an
    allocator. Nothing is ever taken out of it.
  - One way to write each thing: a count per key is `foldBy` with a
    reducer, so there is no `countBy`. An item that is its own key is
    `itself`, so no operator has a second form without a key.
  - `Keys` is the one place that reads a key's type. A key is a value: a
    pointer anywhere in it, a `[]const u8` included, is a compile error
    that says to key by a `Line(n)`. So is a float.
  - `keyBefore` is the one place that compares two keys, for both
    orders. A NaN comes after every number in `ascending` and in
    `descending` alike. An order is a handler of two items that cannot
    fail. `sorted` is stable, and `top` emits exactly what `sorted` and
    `take` emit: keep the tests that hold them together, the one with
    NaNs among them.
  - All five have a fixture: `takeLast` is `same`, the other four are
    `lean`, each with its reason beside it. The loop by hand keeps its
    arrays on its stack and its counters in locals; do not give it the
    shape of the stages to make a fixture pass.
  - `tests/zero_overhead/cases.zig` names the errors of its fixtures in a
    `comptime` block so that both variants number them alike. A fixture
    that brings a new error adds it there.
  - Not there, and back only by decision: `groupBy` with a sub-pipe per
    key, room that grows, room on the heap.
- **A directory is a source, named by its path.** `src/ext/fs.zig`
  (`zrx.ext.fs`) holds two sources of a directory, `entries` and `walk`,
  and what opens a file: the bindings `fileReader` and `fileWriter` and
  the sources `fileLines` and `fileBytes`. It is written against the
  source and resource contracts alone.
  [docs/spec-fs.md](docs/spec-fs.md) is its design record: the reasons and
  what was rejected. Read it before changing the extension. The rules it
  gives:
  - The core opens nothing: `src/io.zig` is `print`, `write`, `lines` and
    `Line`, over a reader or a writer somebody else made. What opens a
    file is here and what opens a standard stream is in
    `zrx.ext.process`. Do not put a file or a stream back into the core.
  - `fileLines` is the core's `lines` over the reader it opens. Do not
    give it a line reader of its own.
  - `fileLines` and `fileBytes` borrow their path, so neither may be made
    from text an item holds inline (an entry's path) in the `source_of` of
    an `each`; a slice whose bytes live elsewhere is fine. That is open, and
    recorded in the spec: do not fix it in passing.
  - The directory is given by path, as for `fileLines`, not by a role. A
    source holds a copy of its path, so one may be made from an entry
    inside the `source_of` of an `each`.
  - An item holds its path inline (`Entry(n)`), beginning with the
    directory's as it was given. What does not fit fails the run with
    `error.PathTooLong`, and a path `std` would not open (of
    `std.fs.max_path_bytes` bytes or more, or on Windows of more than
    `PATH_MAX_WIDE` UTF-16 units) with `error.NameTooLong`, before it is
    given; the directory a source is given, before it is opened.
  - Nothing allocates. What a source needs room for is written where it
    is made, and running out is an error of its own name: `walk(path, n,
    depth)` holds `depth` listings in its `run` and fails with
    `error.TooDeep`. The directory given is depth 1. Not a list that
    grows, and not the call stack.
  - A name is joined by the path rules of the system, in `joinAs`: no
    separator after one, nor after a drive alone on Windows. Windows is
    not run here, so a change to the join is pinned by the join tests,
    which hold both sets of rules on any system.
  - Every directory that was opened is closed on every way out. Do not
    use `std`'s `Walker`: its `deinit` leaves them open. A directory is
    pushed before it is opened.
  - A kind the listing left `.unknown` is asked for. Links are never
    followed, also not one put in a directory's place since it was listed.
  - What cannot be opened or read fails the run: it is the source's
    failure and belongs to no item. An error path takes one directory
    when the directory is an item (`each` under `attempt`). Do not carry
    a failure in the item to go on past it.
  - Both sources ask for `zrx.Stop` and look at it before each read.
  - Tests depend neither on the order of a listing nor on permissions:
    the test `Io` in `tests/fs.zig` stands in for what is not at hand.
  - No zero-overhead fixture and no claim of zero overhead.
  - Not there, and back only by decision: watching, globbing, following
    links, sorting, metadata beyond the kind, going on past an
    unreadable directory within one walk.
- **Lifecycle.** Stages are constructed in place, process items with `push`,
  and handle normal input end with optional `finish`. `print` handles its
  writer's flush in those hooks. Program resource `release` cannot fail.
- **Programs must terminate.** `program` takes a source and a terminated
  operator tuple or `pipe(...)` value. Each child of `branch`, and the
  sub-pipes of `when` and `otherwise`, accept those same two forms, never a
  bare operator. Every branch must terminate; route cases may rejoin.
- **A run returns nothing.** `run` returns `void`, by design: neither a
  value nor an error. Whatever a program produces (output, a summary, a
  count that decides an exit status) is an effect of a stage in its pipe:
  a sink, or a handler that writes through a dependency, such as
  `tap(remember)` into a `*Summary`. What fails it is taken inside it, by
  an error path or by its rescue, whose effect is the same kind of thing:
  a line on stderr, a status in an `*Exit`. `whole` in `src/program.zig`
  is the one place that enforces it: the error set of the run must be
  empty there, and what is left is named in the compile error. Inside the
  library a run is still an error union (`runResolved`, a system's
  members, the scope): only the two public `run`s are total. That is the
  intended form and not a workaround. Do not list "a program has no
  result" as a gap, and do not add a way to return a value or an error
  from `run`. zrx does not call `io.recancel()` for a cancelled run:
  `std` asserts an acknowledged request, and a handler can return
  `error.Canceled` without one. The rescue is given the cancellation and
  the choice is its handler's.
- **The process is an extension: its streams are bindings, and nothing in
  it ends the process.** `src/ext/process.zig` (`zrx.ext.process`) holds
  the three standard streams, `Exit`, `status` and `fail`, written against
  the resource and handler contracts alone.
  [docs/spec-process.md](docs/spec-process.md) is its design record: the
  reasons, what was rejected and what was measured. Read it before
  changing the extension. The rules it gives:
  - A stream names its role first, as `fileReader` and `fileWriter` do:
    `stdin(Role, n)`, `stdout(Role, n)`, `stderr(Role, n)`. There is no
    form without a role beside it.
  - The core has no standard streams: `Stdout`, `Stderr` and `Stdin` are
    declared here, and the lines of standard input are `lines(Stdin, n)`
    with a `stdin` binding. Do not put `stdout(n)` or `stdinLines(n)` back
    as a shorter spelling.
  - Nothing allocates and the binding flushes nothing. A read that fails
    through `stdin` is `error.ReadFailed`, as through `fileReader`: do not
    put the system's error in its place there.
  - `status(n)` raises and never lowers. `fail(options)` sets: a rescue is
    called once. `status` refuses an error alone and `fail` anything but
    one, so there is one way to write each.
  - `fail` is not a binding:
    `rescue(process.fail(.{})).provide(.{stderr(Stderr, 256)})` stays the
    one way to bind a rescue, and what `fail` asks for is checked by the
    errors `rescue` already has.
  - One spelling: `fail` is always called with its options, and the silent
    form is `.prefix = null`, not a second handler.
  - The status is set first. The line is best effort, and it is one line:
    a control byte in the prefix is refused where it is written.
  - `fail` is given `error.Canceled` like any failure. Nothing here calls
    `std.process.exit` or `io.recancel()`.
  - A fixture in which an error's name is written takes the error as a
    parameter: errors are numbered per compilation.
  - Not there, and back only by decision: an arguments source, a typed
    parser of options, a usage text, choosing a program, a `refuse`, a
    binding chosen at run time, environment variables, child processes,
    signals.

## Zero overhead

- Claim only what is checked. `zig build zero-overhead` compares optimized LLVM
  IR of pipelines and hand-written loops (`tests/zero_overhead`,
  `tools/same_code.zig`). When adding or changing a synchronous operator, add
  or extend a fixture (every synchronous operator has one); a new fixture is
  `same_*` unless the difference is only loop shape, then `lean_*` with the
  reason in a comment.
- Do not force inlining. Keep stages free of hidden memory: return
  `down.push(x)` directly or compare its result and return a constant; never
  store a `Flow` and later select between it and a constant (it defeats the
  optimizer; `lean_take` exists because of this).
- Each stage of a program is its own local (`Chain.withLocals`); nested pipes
  are spliced so this holds for them too. Sub-pipes of `branch` and `route`
  are stored as one value. A stage that indexes into an array it owns cannot
  be kept in registers at all, so give such a buffer a stage of its own and
  keep counters in another (see `batch`).
- `tools/same_code.zig` compares instruction shape: the multiset of
  instructions with value and block names erased, phi inputs in any order, and
  `> c` equal to `>= c + 1`. Nothing else is equated; a comparison never
  matches its negation. Say "the same instructions" for a `same_*` fixture,
  not "the same program": wiring is not compared, `behavior.zig` covers
  results. The tool has tests of its own. Do not widen it to make a fixture pass.
- A fixture that names an error no fixture names yet stands before the
  first one that names an error (`recover`), not at the end of
  `cases.zig`. The integer behind an error is given out as the compiler
  comes to the name, the exported functions at the end of the file first:
  appended, `same_math_checked` shifted the errors of three older
  fixtures and with them the form of their comparisons.
- `queue` costs a real buffer and a task; say so rather than hiding it.
- An item goes from stage to stage as a value, and whether the optimizer
  takes a copy out depends on the pipe. Give the measurements and no
  rule: a rule was written here twice and was wrong twice ("one copy for
  each handler", then "only where a handler scans the bytes"). Measured
  on a `Line(120)` from a slice, optimized for aarch64: no copy with
  `filter`, `map` and `forEach` where the handlers read only the length;
  the line once with one handler that scans; with three, once and once
  more for an item the first filter lets through; and behind `batch(128)`
  and `flatten()` the line once, into the buffer, and the buffer once for
  each batch that is emitted, though the handler reads only the length.
  Those are the copies in the compiled code, read off the optimized IR by
  where each stands: the first table counted two places that copy a batch
  as two copies of it, and one is taken when a batch fills and the other
  at the end of the stream. No test holds the counts; the two fixtures
  named here use a `Line(32)` and hold their own comparison. That was found when the first
  fixture with such an item failed as `lean` with a function handler
  exactly as with a pattern, so it is not the pattern's cost.
  `lean_pattern_line` has the copy on both sides and says so; the guide
  says so. It is not the call of the handler either. This file said so
  at first, and "one copy for each handler": a prototype in which a
  handler declared `*const Item` and its stage passed a reference had the
  same copies, so do not add that as a second way to write a handler.
  What has none is a pipe whose items are references from the source on
  (`*const Row`), which needs nothing new: `same_line_reference` holds
  that such a pipe is the loop over pointers, for a `Line(32)`. The line
  sources push values so that a line can cross a `queue`. A
  source of references would be good only up to the next boundary, and
  comes by decision, with a rule for that.

## Diagnostics

- Every misuse a user can plausibly write gets a `@compileError` that names the
  operator, states what was found, and says what to write instead. Each has a
  case in `tests/compile_fail/` with its exact message in
  `tests/compile_fail.zig`. Checks inside runtime functions need `comptime`
  (`if (comptime !ok) @compileError(...)`).
- Comptime entry points raise the branch quota with
  `@setEvalBranchQuota(di.quota)`; new reflection-heavy functions do the same.

## Tests and examples

- A test runs a program through `support.run(program, deps)`, which binds
  a rescue that hands the failure back, so `try` and `expectError` read as
  they would for an error union. A run that cannot fail, and one that is
  given a rescue of its own, is run directly. What a run can still fail
  with is asked through `support.runLeft`, whose `anytype` rescue writes
  the names down when the run fails: make it fail with what should be
  left. A mutant then fails a test instead of failing to compile.
- Suites in `tests/` import only the public `zrx` module, one file per area.
  `tests/extending.zig` keeps the public operator, source and handler contracts
  (and the guide's example) honest.
- Examples are small, use function aliases at the top (`const map = zrx.map;`),
  and have their exact output asserted in `build.zig`.
- Examples and apps are written with the extensions. A handler written
  by hand for what an extension has (`add` beside `math.sum`, an `Exit`
  and a `fatal` beside `process.Exit` and `process.fail`) is a second
  spelling in the place a reader copies from. An extension is aliased at
  the top like the core: `const sum = zrx.ext.math.sum;`.
- In examples, apps and documentation, write a pipe with one operator per line
  (end the tuple with a trailing comma so `zig fmt` keeps it that way), and do
  the same for the sub-pipes of `branch` and the cases of `route`. A pipe with
  a single operator stays on one line. Name sub-pipes rather than nesting
  multi-line pipes deeply. Tests may keep short pipes on one line.
- `examples/apps/` holds independent projects that depend on zrx by path and
  have their own CI job; see `examples/apps/README.md`. A gap found while
  writing an app is recorded in that app's README, not fixed in passing.
- `zig build test` must pass in Debug and ReleaseFast; `zig build check` adds
  formatting and the cross-target catalog (the core must compile freestanding).
- Tests that need concurrency use `std.testing.io` and must not depend on
  timing or scheduling order, neither to pass nor to catch what they are
  for. Never wait a length of time or a number of yields for something to
  have happened: wait on an event the test can observe. To put a request at
  a chosen point of another task, hold that task there with a test `Io`
  (`support.JoinHeld` holds a task at its join until it has been asked to
  cancel). The third review of PR 5 found a test that waited 2000 yields
  and failed when the test thread was held up.
- Things that run at the same time (programs of a system, segments, queued
  sub-pipes) get a log each: the test logs are not synchronized. To show
  that something is interrupted, have it wait far longer than the test and
  record whether it woke by itself, rather than measuring how long the run
  took. To show that a check stops something, the party that waits for the
  event must wait without sleeping (spin on `checkCancel` or on shared
  state): if it sleeps it is cancelled where it sleeps, and the test passes
  without the check. Before a test cancels a task, it waits until that task
  has started everything it starts.
- In Debug, `std.testing.io` can lose a request to cancel that is pending
  while the task starts another one: its allocator captures a stack trace
  through a lock that can be cancelled. Measured: 6 of 300 Debug runs lost
  it, none over `std.heap.smp_allocator`, none in ReleaseFast. A test that
  has a request pending while tasks are started uses an `Io` over a plain
  allocator; suspect this before the library when only Debug fails so.
- A mutant that does not compile proves nothing: the runner must report a
  failed build as such. Twice a check here passed for that reason.
- A mutant that survives on one machine does not show its safeguard to be
  redundant. A check in `serve` kept `std`'s shared constant reader from
  being written to; every test passed without it on macOS, it was removed
  as unpinned, and the whole HTTP suite then crashed on Linux in
  ReleaseFast. Before removing such a check, find out why it is there.
- A change to the scope or to segments is checked by removing each safeguard
  in turn and seeing a test fail, and by repeating the `flow`, `programs`
  and `extending` suites a few hundred times in Debug and ReleaseFast under
  a watchdog that also fails when the binary is missing. A hang is a
  failure. Repetition finds little by itself: 300 clean runs hid a hang
  that one differently paced source showed at once. Run the repeats in
  several loops at the same time: two runnables that wrote to one log
  passed 400 runs in a row and failed ten times in 3600 run six abreast.
- Concurrency is tested as invariants over shapes (`tests/flow.zig`): every
  shape of pipe is run with its ended side running out, being done and
  failing. A new shape goes there, not into a one-off test.

## README, CI and releases

- The README is for a reader deciding whether to try zrx: what it is,
  install, the quickstart, the model, zero overhead in a paragraph,
  platforms, the build commands. Keep each a few lines. Numbers that
  change with the code (how many fixtures, what is `lean`) are in the
  guide, and the README links there. The README's quickstart is
  `examples/quickstart.zig` without its comments; change both together.
- The install lines of the README are what
  `.github/scripts/consumer-smoke.sh` runs: a new project, an empty package
  cache, `zig fetch --save=zrx` and the two `build.zig` lines. Change the
  two together.
- `.paths` in `build.zig.zon` is what a dependent fetches: the library and
  what `build.zig` needs to be loaded. A file that `build.zig` imports or
  embeds goes in that list; the smoke test fails without it.
- CI checks a pull request into `main`, natively on Linux, macOS and
  Windows; formatting and the cross-target catalog run on Linux. A pull
  request into any other branch runs no job, so a stack is merged into
  the branch of its bottom pull request and checked once, where it
  reaches `main`. `main` takes a branch only up to date, so nothing runs
  again on a push to it. Branches are deleted when they are merged.
- A release is a version tag on a commit of `main`. Its work goes into a
  branch `release/vX.Y.Z`, whose pull request into `main` is where it is
  checked; that branch also changes `.version` in `build.zig.zon` and the
  tag in the README's install line. After it is merged the owner tags the
  merge commit GitHub reports for that pull request, not a local `main`,
  which can be stale and already declare the version, and pushes `vX.Y.Z`.
  A version tag cannot be moved or deleted (a ruleset of the repository,
  with no one to bypass it): a wrong release is followed by a new version,
  not mended under the same tag.
  `.github/workflows/release.yml` checks that the tag names the version,
  validates the tagged commit, installs the published archive with the
  smoke test and makes a draft release. The owner publishes it. Agents do
  not push tags or publish releases.
