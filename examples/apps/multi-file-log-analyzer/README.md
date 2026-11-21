# Multi-file log analyzer

Read two finite service logs together, write their error records to a JSONL
alerts file, and print one JSON summary with counters for each log. Built
with zrx and Zig **0.17.0**; it is the example for merging sources. No
third-party dependencies.

```sh
cd examples/apps/multi-file-log-analyzer
zig build
printf '1\terror\tapi\t7\n3\twarn\tapi\t11\n' > left.tsv
printf '2\tinfo\tdb\t17\n4\terror\tdb\t19\n' > right.tsv
./zig-out/bin/multi-file-log-analyzer left.tsv right.tsv alerts.jsonl
# stdout: {"left":{"records":2,"warnings":1,"errors":1,"latency_ms":18},"right":{"records":2,"warnings":0,"errors":1,"latency_ms":36}}
# alerts.jsonl, one line per error record:
#   {"source":"left","ts_ms":1,"service":"api","latency_ms":7}
#   {"source":"right","ts_ms":4,"service":"db","latency_ms":19}
```

## The pipes

The program is one constant in [`src/app.zig`](src/app.zig):

```zig
const alerts = pipe(.{
    filter(isFailure),
    map(field(.entry)),
    queue(32),
    map(json.encode(.{})),
    write(Alerts, "{f}\n"),
});

const totals = pipe(.{
    fold(Summary{}, Summary.add),
    map(json.encode(.{})),
    print(Report, "{f}\n"),
});

const logs = mergeTagged(events.Side, .{
    .left = lines(Left, max_line),
    .right = lines(Right, max_line),
});

/// A line of a log: four columns between tabs. (In `events.zig`.)
const record = seq(.{
    extract(.ts_ms, int(u64)),
    "\t",
    extract(.level, as(Level, repeat(pattern.lower, .{ .min = 1 }))),
    "\t",
    extract(.service, as(Service, service_name)),
    "\t",
    extract(.latency_ms, int(u32)),
    optional("\r"),
});

pub const parsed = pipe(.{route(.{
    when(compose(.{ field(.item), record }), .{map(toEvent)}),
    otherwise(.{map(refuse)}),
})});

pub const analyzer = program(logs, .{
    events.parsed,
    branch(.{
        alerts,
        totals,
    }),
});
```

`execute` runs it with the files the arguments name:

```zig
analyzer.run(.{
    io,
    exit,
    rescue(fatal).provide(.{stderr(256)}),
    fileReader(Left, args[0], max_line + 1),
    fileReader(Right, args[1], max_line + 1),
    fileWriter(Alerts, args[2], 4096, .{ .mode = .publish }),
    stdout(512),
});
```

- `mergeTagged` runs each log as a task and marks every line with the log it
  came from.
- A line is taken apart by a [text pattern](../../../docs/guide.md#text-patterns).
  `record` says what a line looks like and what is kept of it: two numbers,
  the level as a `Level` (its `from` knows the words of the format, and
  that `error` is `.failure`) and the service as a `Line(32)`. A service
  name with another byte in it, or longer than 32 bytes, is no record.
- The pattern is the predicate of a case, so the case is given what was
  extracted *with* the line, and the line knows its log. `toEvent` puts the
  two together as an `Event`: a level and an `Entry` that carries the
  source along.
- `isFailure` is a combinator: `compose(.{ field(.level), eq(.failure) })`.
- An entry owns its service name (`zrx.Line(32)`), so it can cross the
  `queue` by value. The queue puts the alerts file on a task of its own.
- The alerts file keeps the order of each log. How the two logs interleave
  depends on which supplies a record first.
- The four roles (`Left`, `Right`, `Alerts`, `Report`) are bindings of
  `run`. The tests run the same `analyzer` with fixed readers and writers.

[`src/events.zig`](src/events.zig) holds the record format and the counters;
[`src/main.zig`](src/main.zig) returns the exit status. A run returns
nothing: what fails it goes to `rescue(fatal)`, which writes the `fatal:`
line and stores the status, once the files are closed.

## Format

A record is `timestamp_ms<TAB>level<TAB>service<TAB>latency_ms`, at most 128
bytes before its LF; a CR before the LF is ignored. The level is `info`,
`warn` or `error`. A service name is 1 to 32 ASCII letters, digits,
underscores or dashes. The numbers are decimal: `u64` and `u32`.

Each log gets `records`, `warnings`, `errors` and `latency_ms` (the sum) in
the summary.

## Outcome

| Exit | Meaning |
|---|---|
| 0 | The summary is on stdout and the alerts file has its name. |
| 2 | Anything else: `fatal: <error>` on stderr. No alerts file is published and an existing one is left as it was. |

The summary is printed when both logs have ended. The alerts file gets its
name after that, once the run has succeeded. So a summary on stdout does not
by itself say that the alerts file exists; exit status 0 does.

- A log that cannot be opened (`FileNotFound`), a malformed record
  (`InvalidLogRecord`) or a line over 128 bytes (`StreamTooLong`) fails the
  run before the stream ends: nothing is printed.
- A failure from there on can follow a printed summary. An alerts path that
  already exists is one: the summary is printed, then the run fails with
  `PathAlreadyExists`.

## Tests

```sh
zig build test
zig build test -Doptimize=ReleaseFast
zig build check
```

[`tests/integration.zig`](tests/integration.zig) runs `analyzer` with fixed
readers and writers, then the executable in a temporary directory. No test
looks at how the two logs interleave.

## What changed from the first version

- The custom tagging source is gone: `mergeTagged` does it.
- Files are opened, buffered, flushed and published by `fileReader`,
  `fileWriter` and `stdout`. JSON is `json.encode` into `write` and `print`.
  No handler touches a reader or a writer.
- The summary no longer has a combined `total`; it was the sum of the two.
- The first version named the alerts file and then printed the summary. The
  order is now the other way round, as described under [Outcome](#outcome).
- `--help` is gone. Wrong arguments are `fatal: InvalidArguments`.

## What this app needed from zrx

The pattern is stricter than the function it replaced, which converted
numbers with `std.fmt.parseInt` and trimmed every trailing carriage return.
A record is now invalid where it was accepted before if a number has a
sign (`+1`, and `-0`, which was zero), if a number has an underscore in it
(`1_000`), or if the line ends in more than one carriage return. One
carriage return before the line feed is taken, as before.

Nothing is worked around. Taking a line apart was the one handler here that
was not a few lines; it is a text pattern now. One thing is left:

- **A line that is no record.** `require` hands on what a pattern found and
  lets go of the item. Here the item is needed too, for the log it came
  from, so the pattern is the predicate of a case, and the lines it does
  not describe go to `refuse`, a handler whose one line is
  `return error.InvalidLogRecord`. Nothing in zrx says "fail with this"
  without a handler.
