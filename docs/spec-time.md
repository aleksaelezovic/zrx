# Spec: time

Status: implemented as `zrx.ext.time` (`src/ext/time.zig`), in a first
draft. The five choices under "Proposed" wait for the owner's decision.

This file is the design record of the extension: why it is the way it is,
what was rejected and what was measured. The [guide](guide.md#time) says
how to use it, and every behavior named there is pinned in
`tests/time.zig`. `AGENTS.md` keeps the short rules to know before editing
it and points here for the reasons.

## An extension without a task

It holds a source (`ticks`), a handler (`stamp`) and a synchronous operator
(`throttle`), each written against its public contract and analyzed only
when `zrx.ext.time` is referenced. All three take the time from the
`std.Io` of the run.

What tells it from the core's `debounce` and `batchWithin` is that nothing
here keeps an item or starts a task. An operator that has to emit while its
input is silent needs a task, so it is a boundary and belongs with those.
That line decides what is in the extension and what is not.

Periods and windows are positive comptime `std.Io.Duration` values measured
on `.awake`, as for `batchWithin` and `debounce`. The parameter is typed,
so that `.fromSeconds(1)` can be written; a bare number is then Zig's own
error at the call, which `tests/compile_fail/time_throttle_number.zig`
pins.

## Proposed

### 1. `Stop.waitTimeout`, the one addition outside the extension

`ticks` has to wait for whichever comes first: its next time, or the news
that its consumers are done. `zrx.Stop` had `requested` and `wait`, and no
wait with an end. `Stop.waitTimeout(io, timeout)` in `src/completion.zig`
is `wait` with one: it waits on the run's signal where there is one, and on
an event of its own where there is none, as `wait` does.

Rejected:

- **Composing it from `stop.wait` and a sleep with `std.Io.Select`.** That
  is two tasks for every tick, and it needs an `Io` that runs tasks
  concurrently even for a program without a boundary, where `Stop` has no
  signal and `stop.wait` never returns.
- **Reading `stop.signal` in the extension.** The field is public, but
  that is writing against the representation and not the contract.
- **Not cooperating, and learning of completion through `push`.** A source
  that ticks every hour would hold a finished run for up to an hour.

A wake is not the deadline. `std.Io.Event.waitTimeout` reports any wake
that did not set the event as a timeout, so `ticks` looks at the stop and
at the clock again after every wait. The test "ticks woken before its time
looks at the clock and waits again" holds the source to that with an `Io`
whose first timed wait returns at once.

`zrx.testing.Clock` does not move `io.sleep`, which sleeps for real. A
timed wait on an event is what a test can see with `waitingAt`, and that is
the second reason the source does not sleep.

### 2. `ticks` pushes the count, the first a period after it starts

The item is a `u64`: 0 one period after the source starts, 1 a period after
that. Tick `n` is due `n + 1` periods after the start.

It pushes the count and not the time, because the time is
`map(time.stamp(clock))`: pushing a timestamp would be a second spelling,
and would choose the clock for the caller. The first tick comes after a
period, as Rx `interval` does, and not at once.

### 3. A late tick is skipped, not caught up

The times are fixed when the source starts, so a pipe that takes its time
does not make them drift. A push returns when the pipe is through with the
tick. A tick whose time has passed by then is not pushed, and its number is
missing from the count: 0, 3, 4 says that two were skipped. A tick that is
due exactly then is pushed at once.

Rejected:

- **Catching up**, pushing every missed tick at once. A slow pipe would be
  handed a burst for being slow.
- **Counting the next period from the end of the push.** The times drift,
  and the count no longer says what time a tick stands for.
- **Pushing the latest missed tick at once and skipping the ones before
  it.** A pipe that is always a little slower than the period would never
  rest.

### 4. `stamp(clock)` is always called with its clock

`map(time.stamp(.real))` emits `time.Stamped(T)`: the fields `at`, a
`std.Io.Timestamp`, and `item`. The clock is always given, as the options
of `json.encode` are: `.real` is a date, `.awake` is what to measure with,
and neither is the obvious default.

It emits a type of its own and not a `Tagged`, whose field is `source` and
says where an item came from.

### 5. `throttle` is the leading edge, and keeps 64 bits

It passes an item and drops the ones within the window of it. The window
starts with an item that passed: a dropped item does not extend it, and an
item that arrives just as it ends passes. Nothing is kept, so the last item
of a burst is dropped and nothing is emitted at the end of the stream. A
throttle that emits the last item of a window has to emit while its input
is silent, which is `debounce`'s kind of operator.

The end of the window is kept as `i64` nanoseconds (`Nanoseconds`), not as
the 96 bits `std.Io` counts in. The reason is under "Measurements". The
cost is a limit of 292 years on a clock that starts with the system; past
it the `@intCast` is a safety panic in Debug and ReleaseSafe.

## Measurements

`stamp` and `throttle` each have a `same` fixture against a loop by hand
that reads the same clock. Reading the clock is a call through the
`std.Io` in both variants, so neither could be `lean`: `lean` allows no
call.

| Fixture | Instructions, both variants |
|---|---|
| `same_time_stamp` | 27 |
| `same_time_throttle` | 36 |

Two things were found on the way.

**A stage's state in an integer that is not the size of a register costs
an instruction.** With `open_at` as an `i96`, `throttle` measured 32
instructions to 31 by hand: one `sext`, and the comparison in 128 bits
where the loop by hand compared in 96. Zig keeps an `i96` in memory
sign-extended to 128 bits. A stage is reached through a pointer and is
optimized before it is inlined, so the extended form stays; a local of the
loop by hand is promoted before that. With `i64` both variants are the
same 36 instructions, of which five are the assumptions of the two
`@intCast`s and no code. Keep a stage's state in integers the size of a
register.

**The declared type of a stack slot is compared.** The `stamp` fixture
builds its pair through a function by hand as well. Written in place by
hand, both variants are 27 instructions and differ in one: the slot the
clock answers into is declared `%Io.Timestamp` on one side and
`[16 x i8]` on the other, the same size and alignment. The tool rightly
does not equate them, and it was not changed.

## Tests

Time is moved with `zrx.testing.Clock`. For the source a test waits on
`waitingAt`, the event that the source is in its timed wait. `stamp` and
`throttle` run in a program without a boundary on the test's own task,
where a `tap` with the clock among its dependencies sets the time each
item arrives at. Nothing waits a length of time.

Fifteen mutants of the extension were each caught by a test. Six of them
are caught by a hang and not by a failed expectation: a source that is not
told to stop, or that waits at another time than the test does, leaves the
test waiting. That is how the `Stop` tests of `tests/flow.zig` fail too.

## Not there

Back with stopping from outside, or by decision. The stage contract does
not grow for them.

- `timeout`. It has to end a run whose source is waiting for input, which
  is stopping it from outside. That is
  [proposed in the segments spec](spec-segments.md#stopping-from-outside)
  and not there yet.
- `delay`. It holds items until their time, so it needs a buffer and a
  task: a boundary of its own.
- `sample`. It emits while its input is silent, so it needs a task, as
  `debounce` does.
- A throttle that emits the last item of a window, for the same reason.
- The time between two items. `map(time.stamp(.awake))` and a `scan` over
  the pairs can say it; no test holds that sentence.
