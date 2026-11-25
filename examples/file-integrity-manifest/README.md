# File integrity manifest

Writes a JSONL manifest with the byte count and SHA-256 of each file named on
the command line, four files at a time. A file that cannot be hashed gets a
row of its own, so the rest are still checked. Built with zrx and Zig
**0.17.0**, no third-party dependencies.

```sh
cd examples/file-integrity-manifest
zig build
printf abc > example.txt
./zig-out/bin/file-integrity-manifest manifest.jsonl example.txt missing.txt
# manifest.jsonl, rows in any order:
#   {"path":"example.txt","bytes":3,"sha256":"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"}
#   {"path":"missing.txt","failure":"FileNotFound"}
# exit status: 1
```

## The program

All of it is in [`src/main.zig`](src/main.zig), and `main` runs it as it is:

```zig
const digest = pipe(.{fold(Hash{}, Hash.update)});

/// path -> a regular file -> its bytes -> one digest -> a row
const hashed = pipe(.{
    map(regularFile),
    each(bytesOf, digest),
    map(described),
});

const rows = pipe(.{
    map(json.encode(.{ .emit_null_optional_fields = false })),
    write(Manifest, "{f}\n"),
});

const exit_status = pipe(.{
    filter(hasFailed),
    forEach(process.status(status.incomplete)),
});

pub const manifest = pipe(.{
    concurrent(workers, .{attempt(hashed, anyerror, .{map(failed)})}),
    branch(.{
        rows,
        exit_status,
    }),
});

program(fromSlice(args[2..]), manifest).run(.{
    init.io,
    &exit,
    rescue(fatal).provide(.{stderr(Stderr, 256)}),
    fileWriter(Manifest, args[1], 8192, .{ .mode = .publish }),
});
return exit.code;
```

- **Hashing a file is a pipe of its own.** `each` gives every path a source,
  `fileBytes`, which reads it 32 KiB at a time; `digest` folds the pieces
  into one `Hash`, the `bytes.digest` of SHA-256 beside a count of the
  bytes; `described` makes the row. The sub-pipe starts afresh for
  every file.
- **A file that cannot be hashed is data, not a failed run.** Whatever
  `hashed` fails with, such as a missing file or a directory, `attempt`
  sends down its error path, and the row `failed` makes of it goes on in
  place of the file's.
- **Four files at a time.** Each worker of `concurrent` has its own copy of
  `hashed`; they take turns pushing rows into the rest of the pipe.
- **Every row goes to both sub-pipes of `branch`.** `rows` writes it;
  `exit_status` keeps the ones that say what went wrong, and each raises the
  status with `process.status`. `main` returns it.
- **The manifest appears whole or not at all.** `write` flushes once, at the
  end. The `.publish` file gets its name only after the run has succeeded and
  the rows are flushed; a run that fails before that leaves the output path
  untouched.
- A run returns nothing. What fails it goes to `rescue(fatal)`:
  `fatal: ErrorName` on stderr and the status `failed`, once the output has
  been closed without getting its name. `fatal` is `process.fail` with that
  status and prefix.

The handlers that remain are one to four lines each: `Hash.update`,
`bytesOf`, `described`, `failed` and `regularFile`. The exit status, the
rescue and the digest are the library's (`zrx.ext.process`,
`zrx.ext.bytes`).

## Rows

One JSON object per line, in the order the workers finish, not argument order.

| Field | In | Value |
|---|---|---|
| `path` | every row | The argument as given. |
| `bytes` | hashed files | Bytes read. |
| `sha256` | hashed files | Lowercase hex digest. |
| `failure` | failed files | Zig error name, such as `FileNotFound`, `IsDir` or `NotRegularFile`. |

## Exit status

- **0**: every file was hashed.
- **1**: the manifest is complete and holds at least one `failure` row.
- **2**: no output path or no files (`fatal: InvalidArguments`), or the run
  failed (`fatal: ErrorName` on stderr). No manifest is written. An output
  path that already exists is kept as it was (`fatal: PathAlreadyExists`);
  this is found when the manifest is published, after the files were hashed.

## Scope

Not here, on purpose:

- An argument index in each row. A path given twice gives two identical rows.
- A check that a file did not change while it was read. Only a regular
  file is opened: a directory is an `IsDir` row, and a named pipe, a device
  or a socket a `NotRegularFile` row, since opening a pipe nobody writes to
  would hold up the whole manifest. The kind is looked at before the file
  is opened, so a path that is replaced in between is not caught.
- UTF-8 validation of paths. An empty path is a `FileNotFound` row.
- `--help`.

## What this app needed from zrx

Nothing beyond what it has. `each`, `attempt` and `fileBytes` came out of an
earlier version of this app, where hashing a file was one handler that opened
it, read it and built the row.

One thing reads less well than it could: `failed` takes its failure as
`anytype`. The paths are `[:0]const u8` in `main` and `[]const u8` in the
tests, and a handler that names its item takes both as a `[]const u8`. A
failure is a `Failed(anyerror, Path)`, whose field does not coerce, so a
handler that named it could serve only one of the two.

Two things stay in `main` rather than in a pipe, and neither is a gap:

- The argument count is checked before the program exists, because the
  output path is one of its bindings.
- The exit status is stored through a `*process.Exit` and returned by `main`. It
  cannot be acted on inside the pipe: the manifest is published after the
  pipe has ended.

## Checks

From this directory:

```sh
zig build
zig build test
zig build test -Doptimize=ReleaseFast
zig build check
```

`test` runs the pipe with an injected writer and `process.Exit` (including a file
larger than one read), and the real executable in temporary directories with
its exit status, output and manifest asserted.
