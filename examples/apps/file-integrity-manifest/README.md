# File integrity manifest

Write a SHA-256 manifest of a stable set of regular files. A failed input
gets its own error record so the rest can still be checked.

```sh
zig build
printf abc > example.txt
./zig-out/bin/file-integrity-manifest manifest.jsonl example.txt missing.txt
```

Each JSONL row carries the one-based argument index and path. Success rows
include the byte count and lowercase digest. Error rows include the Zig
error name. Rows are in completion order. The index distinguishes repeated
paths and lets consumers reconstruct argument order.

```text
path arguments → four bounded workers (open, read in chunks, hash)
               → one serialized manifest writer
```

Each worker uses a 32 KiB read buffer and its own hash state. The worker
operator has four input slots. Jobs borrow immutable paths from argv for the
duration of the run. The manifest is streamed with an 8 KiB writer buffer.
Task stacks, runtime allocations and argv storage are additional.

Use regular files in a tree that stays stable for the run. Symlinks to regular
files are followed. A size or modification time change observed while hashing
becomes a per-file error. These checks do not provide a filesystem snapshot.

Exit **0** means every file was hashed. Exit **1** means the manifest includes
one or more per-file errors. Exit **2** means usage, output or run failure.
The output appears after a successful flush and an existing path is preserved.

Run `zig build test`, `zig build test -Doptimize=ReleaseFast` and
`zig build check` from this directory.
