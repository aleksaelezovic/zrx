# Agent instructions

Canonical agent guidance for zrx. Agent-specific instruction files are symlinks
to this file; edit `AGENTS.md`, not copies.

## Scope and workflow

- zrx is a declarative push-stream library for Zig with type-keyed dependency
  injection. A system is several programs; a program is one source and one
  terminated pipe; a pipe is a composition of operators; operators take
  handlers. `program.run(deps)` and `system.run(deps)` are the only execution
  boundaries. [docs/guide.md](docs/guide.md) is the user-facing reference.
- Develop in reviewable increments and stop at agreed review points. Recommend
  a concrete next step after each task. Distinguish accepted design decisions
  from proposals. Keep human-facing README content minimal; put detail in the guide.
- One way to write each thing. Before adding an operator, option or accepted
  form, check that it cannot already be written with what exists; if it can,
  do not add a second spelling. Prefer rejecting an ambiguous form with a
  compile error that says what to write instead.
- Build from core principles upward: new behavior is composed from the
  operator, source and handler contracts, not special-cased in the core.
  `src/pipe.zig` (chain), `src/di.zig` (injection) and `src/program.zig` stay
  small and know nothing about individual operators.
- The feature set of the previous implementation is an upper bound, not a
  backlog. HTTP, signals, retry and the standalone apps were dropped in the
  rewrite and return only by explicit decision.
- Exactly Zig 0.17.0 (`.zigversion`). Reuse `std.Io`, `std.mem.Allocator` and
  std containers; no scheduler or runtime of our own.

## Design decisions

- **Push with a flow answer.** `down.push(item)` returns `E!Flow` (`.more` or
  `.done`). Early stop is a value, never an error. A stage that answered
  `.done` may still be pushed to and keeps answering `.done`.
- **Operators are values; state is separate.** An operator declares
  `Out(Env, In)`, `Stage(Env, In)` and optionally `Provides(Env)`. All checks
  happen in `Out`, which runs for the whole pipeline before any stage type is
  built. A pipe is an operator; nesting is associative, including for `provide`.
- **Dependencies are resolved once.** The environment is a tuple keyed by exact
  type. A stage copies what its handler asked for at `init`; nothing is looked
  up per item. `std.Io` and the allocator are ordinary dependencies.
  `provide` and `resource` extend the environment for what follows; a value of
  an already-present type shadows it. Sub-pipes of `branch` and `route` scope
  their own provisions.
- **Handlers** are comptime-known functions: leading parameters are
  dependencies, trailing parameters are the operator's data and may be
  `anytype`. Composite handlers (`all`, `compose`, ...) are struct types that
  forward their children's requirements. No closures, no runtime function pointers.
- **Errors are Zig errors.** A handler error fails the run after teardown.
  `recover(handler)` guards the operators after it per item; its error
  parameter type selects what it handles; `error.Canceled` is never handled;
  errors during finish, or beyond a `queue`, are not item errors. No error lane,
  no rollback.
- **`queue` is the only task boundary.** `branch` is terminal direct fan-out and
  `route` is exclusive direct dispatch; either becomes concurrent only through
  a queue in a sub-pipe. A rejoining route case must not contain a queue.
  `system` and `merge` use `tasks.all`: `Io.async`, fail fast, cancel the rest.
- **Lifecycle.** `init` in order, `start` in reverse, pushes, then on a normal
  end `finish` in order and `flush` in reverse; always `deinit` in reverse.
  Whoever owns a writer flushes it. `release` cannot fail.
- **Programs must terminate.** `program` takes a source and a `pipe(...)`;
  `branch`, `when` and `otherwise` take `pipe(...)` too, never a bare operator.

## Zero overhead

- Claim only what is checked. `zig build zero-overhead` compares optimized LLVM
  IR of pipelines and hand-written loops (`tests/zero_overhead`,
  `tools/same_code.zig`). When adding or changing a synchronous operator, add
  or extend a fixture; a new fixture is `same_*` unless the difference is only
  loop shape, then `lean_*` with the reason in a comment.
- Do not force inlining. Keep stages free of hidden memory: return
  `down.push(x)` directly or compare its result and return a constant; never
  store a `Flow` and later select between it and a constant (it defeats the
  optimizer; `lean_take` exists because of this).
- `queue` costs a real buffer and a task; say so rather than hiding it.

## Diagnostics

- Every misuse a user can plausibly write gets a `@compileError` that names the
  operator, states what was found, and says what to write instead. Each has a
  case in `tests/compile_fail/` with its exact message in
  `tests/compile_fail.zig`. Checks inside runtime functions need `comptime`
  (`if (comptime !ok) @compileError(...)`).
- Comptime entry points raise the branch quota with
  `@setEvalBranchQuota(di.quota)`; new reflection-heavy functions do the same.

## Tests and examples

- Suites in `tests/` import only the public `zrx` module, one file per area.
  `tests/extending.zig` keeps the public operator, source and handler contracts
  (and the guide's example) honest.
- Examples are small, use function aliases at the top (`const map = zrx.map;`),
  and have their exact output asserted in `build.zig`.
- In examples, apps and documentation, write a pipe with one operator per line
  (end the tuple with a trailing comma so `zig fmt` keeps it that way), and do
  the same for the sub-pipes of `branch` and the cases of `route`. A pipe with
  a single operator stays on one line. Name sub-pipes rather than nesting
  multi-line pipes deeply. Tests may keep short pipes on one line.
- `zig build test` must pass in Debug and ReleaseFast; `zig build check` adds
  formatting and the cross-target catalog (the core must compile freestanding).
- Tests that need concurrency use `std.testing.io` and must not depend on
  timing or scheduling order for their assertions.
