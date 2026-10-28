# Agent instructions

This is the canonical agent instruction file for zrx. Agent-specific instruction
files are symlinks to this file; edit this file rather than maintaining copies.

## Scope and review loop

- zrx is a Zig library for declarative functional pipelines and, later,
  observables and subscriptions.
- Develop in small, reviewable increments. Finish the agreed milestone and stop
  for review; do not implement later milestones speculatively.
- Current scope is repository setup and API design only. No library code, build
  scaffolding, or tooling is required for this milestone.
- Next comes synchronous value composition with `pipe` and `map`. Filtering and
  reactive semantics need their own design review.
- A formatter, linter, or canonicalizing optimizer is separate future work.

## Public API and contracts

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
  implementing an operator. Decide empty and nested tuple behavior explicitly.
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

- With the first implementation, add a reproducible build/test entry point and
  document its exact commands in the README.
- Add tests for valid compositions, type transitions, ordering, and equivalent
  single-item/tuple forms. Add compile-fail tests for invalid contracts.
- Keep implemented API examples executable and tested. Clearly label design-only
  snippets as illustrative until implementation exists.
- Format Zig code with the pinned compiler's `zig fmt` and run the documented
  checks. Report the compiler version, checks actually run, and any limitations.
- For documentation-only changes, check links, symlink targets, and whitespace;
  do not claim compilation or test coverage.
