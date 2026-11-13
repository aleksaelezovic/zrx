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
  `.done`). Early stop is a value, never an error.
- **"Done" is a hint, sticky where it originates.** A stage that answered
  `.done` of its own accord may still be pushed to and keeps answering
  `.done`; whoever is answered `.done` stops pushing items. Final values
  (`fold`, `batch`) are still pushed and refused there. Nothing remembers a
  "done" on behalf of another stage, and no promise is made that no handler
  runs for a value nobody takes. PR 3 tried to make that a guarantee and
  needed machinery in the chain, across tasks, that kept regressing.
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
  parameter type selects what it handles; `error.Canceled` is never handled;
  errors during finish, or beyond a `queue`, are not item errors. No error lane,
  no rollback.
- **`queue` is the only task boundary.** `branch` is terminal direct fan-out and
  `route` is exclusive direct dispatch; either becomes concurrent only through
  a queue in a sub-pipe. A rejoining route case must not contain a queue.
- **A queue splits a pipe into segments; each segment is a task.**
  [docs/spec-segments.md](docs/spec-segments.md) is the design record: its
  rules, what is *not promised*, and the acceptance cases. Segment 0 is the
  source and the stages up to the first queue. A program without a queue is
  a plain loop on the caller's task.
- **The end of the stream travels with the data.** `finish` runs in order up
  to and including a boundary, on the task that pushed into it; the
  boundary's task finishes what follows. No task finishes, joins or waits
  for another segment's stages. Only `flush` and `deinit` run on the caller,
  after every task has returned.
- **One scope supervises every group of tasks** (`tasks.Scope`): the segments
  of a program, the sources of `merge`, the programs of `system`. Members are
  started with `Io.concurrent` and never run on the supervising task, which
  only waits. The first outcome is the result: a member returning an error,
  or a member saying the group is done (`merge`, when the pipe answers
  `.done`); the rest are cancelled and joined. There is no sequential
  fallback: an `Io` that cannot start a member is
  `error.ConcurrencyUnavailable`. A cancel request for the caller that is
  there when the scope settles the outcome wins; once the outcome is
  settled the scope only joins. A failure is a task's return value: nothing
  is reported on the side, and nothing is cast from `anyerror`. A member is
  started and joined on its own `Io`.
- **Every task ends its work in one place** (`Scope.Runner`), in a fixed
  order: `run`; under the mutex, put a failure on record; `retire` (nobody
  waits on it again: a queue closes); under the mutex, decide whether to
  end; `end` (finish the segment's stages). A segment and
  an operator only say what each step is. Do not decide any of it elsewhere:
  the first review of PR 5 found three defects that were one, a segment's
  end handled in three files (the queue closed itself only when done, the
  segment looked at a flag set after it had returned, the program picked the
  `Io`).
- **Decide right before acting, and promise only that.** Two tasks cannot
  agree on "never after X": between a look and the act, the other can move.
  Every decision is taken under the scope's lock, as the last thing before
  what it allows and after every step that can take time (a join, a
  `retire`), and reads all it depends on then, the caller's cancellation
  included. The spec lists them in one table. Never write "always",
  "never after" or "whatever else has happened" about two tasks: say which
  decision it is and when it is taken. Both reviews of PR 5 found promises
  worded as absolutes, and decisions taken one step too early.
- **After a failure is on record no segment decides to end its stream**,
  and nothing flushes. That is all a failure promises: handlers may run for
  items already queued until the cancel request arrives, and an end that
  has begun is cancelled, not undone.
- **Working for nothing is decided from a static tree.** A member names who
  feeds it (`fed_by`) and whether everything it puts out goes to other
  members (`feeds_only_members`, from `sinks_directly`). Once all of those
  have returned the scope cancels it if it is still at work. That is only a
  faster way of learning "done": the member then retires and ends its
  stream as if a push had told it, and nothing may depend on which it was.
  Stages are not asked anything from another task.
- **Invariants before cases.** `docs/spec-segments.md` lists what must hold
  whatever happens. A defect is first matched to the invariant it breaks,
  and the fix restores that invariant where it is decided, for every shape,
  not for the reported one. If it breaks none, an invariant is missing or
  the finding is against something not promised.
- **Do not add to the stage contract for concurrency.** A boundary stage has
  `zrx_boundary`, `work`, `retire` and `taskIo`; a stage with sub-pipes has
  `has_boundary`, `sinks_directly`, `Tasks` and `tasks`. A review finding
  against something the spec lists as not promised is answered by pointing
  there, not by a change.
- **Lifecycle.** `init` in order, pushes, then on a normal end `finish` in
  order and `flush` in reverse; always `deinit` in reverse. There is no
  `start` hook: no stage emits before the first item.
  Whoever owns a writer flushes it. `release` cannot fail.
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
  timing or scheduling order for their assertions. Things that run at the
  same time (programs of a system, segments, queued sub-pipes) get a log
  each: the test logs are not synchronized. To show that something is
  interrupted, have it wait far longer than the test and record whether it
  woke by itself, rather than measuring how long the run took. To show that
  a check stops something, the party that waits for the event must wait
  without sleeping (spin on `checkCancel` or on shared state with
  `std.Thread.yield() catch {}`): if it sleeps it is cancelled where it
  sleeps, and the test passes without the check. Before a test cancels a
  task, it waits until that task has started everything it starts.
- A change to the scope or to segments is checked by removing each safeguard
  in turn and seeing a test fail, and by repeating the `flow` and `programs`
  suites a few hundred times in Debug and ReleaseFast under a watchdog that
  also fails when the binary is missing. A hang is a failure.
- Concurrency is tested as invariants over shapes (`tests/flow.zig`): every
  shape of pipe is run with its ended side running out, being done and
  failing. A new shape goes there, not into a one-off test. When "done" is
  involved the source holds back, so that both ways of learning it (the
  answer to a push, being cancelled) are taken: a fast source hides the
  second, which is how the first review of PR 5 found a hang the tests had
  not.
