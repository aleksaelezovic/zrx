# Spec: segments and one scope

Status: steps 1 to 4 are implemented; step 5 is proposed. Replaces the
approach of the closed PR 3 (`rewrite-hardening`).

Each entry is marked **accepted** (agreed on 2026-11-13) or **proposed**.

## Why

On `main`, "done" and errors travel back as the answer to `push`. That is exact
and free, but only while someone pushes. A queue cuts that path, and four
defects follow (first review of PR 1):

- a stage can be torn down while a queue's task still uses it;
- a worker's error is not seen while the source waits for input;
- `merge` does not stop an idle source when the pipe is done;
- `system` can run a member on the supervising task.

PR 3 fixed these by supervising the pipe from outside and by turning "done"
into a guarantee. This spec changes the structure instead.

## Terms

- **Segment.** A `queue` splits a pipe into segments. A segment is one task
  running a synchronous chain: segment 0 is the source and the stages up to the
  first queue; every other segment takes items from one queue and runs the
  stages up to the next. A sub-pipe of `branch` or `route` that starts with a
  queue is a segment of its own.
- **Scope.** The one supervisor, in `src/tasks.zig`, used by `program`
  (segments), `merge` (sources) and `system` (programs).

## Rules

1. **A program without a queue is unchanged**: one loop on the caller's task.
   *(accepted)*
2. **Every segment is a task of the scope; the caller only waits.** Tasks are
   started with `Io.concurrent`, never run on the caller. *(accepted)*
3. **The end of the stream travels with the data.** A segment that runs out of
   input runs `finish` for its own stages, in order, closes its outgoing
   queues and returns. No task finishes another segment's stages.
   *(accepted)*
4. **Graceful end.** When the source returns, every item it pushed is still
   handled: each queue drains, each segment finishes in turn, then writers
   flush. Nothing is cancelled. Only a stage that is done, or a failure, cuts
   this short. *(accepted)*
5. **Failure.** The first task that fails is the result of the run. The
   failure is on record before anybody can see that the task's work ended;
   the scope then cancels every other task and joins them. A segment decides
   whether to end its stream as the last thing before it does, and does not
   once a failure is on record; `flush` is skipped. *(accepted)*
6. **Working for nothing.** A segment whose every output is a queue is
   cancelled once every segment fed by those queues has returned, if it is
   still at work. That is as good as its work having ended well: what the
   work returned is dropped, and the segment ends its stream like any other.
   A segment that is already ending its stream is left to end. This is
   decided from a static tree of segments, by the scope, when a task
   returns. *(accepted; "ends its stream like any other" added after the
   first review of PR 5)*
7. **After every task is joined**, on the caller: `flush` in reverse order (on
   success), then `deinit` in reverse order. *(accepted)*
8. **Cancelling the run** (the caller's task is cancelled) cancels every
   segment, skips `flush`, and returns `error.Canceled`. *(accepted)* The
   run looks for such a request each time it has waited for anything, as the
   first thing when it settles its outcome: a request that is there then
   wins, whatever the segments have done, also when it arrived while the run
   was joining a segment it had cancelled for working for nothing. A request
   that arrives after the outcome is settled stays pending for the caller,
   and `run` returns that outcome. *(proposed, after the reviews of PR 5)*
9. **`merge` and `system` use the same scope.** In `merge`, a member that is
   answered `.done` ends the group as a success and the others are cancelled.
   On an `Io` without concurrency both return
   `error.ConcurrencyUnavailable`; there is no sequential fallback.
   *(accepted)*

10. **A segment runs on the `Io` in force at its queue.** Its task is
    started, joined and cancelled on that `Io`; segment 0 runs on the `Io`
    of the first queue. *(proposed, after the first review of PR 5; it is
    what `main` did)*

## Invariants

The rules above are what happens. These are what must hold whatever
happens, and what the tests check over shapes of pipes rather than case by
case (`tests/flow.zig`, "invariants over shapes"). A defect found in review
is first matched to the invariant it breaks; if it breaks none, either an
invariant is missing here or the finding is against something not promised.

1. **One exit, one place.** Every task ends its work through the same steps,
   in `tasks.Scope`: decide what the end means and put a failure on record,
   then let go of whoever waits on the task, then end the stream. No
   operator and no segment decides any of this for itself.
2. **A queue whose task is gone answers `.done`.** However that task ended:
   the input ran out, it was done, it failed, it was cancelled. No producer
   waits on a queue nobody takes from.
3. **Being cancelled for working for nothing changes nothing but the time.**
   A segment learns "done" from the answer to a push or from being
   cancelled; the run's result, what every sub-pipe receives and which
   hooks run are the same either way.
4. **On success every stage finishes once and then flushes once.**
5. **On failure nothing flushes, and no segment decides to end its stream
   once the failure is on record.** It is on record before anybody is let go
   by it, and a segment decides as the last thing before it ends.
6. **Every task has returned before anything is torn down.**

## Decisions

Two tasks cannot agree on "never after": between a look and the act that
follows it, the other task can always move. So every decision is taken
under the scope's lock, right before what it allows and after every step
that can take time, and it reads everything it depends on at that moment.
Rules and invariants are promises about these points, not about instants
across tasks.

| Decision | Taken by | When |
|---|---|---|
| This task's failure fails the run | the task | when its work is over, before it retires |
| This task ends its stream | the task | after it has retired, as the last thing before it ends |
| A task works for nothing and is cancelled | the run | when a task returns |
| The outcome of the run | the run | each time it has waited for anything; its own cancellation first |
| Flush | the caller | after the run returned success |

The second review of PR 5 found two decisions taken too early: the run
accepted success without looking at its own cancellation after a join, and
a task decided to end its stream before retiring. A decision that seems to
be taken at the wrong moment is fixed by moving it in this table, not by a
check where the symptom showed.

## Contract

- **"Done" is a hint, sticky where it originates** *(accepted)*. A stage that
  answers `.done` of its own accord keeps answering `.done`. Whoever is
  answered `.done` stops pushing items. Final values (`fold`, `batch`) are
  still pushed and are refused by the stage that is done.
- **Stage hooks** *(accepted)*: `init`, `push`, `finish`, `flush`, `deinit`,
  `provide`. `start` is removed: no stage emits before the first item. A stage
  that is a task boundary declares `zrx_boundary`, the body its task runs
  (`work`), what lets go of whoever waits on that task (`retire`) and the
  `Io` it runs on (`taskIo`). `src/pipe.zig` knows the marker and the hooks,
  not `queue`.
- **`branch` and `route`** keep plain per-sub-pipe flags, as on `main`
  *(accepted)*.
- **The run's error set stays inferred** *(accepted)*: a segment's error is
  the return value of its task.

## Stopping from outside

- **Graceful stop is the source ending** *(proposed)*. There is one spelling
  for "no more input": the source returns. Rule 4 does the rest. A signal
  handler, a timeout or another task asks the *source* to end; it does not
  talk to the pipe.
- **A stop trigger for sources** *(proposed, later)*. A source that waits for
  input cannot see a flag, so the library needs a way to end one from outside:
  a type-keyed dependency (`zrx.Stop`) and a source wrapper that ends its
  source when it is requested. It is composed from the source contract and
  needs no change to the core. Signals were dropped in the rewrite; this
  returns only by explicit decision, after step 3 below.
- **No context passed between segments** *(proposed)*. A segment learns that
  the stream is ending when its queue is closed and empty, which is when its
  `finish` runs. A flag that says so earlier would be a second spelling of the
  same fact, and acting on it means skipping buffered items, the opposite of
  rule 4. A handler that wants a flag of its own injects one as a dependency.
- **Hard stop is cancellation** (rule 8). Graceful with a deadline is: request
  the source to end, then cancel the run if it has not returned in time.

## Not promised

- That no handler runs for a final value once a later stage is done. Stages
  between the one that emits it and the one that is done may run for it.
- That a segment with a synchronous sink of its own (`branch` with one direct
  and one queued sub-pipe) is stopped before its next push.
- Which wins when a failure and a "done" happen together: whichever the
  scope has on record first. The same goes for a failure in the work of a
  segment that is being cancelled for working for nothing: it is dropped.
- That a cancel request for the caller wins over an outcome the run has
  already settled.
- That nothing of a segment's end runs after a failure is recorded
  elsewhere. The end is decided right before it begins; one that has begun
  is cancelled, not undone.
- That no task starts after another has failed. All are started together.
- That items already in a queue are not handled after a failure elsewhere.
  Handlers may run for some of them until the cancel request arrives; no
  `finish` runs.
- Interrupting a handler that never calls into `std.Io`.
- Exact item counts before a queue: stages before it may have handled more
  items than the stages after it take.

A review finding against something on this list is answered by pointing here,
not by a change.

## Costs

- A queue costs what `std.Io.Queue` costs when two threads contend for it.
  Measured with std alone on macOS aarch64: about 9 ns/item with no second
  thread, 45 to 60 with one put per item against a consumer on another
  thread, about 10 when the producer puts 32 items at a time. The producer
  takes the queue's lock once per item, and when the consumer has caught up
  it sleeps and has to be woken: the benchmark's pipeline makes roughly 70
  to 130 futex calls per 1,000 items, on `main` and here alike.
- In the benchmark's pipeline through zrx: about 35 ns/item with
  `queue(256)`, and 13 when the far side never has to wait (the queue holds
  everything before it starts). So about 22 of the 35 are the two sides
  waking each other, and 13 are the floor of one lock per item. A bigger
  queue alone barely helps (29 with `queue(65536)`), and slowing the far
  side down on purpose (a `tap` that sleeps every few thousand items) gets
  to about 21: the sleeping costs what it saves.
- Handing over chunks instead of items gets under that floor: `batch(64)`,
  a `map` to an array, `queue(64)`, `flatten()` measures about 4.7 ns/item.
  It needs an owning chunk, which `batch` does not emit (its slices are not
  valid across a queue) and which cannot be a fixed array for a short last
  chunk. That is a gap in the library, not built.
- No cost is attributed to running the source as a task. The project's
  benchmark reads about 36 ns/item on `main` and 47 to 57 here, but another
  harness of the same pipeline reads 35 to 37 here and 43 to 47 on `main`,
  and std alone shows no difference between producing on the calling thread
  and producing on a task. The figure moves within the contended band with
  the timing of the two threads. (An earlier version of this section, the
  commit message of step 2 and the description of PR 5 said the source
  running as a task cost about 17 ns/item. That was one benchmark read as a
  cause.)
- Tasks are cancelled one after another: `std.Io` sends a cancel request by
  joining the task. One that is slow to notice delays the request to the
  others; the run returns at the same moment either way.
- While a segment that was cancelled for working for nothing ends its
  stream, it cannot be interrupted again: that request was the only one its
  task can be sent.
- A handler behind a queue that swallows `error.Canceled` and goes on can
  hold a run that has failed: the queue it takes from is not closed when
  the segment before it fails. (The other direction is covered by
  invariant 2.)

## Acceptance cases

Each is a test that fails on `main` or pins behaviour `main` already has.
Interruption is shown by a party that waits far longer than the test and
records whether it woke by itself, never by timing.

1. A handler after a queue uses a resource provided before the queue while the
   source fails: the resource is released only after that handler has returned.
2. The source waits forever; a handler after a queue fails: `run` returns that
   error and the source did not wake by itself.
3. As 2, with the failing handler behind two queues, and inside a queued
   `branch` sub-pipe.
4. `merge` of an idle source and one that emits, into `take(1)`: `run` returns.
5. `system`: one member fails while another waits forever: `run` returns the
   failure. On an `Io` without concurrency: `error.ConcurrencyUnavailable`.
6. A queue compiles in a pipe whose handlers return `anyerror`.
7. Graceful end: the source returns with a full queue and a slow consumer;
   every item is handled, a `fold` after the queue emits, writers flush.
8. Graceful end across two queues and across a queued `branch`: sub-pipes
   finish, each exactly once.
9. Idle source, `queue`, `take(1)`: `run` returns (rule 6).
10. Three segments, the last done, the middle one waiting in a handler: `run`
    returns and that handler did not finish by itself.
11. A segment fails while another is draining: no `fold` after it emits and no
    writer is flushed.
12. The caller is cancelled: `error.Canceled`, every task joined, no `finish`.
13. A writer provided before a queue and written to after it is flushed after
    the last segment has finished.
14. The zero-overhead fixtures are unchanged and pass.
15. `run`'s error set is the handlers' and operators' errors, plus
    `error.Canceled` and `error.ConcurrencyUnavailable` with a queue.

## Steps

Each step is one reviewable change, from `main`.

1. The scope in `src/tasks.zig`; `system` and `merge` ported to it and the
   scope tested through them (cases 4, 5). *Done.*
2. Segments: the boundary hook, `finish` stopping at a boundary, the source as
   segment 0, `start` removed (cases 1 to 3, 6 to 8, 11 to 15). *Done.*
3. Rule 6 (cases 9, 10). *Done.*
4. The guide, and the design decisions in `AGENTS.md`. *Done.*
5. *(proposed)* The stop trigger for sources.
