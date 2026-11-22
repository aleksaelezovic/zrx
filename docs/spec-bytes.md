# Spec: bytes

Status: implemented as `zrx.ext.bytes` (`src/ext/bytes.zig`). Four of its
choices are proposals that the owner has not yet decided. Each is listed
here as the decision asked for, and marked "(a proposal)" where its reasons
are given below:

1. `digest` takes a started hasher, `digest(Sha256.init(.{}))`, and not a
   type, `digest(Sha256)`.
2. `hex` and `base64` of an item whose length is known only at run time
   stay, though `{x}`, `{X}` and `{b64}` write a `[]const u8` too.
3. A digest is folded with `fold`, and a hasher that holds a block pays
   two copies of its state per piece; no operator feeds a hasher in place.
4. Decoding is there, `fromHex(n)` and `fromBase64(codecs, n)`, to a
   length that is written only.

This file is the design record of the extension: why it is the way it is,
what was tried and rejected, and what was measured. The
[guide](guide.md#bytes) says how to use it, and every behavior named there
is pinned in `tests/bytes.zig`. `AGENTS.md` keeps the short rules to know
before editing it and points here for the reasons.

## What it is, and why it is not called `crypto`

It is what a stream of byte pieces is turned into: a digest, and the text
of bytes. It is written against the handler contract alone, is analyzed
only when it is referenced, and has no operator.

It holds digests of `std.crypto.hash` and of `std.hash` alike. A CRC or an
xxHash is no cryptography, and a module named `crypto` that offered them
would say they were. It holds the text encodings of bytes, which are not
cryptography either. And it holds none of what the name would promise: no
ciphers, no signatures, no handling of keys, and nothing that compares in
constant time. So it is named after what it works on.

## A digest is the state of a fold

The evidence it was designed from is `Hash` in the file-integrity-manifest
app: a struct around a `Sha256` with an `update(hash, piece)` reducer, used
as `fold(Hash{}, Hash.update)` over the pieces of a file inside `each`, and
finished in a later handler. `digest(start)` is that struct as a line:

```zig
const Sha256 = bytes.digest(std.crypto.hash.sha2.Sha256.init(.{}));

fold(Sha256{}, Sha256.update),
map(Sha256.final),
```

What it returns is a type with one field, `hasher`, that begins as `start`,
and two plain functions.

**Plain functions, not composite handlers.** The app's `Hash` counts the
bytes of a file beside its digest. A state of a caller's own can hold a
digest state and call `Sha256.update` and `Sha256.final` from its own
reducer and handler. A composite handler can only be called through the
handler contract, and the count would have had no place.

**It is given a hasher, not a type (a proposal).** The hashers of `std` are
started in different ways:

| | `init` |
|---|---|
| `std.crypto.hash` (`Sha256`, `Blake3`, ...) | `init(options)` |
| CRCs, `Fnv1a` | `init()` |
| `Wyhash`, `XxHash32`, `XxHash64`, `XxHash3` | `init(seed)` |

`digest(H)` with a type would need a rule for each row, and for the last
one a seed nobody wrote. Given the hasher as its own `init` starts it,
there is one spelling for all of them and nothing is guessed. A type
passed by mistake is a compile error that says to start it.

### How a hasher is told

By its shape, read in `Finish.of`, not by a list of names. A hasher has
`update(*H, bytes)`, where `bytes` is a `[]const u8` or `anytype` (xxHash),
and a `final` of one of two kinds:

| `final` | The digest | Which |
|---|---|---|
| returns a value: `final(*H) T`, `final(H) T` | that value, an unsigned integer | `std.hash` |
| fills what it is handed: `final(*H, *[n]u8)`, or `final(*H, []u8)` with a `digest_length` | the array | `std.crypto.hash` |

That is how the two families are told apart: nothing asks which module a
hasher is from. A hasher of a caller's own with either shape is taken.

**The output is one of two types, compared as types.** The first check
took a pointer to any array of bytes and a slice of bytes, and looked only
at `const`. A review found that a `*[n:0]u8` passed: the digest was then
returned as an array whose sentinel nobody had written. A `[:0]u8`, a
`[]align(16) u8` or a `*align(16) [n]u8` passed as well and failed at the
call, where a plain array cannot be handed to them. `Filled` now asks
whether the output is `*[n]u8` or `[]u8`, as types, so that a sentinel, an
alignment, `const`, `volatile` or an address space of its own is refused
at `digest`, with one message that names the type found and the two that
are taken. An output that points to no bytes at all is no hasher, and
gets the message for that.

`digest_length` is read where it is needed and checked where it is read
(`length`): it is an integer, it is not negative, and where `final` fills
a `*[n]u8` and the hasher declares one too, it is `n`. A `final` that
fills a `[]u8` with no `digest_length` beside it has nothing to say how
long its digest is, and is refused.

**What a digest is, is said exactly.** The first check took any `final`
of one parameter that returned something, and told the two families apart
by that alone. A review found that a `final` returning `bool` passed as
the integer of `std.hash`. So did a signed number, a float, an optional,
an error union (which made the handler fallible) and an array that was
returned and not filled. `finished` now names the two digests and takes
nothing else: an unsigned integer that is returned, or an array of bytes
that is filled by a `final` that returns nothing. No width is singled
out: `std.hash.crc` has CRCs from three bits upward, so a `u1` is taken
with them.

The checks beside it were as loose and are tightened with it. `update`
returns nothing: one that returned a `bool`, a count or an error union
got as far as Zig's own "value ignored", and a reducer has nowhere to put
an answer or a failure. And the first parameter of `final` is the hasher,
`H`, `*H` or `*const H`, the three that `std` writes: a `final` that is
no method was Zig's "no member function", and one that took `anytype`
passed. Each of these is the one compile error for a type that is not a
hasher.

`finalResult(*H) [n]u8` was a third shape at first. A mutant without it
passed every test, because every hasher of `std` that has it also has the
`final` it calls. It was taken out.

Not a hasher by that shape, and refused with a compile error that says
what is missing:

- `std.hash.Adler32` has `update` and no `final`; its checksum is a field.
- `Murmur` and `CityHash` hash one text and are not fed in pieces.
- `AsconXof128` and `AsconCxof128` have no length of their own for their
  output: they `squeeze` and have no `final`.
- `sha3.KMac128` and `KMac256` fill a `[]u8` of any length and call their
  length `mac_length`. That is not read as a `digest_length`: one name is
  read, and a second would be a list of names.

A keyed hasher of `std` (`SipHash`, a `Blake3` started with a key) has the
shape and is taken. The key is `std`'s and the caller's: nothing here reads
one, stores one or compares a result.

Of `sha3`, every other hasher has the shape: `Sha3_224` to `Sha3_512`,
`Keccak256`, `Keccak512`, `Shake`, `TurboShake`, `CShake`, `TupleHash`
and `KT128` and `KT256`. A `TupleHash` hashes a tuple, each `update` one
element of it, so its digest is of the pieces as they came and not of
their bytes alone. It is taken, since that is what its `update` is, and
the guide says so. The guide names each hasher of `std.crypto.hash` that
is taken, and the test "the digest is what the hasher's own final
returns" holds every one of them.

### What the state costs

A reducer is given its state as a value and returns one. What the
optimizer makes of that depends on the state:

| Fixture | Hasher | State | Result |
|---|---|---|---|
| `same_checksum` | `std.hash.Crc32` | 4 bytes | the same 33 instructions on aarch64, 66 on x86_64 |
| `same_digest` | `Sha256` | 112 bytes | the same 107 and 133, with the two copies below in the loop by hand |

For a hasher that holds bytes it has yet to hash, the state is copied out
and back for every piece: two `memcpy` of the state. The loop by hand in
`same_digest` has those two copies as well, which nobody would write, so
that the fixture compares everything else. Without them the loop by hand
has 103 instructions on aarch64 where the pipeline has 107, and 128 on
x86_64 where it has 133, and no copy.

That is paid per piece, not per byte. The sizes of some states, measured
on aarch64: `Sha256` 112 bytes, `Sha512` 224, `Sha3_256` 352, `XxHash3`
544, `Blake3` 1920, `KT128` 82560.

**No operator feeds a hasher in place (a proposal).**
It is the reducer contract's cost, not this extension's: anything that
folds a state with a buffer in it pays it. An operator that feeds a hasher
in place would have no copies. It has been neither written nor measured,
and it would be a second spelling of the fold; it returns only by
decision.

## The text of bytes

`hex(case)` and `base64(codecs)` are composite handlers for `map`. `case`
is `std.fmt.Case` and `codecs` a `std.base64.Codecs`, so the alphabets are
`std`'s and one of a caller's own is taken too.

- An array becomes an array: the length is known when the program is
  compiled, so the text is a value. That is what the manifest app needs: a
  field of a row that `std.json` writes as a string.
- An item whose length is known only when the program runs, a `[]const u8`
  or a value that reads its bytes with `text()`, becomes a value that
  holds the item and is formatted with `{f}`. This follows `json.encode`:
  nothing is allocated, and nothing is borrowed that the item had not
  already borrowed. A `Line` is held as a copy, so the value crosses a
  `queue`.

**What `std` already writes (a proposal to keep the overlap).** `{x}`,
`{X}` and `{b64}` format a `[n]u8` or a `[]const u8` that is printed as it
is, so `print(Role, "{x}\n")` writes a digest with no handler, and for a
bare slice `map(hex(.lower))` with `{f}` is a second way to the same
output. It was kept because the rule would otherwise be two: `{x}` does
not format a `Line` (a struct is asked for `formatNumber`), and `{b64}` is
the standard alphabet with padding only. The alternative is to refuse a
bare `[]const u8` with a compile error that points to `{x}` and `{b64}`,
and to keep the value for a line and for other alphabets. The guide says
where `std`'s format is enough.

A digest of `std.hash` is an integer and is not bytes: `hex` refuses it
and says to write it with its format, `{x:0>8}`.

The value that holds an item has no `jsonStringify`. As a field of a row
given to `json.encode` it would be written as a struct. Use an array
there.

## Decoding

`fromHex(n)` and `fromBase64(codecs, n)` return `E![n]u8`.

**The number of bytes is written (a proposal to have decoding at all).**
The brief allowed decoding only if it returns a value under the lifetime
rule. A result as long as the text happens to make it has no length known
at compile time, so it would be a slice into a buffer somebody has to own.
With the length written the result is an array. That fits what one decodes
in a pipe: a digest of a known size, to compare with one that was
computed.

Its failures are named, in `HexError` and `Base64Error`, so that
`recover` and `attempt` can take them:

- A text that is not as long as `n` bytes make it is
  `error.InvalidLength`, before its characters are looked at.
  `std.fmt.hexToBytes` returns a shorter slice for a shorter text, so the
  length is checked here.
- For Base64 the length is asked of `std` first
  (`Decoder.calcSizeForSlice`), and a text of a length no text of the
  alphabet has is `error.InvalidPadding`, which is what `std` calls it.
- An array item whose length can never be `n` bytes is a compile error:
  it would fail for every item.

## Fixtures

| Fixture | What |
|---|---|
| `same_checksum` | a digest whose state is a number |
| `same_digest` | a digest whose state holds a block; see above |
| `same_base64` | `base64` of an array |
| `lean_hex` | `hex` of an array: 82 instructions to 99 by hand |

`lean_hex` is `lean` because the loop by hand has its eight digits put
into one number and taken apart again; the pipeline is the shorter one.

In `same_base64` the loop by hand binds `std.base64.standard` to a local
constant. A comptime parameter is an anonymous constant in the pipeline,
and the named global of `std` would differ from it by name only.

**No fixture for decoding.** One was written for `fromHex` behind a
`recover`. Its error names (`InvalidLength`, `InvalidCharacter`,
`NoSpaceLeft`) renumbered the errors of `cases.zig`, and `same_recover`,
`same_recover_stop`, `same_recover_fail`, `same_rescue` and `same_require`
stopped matching: `icmp uge` against `icmp ult`, the hazard the comment at
`same_require` describes. It was taken out. A fixture of this extension
brings no error names of its own into that file.

## Not there

Back only by decision:

- decoding to as many bytes as the text stands for, as a bounded value;
- Base64 of a stream of pieces as one text. Three bytes make four
  characters, and a group may begin in one piece and end in the next, so
  it needs a state that carries up to two bytes. Hexadecimal has no such
  groups: `write(Role, "{x}")` over the pieces is the text of the whole;
- an operator that feeds a hasher in place;
- a `jsonStringify` on the value that holds an item;
- ciphers, signatures, keys and constant-time comparison.
