# Audit archive

Redact a finite audit export into an ordered JSONL archive with fixed record
and queue storage. Supply a file or `-` for stdin, and a new output path.

```sh
zig build
printf '%s\n' '{"id":1,"ts_ms":2,"action":"read","resource":"node-7","actor":"alice","detail":"private"}' |
  ./zig-out/bin/audit-archive - archive.jsonl
```

Input is one JSON object per line, up to 1024 bytes excluding LF. Each record
has an unsigned `id` and `ts_ms`, an action (`read`, `create`, `update` or
`delete`), a 1–96 byte resource identifier (ASCII letters, digits, dots,
hyphens and underscores), a nonempty string `actor` and an optional string
`detail` that may be omitted or null. Unknown and duplicate fields fail validation. Only `id`, `ts_ms`,
`action` and `resource` enter the archive. Supply resource identifiers suitable
for disclosure.

```text
line → validate and redact → batch(32) → queue(&slots) → flatten → archive
```

A slow writer eventually fills the four batch slots. At that point the
producer waits to submit its next batch before reading more input. The
event-based test holds a write, observes the full-queue wait, releases the
writer and verifies the exact records, including the final partial batch.

Malformed records or failed input/output return exit **2**. Diagnostics give
the error name and never include source records. The CLI flushes before
publishing the output atomically without replacing an existing path.

| Storage | How to account for it |
|---|---|
| Queue | 4 × `@sizeOf(zrx.Batch(Record, 32))` bytes |
| Staging and in-flight values | 32 × `@sizeOf(Record)` for batch staging, plus batches passed to and from the queue, current lines/records and temporary copies |
| I/O | 1,025 reader bytes and 16 KiB writer bytes, plus metadata and any OS buffers |
| Scratch | 8 KiB fixed parser allocator, reused for each record |
| Other | Task stacks, runtime allocations, argv and process memory |

The app makes no general-purpose allocations per record. Parser allocations
come from the fixed scratch buffer. Queue and staging sizes describe specific
buffers. Process memory also includes the other entries above.

```sh
zig build test
zig build test -Doptimize=ReleaseFast
zig build check
```

## Benchmark

```sh
zig build bench -Doptimize=ReleaseFast
for mode in loop sync per_item batched; do
  ./zig-out/bin/audit-bench "$mode" 200000 256 1000 0 standard
done
```

Arguments are mode, record count, optional detail bytes (0–800), sink delay
in microseconds per buffered drain, source delay in microseconds per 64
records, and profile (`small` 8×2, `standard` 32×4, `large` 64×8 items per
batch × batch slots). The tool generates distinct records in bounded memory
and runs the same JSON parsing, redaction, encoding, buffering and final
flush for every variant. The sink hashes the bytes so runs can be compared
without disk noise. The unit test checks that all four variants produce the
same byte count, SHA-256 and number of drains. Input detail length changes
the parsing workload. Queue items retain their fixed inline size.

The output reports throughput, sampled latency from submission to encoding
into the writer, source futex calls and time in those calls, and queue,
staging, writer and parser storage. Percentiles are bucket upper bounds.
Futex measurements include contention and have instrumentation overhead.
Delays simulate the source and sink. Use an OS tool such as `/usr/bin/time -l`
(macOS) or `/usr/bin/time -v` (Linux) for peak RSS in a separate process for
each mode. The benchmark also reports successful allocations and cumulative requested
bytes through the threaded I/O allocator. Thread stack mappings and argv
are outside that counter. Peak RSS includes those process costs.

The app uses a terminal handler and an explicit flush to keep the archive
buffered. The queue wait probe lives in the test and benchmark as an injected
`std.Io` wrapper.
