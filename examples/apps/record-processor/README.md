# Record processor

A finite import CLI built with zrx and Zig **0.17.0**: validate and normalize
`identifier,name,amount_cents` records, write the accepted ones to a new file,
report the rejected ones, and print a summary. No third-party dependencies.

```sh
cd examples/apps/record-processor
zig build
printf ' ab-1 , Ada  Lovelace , 00042\nbad!,Bob,9\n' > input.txt
./zig-out/bin/record-processor --input input.txt --output normalized.txt
# normalized.txt: AB-1,Ada Lovelace,42
# stderr: record 2: InvalidIdentifier
# stdout: summary: accepted=1 rejected=1 amount_cents=42
# exit status: 1
printf 'x,Zed,7\n' | ./zig-out/bin/record-processor --output new.txt
./zig-out/bin/record-processor --help
```

## The pipeline

All of it is one declaration in [`src/composition.zig`](src/composition.zig):

```zig
pub const records_pipe = pipe(.{
    map(validated),
    scan(Numbered{}, Numbered.advance),
    map(Numbered.withinLimit),
    branch(.{
        accepted_records,
        rejections,
        totals,
    }),
});
```

```mermaid
flowchart TD
    L["lines(Input)"] --> V["map(validated): parse, identifier, name, amount"]
    V --> N["scan: number every record"]
    N --> M["map(withinLimit): fatal past the record cap"]
    M --> B["branch"]
    B --> A["filter accepted, map record, print to Accepted"]
    B --> R["filter rejected, map rejection, print to Diagnostics"]
    B --> T["map contribution, fold totals"]
    T --> F["tap: flush record output"]
    F --> S["tap: remember totals, print summary to Console"]
```

- The schema is four named handlers composed left to right; the first rule a
  line breaks becomes that record's outcome. A rejection is data, not a failed run.
- `Rules` (amount ceiling, record cap) is an injected dependency.
- The four destinations are roles: `Input`, `Accepted`, `Diagnostics`
  (`zrx.Stderr`) and `Console` (`zrx.Stdout`). Production provides them from
  real files and streams; tests provide fixed readers and writers to the same
  program.
- The summary is written only after record output has been flushed successfully.

`app.zig` is the boundary around it: it parses the command, opens the input,
creates the output, runs the program and turns the totals into an outcome.
`main.zig` owns exit codes.

## Format and policies

- Exactly `identifier,name,amount_cents`: no header, quoting, embedded commas
  or comments. LF ends a record; a final unterminated record is accepted; one
  trailing CR is removed. Blank lines are rejected records.
- ASCII space and tab are trimmed at field edges. Identifier: 1–32 ASCII
  letters, digits, `_` or `-`, uppercased. Name: 1–80 bytes of ASCII letters,
  digits, spaces, apostrophes, hyphens and dots, repeated spaces collapsed.
  Amount: 1–32 decimal digits, integer cents from 0 through 1,000,000,000,
  leading zeros removed.
- At most 256 bytes per line excluding LF, and 10,000 records including
  rejected ones. Exceeding either is **fatal** (`StreamTooLong`,
  `TooManyRecords`), not truncated input.
- Accepted output keeps input order. A diagnostic carries the 1-based record
  number and the first broken rule, never the record's content.
- `--output NEW_PATH` is required and is created exclusively: an existing file,
  including the input, is never overwritten. Input defaults to stdin;
  `--input PATH` reads a file and `--input -` selects stdin.
- Exit **0**: all accepted (including empty input). **1**: finished, with
  rejected records. **2**: invalid usage, or a fatal I/O or limit error, which
  prints `fatal: ErrorName` to stderr and no summary.
- Not atomic: a fatal run can leave a new file holding the records written so
  far (always whole records). There is no rollback or durability guarantee.

## Checks

From this directory:

```sh
zig build
zig build test
zig build test -Doptimize=ReleaseFast
zig build check
```

`test` runs the domain unit tests, the production program with injected
readers and writers (including failing writers), and the real executable on
temporary files with its exit status, stdout, stderr and output file asserted.
Every executable run has a 10-second deadline and is killed and reaped on failure.

## Layout

```text
src/
  main.zig                 exit codes and the fatal report
  app.zig                  command dispatch, opening files, running
  composition.zig          the pipeline and its roles
  handlers.zig             a handler combinator zrx does not have yet
  domain/
    commands.zig           option parsing and usage
    records.zig            bounded data, outcomes, numbering, limits
    validation.zig         the schema, one handler per rule
    summary.zig            totals
```

## What this port needed from zrx

This app existed for the previous zrx and was rebuilt on the rewritten API
without changing the library, to find out what is missing. Ordered by how
much each one shaped the code:

1. **Turning an error into a value.** `recover` can only skip the failing
   item; here a rejected record must continue downstream to be numbered,
   reported and counted. [`handlers.zig`](src/handlers.zig) adds
   `orElse(handler, fallback)` through the public composite-handler contract.
   It belongs in zrx next to `compose`.
2. **Creating a file exclusively.** `createFile` always truncates, so "never
   overwrite" meant opening the output in `app.zig` and passing its writer as
   a dependency, flush-on-failure included. An option on `createFile` would
   move that back into the pipe. The input is opened there too, because no
   source says "this file, or stdin".
3. **A program has no result.** The caller needs the totals for the exit
   status, so `tap(remember)` stores them through a `*Summary` dependency.
4. **`print` only ends a pipe.** Writing records and then aggregating became a
   `branch` with a `filter` per destination, which reads well; flushing before
   the summary needed a handler.
5. **Choosing a program is plain Zig.** Help, invalid usage and processing are
   a `switch` in `app.zig`; a pipe cannot switch to another source.
6. **Owned bounded text.** The old `zrx.Line(n)` is gone; `records.zig`
   defines `Text(n)`.

What needed nothing: the record cap (`scan` numbers, a handler enforces),
injected rules, and testing the production program against in-memory I/O.
