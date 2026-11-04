# Bounded I/O

Inputs declare paths, standard endpoints, or standard-library IP addresses.
`run(.{ allocator, io, services... }, flows)` acquires selected resources and
releases owned handles after execution users join. Process stdio stays borrowed.

`Line(n).fromSlice(bytes)` copies bounded text using the same rule as
`line(n, bytes)`. `Line(n).fromFormat(fmt, args)` formats directly into owned
inline storage. Both fail `LineTooLong` rather than truncate; neither appends LF.

- [Line-owned records](../data/lines.zig) keep bounded bytes inline.
- [Sources and resource glue](lines.zig) provide stdin, files, and outgoing TCP.
- [Byte I/O](bytes.zig) provides `Reader`/`reader`, `Writer`/`writer`,
  `readChunks`, `writeTo`, `writeBytes` and `flush`. Resources own byte I/O,
  independently of framing. Built-in line endpoints reuse these owners.
- [Framing](../ops/splitBy.zig) splits chunked sequences by a delimiter value or
  typed predicate; [flatten](../ops/flatten.zig) expands chunks into elements.
- [Arguments](cli.zig) provides a managed `*Arguments` view from explicit
  `std.process.Args`, including argv[0]. Command/flag parsing stays in the app.
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

Default tests never wait for human input or a public network. File tests use
temporary directories; HTTP tests use finite loopback peers and ephemeral ports.

Preparation and gated worker startup precede resource acquisition. Empty selected
outputs still create files; failures release earlier resources without undoing
creation/truncation or writes. Failed/canceled cleanup does not flush.

LF is framing; encoding and CR are data. Fan-out, retention and collection can
copy line values safely, but larger bounds cost storage and copies. Duplicate
standard endpoints/textual file conflicts fail before acquisition; path alias
canonicalization and concurrent shared-writer serialization are not provided.

`readChunks(n, pointer)` accepts a mutable `std.Io.Reader`, standard file/TCP
reader or managed `Reader` pointer directly. No additional reader interface is
introduced. Concrete file/TCP readers retain native errors; the erased standard
interface reports `ReadFailed`. It emits owned nonempty `Chunk(u8, n)` values
using short reads, without waiting to fill the chunk. Zero read progress is not
EOF. Polling remains cooperative. The pointer/storage stay borrowed and stable;
new traversal consumes the current position, without rewinding.

`splitBy('\n', .{ .max_items = n })` frames chunks into owned byte Chunks.
Default policy retains empty delimited frames and a nonempty final tail.
For words, use `splitBy(std.ascii.isWhitespace, .{ .max_items = n, .empty = .skip })`.
Predicates are typed non-fallible functions with ordinary injected prefixes.
Framing is serial and bounded across chunks, not one independent split per chunk.
Excess length emits pending `FrameTooLong` and ends; first pending upstream
error discards unfinished state and ends. Source/cancellation failure never
flushes a tail. Arrays/slices and non-byte elements are supported too.

`readerLines(n, pointer)` remains the LF convenience returning `Line(n)`. It
shares the bounded framing core, preserving `LineTooLong` as a source failure.
All these pull forms can be returned by `flatMap`; no worker or queue is added.
`flatten()` expands arrays/slices/Chunks byte-by-byte (or element-by-element).
It owns the current array/Chunk; slice referents remain borrowed.

`reader(config)` provides a managed `*Reader`, with stdin/file/outgoing-TCP
configuration. Files/connections open afresh per run and close after users join;
stdin is never closed or rewound. `Reader.interface()` lends the std interface.
Pass the owner directly to read sources to preserve its underlying errors.
Acquisition/read/cancellation failures remain execution control.

Both `reader` and `writer` accept either a configuration value or a comptime-known
typed configuration provider. A provider returns the exact `Reader.Config` or
`Writer.Config` (optionally fallible); all its parameters are injected services,
with no ordinary data suffix. It runs once per reachable recipe acquisition,
not during construction or per item. Its dependencies, including referents
borrowed by configuration, outlive the I/O owner. Provider failures/cancellation
are acquisition control. `deriveResource(Role, reader(provider))` and the writer
equivalent preserve the same lifetime while exposing a nominal role. Generic
providers, closures, runtime callback pointers and optional configurations are
not supported. Unreachable recipes and providers remain cold.

`writer(destination)` provides a managed `*Writer`. `Writer.write(bytes)` writes
exact bytes without delimiters or implicit flushing; `Writer.flush()` is explicit
fallible finalization. `writeTo(pointer)` consumes byte arrays/slices/Chunks or
individual bytes and flushes only after normal end, without closing. It accepts
standard interface/file writers or the managed owner. `writeBytes` and `flush`
are the equivalent callback functions. Use `writeTo(*Writer)` (or another exact
supported pointer service type) to inject the writer rather than supply a pointer
at declaration time. Its binding is planned/acquired normally, not per item.
`writeLine(pointer, Line(n))` explicitly
encodes payload + LF and flushes per line, matching built-in line sinks.
Flush is not fsync. Release closes owned handles without flushing failed work.
Unlike built-in endpoints, arbitrary reader/writer recipes do not register path/
endpoint claims: callers ensure safe paths and serial/exclusive use across roles.

HTTP has one active connection/request, bounded bodies and close-after-response.
`httpServer(config)` is a managed `*HttpServer` recipe, with the same typed
configuration-provider rules as reader/writer. `httpRequests(*HttpServer)` or
`httpRequests(ServerRole)` borrows the acquired server; the role is a nominal
single-field wrapper of `*HttpServer`. A custom resource can add acquisition
behavior while retaining this base owner. Concrete `httpRequests(config)` uses
the same HTTP runtime. Request users join before owned server release; borrowed
owners require caller cleanup. Each acquisition supports one traversal.
Request helpers provide duplicate-aware `headerValues`/`uniqueHeader`,
stable `HttpBodyTooLarge`/`HttpInvalidBody` protocol errors, and bounded
`jsonResponse` encoding through `std.json`. They do not choose client/domain
status policies or turn cancellation/transport failures into request data.
General listener/full-duplex session declarations, DNS/reconnect policy,
application timeouts and filesystem watching remain separate designs. See the
[execution guide](../../docs/execution.md) for dependency and cleanup rules.
