# Spec: the exit status of a command-line program

Status: implemented as `zrx.ext.cli` (`src/ext/cli.zig`).

This file is the design record of the extension: why it is the way it is,
what was rejected and what was measured. The
[guide](guide.md#command-line-programs) says how to use it, and every
behavior named there is pinned in `tests/cli.zig`. `AGENTS.md` keeps the
short rules to know before editing it and points here for the reasons.

## What it replaces

A run returns nothing, so a command-line program leaves its exit status
through a dependency and takes the failure of the run in a rescue. Before
the extension, every example and most apps wrote the same few lines for
that, about a dozen copies:

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
set the status and said nothing). The extension is the smallest thing that
removes them: the type, and one handler with those three variations.

## A type and one handler

`Exit` is `struct { code: u8 = 0 }`, a dependency like any other. It is in
the extension so that a handler of the caller's own and `fail` ask for the
same type.

`fail(options)` is a composite handler of one error. It sets the status,
then writes `prefix: Name` to `zrx.Stderr` and flushes.

**One spelling.** `fail` is always called with its options, `.{}` for the
defaults, as `json.encode` is. The silent form is `.prefix = null`. It is
not a second handler: two handlers would be two names for "what a failed
run leaves", and a flag beside the prefix would be two fields that say one
thing. What the handler requires is read off the options at compile time,
so the silent form asks for no `zrx.Stderr`.

**The defaults are Zig's.** `error: Name` and status 1 are what Zig does
with an error returned from `main` (`std.start` logs it with `std.log.err`
and returns 1). A program that says nothing else behaves as one that
returned the error would.

**The status first, the line best effort.** A write or a flush that fails
is dropped. A rescue handler returns `void`: there is nobody left to give
that failure to, and the status must stand whatever becomes of the line.

**The prefix is taken literally.** The line is one `print` with a format
built at compile time, so that it is the call one writes by hand. Braces in
the prefix are doubled there.

## A handler, not a binding

`rescue(cli.fail(.{})).provide(.{stderr(256)})` stays the one way to bind a
rescue. A `cli.rescue(...)` that hid the `provide` would be a second
spelling of it, and would have to decide the size of a buffer for the
caller.

It also means the extension checks nothing about dependencies itself. What
`fail` asks for is checked by `rescue`, whose messages already say what to
write: an `Exit` passed by value, no stderr, and the stderr of the run,
which is released before a rescue is called. `tests/compile_fail/` has a
case for each with `cli.fail` (`cli_fail_exit_value`,
`cli_fail_without_stderr`, `cli_fail_stderr_of_run`).

A composite handler bound with `rescue` is given exactly the errors the run
can fail with, as an `anytype` parameter is. So `fail` leaves nothing over,
whatever the run can fail with.

## One error, in a rescue or at the end of a pipe

Being a handler of one error, `fail` also ends a pipe whose item is one:

```zig
program(fromValue(err), .{forEach(fatal)}).run(.{ io, exit, stderr(256) });
```

That is how the apps already said the same of what failed before there was
a run, such as a wrong number of arguments, with their own `fatal`. So
there is no `refuse` in the extension: it is writable with what exists.

`fail` refuses anything but exactly one error, with a compile error. That
includes a place where the types would fit: as the fallback of an `orElse`
inside a `tap` it would be given an error and an item, set the status and
let the stream go on. The line names a failed run and holds nothing of an
item. A failure that should say which file or which line is an item's, and
is taken in the pipe by an error path, where the item is at hand.

Status 0 and an empty prefix are compile errors as well: the first says a
failed run succeeded, the second begins the line with `: `.

## Cancellation, and the process

`fail` is given `error.Canceled` like any failure and writes `Canceled`.
It calls neither `io.recancel()` nor `std.process.exit`: `main` returns
the status, and what a cancelled caller owes its own caller is not
something a handler for the exit status can know.

## Measurements

Two fixtures, both `same`:

- `same_cli_fail_silent`: bound as a rescue, against a loop by hand that
  stores the status where it fails. 18 instructions.
- `same_cli_fail`: the line, against the `print` and `flush` one writes.
  126 instructions.

**The fixture of the line takes its error as a parameter.** Errors are
numbered per compilation, and the two variants of the fixtures are two
compilations with different sets of errors. A constant error that reaches
`@errorName` is therefore a different constant in each. Measured once: as
the rescue of a program with two failing handlers,
`cli.fail(.{ .status = 2, .prefix = "fatal" })` and the function handler
above were the same 145 instructions, except `select i16 2` and `9` on one
side and `7` and `8` on the other. Such a fixture would also break whenever
an error is added to either variant. A fixture that only asks whether a run
failed, as `same_rescue`, is not affected.

Against a whole loop by hand, the same program differed in shape as well:
the pipeline merges its two failures with selects where the loop keeps a
branch. That is the pipeline's, with any rescue handler, and `lean` does
not allow the calls a `print` makes. So the line is compared where nothing
but the handler is there.

Each of eight changes to the handler made a test fail: no status, a fixed
status, the status after the line, no flush, another format, braces not
doubled, a stderr asked for in the silent form, and no check of what it is
given. Two of them fail to compile on what `tests/cli.zig` writes, which is
that test asking for the behavior.

## Not there

Back only by decision:

- an arguments source. `fromSlice(args[1..])` for the slice
  `init.minimal.args.toSlice(arena)` returns, and `fromIterator(&iterator)`
  for `init.minimal.args.iterate()`, are that already. `tests/cli.zig` pins
  the item type of both;
- choosing a program for the arguments. It is decided once, before any
  run, and is a `switch` in `main`;
- a usage text and option parsing. One app writes the usage after the line
  (`record-processor`), and one parses a port without zrx (`http-bench`).
  One copy is not a pattern;
- a status that is an enum. `file-integrity-manifest` has
  `Exit = enum(u8)` and a `fold` over it; it keeps a handler of its own or
  moves to `cli.Exit`, which is a decision for that app.
