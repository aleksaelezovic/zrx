# Spec: segments and one scope

Status: being implemented step by step (see Steps). Replaces the approach of
the closed PR 3 (`rewrite-hardening`).

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
5. **Failure.** The first task that returns an error is the result of the run.
   The scope marks the run as failed, cancels every other task and joins them.
   A segment does not begin `finish` once the run is marked failed, and
   `flush` is skipped. *(accepted)*
6. **Working for nothing.** A segment whose every output is a queue is
   cancelled once every segment fed by those queues has returned. What it
   returns is discarded. This is decided from a static tree of segments, by
   the scope, when a task returns. *(accepted)*
7. **After every task is joined**, on the caller: `flush` in reverse order (on
   success), then `deinit` in reverse order. *(accepted)*
8. **Cancelling the run** (the caller's task is cancelled) cancels every
   segment, skips `finish` and `flush`, and returns `error.Canceled`.
   *(accepted)*
9. **`merge` and `system` use the same scope.** In `merge`, a member that is
   answered `.done` ends the group as a success and the others are cancelled.
   On an `Io` without concurrency both return
   `error.ConcurrencyUnavailable`; there is no sequential fallback.
   *(accepted)*

## Contract

- **"Done" is a hint, sticky where it originates** *(accepted)*. A stage that
  answers `.done` of its own accord keeps answering `.done`. Whoever is
  answered `.done` stops pushing items. Final values (`fold`, `batch`) are
  still pushed and are refused by the stage that is done.
- **Stage hooks** *(accepted)*: `init`, `push`, `finish`, `flush`, `deinit`,
  `provide`. `start` is removed: no stage emits before the first item. A stage
  that is a task boundary declares `zrx_boundary` and one more hook, the body
  its task runs. `src/pipe.zig` knows the marker and the hook, not `queue`.
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
- Which wins when a failure and a "done" happen together: whichever task the
  scope sees return first.
- That items already in a queue are not handled after a failure elsewhere.
  Handlers may run for some of them until the cancel request arrives; no
  `finish` runs.
- Interrupting a handler that never calls into `std.Io`.
- Exact item counts before a queue: stages before it may have handled more
  items than the stages after it take.

A review finding against something on this list is answered by pointing here,
not by a change.

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
4. The guide, and the design decisions in `AGENTS.md`.
5. *(proposed)* The stop trigger for sources.
