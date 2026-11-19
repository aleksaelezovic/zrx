# File integrity manifest

Writes a JSONL manifest with the byte count and SHA-256 of each file named on
the command line, four files at a time. A file that cannot be hashed gets a
row of its own, so the rest are still checked. Built with zrx and Zig
**0.17.0**, no third-party dependencies.

```sh
cd examples/apps/file-integrity-manifest
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

/// path -> its bytes -> one digest -> a row
const hashed = pipe(.{
    each(bytesOf, digest),
    map(described),
});

const rows = pipe(.{
    map(json.encode(.{ .emit_null_optional_fields = false })),
    write(Manifest, "{f}\n"),
});

const exit_status = pipe(.{
    fold(Exit.complete, Exit.after),
    forEach(remember),
});

pub const manifest = pipe(.{
    concurrent(workers, .{attempt(hashed, failed)}),
    branch(.{
        rows,
        exit_status,
    }),
});

program(fromSlice(args[2..]), manifest).run(.{
    init.io,
    &exit,
    fileWriter(Manifest, args[1], 8192, .{ .mode = .publish }),
}) catch |err| return fatal(init.io, err);
return @backingInt(exit);
```

- **Hashing a file is a pipe of its own.** `each` gives every path a source,
  `fileBytes`, which reads it 32 KiB at a time; `digest` folds the pieces
  into one `Hash`; `described` makes the row. The sub-pipe starts afresh for
  every file.
- **A file that cannot be hashed is data, not a failed run.** `attempt` emits
  `failed(err, path)` in place of whatever `hashed` failed with, such as a
  missing file or a directory.
- **Four files at a time.** Each worker of `concurrent` has its own copy of
  `hashed`; they take turns pushing rows into the rest of the pipe.
- **Every row goes to both sub-pipes of `branch`.** `rows` writes it;
  `exit_status` folds all of them into one `Exit` and stores it once, at the
  end of the stream. `main` returns it.
- **The manifest appears whole or not at all.** `write` flushes once, at the
  end. The `.publish` file gets its name only after the run has succeeded and
  the rows are flushed; a run that fails before that leaves the output path
  untouched.
- A run that fails is reported by a second, one-line program:
  `fatal: ErrorName` on stderr.

The handlers that remain are one to four lines each: `Hash.update`,
`bytesOf`, `described`, `failed`, `Exit.after` and `remember`.

## Rows

One JSON object per line, in the order the workers finish, not argument order.

| Field | In | Value |
|---|---|---|
| `path` | every row | The argument as given. |
| `bytes` | hashed files | Bytes read. |
| `sha256` | hashed files | Lowercase hex digest. |
| `failure` | failed files | Zig error name, such as `FileNotFound` or `IsDir`. |

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
- A check that a file did not change while it was read, and a check for
  regular files. A path is opened and read to its end: a directory fails
  with `IsDir`, and nothing tells a FIFO or a device from a file.
- UTF-8 validation of paths. An empty path is a `FileNotFound` row.
- `--help`.

## What this app needed from zrx

Nothing beyond what it has. `each`, `attempt` and `fileBytes` came out of an
earlier version of this app, where hashing a file was one handler that opened
it, read it and built the row.

Two things stay in `main` rather than in a pipe, and neither is a gap:

- The argument count is checked before the program exists, because the
  output path is one of its bindings.
- The exit status is stored through a `*Exit` and returned by `main`. It
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

`test` runs the pipe with an injected writer and `Exit` (including a file
larger than one read), and the real executable in temporary directories with
its exit status, output and manifest asserted.
