# Spec: JSON

Status: implemented as `zrx.ext.json` (`src/ext/json.zig`): two handlers,
`encode` and `decode`.

This file is the design record of the extension: why it is the way it is,
what was considered and rejected, and what was measured. The guide says how
to use it, under [Input and output](guide.md#input-and-output) and
[Decoding JSON](guide.md#decoding-json). `AGENTS.md` keeps the short rules
to know before editing it and points here for the reasons.

## A layer over `std.json`

The extension is named after its format and is analyzed only when it is
referenced. Both handlers are written against the handler contract alone,
and the parsing and the writing are `std.json`'s. There is no general
serialization layer for one format, and nothing here is known to the core.

`map(json.encode(.{}))` returns `std.json.fmt(item, options)`, which
`print` or `write` formats with `{f}`. One spelling: `encode` is always
called with its options, and there is no sink that hides
`write(Role, "{f}\n")`.

`map(json.decode(T, options))` reads an item that is text as one whole
document, with `std.json.parseFromSliceLeaky`. It is always called with its
options as well. The text is a `[]const u8`, or a value that reads its text
with `text()`, as a `Line` does: the rule the pattern extension has for
what a pattern is put to.

## What is decoded is a value

An item goes from stage to stage as a value. What `decode` reads from is
gone when it returns: the text of a `Line` is in the item it was given, and
what `std.json` allocated is in the scratch memory on its stack. So nothing
it returns may point into either.

Whether a `T` is a value is read off the type, as `as` reads it in the
pattern extension: a `T` with a pointer anywhere in it is refused where
`decode` is written, with the field named and what to write instead. A type
that reads itself with a `jsonParse` is held to the same rule; how it reads
is not looked at.

"Anywhere" is every kind of type that holds another: an optional, an error
union, an array, a vector, a struct, a union. Review found the error union
missing: a type whose `jsonParse` filled a field `anyerror![]const u8` from
the allocator compiled, and the name it returned was read back overwritten.
The list of what a type is made of had an `else` for everything it did not
name. It now names every kind, so one that `std` adds does not compile
until it is said what it holds. Put once to 36 types, with pointers behind
each of those kinds, it answered as `holdsPointer` of the pattern extension
does; before, the two differed on the eight that held an error union. No
test holds that comparison: they are two copies of one question, each
private to its extension.

What is not seen is an address kept as a number, a `usize` from
`@intFromPtr`. No reading of a type finds that.

`std.json` would read into such a `T` without complaint. With
`.alloc_if_needed`, which is its default for a whole text, a string without
an escape is a slice of the text and one with an escape is a copy in the
allocator, so the same field would dangle in one of two places depending on
the text.

A `T` that `std.json` has no way to read (an untagged union, a `void`
field, a `comptime` field) is refused in the same place. `std` has compile
errors of its own for those, raised inside `std` and naming no operator.

### Rejected: a `from` contract

`as(T, p)` keeps what a pattern matched as a `T` that `T.from(text)` makes.
The same was considered here: `decode(T, options)` where `T.from(parsed)`
makes the value from an intermediate struct with slices, read first. It
would carry over the hand-written decoder of the audit-archive app as it
is, with its `Entry` that borrows and its `Record` that owns.

It is not there. It is a second way to say what a `T` is made of, and it
leaves the common case with boilerplate: a struct with a name in it needs a
second struct with a slice and a function between the two. With a `Line`
that `std.json` reads, that struct is decoded as it is, and what `encode`
wrote of a value `decode` reads back.

A shadow type built from `T` by reflection, each `Line` in it read as a
slice and then copied, was rejected for the same reason one step further:
it is the serialization layer.

What this costs the audit-archive case: `decode(Record, ...)` with
`.ignore_unknown_fields` is one line, and it no longer requires the fields
that are checked and then dropped (`actor`). To keep that check, the type
decoded has those fields too, as a type with a `jsonParse` that reads a
string and keeps nothing. The extension does not provide that type.

## `Line` has a `jsonParse`, in `src/io.zig`

This is the one change outside the extension, and a proposal until the
owner accepts it.

Text in a value is a `Line(n)`. `std.json` reads a struct through the
declaration `T.jsonParse` of that struct: it looks nowhere else. So the
hook has to be declared on `Line` itself, beside the `jsonStringify` that
was already there for `encode`; nothing in `src/ext/json.zig` could make
`std.json` read a `Line`. Without it the rule above leaves no text but an
array of exactly as many bytes.

It is `std.json`'s contract and not the extension's: the method names
nothing of zrx, and a caller who uses `std.json` directly gets it too.
`Line` is read as it is written, like a byte slice: from a string, or from
an array of numbers, which is what `jsonStringify` writes for bytes that
are not UTF-8. It delegates to `std.json.innerParse([]const u8, ...)` and
copies.

A text too long for its line is `error.ValueTooLong`, not the
`error.StreamTooLong` that `Line.from` has. A `jsonParse` can return only
what `std.json` already fails with: its result is returned through
`std.json`'s own error set.

The method is generic (`source: anytype`), so it exists only where it is
called. Checked on `wasm32-freestanding` and `thumb-freestanding-eabi`, in
Debug: a program over `Line` items that does not decode compiles to 87
functions, none of `std.json`; one that decodes its lines has 277, 62 of
them `std.json`'s. The core compiles freestanding as before
(`zig build cross`), and so does `decode`.

## How the scratch memory is given

`std.json` wants an allocator even for a `T` without pointers: its scanner
keeps a bit for each level of nesting in a list, and a name, a number or a
text written with an escape is copied before it is read.

`decode` gives it a `FixedBufferAllocator` over `options.scratch` bytes of
its own stack, new for every item.

**A size, not an allocator dependency.** An allocator in the environment
was the alternative: `decode(T, options)` with `std.json.ParseOptions`
alone, and an arena per item. That is a dependency every program that
decodes has to provide, traffic on the heap for every object (the list of
nesting bits is allocated at the first `{`), and no bound on what one text
can make the run use. With a size, what one item can use is bounded,
`decode` asks for nothing, and running out is `error.OutOfMemory`: the
item's error, taken by an error path like the rest.

**No default.** `std`'s lists begin at one cache line, so what a text needs
differs by target. Measured on aarch64-macos, where that is 128 bytes: a
flat object without an escape is read with 129 bytes of scratch and not
with 128; the same object with one escaped string is not read with 256 and
is with 512. A number alone needs none. Any number written for the user
would be a guess, right on one target and short on another. The guide says
what the memory is used for and gives a rule of thumb; it promises no
formula.

**The options are nested.** `.parse` is `std.json.ParseOptions` as it is,
so that nothing of `std`'s is copied and nothing has to follow it. The
price: an option of `std.json` written at the top level
(`.ignore_unknown_fields`) is Zig's own "no field named", at the call.

## Errors

`DecodeError` is written out: the set of `std.json` for one whole text,
without `BufferUnderrun`, which `std.json` lists and documents as never
returned for one. It is written out so that an error path can name it, and
so that an error `std` adds does not compile: the handler narrows what
`std.json` returned into it. `tests/json.zig` holds a text for every one of
them and compares the two sets.

## Measurements

`decode` has no zero-overhead fixture, and the guide claims nothing of its
cost but that `std.json`'s parser is called once for an item.

A fixture was written and is not there: the sum of two numbers of each
text, decoded with `map(json.decode(...))`, against a loop that calls
`std.json.parseFromSliceLeaky` over a `FixedBufferAllocator` by hand.

- The exported function had 614 instructions with zrx and 614 by hand on
  one of the two targets of the check, and 617 and 617 on the other.
- It fails as `same` all the same. The lines that differ are the numbers
  of the error values, and the names of the `std` functions called
  (`eql__func_61` with zrx, `eql__func_10` by hand). Both are given per
  compilation. Within the function the renumbering was consistent.
- `tools/same_code.zig` compares every function in the file, and the
  parser is called, not inlined. Its functions are in both files under
  names that differ the same way, so each is reported as present in one
  variant only.
- With the fixture in the file, six fixtures that pass without it failed
  as well: `same_recover`, `same_recover_fail`, `same_recover_stop`,
  `same_require`, `same_require_found` and `same_rescue`. Five had the same
  count of instructions on both sides; `same_require_found` had 40 with
  zrx and 35 by hand. Why was not looked into.

Passing would take a tool that equates numbers given per compilation. That
is widening it to make a fixture pass, which `AGENTS.md` rules out, and the
fixture would still disturb the others. A handler that wraps a call into
`std` that is not inlined cannot have a fixture as the check is built.

## Not there

Back only by decision:

- a decoder that reads a document as it arrives;
- a document that spans several items: the pieces of `fileBytes`, or one
  object written over several lines;
- a `from` contract, or a type that is checked and dropped (see above);
- a default for `.scratch`;
- a place for `isText` and `holdsText` that the pattern extension and this
  one share. Each has a private copy of the rule "a `[]const u8`, or a
  value with `text()`".
