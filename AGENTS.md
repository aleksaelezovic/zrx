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
- Current scope is synchronous value composition with `pipe` and both `map`
  forms, with executable examples, unit tests, and compile-fail tests. Filtering
  and reactive semantics need their own design review.
- A formatter, linter, or canonicalizing optimizer is separate future work.

## Public API and contracts

- Aim for declarative code that is pleasant to read and expresses a clear
  sequence of intentions, like natural-language steps. Prefer explicit intent
  over implicit behavior or merely minimizing characters.
- Favor standalone functional calls over method chaining. Normal Zig namespace
  access, field access, and tuple syntax are not prohibited.
- Reuse existing operators before adding helpers or abstractions.
- Support both `map(transform)` and `map(.{ first, second })`. The tuple composes
  left to right and must mean the same thing as consecutive `map` stages.
- Prefer single-item and tuple forms when their meaning is unambiguous, not
  arbitrary ad hoc overloads. Normalize equivalent forms through one internal
  composition rule rather than separate implementations.
- Zig has no ordinary user-defined variadic functions or declaration overloading.
  Express these forms through comptime/type-directed dispatch as appropriate.
- Specify accepted inputs, output types, ordering, and edge cases before
  implementing an operator. Reject empty operator tuples in `pipe` and empty
  transformer tuples in `map` at comptime; an empty composition must not silently
  mean identity. A named identity operator may be considered separately, but its
  API is not yet decided.
- Always reject nested operator and transformer tuples. Keep compositions flat;
  express reusable groups through named helper operator functions instead.
- For this milestone, transformers are comptime-known functions with one
  explicitly typed runtime parameter and an explicit return type. Generic
  transformers, function pointers, and captured runtime state are out of scope.
- Follow Zig's normal function argument coercions. Preserve error unions as
  values; do not implicitly unwrap them or propagate errors.
- Validate statically knowable structural and type contracts at comptime.
  Diagnostics should identify the failing stage and expected contract where
  practical. Do not imply arbitrary runtime behavior can be proven at comptime.
- Make allocation, ownership, lifetimes, side effects, and error propagation
  explicit. Do not add hidden allocation or implicit scheduling.

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
  direct calls against both map forms within each target. Resolve aliases and
  compare narrowly normalized function bodies; do not compare whole binaries or
  treat a match as a general proof of semantic equivalence or performance.
- Keep local validation independent of a CI provider. CI integration remains a
  separate follow-up; no foreign runtime or emulator is required for cross checks.
- Keep implemented API examples executable and tested. Clearly label design-only
  snippets as illustrative until implementation exists.
- Format Zig code with the pinned compiler's `zig fmt` and run the documented
  checks. Report the compiler version, checks actually run, and any limitations.
- For documentation-only changes, check links, symlink targets, and whitespace;
  do not claim compilation or test coverage.
