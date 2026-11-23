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

Each of these is there because of something that was measured.

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

### What the decoder reads from

`std`'s decoders assert that their input can hold what they look at before
they take it: 4 bytes of a flate stream, 2048 of a Zstandard table. A
reader bound by someone else may hold less, or nothing.

The first version therefore never gave a decoder the caller's reader. It
read through 4 KiB of the binding's own (`held_bytes`, a `Reader.Limited`
with no limit). A review of PR 65 showed what that costs: a `Limited` takes
from the reader below whatever fits its buffer, so the bytes that followed
a zlib stream were gone from the caller's reader when the run returned,
although the guide said they were not read. The test that reproduced it
is `what follows a zlib stream is left in the reader it was read from`.

`std`'s flate decoder itself takes the bytes of the stream and no more: it
looks at four bytes and tosses what it used of them. So a flate decoder now
reads the caller's reader itself where that reader's buffer holds those
four bytes (`flate_ahead`), and what follows a zlib stream stays in it.
Only a reader with a smaller buffer is still read through `held`, and for
that one the guide says that what was read past the end is gone. Four is
what was found by running it: with a buffer of three `std` asserts, and
the first number written here, the ten bytes of a gzip header, was wrong,
because `std` reads a header into memory of the decoder's own.

This removes a layer over `std` where the finding was, and adds none.

The same cause does not reach the other two formats. A gzip stream is every
member up to the end of its input, and bytes that are no member fail the
read; a Zstandard stream is every frame up to the end of its input, and
bytes that are no frame fail the read. A read that succeeded has left
nothing behind in either. The Zstandard decoder keeps reading through
`held`: 2048 bytes is more than to ask of a caller's reader.

**Rejected: checking the caller's buffer at acquisition**, with an error
for one that is too small. A `std.Io.Reader.fixed(bytes)` has a buffer
exactly as long as its bytes, so the check would answer an empty stream, or
one cut off in its first bytes, with an error about buffers where every
other cut is `error.ReadFailed`. And it would add a name to the errors of
every run that reads compressed input.

**Rejected: only saying so in the guide**, with the advice to give a
bounded reader. Where a zlib stream ends is known only by decoding it, so a
caller who needs what follows often cannot bound it.

**Rejected: handing the decoder a byte at a time** through the binding's
buffer, which could keep what follows with any reader: a call into the
caller's reader for every compressed byte. Neither tried nor measured.

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

The checksums are compared where a stream ends, so only a stream that is
read to its end is checked. A pipe that is done before that, after
`take(1)` say, reads no further, and a wrong checksum it never reached is
not its failure (`a pipe that is done does not read to the end, ...`). Nor
is anything said of where the reader of the compressed bytes then stands:
what follows a zlib stream is in it only once the stream was read to its
end. A review of PR 65 found the guide promising both without that
condition.

### Headers

`std` checks the magic number and the method of a gzip header, and the
method and window size of a zlib header, and reads past the rest. RFC 1950
says a decoder must check the whole of `CMF` and `FLG`, and `std` ignores
`FCHECK`: a zlib header with wrong check bits decoded, and its checksum
matched. It ignores `FDICT` too, and reads the four bytes that name the
dictionary as deflate data. RFC 1952 says a decoder must refuse a gzip
header with a reserved flag set, since the flag may mean a field that would
be read as data; `std` does not look.

`Inflate.begin` checks those before the decoder takes the header, while
the decoder is in its `protocol_header` state. It looks at the first two
bytes of a zlib header and the first four of a gzip header, and the reader
the decoder reads from holds four (`flate_ahead`). For gzip that is every
member, since the decoder is started again for each one. Each of these
fails the read like a corrupt stream. A preset dictionary is refused rather
than read: there is no way to give one, and a stream that needs one cannot
be decoded without it.

The header CRC of a gzip header (`FHCRC`) is skipped, as `std` skips it:
RFC 1952 does not require a decoder to compare it.

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

A stream that is cut short, corrupt, has a header a decoder must refuse,
does not match its checksum, or (gzip) is followed by bytes that are no
member fails the read with
`error.ReadFailed`, and nothing more specific. That is what any reader
given to `lines` fails with, so a gzip or zlib input adds no error to a
run, and a rescue written for the plain program still fits. `fileReader`
does not translate a `ReadFailed` either. `std` keeps the cause in a field
of the decoder, and the binding does not surface it.

**Considered: returning the cause from the binding** once the run has come
back with `ReadFailed`. It would widen the error set of every program that
reads compressed input by some twenty names, change it with the binding,
and name a cut-short stream `error.EndOfStream`.

A Zstandard input adds `error.ZstdWindowTooSmall`, when the binding is
acquired and before anything is read (below).

## The end of a compressed stream

A compressed stream needs an end: the last block, and for gzip and zlib a
checksum. Writing it can fail, which a resource `release` cannot. So, as
with `fileWriter`'s `.publish` mode, it happens in the binding after
everything it wraps has returned without an error, and is part of the run:
the run fails with `error.WriteFailed`.

The writer below is flushed there as well. Nobody else does it: a
`fileWriter` that replaces a file leaves the flush to the sink of the pipe,
and the sink flushes its own role, which is the compressing writer.

When what the binding wraps fails, the stream is left without its end, on
purpose: reading it back fails, which is how a reader learns the writer did
not finish. That is all that is said of a failed run. The end is written
before `Into` is flushed, and that flush can fail with the end in place, in
part or whole, and a binding outside this one can fail after it returned.
The first wording said that any failed run left the stream without its
end; a review of PR 65 showed both.

Under a `fileWriter` in `.publish` mode the end is written before the file
is named, because the compressing binding needs the file's role and is
acquired inside it. So a file that was named holds a whole stream.
Publication is atomic per file, not per run: of two published files, one
can be named before naming the other fails, and the guide says so where it
describes `.publish`. The first wording here, "a failed run names no file",
did not hold for that run.

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

Buffers are on the stack of the run, as for the other I/O bindings. The
Zstandard window is too large for that and is the caller's. Nothing is
allocated.

| | |
|---|---|
| `gzipReader`, `zlibReader` | The 64 KiB window (`flate.max_window_len`), 4 KiB of compressed bytes, the caller's `n`, and 3 KiB of decoder. Measured in Debug: 82 KiB of stack more than the plain reader. |
| `zstdReader` | The slice it is given: 128 KiB for a block and the window. 4 KiB and the caller's `n` on the stack. `std`'s decoder puts two blocks, 256 KiB, on the stack of the task that reads. |
| `gzipWriter`, `zlibWriter` | The 64 KiB window, which is the writer's buffer, and `flate.Compress` itself, 230,096 bytes. `std` returns it by value, and a Debug build had three copies at once: 741 KiB of stack was measured. An optimized build was not measured. |

A Zstandard frame says how much window it needs: `zstd` of a known file
asks for the file's length up to its level's limit, `zstd` of a pipe for
2 MiB at the default level, `zstd --long` for more than 8 MiB. A frame that
asks for more than the slice leaves beside a block fails the read, as a
corrupt one does.

### The Zstandard window is the caller's

The first version allocated the window from the run's `std.mem.Allocator`
when the binding was acquired, with `options.window` saying how much. The
owner decided against it: the core and the other extensions allocate
nothing, and a buffer is sized where it is written and held by whoever
writes it. `zstdReader(Role, From, n, window)` takes a `[]u8`, and nothing
in the extension asks for an allocator.

`std` wants one buffer of `window_len + zstd.block_size_max` bytes, so the
slice is exactly that and its length says both: what is left beside a block
is the window. There is no option that repeats it. The guide shows it as a
static array of `zstd.block_size_max + zstd.default_window_len` bytes, 8
MiB and 128 KiB, which is what the format recommends every decoder to
accept.

A slice and not an array of a comptime length: how much window a caller
gives may depend on what it was started with, and a pointer to an array
becomes a slice by itself. So its length cannot be checked at compile
time. `std` asserts on a buffer with no room for a block, and the binding
fails with `error.ZstdWindowTooSmall` at acquisition for a slice of
`block_size_max` bytes or less. More than that is not refused: a frame that
says how long its content is asks for a window of that length, which can be
a few bytes, and `tests/compress.zig` reads one with a window of 17.

A binding is acquired once for a run, so the slice has one user at a time.
Two runs at once that were given the same slice would share it; the guide
says they need two.

**Considered: the compressor and the flate window from the allocator.**
That would take 290 KiB or more off the stack and make every compressing
binding need an allocator, where nothing else in zrx allocates.

`std`'s compression levels are not ordered by size on every text: 60,000
lines of `line N` took 113,535 bytes at `.fastest` and 137,873 at `.best`.
Both read back. The level is `std`'s type and its matter.

## No zero-overhead fixture

Nothing of this extension is in the item loop: a pipe is the same value
with and without it. What it costs is the codec and the one copy named
above.

## Not there

What is not there, and comes back only by decision, is in
[the backlog](BACKLOG.md#compression).
