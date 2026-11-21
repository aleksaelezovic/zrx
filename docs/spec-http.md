# Spec: HTTP

Status: implemented as `zrx.ext.http` (`src/ext/http.zig`), in a first
version that is one worker per open connection, with no timeouts and no
graceful shutdown. The guide's "Not here yet" lists what was left out on
purpose.

This file is the design record of the extension: why it is the way it is,
and what review found on the way. The [guide](guide.md#http) says what it
does, and every behavior named there is pinned in `tests/http.zig`.
`AGENTS.md` keeps the short rules to know before editing it and points here
for the reasons. Performance is stated only in the benchmark app's README,
with the measurement behind it.

## An extension, not core

It is written against the public source, operator and handler contracts,
and is analyzed only when `zrx.ext.http` is referenced. The core knows
nothing of it and still compiles freestanding. Parsing stays
`std.http.Server`'s.

`serve` holds a synchronous sub-pipe as `concurrent` does. It constructs
the sub-pipe per connection, with that connection's `Response` added to the
environment. A boundary inside it is a compile error.

## Who owns a connection

The listener owns an accepted `Connection` until a `serve` or a `reject`
takes it. It closes what nobody took after the run's tasks have returned.
Whoever took it closes it.

**`reject` is the one way to let go of a connection.** A `pending` slot
measures "accepted and not taken", and the listener cannot tell a
connection that waits in a queue from one a stage dropped. So a dropped
connection keeps its slot until the run is over. That is the rule the guide
states. The table does not evict, and the source does not guess, to hide a
pipe that drops.

**A connection is handed over once.** The listener checks that its slot
still holds that connection, by a generation per slot. A copy that comes
second fails with `error.ConnectionTaken` and touches neither the slot nor
the socket. Sockets are not compared for this: the system reuses their
handles.

## Writing an answer

Responders write unflushed. `serve` flushes before a read that may wait for
the peer: a head or body that is not whole in the buffer. There is no flush
per response.

Every head is written by `Exchange.begin`, which is where a status is
judged:

- an interim status (1xx) is answered 500, since it would leave the peer
  without an answer;
- 204 and 304 go out without a body or a length.

Answers completed before a handler failed are flushed, unless it failed
with a cancellation.

## Failures and cancellation on a socket

A cancellation `std` recorded on the connection comes out of `serve`
whatever the conversation returned.

A socket on which `std` recorded a failure is not read from or written to
again, whether or not the failure came back as an error. A second failure
would replace the record, and a cancellation in it would be lost. `serve`
looks after every request and before an answer starts.

## The body nobody read

An unread body is skipped only once the pipe is through with the request,
never before or while it is answered. The read overwrites the head, which
the item being answered may point into.

The independent review before the merge found a `content-length` counted
before the skip and content written after it. That is why `begin` writes
every head itself, and `std`'s `respondStreaming`, which skips first, is
not used.

A read that fails in the skip is returned, for a socket and a transport
alike.

## Requests that are refused before a handler sees them

`serve` refuses a request whose `Host` is not in order, and one whose head
a proxy in front could read differently (`refusal`). `std` parses
leniently, and a disagreement on where a request ends is request smuggling.

That check holds only what `std` lets through. Two rules that duplicated
refusals of its parser were removed when no test could tell them apart.

### No body framed by a transfer coding

Such a request is answered 411 before any handler sees it.

Chunk sizes cannot be checked from outside `std`. Its chunk reader takes
sizes that are no hexadecimal number, and overflows on one near 2^64, which
is a remote stop of a safe build. Two smaller measures each left
`request.body` reaching that decoder: not skipping such a body, and then
closing the connection after one.

Chunked request bodies return when `std` decodes them with checks, or by
explicit decision with a decoder of zrx's own.

## Paths

Path parameters are not a feature of HTTP. `http.path` takes a string, or
any predicate of text, and answers what that answers. So a pattern that
extracts makes the case's item a `Found` of the values and the request.
HTTP imports nothing of the pattern extension and has no router of its own.

Taking either made the parameter `anytype`, which gives its argument no
type:

- a list of bytes is told by its shape and still taken;
- an expression that needs a result type (`@ptrCast`) has to name it, and
  the guide says so.

A second function for predicates would have kept the typed parameter and
been a second spelling.
