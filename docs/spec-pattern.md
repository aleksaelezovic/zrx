# Spec: text patterns

Status: implemented as `zrx.ext.pattern` (`src/ext/pattern.zig`).

This file is the design record of the extension: why it is the way it is,
what was tried and rejected, and what was measured. The
[guide](guide.md#text-patterns) says how to use it. `AGENTS.md` keeps the
short rules to know before editing it and points here for the reasons.

## What a pattern is

The extension is written against the handler contract alone and is analyzed
only when it is referenced. It has no operator.

A pattern is a composite handler, as `gt(80)` is: a predicate on one item
that is text. There is no `match(p)` that makes a handler of a pattern. One
that extracts answers `?Extracted(p)`, a predicate that finds a value, and
everything else follows from what `when`, `require` and `all` do with one.

What is written is a `Pattern(Node)`. The nodes that match are private
types, and a pattern is told by a private `Mark`, not by a name: a caller's
own handler may declare anything.

`std` has no matcher, so this is the one extension that is not a layer over
`std`. It is kept to bytes, with no Unicode classes.

## Matching goes left to right and gives nothing back

`repeat` takes as much as it can and gives nothing back. `oneOf` takes its
first choice that matches, for good. That is on purpose and is not to be
softened:

- it is the scanner one writes by hand, which is what the `lean_pattern_*`
  fixtures compare with;
- it has no text that takes exponentially long, which matters where the
  text is a request's path;
- it is why this is not called a regular expression.

### What it costs

The first draft said that nothing is read twice, and that a pattern costs
what the hand-written scanner costs on any text. Both were wrong, and a
review measured the square of the length.

A part that fails has been read. The next choice of a `oneOf`, or what
follows an `optional`, reads it again, once per round inside a `repeat`.
The guide says so and shows what to write instead.

That case is not a compile error, because it cannot be seen: two choices
that share a beginning and take the same bytes are linear. Nothing writes
the shared part once for the user either. A pass could only merge parts
that are the same part, and the case that was measured (`lower` again and
again, then `!`, or else one `lower`) shares no part, only bytes.

### Where a pattern does not compile

What the rule makes unmatchable is a compile error where it can be seen:

- a part behind a `repeat` that took its first bytes;
- a choice behind its own beginning;
- a choice behind one that always matches.

Where it cannot be seen, nothing is said, rather than a guess.

## Types are in the pattern

`int(T)` says the type, so the struct of what a pattern extracts is
inferred, and a number that does not fit does not match. A draft that
converted after matching had a route take a path whose number then failed
to parse.

## What a pattern is put to

A pattern is put to a `[]const u8`, or to a value that reads its text with
`text()`, as a `Line` does. That is told by the name `text`, since it is
what a caller's own type may declare.

**What is taken out of a value is a value.** A handler is given its item
by value, and a `Line` holds its text inside it, so a piece of that text
lives no longer than the call. An `extract` cannot return a borrow into a
value's own storage, and one that would does not compile.

Two other designs were considered:

- **Offsets into the line.** Every handler would have to put a span back to
  its line.
- **A borrowed text that lives as long as the push.** It dangles behind a
  `queue`, and it needs the operators to hand a predicate a pointer.

## `as`: what is kept as a value

`as(T, p)` keeps what `p` matched as a `T` that `T.from(text)` makes.
`Line(n)` already had that `from`, and the apps already called it by hand
(`Service.from(column)`). A text `from` fails for does not match, which is
the rule of `int`. It is one contract for a copy of bounded length and for
the words of a format as an enum, not two nodes.

Whether what `as` keeps is a value is read off `T`, not off how the pattern
is written. A `T` with a pointer anywhere in it is taken to point into the
text `from` was given (`holdsPointer`), so it is extracted from a
`[]const u8` and refused from a `Line`. Review showed a `from` that kept
its slice being extracted from a `Line` as if it were a copy.

## Maybe nothing, always, never

Three things a part can be. The first two were taken for one at first:

- **`nullable`**: it can match without taking a byte.
- **`refuses`**: it can match nothing and still say no. An `as` over a part
  that may be empty can refuse what was matched.
- **`never`**: it describes nothing (see rules, below).

That a part can match nothing is not that it always matches. `oneOf` tells
a choice the ones after it cannot be reached only where it always matches,
and `optional` refuses only a part that always matches. Review found a
fallback refused behind `as(Line(0), optional("x"))`, and
`optional(as(Line(0), optional("x")))` refused. `repeat` still asks only
whether a part can match nothing, since that is what would never stop.

## Choices with names

Choices of a `oneOf` may be written with names,
`oneOf(.{ .inner = self, .word = as(Word, letters) })`. Extracted, they are
a tagged union that says which one matched, each choice holding what it
keeps: its value, a struct of its extracts, or `void`.

- Without names an extracted `oneOf` is the text that matched, as before.
  Names are what a union needs, and two unnamed choices of different types
  have none to give. That is why
  `extract(.object, oneOf(.{ self, as(Term, plain) }))`, as it was first
  asked for, is written with names.
- A choice that is only text holds `void` and not that text: a slice would
  make every literal choice a borrow on a `Line`.
- A named choice with extracts inside is the one way to group the extracts
  of an ordinary part into a struct. There is no node for that alone.

## A rule that holds itself

`recursive(rule, .{ .depth })`, where `rule` builds the pattern from
`self`. It is not recursion: the rule is built `depth` times at compile
time, each from the one further in, and the innermost `self` is a node that
never matches. So:

- the matcher is straight code;
- the text does not choose the depth of the stack. A prototype that called
  itself matched 20,000 levels and overran the stack at 200,000;
- every compile-time check works on each level.

A comptime function over the depth could already write the matching. The
helper is there by decision all the same: the base case and the limit are
the library's and not each caller's, and it is what makes nested extraction
possible.

What a level extracts is a struct of its own (`Recorded`), a typed node as
`int` is. So the names of one level clash with no other and the whole has a
size, which is why the depth is written.

A level is told to be dead by `never`, which `seq`, `oneOf`, `repeat`, `as`
and `extract` pass on. A rule that is dead at depth 1 has no way to end and
does not compile, and `seq` does not take a dead part for the mistake of a
part that can never match.

## Measurements

Say these numbers, and not "zero overhead".

### The fixtures

The pattern fixtures are `lean`, not `same`: a pattern carries a position
through its parts.

### A plan that was built and is not there

The last part of a pattern was asked "is all that is left yours" (`finish`)
and not "where do you end", as the loop by hand leaves at the first wrong
byte.

| Fixture | Before | With the plan | By hand |
|---|---|---|---|
| `lean_pattern_route` | 80 | 70 | 71 |
| `lean_pattern_filter` | 40 | 38 | 36 |
| `lean_pattern_require` | 102 | 107 | 102 |
| `lean_pattern_line` | 114 | 136, past what `lean` allows | 111 |

The fixtures by hand are written in both shapes, and that plan matches one
of them. This is what that one experiment measured, not a finding about
every plan: another optimization is judged by the same fixtures, and is
worth having if it improves them all.

### A rule

A rule has no fixture, because it is not `lean`. Against the same rule
written by hand as a function built for each depth, a filter over a rule
three deep measured:

- 80 instructions to 73, no call and no `alloca`;
- two more loads of a byte: a choice that fails on a byte, and the next
  that reads it again.

Timed on 818 MB of nested text it took 0.45 s, the hand-written rule
0.58 s and a hand-written depth counter 0.61 s. Eight levels took what
three did. That is one kind of text on one machine.

The first measurement was 97 instructions. A string of one byte went
through `std.mem.startsWith`, which asks first whether the two texts are
the same memory. It is now compared as a byte.

## Not there

Back only by decision:

- a format string read backwards. `"/items/{id}"` would be a string
  language of our own;
- going back;
- finding the places a pattern matches inside a text;
- a node that only groups the extracts of a part into a struct.
