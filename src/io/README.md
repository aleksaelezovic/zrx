# Line I/O programs

Declare paths or standard-library IP addresses, not open handles. The same
`run(allocator, io, flows)` owns the selected resources, their buffers, and
cleanup. Standard stdin/stdout/stderr handles remain open.

## Contracts and examples

- [Value-owned `Line(n)` records and `line`](../data/lines.zig).
- [Input/output declarations](lines.zig): `stdinLines`, `fileLines`, `tcpLines`,
  `stdoutLines`, `stderrLines`, and `writeFileLines`.
- [Queue interoperability](readFrom.zig) remains separate.
- [CLI interpreter](../../examples/io_cli.zig): `ping` and `upper TEXT`;
  replies on stdout, invalid commands on stderr, EOF ends the program.
- [File extraction](../../examples/io_file.zig): save `keep ` entries to a new
  output file and send rejected entries to stderr.
- [TCP display](../../examples/io_tcp.zig): LF-framed `INFO`/`WARN` messages;
  share decoding between stdout display and a new file audit.
- [TCP take](../../examples/io_tcp_take.zig): share the first n records
  between display and a new file; finish without waiting for peer EOF.

API details live beside the source declarations. All example graphs are
tested externally in [the I/O example suite](../../tests/io_examples.zig) using
finite endpoints; TCP tests use a local controlled peer.

## Run the programs

Build/install without starting an interactive program:

```sh
zig build io-examples
printf 'ping\nupper Hello, Zig!\nunknown\n' | ./zig-out/bin/io-cli
```

With your own input and a **nonexistent** output path:

```sh
./zig-out/bin/io-file INPUT_PATH NEW_OUTPUT_PATH
```

With a peer listening at the selected local address, sending LF-delimited
records, and closing to signal EOF:

```sh
./zig-out/bin/io-tcp 127.0.0.1 9000 NEW_AUDIT_PATH
```

To stop successfully after five records even when the peer stays open:

```sh
./zig-out/bin/io-tcp-take 127.0.0.1 9000 5 NEW_OUTPUT_PATH
```

Live invocations are opt-in. `zig build test` compiles the actual entry points
and tests their graphs without waiting for human input or an external service.
`zig build check` additionally cross-compiles hosted I/O for the five hosted
catalog targets. Line values remain covered on all six, including freestanding
WebAssembly; process handles/cwd and OS sockets require a host.

## Boundaries worth keeping visible

Records own bytes inline; they never borrow the reader's reusable buffer.
Large bounds cost copies/queued storage. LF is framing; encoding/CR normalization
are explicit application transformations. Output adds LF and flushes per record,
not byte-exact copying, atomic publication, fsync, or remote acknowledgement.

Preparation and gated worker startup precede acquisition. Acquisition failures
clean up partial resources; selected output files are created even for empty
input. Creation/truncation and earlier writes are not rolled back. Owned
handles close after their users join, not merely when a producer returns.

Use one terminal per standard output endpoint; merge inputs to combine writes.
Duplicate standard endpoints and textual input/output file conflicts are
rejected before acquisition. Path aliases (symlinks/hardlinks/relative spellings)
and conflicts with other processes are not detected. Concurrent runs must not
unsafely share process inputs or outputs.

Listeners, full-duplex connection declarations, DNS/reconnect policy, application
read timeouts, arbitrary owned payloads, terminal UI, and filesystem watching
remain separate features. No additional scheduler or universal service context
is introduced. See the [execution guide](../../docs/execution.md) for sharing,
cancellation, error, and lifetime rules across operators.
