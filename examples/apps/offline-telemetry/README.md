# Offline telemetry

Replays two cold-storage sensor feeds with zrx and Zig **0.17.0**. A reading
outside 0 to 8 °C is an alert and is printed as it is seen. Routine readings
are grouped into windows of at most 8 readings or 200 ms, and each window is
archived as one JSON row. It is the example for `system`, `route` and
`batchWithin`.

```sh
cd examples/apps/offline-telemetry
zig build
printf '1,3500\n2,8200\n3,4000\n' > north.csv
printf '3,4900\n4,-5\n' > south.csv
./zig-out/bin/offline-telemetry north.csv south.csv north.jsonl south.jsonl
# stdout, in either order:
#   {"sensor":"north","ts_ms":2,"temp_mc":8200}
#   {"sensor":"south","ts_ms":4,"temp_mc":-5}
# north.jsonl: {"first_ts_ms":1,"last_ts_ms":3,"count":2,"min_mc":3500,"max_mc":4000,"sum_mc":7500}
# south.jsonl: {"first_ts_ms":3,"last_ts_ms":3,"count":1,"min_mc":4900,"max_mc":4900,"sum_mc":4900}
```

## The pipes

All of it is in [`src/app.zig`](src/app.zig). One feed is one pipe:

```zig
const alerts = pipe(.{
    map(alert),
    map(json.encode(.{})),
    print(Alerts, "{f}\n"),
});

const windows = pipe(.{
    batchWithin(window_size, window_age),
    map(reduce(Window{}, Window.add)),
    map(json.encode(.{})),
    write(Archive, "{f}\n"),
});

pub const readings = pipe(.{
    map(parse),
    map(require(isPlausible, error.InvalidReading)),
    route(.{
        when(needsAlert, alerts),
        otherwise(windows),
    }),
});

pub const feed = program(lines(Input, max_line), readings);
```

`feed` is one program for both sensors, for production and for tests. What
differs is what it is run with. `execute` gives each feed its bindings and
runs the two as a `system`:

```zig
const north = feed.provide(.{
    Sensor.north,
    fileReader(Input, args[0], max_line + 1),
    fileWriter(Archive, args[2], 4096, .{ .mode = .publish }),
    stdout(256),
});
```

- The predicates are combinators. `needsAlert` is
  `compose(.{ field(.temp_mc), any(.{ lt(0), gt(8000) }) })`, and
  `isPlausible` is the same with `all(.{ ge(-100_000), le(150_000) })`.
- Three handlers are functions: `parse` (a line to a reading), `alert`
  (labels a reading with the `Sensor` dependency) and the reducer
  `Window.add`, which gets count, minimum, maximum, sum and the first and
  last timestamp from one fold over the window's readings.
- Nothing is shared between the two programs. Each has its own input, its
  own archive file and its own writer to standard output, so there is no
  lock.
- A run returns nothing. What ends the system goes to the `rescue(fatal)`
  it is run with, `system(.{ north, south }).run(.{ io, exit, stderr(256),
  rescue(fatal) })`: the `fatal:` line and the status `main` returns.

## Format and output

- Input: `timestamp_ms,temperature_millidegrees_C` per line, no header, at
  most 64 bytes excluding LF. One trailing CR is removed and a final
  unterminated line is accepted. The temperature must be within -100 to
  150 °C.
- Alerts: the two programs each own a writer to standard output. A program
  flushes every alert by itself, as one whole line. Lines from the two feeds
  interleave in no fixed order.
- Windows: one archive per feed, in arrival order. A window closes at 8
  readings, 200 ms after its first reading, or at the end of input. The 200 ms
  are processing time, so how readings are grouped depends on how fast the
  feed is read; the recorded timestamps stay in the rows.
- Each archive is written to a temporary file and gets its name when its feed
  has finished. That is atomic per file, not per run: when one feed fails,
  the other feed's archive may already be in place, or may not be published.
- An existing output path is never replaced. The run fails with
  `PathAlreadyExists` and the file stays as it was.
- Exit **0**: both feeds replayed and both archives published. Exit **2**:
  anything else, with `fatal: ErrorName` on stderr: `InvalidArguments` (not
  exactly four), `InvalidReading`, `StreamTooLong`, `FileNotFound`,
  `PathAlreadyExists`, or another I/O error. Alerts printed before a failure
  stay printed, and how many of the other feed's alerts precede it is not
  fixed.

## Checks

```sh
zig build
zig build test
zig build test -Doptimize=ReleaseFast
zig build check
```

The tests run `feed` on injected readers and writers, each feed with its own
log, and the real executable on temporary files. They run on
`zrx.testing.Clock`, so no test sleeps and the rows are exact: with the clock
standing still only a full window or the end of input closes a window, and
one test moves the clock to 200 ms to see a window of three archived while
its feed is still open.

## What this app needed from zrx

Four things it needed were general and have since been added to zrx:
`require`, which fails an item a predicate rejects (the plausibility check
was a handler); `zrx.ext.json` (every app had its own `json` handler);
`zrx.testing.Clock` (the window tests depended on real time); and
`fileReader`, which lets one program read a file in production and a fixed
reader in a test.

What is still worked around here:

1. **A test cannot see an item reach `write` before the stream ends.**
   `write` flushes once, at the end, so the test that watches a window being
   archived while its feed is open brings its own unbuffered
   `std.Io.Writer` that sets an event per row (`Rows` in
   `tests/integration.zig`).

What needed nothing: two programs that share no state (a `system` and a
`provide` per program), alerts that leave as they are seen next to windows
that leave at the end (`print` and `write`), and an archive that appears only
after its feed has succeeded (`.publish`).
