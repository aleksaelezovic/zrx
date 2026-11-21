# N-Quads check

Reads a file of [N-Quads](https://www.w3.org/TR/n-quads/), writes its
statements the one way, and reports every line that is no statement.

```sh
zig build
./zig-out/bin/nquads-check people.nq tidy.nq
# stderr:
#   line 5: not a statement
# stdout:
#   {"statements":4,"in_graphs":2,"rejected":1}
```

`tidy.nq` holds the statements of `people.nq` with one space between their
terms and nothing after the dot. Comments and empty lines are not copied.

## Outcome

| | |
|---|---|
| Exit 0 | Every line was a statement, a comment or empty. |
| Exit 1 | Some line was none of those; the others are still written. |
| Exit 2 | The run failed: `fatal: <error>` on stderr, and no output file. |

The output is published once the input has been read to its end, and is not
written over a file that exists. A line longer than 512 bytes fails the run.

## The grammar is the pattern

`src/nquads.zig` is the grammar of N-Quads written as
[text patterns](../../../docs/guide.md#text-patterns), rule by rule:

```zig
/// `<http://example.org/s>`
const iri_byte = except(oneOf(.{ between(0, ' '), set("<>\"{}|^`\\") }));
const iri = seq(.{ "<", repeat(oneOf(.{ iri_byte, uchar }), .{}), ">" });

/// `subject predicate object graph? .`
pub const statement = seq(.{
    ws,
    extract(.subject, as(Term, oneOf(.{ iri, blank_node }))),
    ws,
    extract(.predicate, as(Term, iri)),
    ws,
    extract(.object, as(Term, oneOf(.{ tripleTerm(max_nesting - 1), iri, blank_node, literal }))),
    ws,
    optional(seq(.{ extract(.graph, as(Term, oneOf(.{ iri, blank_node }))), ws })),
    ".",
    line_end,
});

/// `{ subject: Term, predicate: Term, object: Term, graph: ?Term }`
pub const Quad = pattern.Extracted(statement);
```

There is no parser besides it. `Quad` is read off the pattern, and a `Term`
is a `zrx.Line(256)`: a line is a value, so what is taken out of it is a
copy (`as`). A term longer than that makes its line no statement.

## The pipe

```zig
const statements = pipe(.{
    map(field(.found)),
    tap(Summary.statement),
    map(nquads.Tidy.of),
    write(Output, "{f}\n"),
});

const rejections = pipe(.{
    map(field(.number)),
    tap(Summary.rejection),
    print(Diagnostics, "line {d}: not a statement\n"),
});

pub const check = program(lines(Input, max_line), .{
    scan(Numbered{}, Numbered.next),
    route(.{
        when(isEmpty, .{drain()}),
        when(isStatement, statements),
        otherwise(rejections),
    }),
});
```

- `scan` numbers the lines, so a rejection can say where it is.
- `isStatement` is `compose(.{ field(.line), nquads.statement })`: the
  pattern is put to the line of a numbered line. Its case is given the
  `Quad` with the numbered line it was taken from.
- The handlers are a few lines each: `Numbered.next`, the two counters of
  `Summary`, `Tidy.of` with the `format` that writes a quad, and `judge`,
  which makes a rejected line exit status 1.

## Triple terms, and how deep

RDF 1.2 lets the object of a statement be a triple term, `<<( s p o )>>`,
whose own object may be another one. That rule contains itself, and a
pattern cannot: it is a value that has to exist before it can be a part.
A function can build one from a shallower one:

```zig
fn tripleTerm(comptime depth: usize) type {
    const plain = oneOf(.{ iri, blank_node, literal });
    const object = if (depth == 0) plain else oneOf(.{ tripleTerm(depth - 1), plain });
    return seq(.{ "<<(", ws, oneOf(.{ iri, blank_node }), ws, iri, ws, object, ws, ")>>" });
}
```

So the depth is written (`max_nesting = 4`), not the text's to choose, and a
term nested deeper is no statement. Each level is code of its own: the
ReleaseFast binary is the same size at 1 and at 4 levels, and about 17 KiB
larger at 16.

A triple term is kept whole, as the text of the object. Its parts are not
extracted: an `extract` at every level would be the same field many times.

## What this app needed from zrx

Nothing is worked around. What it shows is missing:

- **Unicode.** Patterns work on bytes. The names of blank nodes take any
  byte from 0x80 as a letter, which is more than the grammar's ranges of
  code points allow.
- **Two cases, one total.** The cases of the route end separately, so one
  `fold` cannot count both. The counters are kept by `tap` through a
  `*Summary`, and `execute` runs a second program of one item, the summary,
  to print it.
- **The parts of a nested term.** A pattern extracts a flat struct. A tree
  of triple terms would need somewhere to put it.
- **Escapes are checked, not decoded.** `é` is accepted and written
  back as it was.

## Checks

```sh
zig build test
zig build test -Doptimize=ReleaseFast
zig build check
```

`src/nquads.zig` tests the grammar line by line. `tests/integration.zig`
runs the production program over a document in memory, and the real
executable on files in a temporary directory.
