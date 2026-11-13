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

- **Segment.** A `queue` splits a pipe into segments. A segment is one task
  running a synchronous chain: segment 0 is the source and the stages up to the
  first queue; every other segment takes items from one queue and runs the
  stages up to the next. A sub-pipe of `branch` or `route` that starts with a
  queue is a segment of its own.
- **Scope.** The one supervisor, in `src/tasks.zig`, used by `program`
  (segments), `merge` (sources) and `system` (programs).

## Guarantees

Each is stated at a point a caller can observe: what `run` returns, what was
flushed, what has been torn down, whether `run` returns at all. Nothing is
promised about a moment inside the run.

1. **On success**, every stage has finished exactly once and then flushed
   exactly once. Stages of one segment finish in order, and flushing starts
   after the last segment has finished, last stage first.
2. **On an error**, `run` returns it and nothing has been flushed. Whether a
   given stage finished is not promised.
3. **Which error.** The first failure of any task. Where tasks are started
   (a queue, `merge`, a `system`): `error.Canceled` instead, if the task that
   called `run` has been asked to cancel by the time `run` returns.
4. **Always**, every task has returned before any stage is torn down, and
   stages are torn down in reverse order.
5. **A failure does not wait.** `run` returns without waiting for a source or
   a handler that is waiting in an `Io` call: it is cancelled there.
6. **A queue whose task has ended takes no more.** However the task ended
   (its input ran out, it was done, it failed, it was cancelled), a push
   into that queue answers `.done`; no producer is left waiting on it.
7. **Graceful end.** When the source returns, everything it pushed is still
   handled: each queue drains and each segment finishes in turn. Only a
   stage that is done, or an error, cuts this short.
8. **A program without a queue is one loop on the caller's task**, and its
   code is what the zero-overhead fixtures compare.
9. **`run`'s error set is inferred**: the handlers' and operators' errors,
   plus `error.Canceled` and `error.ConcurrencyUnavailable` where tasks are
   started. There is no sequential fallback for `merge` and `system`.

## Not promised

A review finding against one of these is answered by pointing here.

- That a source waiting for input is interrupted when the stages behind a
  queue are done. It finds out at its next push, as on `main`. (See "Taken
  out".) `merge` does cancel its other sources when a push of one of them is
  answered `.done`.
- That no handler runs for a final value once a later stage is done. Stages
  between the one that emits it and the one that is done may run for it.
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
- Exact item counts before a queue: stages before it may have handled more
  items than the stages after it take.
- Anything about cancelling a program without a queue, beyond what its own
  handlers and source do with `error.Canceled`: it has no `Io` to ask.

## How it works

Mechanism, not promises. It may change as long as the guarantees hold.

- **The end of the stream travels with the data.** `finish` runs in order up
  to and including a queue, on the task that pushed into it; the queue's task
  finishes what follows. No task finishes another segment's stages. `flush`
  and `deinit` run on the caller after every task has returned.
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
  cancelled. On an outcome it joins every task, cancelling those still
  running unless all returned by themselves. Before it returns it looks at
  its own cancellation once more: joining is not a cancelation point.
- **Each segment runs on the `Io` in force at its queue**; segment 0 on the
  `Io` of the first queue. Tasks are started with `Io.concurrent`, never run
  on the caller, and are cancelled one after another (`std.Io` sends a
  cancel request by joining).
- **`merge`** tells its scope when a push is answered `.done`; the scope then
  cancels the other sources and ends as a success.

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
  and are refused by the stage that is done.
- **Stage hooks**: `init`, `push`, `finish`, `flush`, `deinit`, `provide`.
  There is no `start`: no stage emits before the first item.
- **A task boundary** declares `zrx_boundary`, `work` (the body of its task),
  `retire` (from now on `push` answers `.done`) and `taskIo`.
- **A stage with sub-pipes** declares `has_boundary`, `Tasks` and `tasks`.
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
- **No context passed between segments** *(proposed)*. A segment learns that
  the stream is ending when its queue is closed and empty, which is when its
  `finish` runs. A handler that wants a flag of its own injects one.

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

If it returns, it is a PR of its own, with this list as its starting point.
Until then the behaviour is `main`'s: the segment finds out at its next push.

## Costs

- With a queue, no handler runs on the task that called `run`: the source is
  a task too, so that a failure can interrupt it.
- Tasks are cancelled one after another. One that is slow to notice delays
  the request to those after it; the run returns at the same moment either
  way.
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
- Handing over chunks instead of items gets under that floor: `batch(64)`,
  a `map` to an array, `queue(64)`, `flatten()` measures about 4.7 ns/item.
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

1. A handler after a queue uses resources provided before and after the
   queue while the source fails: neither is released before that handler
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
   every item is handled, a `fold` after the queue emits, stages flush after
   the last segment has finished. (1, 7.)
8. Six shapes of pipe (segments in a row, beside a direct sub-pipe of the
   source and of a segment, two queued sub-pipes, a branch behind a queue,
   queued cases of a route), each with one side running out, being done
   after one item, and failing on the first: `run` returns; a sub-pipe
   beside that side gets every item meant for it; on success every stage
   finishes once and flushes once; on failure nothing flushes. (1, 2, 6.)
9. A failure elsewhere, then a segment whose input has ended: it does not
   end its stream; nor does the source's segment when the source returns
   after the failure. A segment that takes its time retiring decides after
   it has retired. ("How it works", steps 2 to 4.)
10. The caller is cancelled while the run waits: `error.Canceled`, every
    task joined, nothing finishes or flushes. (3.)
11. The caller is cancelled while the run joins its tasks, after a success
    and after a failure: `error.Canceled`, nothing flushes. (3.)
12. A queue's task runs on the `Io` in force at the queue; a program can run
    its segments on two `Io` instances.
13. The zero-overhead fixtures are unchanged and pass. (8.)

## History

1. The scope; `system` and `merge` ported to it.
2. Segments: the boundary hooks, `finish` stopping at a boundary, the source
   as segment 0, `start` removed.
3. Interrupting a segment that works for nothing. *Taken out again.*
4. The guide and `AGENTS.md`.
5. After the first review: every task ends its work in one place.
6. After the second: each decision is taken right before what it allows.
7. After the third: step 3 taken out; the caller's cancellation is looked at
   where `run` returns; one list of guarantees, here.

Not built, by explicit decision only: the stop trigger for sources; an
owning chunk so that `batch` can cross a queue.
