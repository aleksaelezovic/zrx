# zrx

A functional reactive library for Zig, with declarative pipelines and comptime-checked composition.

zrx aims to make data transformations and reactive flows explicit and composable,
using standalone functions and operators rather than method chaining. Clear
contracts and compiler diagnostics should guide both humans and AI agents toward
correct usage.

**Status:** Repository setup and API design only. No library implementation yet.

## Design principles

- Small, orthogonal primitives; reuse operators before introducing new ones.
- Validate types and structural contracts at comptime wherever possible. Runtime
  conditions still require runtime handling.
- Support readable single-item and tuple forms where they have unambiguous,
  equivalent semantics, backed by one internal composition rule.
- Make allocation, ownership, lifetimes, and error propagation explicit.
- Specialize with comptime where useful and let Zig optimize ordinary calls.
  Forced inlining and performance claims require evidence.

## Intended API

Illustrative syntax, not executable examples or a finalized operator contract:

```zig
pipe(value, .{
    map(double),
})

pipe(value, .{
    map(.{ double, increment }),
})
```

`map(transform)` accepts one transformer. `map(.{ first, second })` composes
transformers sequentially, left to right: `second(first(value))`. It is shorthand
for consecutive `map` stages, not fan-out. Each output must satisfy the next
transformer's input contract.

## Development sequence

Work proceeds in small steps, with review between milestones:

1. Define and implement synchronous value pipelines with `pipe` and both `map`
   forms, including tests for valid usage and compile-time rejection.
2. Decide filtering and sequence semantics before introducing `filter`.
3. Introduce observables and subscriptions, starting with synchronous behavior
   and explicit cancellation and lifetime contracts.

A formatter, linter, or canonicalizing optimizer is a separate future scope.
Equivalent public forms should normalize internally; no source-rewriting tool is
part of the initial library.

## Toolchain and license

Target Zig **0.17.0**, recorded in [`.zigversion`](.zigversion).
Build configuration, executable examples, and test commands will arrive with the
first implementation milestone.

Licensed under the [MIT License](LICENSE).
