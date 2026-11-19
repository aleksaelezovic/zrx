# Spec: segments and one scope

Status: implemented in PR 5, except what "Taken out" and "History" list as
not built. Replaces the approach of the closed PR 3 (`rewrite-hardening`).

**This file is the only place that says what a run guarantees.** The guide
repeats the list below in short; `AGENTS.md` and the comments in `src/`
describe how it is done and point here. When they disagree, this file is
right and the other is a defect.

## Why

On `main`, "done" and errors travel back as the answer to `push`. That is exact
and free, but only while someone pushes. A queue cuts that path, and four
defects followed (first review of PR 1):

- a stage could be torn down while a queue's task still used it;
- a worker's error was not seen while the source waited for input;
- `merge` did not stop an idle source when the pipe was done;
- `system` could run a member on the supervising task.

## Terms

- **Segment.** A task boundary (`queue`, `batchWithin`, `debounce` or
  `concurrent`) splits a pipe into segments. Segment 0 is the source and
  the stages up to the first boundary. Each boundary has a task for the
  segment after it, up to the next boundary. A boundary inside a sub-pipe
  of `branch` or a terminal `route` also starts a segment. A concurrent
  boundary also registers worker tasks in the same scope. They take turns
  pushing into its continuation; its boundary task coordinates their
  completion and ends that continuation.
- **Scope.** The one supervisor, in `src/tasks.zig`, used by `program`
  (segments), `merge` (sources) and `system` (programs).

## Guarantees

Each is about one program, stated at a point a caller can observe (what
`run` returns, what has been released, whether
`run` returns at all), and each names the tests that pin it. A sentence
without a test does not belong in this list. Nothing is promised about a
moment inside the run.

1. **On success**, every stage instance with a `finish` hook has finished exactly once.
   The stages of an `each` sub-pipe are instances per item: see 14.
   *Tests: "the end of the stream travels with the data", "queued sub-pipes of
   a branch each finish once", the six "invariants" (`tests/flow.zig`).*
2. **On an error**, `run` returns it. A segment may have finished before
   another segment failed. `print` reports writer flush errors during item
   handling and at stream end.
   *Tests: the "invariants" with a failing side (`tests/flow.zig`),
   "print reports flush errors during a push and at stream end" and
   "printed items stay written when a later item fails" (`tests/io.zig`).*
3. **Which error.** The first failure of any task. Where tasks are started
   (a boundary; a `merge` or `system` of more than one), `error.Canceled`
   instead, if the task that called `run` has been asked to cancel before
   those tasks have all been joined. Once they are joined, only the `Io`
   calls of what still runs on the caller (resource releases or, after a
   `merge` without a boundary, the end of the stream) can see such a request.
   *Tests: "cancelling the caller of a queued program", "the caller is asked
   to cancel while the run starts its tasks", "a cancel request that reaches
   the caller while the run joins its tasks is not lost", "the caller's
   cancellation also comes before a failure" (`tests/flow.zig`), "cancelling
   the caller cancels every member" (`tests/programs.zig`).*
4. **Always**, every task of the program has returned before its resources
   are released. Resources are released in the reverse of the order they
   were acquired in.
   *Test: "nothing is released while a handler behind a queue is still using
   it", "resources outlive every concurrent worker on failure"
   (`tests/flow.zig`), "resources are acquired once what they need is
   there, and released in reverse" and "independent resources are acquired
   in written order; one that needs others comes after them"
   (`tests/di.zig`).*
5. **A failure does not wait.** `run` returns without waiting for a source or
   a handler that is waiting in an `Io` call: it is cancelled there, also
   when another task does not notice that it was asked to cancel.
   *Tests: "a failure after a queue ends the run while the source is
   waiting", "a failure behind two queues, or in a queued sub-pipe", "every
   task is asked to cancel at once" (`tests/flow.zig`), "a failure ends the
   run although the segment it interrupts is printing under a recover"
   (`tests/io.zig`).*
6. **A queue whose task has ended takes no more.** However the task ended
   (its input ran out, it was done, it failed, it was cancelled), a push
   into that queue answers `.done`; no producer is left waiting on it.
   *Tests: the "invariants" (a producer left waiting hangs them), "a
   boundary written against the contract splits the pipe like a queue"
   (`tests/extending.zig`).*
7. **Graceful end.** When the source returns, each queue drains, timed
   operators emit pending values without waiting out their timers, and each
   segment finishes in turn. Debounce emits its latest pending item. Only a stage that is done,
   or an error, cuts this short.
   *Tests: "the stream end waits for the queue to drain", "the end of the
   stream travels with the data" (`tests/flow.zig`), "batchWithin keeps the
   first deadline and starts a new one after emission" and "debounce restarts
   its deadline and emits the latest item during source silence" (`tests/timing.zig`).*
8. **A program with neither a boundary nor a `merge` is one loop on the caller's
   task**, and its code is what the zero-overhead fixtures compare.
   *Test: `zig build zero-overhead`.*
9. **`run`'s error set is inferred**: the handlers' and operators' errors,
   plus `error.Canceled` and `error.ConcurrencyUnavailable` where tasks are
   started. It is `anyerror` only if a handler's is.
   *Tests: "run has a precise error set" (`tests/programs.zig`), "a queue
   works in a pipe whose handlers return anyerror" (`tests/flow.zig`).*
10. **A `system` or `merge` of more than one starts a task per member**, on
    an `Io` that can; otherwise `error.ConcurrencyUnavailable`, with no
    sequential fallback. Of one, it runs that one in place. The programs of
    a system are independent: each keeps 1 to 7 by itself, `system.run`
    returns the first failure of any of them and cancels the others, and a
    program that ended before that has released its resources.
    *Tests: "a system returns a failure while another program is waiting",
    "without concurrency, a system and a merge fail before anything runs",
    "systems nest, and a system of one needs no Io", "a merge of one source
    runs it in place and needs no Io" (`tests/programs.zig`).*
11. **Timed output.** On success, `batchWithin` emits ordered nonempty batches
    of at most its size, using the first item's age for timed emission.
    `debounce` retains the latest pending item and restarts its deadline on
    every push. Both can emit while the source waits for input. Empty input
    emits nothing.
    *Tests: "batchWithin emits 900 of 1000 while the source is idle",
    "batchWithin keeps the first deadline and starts a new one after emission",
    "batchWithin preserves every item and a program can run again",
    "debounce restarts its deadline and emits the latest item during source
    silence", "debounce coalesces input while downstream is busy", and
    "timed operators emit nothing for empty input" (`tests/timing.zig`).*
12. **A producer waiting on `Stop` can finish early without another item.**
    With built-in branching and task boundaries, a downstream limit that
    leaves the producer with no consumers lets the program return normally.
    A live sibling can still receive items. Downstream segments finish and
    report finish errors under guarantees 1 and 2.
    *Tests: "a downstream limit wakes a producer without another item and
    all segments finish", "a shared producer keeps running until both
    queued consumers are done", "a live direct branch still receives items
    when a queued branch stops", "a branch that stopped synchronously no
    longer holds shared upstream open", "a producer can stop a pending input
    wait without canceling its segment", "a queued downstream limit wakes
    an idle producer inside merge", and "a finish error still fails the run
    after a downstream limit", "caller cancellation still interrupts a
    producer responding to Stop", "concurrent worker limits wake the producer
    before their final emissions", and "a concurrent continuation limit wakes
    the producer while a worker is still running" (`tests/flow.zig`).*
13. **Concurrent work sharing.** On success without early completion,
    `concurrent(n, worker_pipe)` delivers each input to one worker.
    Each worker has separate operator state. Output pushes into the shared
    continuation are serialized; input ordering is not preserved. Worker
    pipes finish before the continuation finishes. Empty input still
    finishes all `n` worker pipes.
    *Tests: "concurrent workers overlap and emit without waiting for input
    order", "concurrent serializes downstream pushes while another worker
    is ready", "concurrent shares every item once and rejoins a single
    fold", "concurrent starts the requested number of workers", "each
    concurrent worker owns its limits and finishes its state once on every
    run", "empty input still finishes each concurrent worker and downstream
    once", "one completed concurrent worker leaves input open for the
    others", and the four concurrent "invariants" (`tests/flow.zig`).*

14. **Per-item sub-pipes.** For every item, `each(source_of, sub)`
    constructs the stages of `sub`, runs the source made from the item into
    them and finishes them once, before the push of that item returns. When
    `source_of`, the source or `sub` fails for an item, that item's stages
    are not finished, also when a `recover` or an `attempt` then handles the
    failure. A sub-pipe that is done ends its item only; when the pipe after
    the `each` is done, the item's source is answered `.done` and so is the
    stage before the `each`. `attempt(sub, fallback)` emits the fallback for
    an item `sub` fails on, except for `error.Canceled`; a failure of the
    pipe after it, or of `sub`'s own end of stream, is what `run` returns,
    and the fallback is not asked.
    *Tests: "each runs a fresh sub-pipe over the source made from every
    item", "a sub-pipe that is done ends its item, not the stream", "once the
    pipe after each is done, the item's source stops and so does the stream",
    "a failure in the sub-pipe fails the run, and that item's sub-pipe is not
    finished", "attempt emits the fallback in place of an item its sub-pipe
    fails on", "a failure of the pipe after an attempt passes through,
    whatever its name", "a recover inside the sub-pipe does not see a failure
    of the pipe after the attempt", "attempt falls back from failures but
    never from a cancellation", "a failure of the sub-pipe's own end of
    stream is not an item's", "attempt around each: an item whose source or
    sub-pipe fails becomes one value" (`tests/nested.zig`), and the four
    "invariants" with an `each` or an `attempt` (`tests/flow.zig`).*

## Not promised

A review finding against one of these is answered by pointing here.

- Interrupting arbitrary calls on early completion. A producer waiting for
  input cooperates by waiting on `Stop` alongside that input. Other sources
  discover completion at a push. A custom operator with sub-pipes may keep
  upstream demand live until a push.
- Selectively cancelling an already-running concurrent worker because the
  continuation is done. Its handler returns normally; failures and caller
  cancellation interrupt the entire group through the scope.
- That a sub-pipe beside one that fails gets the items meant for it. A
  failure ends the run.
- That a run fails with `error.ConcurrencyUnavailable` when a member cannot
  be started although the run already has an outcome: a failure, or a
  `merge` whose pipe is done, comes first.
- That no handler runs for a final value once a later stage is done. Stages
  between the one that emits it and the one that is done may run for it.
  This includes the final value of an `each` sub-pipe whose item was cut
  short because the pipe after the `each` is done.
- That an `attempt` takes back what its sub-pipe emitted for an item before
  it failed, or undoes what the item did to the state of its stages.
- That nothing of a segment's end runs after a failure elsewhere. A segment
  decides to end its stream right before it does; an end that has begun is
  cancelled, not undone.
- That items already in a queue are not handled after a failure elsewhere.
- That no task starts after another has failed. All are started together.
- Which failure is "first" when two tasks fail together: the one on record
  first.
- That a failure is returned when the caller has also been cancelled:
  `error.Canceled` is (guarantee 3).
- Interrupting a handler or source that never calls into `std.Io`, or that
  swallows `error.Canceled` and goes on.
- That a request to cancel looks like one everywhere. `std.Io.Writer`
  reports every failure as `error.WriteFailed`, so a request that reaches a
  segment inside a write (`print`) comes out as a failed write, and a
  `recover` may take it for an item error and carry on. The request is used
  up by then: the segment still ends the next time it takes from or pushes
  into a queue, because queues are closed when the run is over, but it is
  not interrupted in an `Io` call of its own after that. That is how `std`
  behaves; the library does not wrap writers to change it.
- That members on different `Io` instances are asked to cancel together.
  Those on one `Io` are; the instances are told one after another.
- Exact item counts before a queue: stages before it may have handled more
  items than the stages after it take.
- Exact wall-clock delivery at a timed deadline. A worker can be delayed by
  scheduling or downstream backpressure. Timed batching can fill its next
  pending batch while its worker delivers a previous one. Debounce can
  replace a pending value until its worker takes it, including when that
  worker is delayed past a quiet-period deadline.
- Anything about cancelling a program that starts no task (no boundary, no
  `merge`), beyond what its own handlers and source do with
  `error.Canceled`: the run itself has no `Io` to ask.

## How it works

Mechanism, not promises. It may change as long as the guarantees hold.

- **The end of the stream travels with the data.** `finish` runs in order up
  to and including a queue, on the task of the segment before it; the
  queue's task finishes what follows. No task finishes another segment's
  stages. Construction and resource acquisition run on the caller. Resource
  release also runs there, after joining. (With `merge`, the sources run as tasks of their
  own and take turns pushing; the segment's own task ends the stream.)
- **Every task ends its work through the same steps**, in one function
  (`Scope.Runner`). A segment and an operator only say what each step is.

  1. Its work (`run`: the source, or a queue's loop).
  2. Under the scope's lock: if the work failed, the run has failed. On
     record before the next step.
  3. `retire`: nobody waits on this task again (its queue closes).
  4. Under the lock, as the last thing before it: whether to end. Not if
     the run is over.
  5. `end`: finish the segment's stages. A failure here fails the run too.

- **The supervising task** waits in one place, and that wait can be
  cancelled. When the run is over and not every task returned by itself,
  everyone is told at once: every queue is closed (each boundary is
  retired), so that no task waits on a queue again whatever became of its
  request to cancel, and all tasks on one `Io` are asked to cancel
  together (they are one `Io.Group`). Then the tasks are joined, and before
  it returns the supervising task looks at its own cancellation once more:
  joining need not be a cancelation point.
- **Built-in boundaries use the program's resolved `Io`.** Segment 0 uses the
  `Io` of the first boundary. Tasks are started in an `Io.Group`.
- **`merge`** tells its scope when a push is answered `.done`; the scope then
  cancels the other sources and ends as a success.
- **A producer that requests `Stop`** gets a signal through its source
  environment. At task setup the chain links demand from segments and from
  terminal branch and route cases. A boundary worker reports `.done` after
  its work returns successfully. A direct case reports it on its first
  `.done`. Each node withdraws demand once, either explicitly or when all
  of its consumers have withdrawn theirs. Reaching the source sets its
  event. The source returns normally and end-of-stream processing follows
  the existing segment lifecycle.

### Decisions

Two tasks cannot agree on "never after": between a look and the act that
follows it, the other can move. So each decision is taken under the scope's
lock, right before what it allows and after every step that can take time.

| Decision | Taken by | When |
|---|---|---|
| This task's failure fails the run | the task | when its work is over, before it retires |
| This task ends its stream | the task | after it has retired, as the last thing before it ends |
| The outcome of the run | the run | when it stops waiting |
| The caller was cancelled | the run | as the last thing before it returns |
| Flush | the caller | after the run returned success |

## Contract

- **"Done" is a hint, sticky where it originates.** A stage that answers
  `.done` of its own accord keeps answering `.done`. Whoever is answered
  `.done` stops pushing items. Final values (`fold`, `batch`) are still pushed
  and are refused by the stage that is done. `branch`, `route` and `merge`
  remember which of their own sub-pipes or pushes were answered `.done`; a
  `route` whose cases rejoin drops a case's final value itself once the pipe
  after it is done.
- **Stage hooks**: `push` and optional `finish`, with infallible in-place
  construction for stages that need it.
- **A task boundary** declares `zrx_boundary`, `work` (the body of its task),
  `retire` (from now on `push` answers `.done` and `work` runs out) and
  `taskIo`. `retire` is called by the boundary's own task when its work is
  over and by the supervising task when the run is: more than once, from
  two tasks, and it must not wait.
- **A stage with sub-pipes** declares `has_boundary`, `Tasks` and `tasks`.
- **A boundary with auxiliary tasks** also declares `Tasks` and `tasks`.
  These members use the same scope and boundary demand node. The boundary's
  `work` coordinates their completion; auxiliary tasks finish their own
  stages, and the boundary task finishes the continuation. `concurrent`
  registers one auxiliary member per worker and waits for their successful
  ends. The continuation returning `.done` or the last worker reaching its
  own input limit closes input and withdraws demand. Scope retirement closes
  input and wakes the coordinator's wait.
- **A stage whose sub-pipe runs within one push** (`each`, `attempt`)
  declares none of these: it rejects a sub-pipe with a boundary, so it has
  no tasks to pass on.
- `src/pipe.zig` knows these markers and hooks, not `queue`.

## Stopping from outside

- **Hard stop is cancellation**: cancel the task that called `run`
  (guarantees 2 and 3).
- **Graceful stop is the source ending** *(proposed)*. There is one spelling
  for "no more input": the source returns, and guarantee 7 does the rest. A
  signal handler or a timeout asks the *source* to end; it does not talk to
  the pipe. Graceful with a deadline: ask the source to end, then cancel the
  run if it has not returned in time.
- **A stop trigger for sources** *(proposed, later)*. A source that waits for
  input cannot see a flag, so the library needs a way to end one from
  outside: a type-keyed dependency and a source wrapper, composed from the
  source contract.
- A segment learns that its input stream is ending when its boundary has
  drained. A handler that needs a flag of its own injects one.

## Taken out: interrupting a segment that works for nothing

PR 5 first included this (it was "rule 6"): a segment whose every output is
a queue was cancelled once the segments behind those queues had returned, so
that a source waiting for input did not hold a run whose pipe was done.

It was taken out after three rounds of review. Of eight findings, four were
in it and two more where it met the caller's cancellation. The reason is
structural, not a matter of more care:

- The segment has to be interrupted *and still end its stream normally*,
  or which stages finish on a successful run depends on timing.
- `std.Io` sends a cancel request only by joining the task. So the
  supervising task blocks, not cancellable, while the interrupted segment
  finishes; everything it would react to waits, its own cancellation
  included.
- A request sent once may reach the segment late, inside its `finish`, where
  it looks like a failure. Keeping it out needs cancel protection, which in
  turn means the segment cannot be interrupted again.
- It needs a static tree of who feeds whom, which put three more
  declarations on every stage with sub-pipes.

The `Stop` dependency gives a participating producer a way to return normally
when its downstream completes. The scope continues to use cancellation for
failures and caller cancellation.

## Costs

The measurements below are from PR 5, when the queue receiver could take
several items per read.

- With a queue, no item handler runs on the task that called `run`: the
  source is a task too, so that a failure can interrupt it. Program binding
  acquisition, stage construction, and resource release stay on the caller.
- A queue costs what `std.Io.Queue` costs when two threads contend for it.
  Measured with std alone on macOS aarch64: about 9 ns/item with no second
  thread, 45 to 60 with one put per item against a consumer on another
  thread, about 10 when the producer puts 32 items at a time. The benchmark's
  pipeline makes roughly 70 to 130 futex calls per 1,000 items, on `main` and
  here alike.
- In the benchmark's pipeline through zrx: about 35 ns/item with
  `queue(256)`, and 13 when the far side never has to wait. So about 22 of
  the 35 are the two sides waking each other, and 13 are the floor of one
  lock per item. A bigger queue alone barely helps, and slowing the far side
  down on purpose gets to about 21: the sleeping costs what it saves.
- Handing over chunks instead of items gets under that floor. The benchmark
  measured about 4.7 ns/item using the original slice-based `batch(64)`, a
  `map` to an array, `queue(64)`, and `flatten()`.
- No cost is attributed to running the source as a task. The project's
  benchmark reads about 36 ns/item on `main` and 47 to 57 here, but another
  harness of the same pipeline reads 35 to 37 here and 43 to 47 on `main`,
  and std alone shows no difference between producing on the calling thread
  and producing on a task. (The commit message of step 2 and an earlier
  description of PR 5 said otherwise. That was one benchmark read as a
  cause.)

## Acceptance cases

Each is a test that fails on `main` or pins behaviour `main` already has. No
test waits a length of time or a number of yields for something to have
happened: it waits on an event it can observe. A party that should be
interrupted waits far longer than the test and records whether it woke by
itself.

1. A handler after a queue uses two program resources while the source fails: neither is released before that handler
   has returned. (Guarantee 4.)
2. The source waits forever; a handler after a queue fails: `run` returns
   that error and the source did not wake by itself. (5.)
3. As 2, with the failing handler behind two queues, and inside a queued
   `branch` sub-pipe. (5.)
4. `merge` of an idle source and one that emits, into `take(1)`: `run`
   returns.
5. `system`: one member fails while another waits forever: `run` returns the
   failure. On an `Io` without concurrency: `error.ConcurrencyUnavailable`.
6. A queue compiles in a pipe whose handlers return `anyerror`. (9.)
7. Graceful end: the source returns with a full queue and a slow consumer;
   every item is handled and a `fold` after the queue emits. (1, 7.)
8. Six shapes of pipe (segments in a row, beside a direct sub-pipe of the
   source and of a segment, two queued sub-pipes, a branch behind a queue,
   queued cases of a route), each with one side running out, being done
   after one item, and failing on the first: `run` returns; unless that side
   failed, a sub-pipe beside it gets every item meant for it and every stage
   finishes once. (1, 2, 6.)
9. A failure elsewhere, then a segment whose input has ended: it does not
   end its stream; nor does the source's segment when the source returns
   after the failure. A segment that takes its time retiring decides after
   it has retired; a failure is on record before the queue behind it lets
   its producer go; a failure while a segment ends its stream fails the
   run. ("How it works", steps 2 to 5.)
10. The caller is cancelled while the run waits: `error.Canceled`, every
    task joined. (3.)
11. The caller is cancelled while the run joins its tasks, after a success
    and after a failure: `error.Canceled`. (3.)
12. Queues can use the `Io` supplied by `Program.provide`.
13. The zero-overhead fixtures are unchanged and pass. (8.)

## History

1. The scope; `system` and `merge` ported to it.
2. Segments: the boundary hooks, `finish` stopping at a boundary, the source
   as segment 0, `start` removed.
3. Interrupting a segment that works for nothing. *Taken out again.*
4. The guide and `AGENTS.md`.
5. After the first review: every task ends its work in one place.
6. After the second: each decision is taken right before what it allows.
7. After the third: step 3 taken out; one list of guarantees, here.
8. After two independent reviews run before handing it back: every
   guarantee names its tests (four lines of the first list were false);
   every task of one `Io` is asked to cancel at once, and every queue is
   closed when the run is over (a request to cancel that `print` reported
   as a failed write, swallowed by a `recover`, hung the run; a task that
   did not notice its request kept the request from the next one).
9. After a third: the run joins its tasks one way only; two tests that
   depended on which task reached a step first were made deterministic. A
   writer of the library's own that put a cancel request back was added
   here and removed again: it corrupted short writes and dropped `sendFile`.
   `src/io.zig` is what `main` has.

Stopping a source from outside remains a proposal.
