# HTTP request scopes and server lifecycle

[Documentation index](README.md) · [Execution and ownership](execution.md)

The [HTTP API](../src/io/http.zig) is implemented for Zig 0.17.0.
The [echo example](../examples/http_echo.zig) has a lean entry point and reusable
`execute` composition: server configuration → requests → exclusive `branch`
cases with named handlers → Response-only terminal. Handlers choose every response, including errors;
there is no HTTP handler wrapper or automatic 500 conversion.

## Run the example

```sh
zig build http-example                  # build/install, no network waits
./zig-out/bin/http-echo 8080 3            # serve three accepted connections
```

From another terminal, make those three requests:

```sh
curl --http1.1 http://127.0.0.1:8080/health
curl --http1.1 --data-binary 'hello' http://127.0.0.1:8080/echo
curl --http1.1 http://127.0.0.1:8080/missing
```

Omit the connection count for an ongoing opt-in server. The executable binds
loopback only and prints its bound URL; port 0 selects an available port.
`zig build test-http` runs the same graph with finite loopback
peers on ephemeral ports, plus lifecycle/error tests. `zig build test` includes
these tests, compile-fail diagnostics, and a zero-connection entry-point smoke
test. `zig build check` also compiles real HTTP graphs on all five hosted catalog
targets; it does not execute foreign runtimes.

## What the run owns

Declarations allocate/open/start nothing. After preparation and gated worker
startup, run allocates bounded buffers and acquires the listener. Optional
`HttpReady` reports the actual bound address, including when configured port is
zero. It signals listening, not guaranteed later startup success; acquisition
failure does not signal it. Keep readiness/stop capabilities alive through run.

There is one active connection and one outstanding request. Each request's
head is copied before body reads invalidate standard parser storage. Body access
is on demand through the run's Io, using standard HTTP body framing:

- `bodyReader()` and `readRemainingBody()` share one single-pass cursor.
- A remaining-body read returns the whole body only if nothing was consumed.
- Limits apply cumulatively to all read/discard paths. Byte access does not
  create one zrx event per byte. `bodyError()` explains generic ReadFailed.
- `100 Continue` is sent only when the handler requests a permitted body.
  An unread body is not drained before sending a response and closing.

Request data, fetched bytes, readers, and constructed response storage are
borrowed until that request completes. Construct one response per request;
the constructor copies temporary body/header bytes into bounded storage.
Do not retain pointers across completion/run, or use readers concurrently.
Response construction never sends. The terminal validates, sends, and flushes;
the last delivery must also finish before the source can reuse its storage.
An invalid/over-bound constructed response fails the terminal without a hidden
fallback. A second/stale response token is rejected before another write.

The scoped lane supports exclusive branch cases, `each`, `filter`, `take`, and
per-item effects, but not independent fan-out, retention, collection, batching,
or signal dependencies. Unsupported compositions fail before acquisition.
Unmatched/filtered requests and per-item effects returning without a response
close automatically after their last delivery finishes. This does not invent
a 404 or 500; clients observe closure. A completed send is not repeated by
finalization. Branch cases may also all terminate, in which case branch itself
is the terminal passed to run. Single values/borrowed arrays declared with
`fromValue`/`fromSlice`, and explicit `forEach(sendHttpResponse)`, use the same send rule; all associated responses
must still originate from live request scopes, not a previous run.

## Completion and limits

Every accepted connection counts toward optional `connection_budget`, including
malformed/empty sessions. This makes finite service possible without `take`.
An optional stop event stops admission and drains an already accepted session
within its existing request deadline; it does not reset that deadline.
Parent cancellation aborts instead. Callbacks must remain cooperative.

`head_timeout` bounds head acquisition. `request_timeout` bounds the whole
accepted session: head/body I/O, processing, queue waits, and response writing.
Standard Io operations may return spurious timeouts; the adapter preserves the
absolute deadline and joins pending operations before reusing their storage.
Cancellation caught by application reader error handling cannot become a
successful terminal send. Timeout/runtime/write failure fails run; malformed or
unsupported heads close that session and allow the next connection.

Shutdown interrupts connected I/O, cancels the source's accept/completion work,
and joins graph users before closing remaining sockets or freeing buffers.
Earlier successful sends are not rolled back. Flush does not prove remote
receipt or exactly-once application effects.

Limits and defaults are documented in `HttpServerConfig`. Response header byte
bounds count stored extra-header names/values, not generated framing bytes.
Framing headers are adapter-owned. TLS, HTTP/2, upgrades, compression, persistent
connections, concurrent clients and streaming response bodies are unsupported.
Parsing inherits the pinned standard library's behavior; this experimental
milestone is not a public-deployment hardening claim.

Generic recovery remains separate, unimplemented work; older `With` sketches
do not override the current dependency-injection model. HTTP does not require it.
Public partition/pipeEach operators and predicate
combinators are also outside this milestone.
