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
  compile error that says what to write instead.
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
  `.done`). Early stop is a value, never an error. A stage that answered
  `.done` of its own accord (`take`) keeps answering `.done`.
- **Done is final, and the chain enforces it.** Whoever is answered `.done`
  stops pushing. For what a stage emits outside of `push` (`start`, `finish`)
  the chain remembers, beside that stage, that what follows it answered
  `.done`, and drops the emission there (`Late` in `src/pipe.zig`): no stage
  in between runs for it. Operators do not guard this themselves. The answer
  has to have travelled by a push: across a `queue` the near side learns it
  at its next push.
- **Taking no more items is not the same as emitting no more.** A stage that
  answers `.done` (from `push` or `start`) closes the output of the stages
  before it, never its own: a `route` whose cases are all done still emits
  their final values. Only an answer from what follows a stage closes that
  stage's output. A chain that rejoins a pipe (a `route` case) asks its tail
  (`isDone`) before a late emission, so the pipe after the route being done
  reaches every stage of every case.
- **A `down` is anything with a `push`.** An operator may run another one
  with a handle of its own, a pointer included (`tests/extending.zig`). Never
  probe a handle for a plain name: ask only what declares a `zrx_*` marker
  (`answersDone` for `isDone`), and check the type is a struct first.
- **Operators are values; state is separate.** An operator declares
  `Out(Env, In)`, `Stage(Env, In)` and optionally `Provides(Env)`. All checks
  happen in `Out`, which runs for the whole pipeline before any stage type is
  built. A pipe is an operator; nesting is associative, including for `provide`.
- **Dependencies are resolved once.** The environment is a tuple keyed by exact
  type. A stage copies what its handler asked for at `init`; nothing is looked
  up per item. `std.Io` and the allocator are ordinary dependencies.
  `provide` and `resource` extend the environment for what follows; a value of
  an already-present type shadows it. Sub-pipes of `branch` and `route` scope
  their own provisions.
- **Handlers** are comptime-known functions: leading parameters are
  dependencies, trailing parameters are the operator's data and may be
  `anytype`. Composite handlers (`all`, `compose`, ...) are struct types that
  forward their children's requirements. No closures, no runtime function pointers.
- **Errors are Zig errors.** A handler error fails the run after teardown.
  `recover(handler)` guards the operators after it per item; its error
  parameter type selects what it handles; `error.Canceled` is never handled.
  A value an earlier operator emits at the end of the stream is an item like
  any other; a later stage's own finish or flush, and anything beyond a
  `queue`, is not. `orElse` is the handler-level counterpart that keeps the
  item. No error lane, no rollback.
- **`queue` is the only task boundary.** `branch` is terminal direct fan-out and
  `route` is exclusive direct dispatch; either becomes concurrent only through
  a queue in a sub-pipe. A rejoining route case must not contain a queue.
- **Every task is supervised, and the supervisor only waits.** A stop or a
  failure must not wait for a producer's next push, for a join, or for a
  handler. A program whose pipe has a queue runs starting (the `start`
  hooks), feeding (the source) and ending (finish and flush) as tasks, one
  after another; the caller waits on `Supervision` and cancels. Never run
  user code on the task that supervises: every hook can block.
- **Done before the first item is still done.** A stage's `start` answers
  like a push (`!Flow`: `return down.push(x)`, or `.more`), and `branch` and
  `route` answer for their sub-pipes. If starting satisfies the pipe, by that
  answer or by a worker's, starting is cut short and the source is not run,
  with or without a queue. `finish` may then reach a stage whose `start` did
  not run: a `queue` that was never started answers `.done` and buffers
  nothing.
- **A `route` that is done asks no predicate**, and once it is done while
  starting, no later case is started (a case that is done by itself leaves
  the others to start). What `push` asks first is one flag (`Arms.idle`),
  kept up to date where a sub-pipe finishes: walking the cases ahead of the
  per-item work makes the optimizer reshape the loop.
- **The sequential fallback orders outcomes; it cannot cancel.** On an `Io`
  with no concurrency a member runs on the caller's task until it returns.
  Do not promise immediate cancellation there. After a failed launch, re-read
  the `Watch` before deciding anything.
- **The cause comes first.** A worker's failure is published before anything
  that would react to it is woken (the queue reports, then closes), and it is
  resolved before any error a phase or a member returned, which may only be
  its consequence. Members run inline settle through the same `Watch` as
  concurrent ones.
- **A failure is acted on where it happens.** Workers report through
  `Supervision.fail(io, stage)`; the first one is the run's result: it cancels
  whichever phase is running and stops further stages from finishing. The
  error is not passed as a value: the program asks the stage for it
  (`failure(self, down) !void`, found with `failureOf`), so the run's error
  set stays inferred and nothing is `@errorCast` from `anyerror`. What an
  interrupted source or ending returns is ignored. All reads of supervision
  state take its mutex.
- **"Done" is one question, asked after the fact.** It is aggregated per
  `branch`/`route` scope (`Arms`) and stops the source when it holds for the
  whole pipe. Ask `anyWants()` after dispatching an item, never sum it up
  along the way: a queued sub-pipe can become done meanwhile. `Supervision`
  takes its `Io` from the first worker, so `Io` may be provided mid-pipe.
- **Members never run on the supervising task.** `system` and `merge` use
  `tasks.all`: `Io.concurrent`, fail fast, cancel the rest. Only an `Io` with
  no concurrency at all runs members one after another; running out part-way
  is `error.ConcurrencyUnavailable`. Do not use `Io.async` for a member: it
  may run inline and block the supervisor. Members share a `tasks.Watch`; a
  member that knows the group has failed or is done says so there, typed, and
  is not waited for (`merge` does at its push boundary). A failure and a
  "done" are separate outcomes; never let one flag stand for both. A program
  without a queue stays a plain loop on the caller's task.
- **Lifecycle.** `init` in order, `start` in reverse, pushes, then on a normal
  end `finish` in order and `flush` in reverse; always `stop` in order, then
  `deinit` in reverse. A stage that runs a task joins it in `stop`, never in
  `deinit`: every task is gone before anything is released. Whoever owns a
  writer flushes it. `release` cannot fail.
- **Programs must terminate.** `program` takes a source and a `pipe(...)`;
  `branch`, `when` and `otherwise` take `pipe(...)` too, never a bare operator.

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
- What a chain keeps per stage lives beside that stage (`slots` in `Chain`),
  reached from the stage pointer. Do not add to `Refs`: one more pointer in
  it, even unused, reshaped the `branch` fixture.
- Not covered: a stage that emits at the end of the stream followed by an
  early stop (`batch` then `take`). A trial fixture met `lean` on x86-64 but
  not on aarch64, where the optimizer restructures the loop and copies the
  remainder with `memcpy`; natively it measured about 0.85 ns/item against
  0.55 by hand, and no better before the chain remembered `.done`. Do not
  claim that combination.
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
  timing or scheduling order for their assertions. Things that run at the same
  time (programs of a system, queued branches) get a log each: the test logs
  are not synchronized. Repeat the concurrency suites a few hundred times, in
  Debug and ReleaseFast, before trusting a change to them. To show that something is
  interrupted, have it wait far longer than the test and record whether it
  woke by itself, rather than measuring how long the run took.
