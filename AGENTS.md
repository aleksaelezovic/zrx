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
  backlog. HTTP, signals, retry and the standalone apps were dropped in the
  rewrite and return only by explicit decision.
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
  `Program.provide` applies bindings in order before constructing the stages.
  A binding shadows an earlier value of the same type. The source and all
  stages use the resulting environment.
- **Handlers** are comptime-known functions: leading parameters are
  dependencies, trailing parameters are the operator's data and may be
  `anytype`. Composite handlers (`all`, `compose`, ...) are struct types that
  forward their children's requirements. No closures, no runtime function pointers.
- **Errors are Zig errors.** A handler error fails the run after teardown.
  `recover(handler)` guards the operators after it per item; its error
  parameter type selects what it handles; `error.Canceled` is never handled.
  A final value from a stage before the `recover` is an item like any other;
  errors of a later stage's own finish, or beyond a `queue`, are
  not item errors. No error lane,
  no rollback.
- **Task boundaries are `queue`, `batchWithin`, `debounce` and `concurrent`.**
  Timed operators buffer input and wait for deadlines within that contract.
  `branch` is terminal direct fan-out and
  `route` is exclusive direct dispatch; either becomes concurrent only through
  a boundary in a sub-pipe. A rejoining route case cannot contain a boundary.
- **Concurrent worker pipes are synchronous.** `concurrent(n, sub)` gives
  each worker its own pipe state and serializes pushes into the continuation.
  The boundary registers workers through `Tasks` and `tasks` in the existing
  scope. Its `work` coordinates their ends; no nested supervisor or selective
  cancellation is used for successful completion.
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
- **Promise only what a caller can observe**: what `run` returns, what was
  flushed, what has been torn down, whether `run` returns. Never a moment
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
- **Text sinks differ only in when they flush.** `print` flushes every
  item, `write` once at the end. `fileWriter`'s `.publish` mode names the
  file after the run has succeeded; it can fail, which a resource `release`
  cannot, so it happens in the binding after the rest of the run returns.
  That makes it atomic per file and not per run: say so wherever it is
  described. The first wording promised that a failed run leaves no file,
  and a review showed two published files where it did.
- **Lifecycle.** Stages are constructed in place, process items with `push`,
  and handle normal input end with optional `finish`. `print` handles its
  writer's flush in those hooks. Program resource `release` cannot fail.
- **Programs must terminate.** `program` takes a source and a terminated
  operator tuple or `pipe(...)` value. Each child of `branch`, and the
  sub-pipes of `when` and `otherwise`, accept those same two forms, never a
  bare operator. Every branch must terminate; route cases may rejoin.

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
- `queue` costs a real buffer and a task; say so rather than hiding it.

## Diagnostics

- Every misuse a user can plausibly write gets a `@compileError` that names the
  operator, states what was found, and says what to write instead. Each has a
  case in `tests/compile_fail/` with its exact message in
  `tests/compile_fail.zig`. Checks inside runtime functions need `comptime`
  (`if (comptime !ok) @compileError(...)`).
- Comptime entry points raise the branch quota with
  `@setEvalBranchQuota(di.quota)`; new reflection-heavy functions do the same.

## Tests and examples

- Suites in `tests/` import only the public `zrx` module, one file per area.
  `tests/extending.zig` keeps the public operator, source and handler contracts
  (and the guide's example) honest.
- Examples are small, use function aliases at the top (`const map = zrx.map;`),
  and have their exact output asserted in `build.zig`.
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
- A change to the scope or to segments is checked by removing each safeguard
  in turn and seeing a test fail, and by repeating the `flow`, `programs`
  and `extending` suites a few hundred times in Debug and ReleaseFast under
  a watchdog that also fails when the binary is missing. A hang is a
  failure. Repetition finds little by itself: 300 clean runs hid a hang
  that one differently paced source showed at once.
- Concurrency is tested as invariants over shapes (`tests/flow.zig`): every
  shape of pipe is run with its ended side running out, being done and
  failing. A new shape goes there, not into a one-off test.
