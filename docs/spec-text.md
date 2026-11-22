# Spec: text handlers

Status: implemented as `zrx.ext.text` (`src/ext/text.zig`). The points
under "Proposed, not decided" are this record's own choices and await a
decision.

This file is the design record of the extension: why it is the way it is,
what was tried and rejected, and what was measured. The
[guide](guide.md#text) says how to use it. `AGENTS.md` keeps the short
rules to know before editing it and points here for the reasons.

## What it is

Handlers and one source over `std.mem` and `std.ascii`, written against the
handler and source contracts and analyzed only when referenced. It has no
operator, and `src/ops/nested.zig` knows nothing of it. Bytes only: the
classes and the case are ASCII's.

| | Put to | Answers |
|---|---|---|
| `trim(bytes)`, `trimStart(bytes)`, `trimEnd(bytes)` | a `[]const u8` | a slice of the same bytes |
| | a `Line(n)` | a `Line(n)` |
| `toUpper`, `toLower` | a `Line(n)` | a `Line(n)` |
| `split(delimiter)`, `tokenize(delimiters)` | a `[]const u8`, or a struct with `text()` | a source of `[]const u8` pieces, for `each` |

## Where the bytes are decides

A handler is given its item by value. For a `[]const u8` that value is a
reference to bytes that stay where they are, so a part of it is a slice of
the same bytes. A `Line` holds its text inside it, so a piece of that text
lives no longer than the call: what is made of a line is a line. This is
the rule of [the pattern extension](spec-pattern.md#what-a-pattern-is-put-to),
that what is taken out of a value is a value, and it is not stated a second
way here.

Changing bytes needs bytes of one's own. `toUpper` and `toLower` are put
to a line and convert the line they were given. Put to a `[]const u8` they
are a compile error that says to copy first:
`compose(.{ Line(32).from, text.toUpper })`. That is already writable, so
there is no second spelling for it, such as `toUpper(Line(32))`.

Where the items are references to lines (`*const Row`), the handler that
yields the text goes first, as for a pattern:
`compose(.{ Row.text, text.trim(" ") })` answers a slice of the line where
it is.

## Which value is made here

The one value of text that is made here is a `Line(n)`, told by identity:
`T == Line(n)` for the length of its `bytes`. A line trimmed is made
from its two fields, with what is kept copied in: a part of a line fits a
line of the same limit.

**Considered and left out: a caller's own type with `text()` and `from`.**
Its `from` may refuse for reasons of its own, so `trim` would answer an
error union, and for a `Line` one that can never happen: every pipe that
trims a line would have `StreamTooLong` among what it can fail with.

What only reads a text takes what a pattern takes: `split` and `tokenize`
are put to a `[]const u8` or to a struct `T` that reads its text with
`pub fn text(*const T) []const u8`. Only a struct, as for a pattern: a
union or an enum with such a `text` is the compile error that says what is
taken.

## Pieces, and how long one lives

`split(delimiter)` and `tokenize(delimiters)` are handlers that answer a
source: the `source_of` of `each`. The source keeps the item itself and
reads its text in `run`. A slice taken in the handler would point into the
value the handler was given, which lives no longer than that call. The
source stands still in the frame of `each`'s push for as long as it runs.

So a piece of a `[]const u8` lives as long as its bytes. The rule for a
piece of a struct is: **it is valid until the push of that item has
returned, and no longer**. That is the sub-pipe; what the `each` emits for
the item, the last emission included (the final value of a `fold` in the
sub-pipe that kept a piece); and the synchronous stages after the `each`
that the push runs through. A caller that keeps a piece beyond that copies
it. `tests/text.zig` holds that a piece is there in each of those places.
Behind a task boundary after the `each`, or kept in a `batch` there, it
dangles.

That is not a compile error, because it cannot be seen from an extension: a
piece is a `[]const u8`, like a piece of `fileBytes`, and the guide says of
both that they are not to cross a boundary. Do not promise more.

**This is the design the pattern extension rejected for `extract`**: "a
borrowed text that lives as long as the push", which "dangles behind a
`queue`". It is here because the task that asked for the extension asked
for it, and for two reasons that do not hold for a pattern:

- nothing has to hand a predicate a pointer. `each` already holds the
  source of an item for the push of that item, for any source;
- the piece is what a sub-pipe works on and not what a pipe carries. What
  leaves the sub-pipe is usually a value made of the pieces (a `fold` into
  a struct, a number, `map(Line(32).from)`).

The alternative keeps the pattern's rule: put to a line, the pieces would
be values, a `Line(n)` each. Then nothing can dangle, and every piece is a
copy of up to `n` bytes whether or not the sub-pipe keeps it. It was not
built or measured.

## Delimiters

A delimiter is a comptime string, also when it is one byte. For `split`
several bytes are that sequence; for `tokenize` they are a set, any byte of
which separates. Those are the two forms the two names stand for
(`std.mem.splitSequence`, `std.mem.tokenizeAny`). One byte goes to the
scalar form of each. `std.mem`'s other forms (`splitAny`,
`tokenizeSequence`, the backwards ones) are not there, and neither is a
delimiter chosen while the program runs, which is a `source_of` of the
caller's own.

`map(text.split(","))` compiles and makes items that are sources. A handler
cannot tell which operator calls it, so nothing rejects it.

## No predicates

A pattern describes the whole of a text, and a test that a pattern already
is has no second spelling here. Each was checked before it was left out:

| Test | As a pattern | |
|---|---|---|
| the text is `GET` | `seq(.{"GET"})` | compiles; held in `tests/text.zig` |
| it starts with `/items/` | `seq(.{ "/items/", repeat(byte, .{}) })` | compiles; held in `tests/text.zig` |
| it ends with `.zig` | `seq(.{ repeat(byte, .{}), ".zig" })` | **does not compile** |
| it holds `x` somewhere | | not a pattern |

**`endsWith` is not a pattern.** The task that asked for this extension took
it to be one. A `repeat` gives nothing back, so the `repeat` before the
suffix takes the suffix too, and the pattern above is the compile error
"seq: part 2 can never match". A suffix after bytes that cannot be in it
(`repeat(except(set(".")), .{})`, then `.zig`) is a pattern, and
`tests/text.zig` holds that it does not describe `a.b.zig`. No other
suffix is one: telling where the suffix begins needs going back.

**`contains` is out** because it is finding a place a pattern matches
inside a text, which the pattern extension lists as back only by decision.
`endsWith` is the same question with the place fixed at the end, so it is
left out with it and not added in passing: whether a test of a part of a
text belongs to patterns or is a handler over `std.mem` here is one
decision for both. Until then it is a handler of the caller's own over
`std.mem.endsWith`.

## Measurements

Read off the optimized IR of the fixtures, for `aarch64-linux` and
`x86_64-linux`. All five are `same`: the zrx variant and the loop by hand
are the same instructions.

| Fixture | The pipe | Against | Calls | Stack slots | Copies |
|---|---|---|---|---|---|
| `same_text_trim` | `trim` put to a `[]const u8` | `std.mem.trim` | 0 | 0 | 0 |
| `same_text_split` | `each` over `split(",")` | the loop over `std.mem.splitScalar` | 0 | 0 | 0 |
| `same_text_tokenize` | `each` over `tokenize(" \t")` | the loop over `std.mem.tokenizeAny` | 0 | 0 | 0 |
| `same_text_trim_line` | `trim` put to a `Line(32)` | a loop that trims the row in a function of its own | 0 | 2 | 2 |
| `same_text_upper` | `toUpper` put to a `Line(32)` | a loop that copies the row first | 0 | 1 | 1 |

The counts are the same on both sides of each comparison and on both
targets. They are measurements of these pipes and no rule for others; no
test holds them. For what the copies of a line are in other pipes, see the
guide's [Lines and values](guide.md#lines-and-values).

In the two fixtures with a line, the loop by hand copies each row before it
reads it, which nobody would write: an item goes from stage to stage as a
value, and in these pipes the optimizer does not take that copy out. It is
on both sides so that what is compared is the handler, as in
`lean_pattern_line`. For `trim`, the loop by hand gives the row to a
function of its own as a tuple of one, as a handler is given its data, and
that function makes the trimmed line.

### What was tried for `trim` put to a line

- **`Line(n).from(kept) catch unreachable`.** The same instructions as the
  loop by hand written the same way, 74 on aarch64, once the copy by hand
  was written as the tuple a handler's data is passed in; with the row
  alone the two differed in the type of that stack slot and nothing else.
  But three stack slots and four copies stood in the code on both sides:
  the row, what is kept, the new line's bytes once more, and one on the
  branch for a text that does not fit, which is never taken and which the
  optimizer left in.
- **Making the line from its fields**, which is what is there: two stack
  slots and two copies, the row once and what is kept once. Against a loop
  by hand that trims inline, 66 instructions to 65 on aarch64 and 127 to
  126 on x86_64, with the same loops: the pipe marks where a stack slot
  begins and ends for every item, and the loop by hand has one store of a
  zero the pipe has not. Those marks are what the optimizer puts around
  the slots of a function it inlines, so the loop by hand that trims in a
  function of its own has them too, and has no store of a zero: with the
  row given alone, the two differed in the type of one stack slot, the row
  or a tuple of it. Given a tuple of one, it is the same instructions, 66
  on aarch64 and 127 on x86_64. That is the fixture.

### What was tried for `toUpper`

- **Writing into a fresh line.** With a sink that stores the row, 47
  instructions to 41 by hand on aarch64 and 77 to 71 on x86_64, with a
  second stack slot the loop by hand has not.
- **Converting the line it was given, in place**, which is what is there.
  With the same sink: 41 instructions to 35 on aarch64 and 69 to 63 on
  x86_64, with one copy of the row's 32 bytes and one stack slot more than
  by hand.
- **The same, with a sink that reads the row** (a `fold` over its bytes):
  the same instructions as the loop by hand. That is the fixture.

So a pipe that converts a line and stores it has a copy the loop by hand
has not, and the fixture does not show it. It is the same finding as for
any item that holds its bytes, and not this handler's: see "Zero overhead"
in `AGENTS.md`.

## Proposed, not decided

- The bytes to strip are always named: there is no bare `trim` beside
  `trim(bytes)`, as `json.encode` always has its options. `text.whitespace`
  is the constant for the common case.
- The names `toUpper` and `toLower`, after `std.ascii`, and not `upper` and
  `lower`, which the pattern extension has for classes of bytes.
- Only a `Line(n)` is made, as above.
- A piece of a struct, such as a line, is valid until the push of that
  item has returned: through the sub-pipe, the `each`'s last emission for
  the item and the synchronous stages after it. A caller that keeps a
  piece longer copies it. As above.
- Several bytes are a sequence for `split` and a set for `tokenize`.

## Not there

Back only by decision:

- `endsWith` and `contains`, as above;
- Unicode, in the classes or the case;
- a delimiter chosen while the program runs;
- `std.mem`'s other ways to split;
- pieces of a line as values.
