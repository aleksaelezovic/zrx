# Bounded I/O

Inputs declare paths, standard endpoints, or standard-library IP addresses.
`run(.{ allocator, io, services... }, flows)` acquires selected resources and
releases owned handles after execution users join. Process stdio stays borrowed.

- [Line-owned records](../data/lines.zig) keep bounded bytes inline.
- [Sources and resource glue](lines.zig) provide stdin, files, and outgoing TCP.
- [Public terminal adapters](../compose.zig) provide stdout/stderr/file effects.
- [File-copy program](../../examples/io_file.zig) is tested through its actual
  composition with temporary files in [public graph tests](../../tests/declarative_graphs.zig).
- [Serial HTTP requests and response effects](http.zig) use scoped request
  capabilities, standard HTTP parsing/body readers and run-owned sockets.
  See [the HTTP guide](../../docs/http.md) and [echo program](../../examples/http_echo.zig).

```sh
zig build io-examples
./zig-out/bin/copy-lines INPUT_PATH NEW_OUTPUT_PATH
zig build http-example
./zig-out/bin/http-echo 8080 3
```

Live invocations are opt-in. File output must not already exist. Line copying
frames records and adds LF; it is not byte-exact for unterminated input.
Successful completion includes flush, not fsync, rollback or atomic publication.

Default tests never wait for human input or a public network. Archived terminal
and loopback TCP regression programs remain in
[tests/legacy_examples](../../tests/legacy_examples/README.md) and exercise the
same internal transport/resource implementation, not the old public API.
HTTP tests use finite loopback peers and ephemeral ports.

Preparation and gated worker startup precede resource acquisition. Empty selected
outputs still create files; failures release earlier resources without undoing
creation/truncation or writes. Failed/canceled cleanup does not flush.

LF is framing; encoding and CR are data. Fan-out, retention and collection can
copy line values safely, but larger bounds cost storage and copies. Duplicate
standard endpoints/textual file conflicts fail before acquisition; path alias
canonicalization and concurrent shared-writer serialization are not provided.

HTTP has one active connection/request, bounded bodies and close-after-response.
General listener/full-duplex session declarations, DNS/reconnect policy,
application timeouts and filesystem watching remain separate designs. See the
[execution guide](../../docs/execution.md) for dependency and cleanup rules.
