# Spec: the process a program runs in

Status: implemented as `zrx.ext.process` (`src/ext/process.zig`). The
shape of the stream bindings and the staging with the core are proposals
until the owner decides them; they are marked below.

This file is the design record of the extension: why it is the way it is,
what was rejected and what was measured. The
[guide](guide.md#the-process) says how to use it, and every behavior named
there is pinned in `tests/process.zig`. `AGENTS.md` keeps the short rules
to know before editing it and points here for the reasons.

## What it replaces

Two things a command-line program wrote by hand.

**The status.** A run returns nothing, so a program leaves its exit status
through a dependency and takes the failure of the run in a rescue. Every
example and most apps wrote the same few lines for that, about a dozen
copies:

```zig
const Exit = struct { code: u8 = 0 };

fn fatal(diagnostics: zrx.Stderr, exit: *Exit, err: anyerror) void {
    exit.code = 2;
    diagnostics.writer.print("fatal: {s}\n", .{@errorName(err)}) catch return;
    diagnostics.writer.flush() catch {};
}
```

The copies differed in three things only: the status (1 or 2), the prefix
(`fatal` or `error`), and whether a line was written at all (seven examples
set the status and said nothing). One app also wrote "status 1 if any file
failed" by hand, as a `fold` over an enum and a handler that stores it.

**This file, or standard input.** The record processor's README lists it
as a gap: `lines(Input, n)` with a `fileReader`, or `stdinLines(n)`, were
two programs over one pipe, because standard input was only a source.

## The name

`process`, not `cli` and not `stdio`. An exit status and arguments are not
streams, and what would come next (child processes, signals) belongs to
the same thing: the process the program runs in. The first version was
`zrx.ext.cli` and held the status alone; the owner found that too small to
be worth a name.

## The standard streams

`stdin(Role, n)`, `stdout(Role, n)` and `stderr(Role, n)` are bindings, as
`fileReader(Role, path, n)` and `fileWriter(Role, path, n, options)` are.

**A stream names its role** *(proposed)*. All three take the role first.
That is what makes a stream stand in for a file: a program reads
`lines(Input, n)` and is run with `fileReader(Input, path, n + 1)` or with
`stdin(Input, n + 1)`, and a program that prints to `Output` is run with a
`fileWriter` or with `stdout(Output, n)`. One shape for the three, and the
shape the file bindings already have. `Stdin`, `Stdout` and `Stderr` are
the roles a stream has when a program has no better name for it:
`stdout(Stdout, 4096)`.

The cost is that the common case stutters. Rejected all the same:

- *A form without a role beside it* (`stdout(n)` and `stdout(Role, n)`):
  two spellings, and Zig has no overloading to carry them under one name.
- *No role at all, and the file takes the stream's* (`stdin(n)` provides
  `Stdin`, and "this file" is `fileReader(Stdin, path, n)`). It needs
  nothing new but the `Stdin` role. But a file is then bound under the
  name of a stream, and a role cannot go to standard output in one run
  and to standard error in another.

**The choice is still two runs.** A binding is a type, so `fileReader` and
`stdin` cannot be one value, and `main` has an `if` with a `run` in each
arm. What is one now is the program. A binding that is one of two, chosen
when it is acquired, is not there.

**The core has no standard streams.** It had `zrx.Stdout`, `zrx.Stderr`,
`zrx.stdout(n)`, `zrx.stderr(n)` and `zrx.stdinLines(n)` from before this
extension, and for one change the roles were one type under two names.
They left the core in the change that moved every example and app here:

- `Stdout` and `Stderr` are declared here. A second pair of roles would
  have made `print(Stdout, ...)` depend on which `Stdout` was imported, so
  the core's pair was not kept beside them.
- `zrx.stdout(n)` is `process.stdout(Stdout, n)`, and `zrx.stderr(n)`
  likewise. The role is written, which is what "this file, or standard
  output" needs.
- `zrx.stdinLines(n)` is `lines(Stdin, n)` run with
  `process.stdin(Stdin, n + 1)`. The one difference went with it:
  `stdinLines` owned its reader and failed with what the system reported,
  and a read through a binding fails with `error.ReadFailed`, as below.
  Nothing in the examples or apps looked at that error.

**A failed read is `error.ReadFailed`.** `stdin` does what `fileReader`
does and for its reason: by the time the failure is back at the binding, a
`ReadFailed` may be another reader's, so the binding does not put the
system's error in its place.

**The reader reads ahead, and is the binding's.** A re-review ran a
program that takes one line twice on one standard input, each run with a
`stdin` of its own, and got the first of two lines only: the first
binding's reader had read the start of the second line into its buffer,
and the buffer went with the binding. Reproduced in `tests/process.zig`,
where the second run reads what was left after the first one's reads.
That is what a buffered reader does, and a binding that cannot hand its
buffer on cannot do otherwise. Nothing new answers it: a value of the role
is a binding already, so `main` makes one reader over standard input and
gives it to each run as `Input{ .reader = &reader.interface }`. The guide
says so with the code, and the same test pins that both lines arrive.

**Nothing allocates, nothing is flushed.** The buffer is an array of a
comptime size in the binding's `bind`, alive for as long as the run. The
binding does not flush: `print` and `write` flush what they wrote, as with
the core's `stdout`.

**A role is the interface or a struct with that one field.** The check is
the one `fileReader` and `fileWriter` make, written again here because
theirs is private to `src/io.zig`. A reader role given to `stdout` is the
mistake it is there for.

## The exit status

`Exit` is `struct { code: u8 = 0 }`, a dependency like any other. It is in
the extension so that a handler of the caller's own, `status` and `fail`
ask for the same type.

### A status for an item

`status(n)` is a handler that raises the status to at least `n` when it is
called, whatever it is called with. It is for `tap` or `forEach`, usually
on an error path: the program finished, and not with everything.

**It raises and never lowers.** `exit.code = @max(exit.code, n)`. Two of
them then say the same in either order, and what something else left there
stays if it was higher. A plain store would make the last one to be
reached win, and which is last depends on the items.

**It is a plain store, not an atomic one.** In the workers of a
`concurrent` two tasks would write one byte. An atomic maximum is not
what one writes by hand, and what it costs was not measured. So it is to
be put where one task calls it, as any handler that writes through a
dependency, and the guide says so.

**It refuses an error alone.** That is the failure of a run, and
`rescue(status(2))` would be a second spelling of
`rescue(fail(.{ .status = 2, .prefix = null }))` that differs only in
raising. The compile error says what to write.

*(Proposed, not done.)* The other way to have one spelling is to let
`status` be the silent form: `rescue(process.status(2))`, a `fail` whose
prefix is not optional, and `fail` raising as well. It is smaller. It was
not done because `fail` was to stay as it is in this change, and because
it changes what a failed run leaves after a higher status.

### The failure of a run

`fail(options)` is a composite handler of one error. It sets the status,
then writes `prefix: Name` to `Stderr` and flushes.

**One spelling.** `fail` is always called with its options, `.{}` for the
defaults, as `json.encode` is. The silent form is `.prefix = null`. It is
not a second handler: two handlers would be two names for "what a failed
run leaves", and a flag beside the prefix would be two fields that say one
thing. What the handler requires is read off the options at compile time,
so the silent form asks for no `Stderr`.

**The defaults are Zig's.** `error: Name` and status 1 are what Zig does
with an error returned from `main` (`std.start` logs it with `std.log.err`
and returns 1). A program that says nothing else behaves as one that
returned the error would.

**The status first, the line best effort.** A write or a flush that fails
is dropped. A rescue handler returns `void`: there is nobody left to give
that failure to, and the status must stand whatever becomes of the line.

**It sets, where `status` raises.** A rescue is called once, after the
run, so there is no order to be independent of: the failure of the run
decides the status, whatever an item left.

**The prefix is plain text, taken literally.** The line is one `print`
with a format built at compile time, so that it is the call one writes by
hand. Braces in the prefix are doubled there.

A review of the first version found that a newline in the prefix breaks
the one line. Reproduced: `.prefix = "fatal\nnext"` wrote
`fatal\nnext: TooBig\n`, two lines. The same cause has neighbours that
do not add a line and still spoil it on a terminal: a carriage return
writes over what came before, an escape starts a control sequence, a
backspace or a delete takes a byte back, a NUL may end the text for
whoever reads the log. So the rule is one: an ASCII control byte in the
prefix (0x00 to 0x1f, and 0x7f) is a compile error, where the prefix is
written, that names the byte and its index. That includes a tab, which
harms nothing, so that the rule has no exception to remember.

Not looked at in the prefix, and said here so that nobody takes it for
covered: bytes from 0x80 up. A prefix may be UTF-8, and the separators
that are written in several bytes (U+0085, U+2028, U+2029) are not
searched for.

**The name is escaped, not refused.** A re-review found the same cause in
the name: an error declared with a quoted name can hold a newline, and
`error.@"Too\nbig"` wrote two lines. A compile error cannot be the answer
there: under `anyerror` the name is known only when the run has failed.
So the name is printed with `std.ascii.hexEscape`: every byte that is not
printable ASCII is written as `\xNN`, a newline as `\x0a`. That is the
prefix's rule turned into an escape, and wider: bytes from 0x80 up are
escaped too, so the line separators of Unicode are, and so is a name in
UTF-8, which only a quoted name can be. An identifier, which is what
almost every error is, is written as before. Not done: a backslash is not
escaped, so a name that holds `\x0a` as text reads as one that holds a
newline. The line stays one either way.

Rejected, both from `std.zig`, because each decodes UTF-8 or parses an
integer type and so has error constants of its own, which are numbered
per compilation (see the fixture below): `same_process_fail` then
differed in those constants only.

- `fmtId`, which writes such a name `@"..."` whole, as it is written
  after `error.`: 947 instructions each side.
- `fmtString`, the escaping of what stands between those quotes, `\n`
  for a newline and the line separators of Unicode as bytes, with UTF-8
  kept: 775 each side.

## A handler, not a binding

`rescue(process.fail(.{})).provide(.{stderr(Stderr, 256)})` stays the one
way to bind a rescue. A `process.rescue(...)` that hid the `provide` would
be a second spelling of it, and would have to decide the size of a buffer
for the caller.

It also means the extension checks nothing about dependencies itself. What
`fail` asks for is checked by `rescue`, whose messages already say what to
write: an `Exit` passed by value, no stderr, and the stderr of the run,
which is released before a rescue is called. `tests/compile_fail/` has a
case for each with `process.fail` (`process_fail_exit_value`,
`process_fail_without_stderr`, `process_fail_stderr_of_run`).

A composite handler bound with `rescue` is given exactly the errors the run
can fail with, as an `anytype` parameter is. So `fail` leaves nothing over,
whatever the run can fail with.

## One error, in a rescue or at the end of a pipe

Being a handler of one error, `fail` also ends a pipe whose item is one:

```zig
program(fromValue(err), .{forEach(fatal)}).run(.{ io, exit, stderr(Stderr, 256) });
```

That is how the apps already said the same of what failed before there was
a run, such as a wrong number of arguments, with their own `fatal`. So
there is no `refuse` in the extension: it is writable with what exists.

`fail` refuses anything but exactly one error, with a compile error. That
includes a place where the types would fit: as the fallback of an `orElse`
inside a `tap` it would be given an error and an item, set the status and
let the stream go on. The line names a failed run and holds nothing of an
item. A failure that should say which file or which line is an item's, and
is taken in the pipe by an error path, where the item is at hand and
`status` says what it means for the outcome.

Status 0 is a compile error for both handlers: for `fail` it says a failed
run succeeded, and for `status` it raises nothing. An empty prefix is one
as well: it begins the line with `: `.

## Cancellation, and the process

`fail` is given `error.Canceled` like any failure and writes `Canceled`.
It calls neither `io.recancel()` nor `std.process.exit`: `main` returns
the status, and what a cancelled caller owes its own caller is not
something a handler for the exit status can know.

## Measurements

Three fixtures, all `same`:

- `same_process_status`: at the end of a pipe that adds every value up,
  against a loop by hand with the `@max` where the value is seen. 19
  instructions.
- `same_process_fail_silent`: bound as a rescue, against a loop by hand
  that stores the status where it fails. 18 instructions.
- `same_process_fail`: the line, against the `print` and `flush` one
  writes, the name through `hexEscape` on both sides. 196 instructions;
  126 before the name was escaped.

The streams have none. They are bindings around `std`'s file reader and
writer and add no stage to a pipe; what a binding costs a run is
`same_resource`'s to hold.

**The fixture of the line takes its error as a parameter.** Errors are
numbered per compilation, and the two variants of the fixtures are two
compilations with different sets of errors. A constant error that reaches
`@errorName` is therefore a different constant in each. Measured once: as
the rescue of a program with two failing handlers,
`fail(.{ .status = 2, .prefix = "fatal" })` and the function handler above
were the same 145 instructions, except `select i16 2` and `9` on one side
and `7` and `8` on the other. Such a fixture would also break whenever an
error is added to either variant. A fixture that only asks whether a run
failed, as `same_rescue`, is not affected.

Against a whole loop by hand, the same program differed in shape as well:
the pipeline merges its two failures with selects where the loop keeps a
branch. That is the pipeline's, with any rescue handler, and `lean` does
not allow the calls a `print` makes. So the line is compared where nothing
but the handler is there.

**How the streams are tested.** No test reads the real standard input.
`Streams` in `tests/process.zig` is an `Io` over `std.testing.io` whose
`operate` serves reads of the standard input handle from memory, three
bytes at a time, and keeps what is written to the two output handles. The
program whose pipe and source are one value is run from a file and from
that standard input and must print the same.

**Mutants.** Each of these changes made a test or a compile-error case
fail. Of the first version: no status, a fixed status, the status after
the line, no flush, another format, braces not doubled, a stderr asked for
in the silent form, no check of what `fail` is given. Of this one:
`status` storing, doing nothing, or taking the minimum; `stdout` and
`stderr` exchanged, either way; `fail` raising; control bytes let through,
or only the newline refused; `status` taking a lone error, or 0; a role
with a second field. One survived at first: a `stdin` buffer one byte
short. No test had a line of the full length, and one was added. Of the
re-review: the name printed as it is.

## Not there

Back only by decision:

- an arguments source. `fromSlice(args[1..])` for the slice
  `init.minimal.args.toSlice(arena)` returns, and `fromIterator(&iterator)`
  for `init.minimal.args.iterate()`, are that already. `tests/process.zig`
  pins the item type of both;
- a typed parser of options, and a usage text. It is a design of its own
  and can grow into a framework for command lines; one app writes a usage
  text (`record-processor`) and one parses a port (`http-bench`);
- choosing a program for the arguments. It is decided once, before any
  run, and is a `switch` in `main`;
- a binding chosen when it is acquired, so that "this file, or standard
  input" is one `run`;
- environment variables. `init.environ_map` is a value `main` has;
- child processes;
- signals. Ending a run on Ctrl-C waits for the source that can be stopped
  from outside, proposed in
  [the segments spec](spec-segments.md#stopping-from-outside);
- a status that is an enum. `file-integrity-manifest` has
  `Exit = enum(u8)` and a `fold` over it; with `process.Exit` that is
  `forEach(status(1))` behind a `filter`, which is a decision for that
  app.
