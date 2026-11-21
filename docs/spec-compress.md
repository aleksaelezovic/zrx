# Spec: compressed input and output

Status: implemented as `zrx.ext.compress` (`src/ext/compress.zig`): gzip
and zlib both ways, Zstandard read only. The decisions below are proposals
until the owner has reviewed them.

This file is the design record of the extension: why it is the way it is,
what was rejected and what was measured. The
[guide](guide.md#compressed-input-and-output) says what it does, and every
behavior named there is pinned in `tests/compress.zig`. `AGENTS.md` keeps
the short rules to know before editing it and points here for the reasons.

## Bindings, and nothing in a pipe

The extension has no operator, source or handler. Each of its five
functions returns a resource: `gzipReader(Role, From, n)` needs the reader
role `From` and provides the reader role `Role`; `gzipWriter(Role, Into,
options)` needs the writer role `Into` and provides the writer role `Role`.
The planner in `src/resources.zig` orders acquisition from `needs` and
`Provides` as it does for any resource, and knows nothing of compression.
A program over `lines(Input, n)` is the same value for a plain file and a
gzip file; only what is bound to `Input` differs.

It is written against the public resource contract and `zrx.di`, and is
analyzed only when `zrx.ext.compress` is referenced. The core knows nothing
of it and still compiles freestanding.

### Two roles

Within a binding tuple a type has one provider, so the compressed bytes and
the plain bytes cannot be keyed by one type. The existing role convention
already answers this: a role is a struct with a single `reader` (or
`writer`) field, and a program that has two streams of a kind has two such
structs. Here one names what the pipe reads (`Input`) and one names the
compressed bytes (`Packed`). Nothing in `src/resources.zig` changed.

The same role on both sides is a compile error where the binding is
written. Without it, the user would get the planner's message that a
binding needs what it provides itself, or that a type is provided twice,
neither of which says to give the compressed bytes a role of their own.

The role a binding provides must be `*std.Io.Reader` or a struct with a
single such field, as for `fileReader`: the binding makes the value. The
role it needs may be any struct with such a field.

**Rejected: a binding that opens the file itself** (`gzipFileReader(Role,
path, n)`). It needs no second role, but it composes with nothing: not
with standard input, not with a reader a test supplies, not with a
published file on the writing side.

## What `std.compress` of Zig 0.17 offers

Found by reading the installed `std` and running it, not recalled.

| | reads | writes | used |
|---|---|---|---|
| `flate` (gzip, zlib, raw deflate) | yes | yes | gzip and zlib |
| `zstd` | yes | no | read only |
| `xz` | yes | no | no |
| `lzma`, `lzma2` | yes | no | no |

There is no codec of zrx's own. So there is no Zstandard compression.

**No xz.** `std.compress.xz.Decompress` grows its buffer with an allocator
and never gives any of it back: decoding a text of 14,644,414 bytes left a
buffer of 21,966,750 bytes. That is a memory the size of the file, where
every other I/O binding has a buffer the caller sizes. It also compares no
checksum (three `TODO`s), its `discard` is `@panic("TODO")`, and it asserts
when started with an empty buffer. It returns when `std`'s decoder is
bounded, not with a decoder of zrx's own.

**No raw deflate, lzma or lzma2.** They are rarely files of their own.
They return by decision.

**Archives** (`tar`, `zip`) are a stream of files, not of bytes, and are
not part of this extension.

## What is added to `std`, and why

Three things, each because of something that was measured.

### A buffer in front of the decoder

A program is not handed the decoder's own reader. That reader's buffer is
its window, and it asserts that nobody asks it to hold more than the window
leaves room for. `lines` looks for the end of a line with
`peekDelimiterInclusive`; on a `flate.Decompress` reader with a line of
100,000 bytes that was a panic in `Decompress.rebase` in a Debug build, and
undefined in ReleaseFast. `zstd.Decompress` has the same assert.

`Plain` puts a buffer of its own, the `n` the caller gives, in front of the
decoder. Its `stream` hands on what the decoder has decoded and asks the
decoder for more only when nothing is buffered, which is the one request
the window always has room for. Such a line is then `error.StreamTooLong`,
as it is for a file. The cost is one copy of the plain bytes, from the
window to the buffer. Do not remove the buffer to save the copy.

`std.Io.Reader.Limited` with no limit would be that buffer. `Plain` has a
vtable of its own because every byte handed on has to pass through code
that can count it (the checksum, below) and decide what the decoder's end
means (the next gzip member, below).

### The compressed side has a buffer of the binding's own too

The decoder does not read the caller's reader directly but through 4 KiB
of the binding's own (`held_bytes`, a `Reader.Limited` with no limit).
`std`'s decoders assert that their input can hold what they look ahead: 10
bytes of a gzip header, 2048 of a Zstandard table. A reader bound by
someone else may hold less, or nothing.

**Rejected: checking the caller's buffer at acquisition.** A
`std.Io.Reader.fixed(bytes)` has a buffer exactly as long as its bytes, so
the check would refuse a test's short stream with an error about buffers.
With a buffer in between there is nothing to check and no error to name.

### Checksums and gzip members

`std`'s flate decoder reads the gzip and zlib trailers into
`container_metadata` and compares nothing: `error.WrongGzipChecksum`,
`error.WrongGzipSize` and `error.WrongZlibChecksum` are declared and never
returned. `Inflate` keeps `std`'s own `flate.Container.Hasher` over the
bytes that pass and compares at the end of each stream. A mismatch fails
the read.

`std` also stops after the first gzip member and leaves the rest unread,
without a word. A gzip file is a series of members (RFC 1952), and `gzip
-d` reads them all. `Inflate` starts the decoder again while bytes follow.
Bytes that are no member fail the read: zero padding after a member is
refused, where `gzip` warns and goes on. A zlib stream is one stream, and
what follows it is not read.

**The checksum of a Zstandard frame is not compared.** `std` reads it and
drops it, and its `verify_checksum` option panics. It cannot be compared
from outside `std` without parsing frames a second time. Of 381
single-byte changes tried on one fixture, some decoded without a failure,
among them changes to literal bytes and to the checksum itself. The guide
says so.

### A decoder that failed is not asked again

`std` leaves a decoder's state where it stood when it failed. A Zstandard
fixture of 100,000 lines with one byte changed failed inside a frame after
12 lines; asked again, it went on from there and delivered 152,351 lines,
none of them the stream's. `Plain` remembers the failure (`failed`).

What the decoder had decoded before the byte it failed at is in its buffer
and is handed on first, so a stream that was cut short gives the lines it
has and then fails.

## What a failure is

A stream that is cut short, corrupt, does not match its checksum, or (gzip)
is followed by bytes that are no member fails the read with
`error.ReadFailed`, and nothing more specific. That is what any reader
given to `lines` fails with, so a gzip or zlib input adds no error to a
run, and a rescue written for the plain program still fits. `fileReader`
does not translate a `ReadFailed` either. `std` keeps the cause in a field
of the decoder, and the binding does not surface it.

**Considered: returning the cause from the binding** once the run has come
back with `ReadFailed`. It would widen the error set of every program that
reads compressed input by some twenty names, change it with the binding,
and name a cut-short stream `error.EndOfStream`.

A Zstandard input adds `error.OutOfMemory`, for its window.

## The end of a compressed stream

A compressed stream needs an end: the last block, and for gzip and zlib a
checksum. Writing it can fail, which a resource `release` cannot. So, as
with `fileWriter`'s `.publish` mode, it happens in the binding after
everything it wraps has returned without an error, and is part of the run:
the run fails with `error.WriteFailed`.

The writer below is flushed there as well. Nobody else does it: a
`fileWriter` that replaces a file leaves the flush to the sink of the pipe,
and the sink flushes its own role, which is the compressing writer.

A run that failed leaves the stream without its end, on purpose: reading it
back fails, which is how a reader learns the writer did not finish. Under a
`fileWriter` in `.publish` mode the end is written before the file is
named, because release order is the reverse of acquisition.

`std` writers are not wrapped. A flush of the compressing writer ends a
block and does not reach the writer below, so `print`, which flushes every
item, costs compression and shows nobody the item. The guide says to use
`write`.

**One misuse cannot be seen at compile time.** `flate.Compress` asserts
that the writer below has a buffer of more than 8 bytes, and a role carries
no buffer size. The binding checks it at acquisition and fails with
`error.CompressedBufferTooSmall`. Unlike on the reading side, a fixed
writer that small could not hold a gzip header either.

## What each binding costs

Buffers are on the stack of the run, as for the other I/O bindings. Only
the Zstandard window is too large for that.

| | |
|---|---|
| `gzipReader`, `zlibReader` | The 64 KiB window (`flate.max_window_len`), 4 KiB of compressed bytes, the caller's `n`, and 3 KiB of decoder. Measured in Debug: 82 KiB of stack more than the plain reader. |
| `zstdReader` | `options.window` and 128 KiB for a block from the run's allocator: 8 MiB and 128 KiB by default, which is what the format recommends every decoder to accept. 4 KiB and the caller's `n` on the stack. `std`'s decoder puts two blocks, 256 KiB, on the stack of the task that reads. |
| `gzipWriter`, `zlibWriter` | The 64 KiB window, which is the writer's buffer, and `flate.Compress` itself, 230,096 bytes. `std` returns it by value, and a Debug build had three copies at once: 741 KiB of stack was measured. An optimized build was not measured. |

A Zstandard frame says how much window it needs: `zstd` of a known file
asks for the file's length up to its level's limit, `zstd` of a pipe for
2 MiB at the default level, `zstd --long` for more than 8 MiB. A frame that
asks for more than `options.window` fails the read.

**Considered: the compressor and the flate window from the allocator.**
That would take 290 KiB or more off the stack and make every compressing
binding need an allocator, where no other I/O binding does.

`std`'s compression levels are not ordered by size on every text: 60,000
lines of `line N` took 113,535 bytes at `.fastest` and 137,873 at `.best`.
Both read back. The level is `std`'s type and its matter.

## No zero-overhead fixture

Nothing of this extension is in the item loop: a pipe is the same value
with and without it. What it costs is the codec and the one copy named
above.

## Not there

- xz, raw deflate, lzma, Zstandard compression, archives: see above.
- The cause of a failed read.
- Comparing the checksum of a Zstandard frame.
- A dictionary for Zstandard: `std` refuses such a frame.
- Reading on past zero padding after a gzip member.
