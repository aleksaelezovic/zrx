# Audit archive

Reads a JSONL audit export, checks every record, and writes the four fields
that may be disclosed as an ordered JSONL archive. Built with zrx and Zig
**0.17.0**; no third-party dependencies. The example is about bounded
backpressure: a slow archive holds the reader back through `batch` and `queue`.

```sh
cd examples/apps/audit-archive
zig build
printf '%s\n' '{"id":1,"ts_ms":2,"action":"read","resource":"node-7","actor":"alice","detail":"private"}' > export.jsonl
./zig-out/bin/audit-archive export.jsonl archive.jsonl
# archive.jsonl: {"id":1,"ts_ms":2,"action":"read","resource":"node-7"}
```

## The pipe

All of it is one declaration in [`src/app.zig`](src/app.zig):

```zig
const safe_resource = compose(.{
    field(.resource),
    records.isSafe,
});

pub const archive = pipe(.{
    map(records.decode),
    map(require(safe_resource, error.UnsafeResource)),
    batch(batch_size),
    queue(queue_depth),
    flatten(),
    map(json.encode(.{})),
    write(Archive, "{f}\n"),
});

pub const archiving = program(lines(Input, records.max_line), archive);

archiving.run(.{
    io,
    exit,
    stderr(256),
    rescue(fatal),
    fileReader(Input, input, records.max_line + 1),
    fileWriter(Archive, output, 16 * 1024, .{ .mode = .publish }),
});
```

- `decode` parses a line with `std.json` into the `Record` that is kept. It
  owns its text (`zrx.Line(96)`), so it can cross the queue. `require` fails
  the run on a resource identifier that `isSafe` refuses. Those two are the
  functions of the app, in [`src/records.zig`](src/records.zig).
- `batch(32)` then `queue(4)` is the boundary: reading and checking run on one
  task, writing on another. When the archive is slow the queue fills and the
  reader waits, having handed over `(4 + 2) * 32` records: the queued
  batches, the one being written and the one waiting for a slot. The queue is
  `4 * @sizeOf(zrx.Batch(Record, 32))` bytes on the stack of the task that
  calls `run`.
- `write` flushes once, at the end. `.publish` writes to a temporary file and
  names it `output` only after the run has succeeded; a path that already
  exists is not replaced.
- The program is one constant. `run` gives it the two files as bindings; a
  test gives it a reader and a writer of its own in their place.
- A run returns nothing. What fails it goes to `rescue(fatal)`, which
  writes the `fatal:` line and stores the exit status `main` returns. It
  is called once both files are closed, while stderr is still open.
- `main.zig` checks the argument count and returns the status. A wrong
  count is reported by a program too: `fromValue` into `forEach(fatal)`.

## Format

Input is one JSON object per line, at most 1024 bytes without its LF; the
last line may be unterminated.

| Field | Value |
|---|---|
| `id`, `ts_ms` | unsigned 64-bit integers |
| `action` | `read`, `create`, `update` or `delete` |
| `resource` | 1 to 96 bytes of ASCII letters, digits, `-`, `_` and `.` |
| `actor` | a string; required, not archived |
| `detail` | a string or null; optional, not archived |

An unknown, duplicate or missing field fails the run, as does anything after
the object. The archive holds `id`, `ts_ms`, `action` and `resource` in that
order, one object per line, in input order.

Parsing is `std.json` into a plain struct, which is looser than the table: it
also takes a number written as a string (`"7"`) or with a zero fraction
(`2.0`), an action by its position (`3` is `delete`), and text as an array of
byte values (`[120,45,49]`). An empty `actor` is accepted. A unit test pins
these.

## Exit status

**0**: every record was archived (an empty export gives an empty archive).
**2**: anything else, with one line `fatal: ErrorName` on stderr and no
archive published. The name is the Zig error: `InvalidArguments` (the
arguments are not exactly `INPUT OUTPUT`), `FileNotFound`,
`PathAlreadyExists`, `ReadFailed`, `WriteFailed`, `UnsafeResource`,
`StreamTooLong` (a line over 1024 bytes or a resource over 96), or what
`std.json` reports (`SyntaxError`, `UnknownField`, `DuplicateField`,
`MissingField`, `InvalidEnumTag`, `Overflow`, `UnexpectedToken`). A
diagnostic never contains record content, and does not say which line failed.

## Checks

```sh
zig build
zig build test
zig build test -Doptimize=ReleaseFast
zig build check
```

`test` runs the record unit tests, the program on a reader and a writer in
memory, the executable on temporary files, and the production pipe against a
writer that stalls. That last test waits for the event that the source is
suspended in a push, checks how many records it had handed over and that
nothing was written, releases the writer and compares the whole archive.

## What it leaves out

- The CLI is `INPUT OUTPUT`: no `--help`, no stdin, and a wrong argument
  count prints `fatal: InvalidArguments` without a usage line.
- No stricter JSON than `std.json` (see [Format](#format)), and no check
  that `actor` is not empty.
- No benchmark and no plain-Zig baseline to compare against.

## What this app needed from zrx

One thing is worked around, with a handler:

1. **JSON can be written but not read.** `zrx.ext.json` encodes only, and
   `Line(n)` is written by `std.json` as a string but cannot be parsed from
   one. `decode` therefore calls `std.json` itself, into a struct of slices
   that borrow from the line, and copies `resource` with `Line(96).from`.
   That struct cannot leave the handler, so parsing and building the record
   are one handler instead of two stages, and it holds a scratch buffer for
   unescaped text.
