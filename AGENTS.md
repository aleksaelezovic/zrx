# Agent instructions

This is the canonical agent instruction file for zrx. Agent-specific instruction
files are symlinks to this file; edit this file rather than maintaining copies.

## Scope and review loop

- zrx is a Zig library for declarative functional pipelines and, later,
  observables and subscriptions.
- Develop in small, reviewable increments. Finish the agreed milestone and stop
  for review; do not implement later milestones speculatively.
- After completing a task or review step, always recommend a concrete next step
  or ask a focused question that helps decide how to proceed. Separate suggested
  follow-up work from work already authorized.
- During reviews, suggest concise additions or corrections to `AGENTS.md` or the
  README when discussion reveals lasting goals, decisions, or workflow changes.
  Distinguish accepted decisions from proposals; do not turn tentative ideas
  into requirements or preserve the conversation as a transcript.
- Current scope includes synchronous value composition, scalar `keepIf`, borrowed
  lazy slice sequences with `filter`/`each`, and explicit collection into caller
  storage or through an allocator, plus synchronous `tap`/`tapWith` effects and
  explicit fail-fast `tryPipe`. Stop for review before adding reactive behavior.
- A formatter, linter, or canonicalizing optimizer is separate future work.

## Long-term direction

- Aim to describe whole systems declaratively: externally pushed inputs,
  transformations, decisions, and explicit effects should be visible in named,
  searchable pipeline stages rather than hidden in unrelated control flow.
- Observables, reducers, subscriptions, and idempotency are future design topics,
  not implemented contracts. A check-then-skip operator alone does not establish
  durable execution; persistence, atomicity, retries, and crash recovery need
  separate designs. Do not promise exactly-once effects.
- Reuse Zig standard-library capabilities and conventions before inventing
  equivalents. In particular use `std.mem.Allocator`, `std.ArrayList`, and
  `std.Io` where appropriate; do not add a universal service context or scheduler.
- Prefer standard readers/writers and existing iterator APIs where they fit.
  Add only the small composition adapters needed by zrx, not parallel stream,
  iterator, or I/O frameworks.

## Public API and contracts

- Aim for declarative code that is pleasant to read and expresses a clear
  sequence of intentions, like natural-language steps. Prefer explicit intent
  over implicit behavior or merely minimizing characters.
- Favor standalone functional calls over method chaining. Normal Zig namespace
  access, field access, and tuple syntax are not prohibited.
- In examples and user-facing pipeline code, alias zrx functions at the top of
  the file (for example `const filter = zrx.filter;`) and use those aliases
  consistently instead of namespace-qualified calls inside pipeline expressions.
- Reuse existing operators before adding helpers or abstractions.
- Support both `map(transform)` and `map(.{ first, second })`. The tuple composes
  left to right and must mean the same thing as consecutive `map` stages.
- Prefer single-item and tuple forms when their meaning is unambiguous, not
  arbitrary ad hoc overloads. Normalize equivalent forms through one internal
  composition rule rather than separate implementations.
- Zig has no ordinary user-defined variadic functions or declaration overloading.
  Express these forms through comptime/type-directed dispatch as appropriate.
- Specify accepted inputs, output types, ordering, and edge cases before
  implementing an operator. Reject empty operator tuples in `pipe`/`tryPipe`
  and empty transformer tuples in `map` at comptime; an empty composition must
  not silently mean identity. A named identity operator may be considered
  separately, but its API is not yet decided.
- Always reject nested operator and transformer tuples. Keep compositions flat;
  express reusable groups through named helper operator functions instead.
- Transformers and predicates are comptime-known functions with one
  explicitly typed runtime parameter and an explicit return type. Generic
  callbacks, function pointers, and callback closures are out of scope. Operator
  instances may carry explicit runtime capabilities or caller-owned state.
- Effect callbacks return `void` or `E!void`: `tap` takes one typed runtime
  parameter, and `tapWith` takes a capability followed by the value. Both forward
  the coerced callback input. Reject other result payloads rather than discard them.
- Follow Zig's normal function argument coercions. Preserve error unions as
  values in `pipe`; only explicit `tryPipe` checks outer error-union boundaries
  and skips later stages on failure. Grouped/separate whole-value maps must stay
  equivalent under either executor. Null and sequence-element errors remain data.
- Validate statically knowable structural and type contracts at comptime.
  Diagnostics should identify the failing stage and expected contract where
  practical. Do not imply arbitrary runtime behavior can be proven at comptime.
- Make allocation, ownership, lifetimes, side effects, and error propagation
  explicit. Do not add hidden allocation or implicit scheduling.
- Keep `map` a whole-value operation even for arrays and slices. `keepIf` returns
  an optional value; it does not silently skip subsequent pipeline stages.
  `filter` and `each` are explicitly elementwise, borrowed, and lazy. `each`
  transforms elements; it is not an eager effect-only iteration operator.
- Sequence sources are slices, pointers to arrays, or zrx views; reject arrays by
  value to avoid returning a view into copied temporary storage. Iteration is
  repeatable, re-reads source storage, and re-executes callbacks.
- Allocation-free views and `collectInto` do not require an allocator. Only
  `collectAlloc(allocator)` allocates output storage; the caller owns and frees
  the returned slice. Keep storage choices explicit rather than using mode flags.
- Effectful operators must receive runtime capabilities such as allocator or Io
  explicitly when needed, rather than inventing implicit global services. Unary
  `tap` can act on state in its input. The pure core requires neither Io nor
  implicit error propagation.
- `tryPipe` provides no rollback or automatic cleanup of owned intermediates;
  keep resource ownership in explicit caller/helper scopes.

## Implementation and performance

- Target exactly Zig 0.17.0, as recorded in `.zigversion`; do not silently upgrade
  the compiler or assume a local version manager reads this file.
- Keep the implementation idiomatic and minimal. Use comptime specialization
  where it serves the contract; let the compiler optimize ordinary calls.
- Do not force all calls inline. Justify optimization with generated-code
  inspection or measurement, and avoid unverified zero-cost claims.

## Validation and documentation

- Keep the README minimal, concise, and human-facing: purpose, status, usage,
  toolchain, validation commands, and license as applicable. Keep agent workflow
  and durable agent-facing design guidance in `AGENTS.md`, not the README.
- With the first implementation, add a reproducible build/test entry point and
  document its exact commands in the README.
- Add tests for valid compositions, type transitions, ordering, and equivalent
  single-item/tuple forms. Add compile-fail tests for invalid contracts.
- Keep the quick native loop in `zig build test`; run `zig build check` before
  considering validation complete. It includes formatting, native tests,
  cross-compilation, and scoped code-generation comparisons.
- Maintain one target/case catalog for cross builds and codegen checks. Compile
  exported runtime-input fixtures that actually instantiate pipelines, not just
  unused generic declarations. Object-only cross builds do not prove foreign
  runtime behavior or support for all Zig targets.
- Codegen checks use the pinned compiler's LLVM backend in ReleaseFast, comparing
  direct code against grouped/separate stages within each applicable target.
  Resolve aliases and compare narrowly normalized IR or scoped AArch64 assembly.
  Preserve instructions, register choices, operands, and order in assembly
  comparisons. Keep nonmatching cases explicitly behavior/cross-only in the
  catalog; do not weaken checks to force equality or claim a general proof of
  semantic equivalence or performance.
- Keep local validation independent of a CI provider. CI integration remains a
  separate follow-up; no foreign runtime or emulator is required for cross checks.
- Keep implemented API examples executable and tested. Clearly label design-only
  snippets as illustrative until implementation exists.
- Format Zig code with the pinned compiler's `zig fmt` and run the documented
  checks. Report the compiler version, checks actually run, and any limitations.
- For documentation-only changes, check links, symlink targets, and whitespace;
  do not claim compilation or test coverage.
