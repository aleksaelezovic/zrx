# Agent instructions

Canonical agent guidance for zrx. Agent-specific instruction files are symlinks
to this file; edit `AGENTS.md`, not copies.

## Scope and workflow

- zrx is a declarative push-stream library for Zig with type-keyed dependency
  injection. A program is one source and one terminated pipe; a pipe is a
  composition of operators; operators take handlers. `program.run(deps)` is the
  only execution boundary. [docs/guide.md](docs/guide.md) is the user-facing
  reference.
- **The library is a minimal core on purpose, and stays one.** One synchronous
  loop; operators that are a single stage and own nothing; no task, no owned
  resource, no I/O helper. It was cut back to this after the concurrency work
  went too broad and too fast to review. The guide's "Not here" section lists
  what was removed.
- **Nothing returns without an explicit decision, and then one piece at a
  time**, each as its own small change with its tests and its zero-overhead
  fixture. Do not add a feature because a task would be easier with it.
- **Do not answer a review finding by adding a component.** A finding is
  either a defect in what exists (fix it there), something `std` or the
  compiler does (say so in the guide, change nothing), or a wish (leave it).
  Do not wrap or re-implement `std` facilities to change their behaviour.
- Develop in reviewable increments and stop at agreed review points. Recommend
  a concrete next step after each task. Distinguish accepted design decisions
  from proposals. Keep human-facing README content minimal; put detail in the
  guide, and keep the guide short: a sentence nobody tests is a sentence that
  will be wrong.
- One way to write each thing. Before adding an operator, option or accepted
  form, check that it cannot already be written with what exists; if it can,
  do not add a second spelling. Prefer rejecting an ambiguous form with a
  compile error that says what to write instead.
- `src/pipe.zig` (chain), `src/di.zig` (injection) and `src/program.zig` stay
  small and know nothing about individual operators.
- Exactly Zig 0.17.0 (`.zigversion`). Reuse std; no scheduler or runtime of our
  own.

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
  up per item. `provide` extends the environment for what follows; a value of
  an already-present type shadows it.
- **Handlers** are comptime-known functions: leading parameters are
  dependencies, trailing parameters are the operator's data and may be
  `anytype`. No closures, no runtime function pointers.
- **Errors are Zig errors.** A handler error fails the run. Nothing in a pipe
  handles one.
- **Lifecycle.** `init` in order, pushes, then on a normal end `finish` in
  order. No other hook exists: no stage owns anything, so nothing is torn
  down. A hook returns with the first operator that needs it.
- **Programs must terminate.** `program` takes a source and a `pipe(...)`.

## Zero overhead

- Claim only what is checked. `zig build zero-overhead` compares optimized LLVM
  IR of pipelines and hand-written loops (`tests/zero_overhead`,
  `tools/same_code.zig`). Every operator is in a fixture; an operator without
  one does not go in. A new fixture is `same_*` unless the difference is only
  loop shape, then `lean_*` with the reason in a comment.
- Do not force inlining. Keep stages free of hidden memory: return
  `down.push(x)` directly or compare its result and return a constant; never
  store a `Flow` and later select between it and a constant (it defeats the
  optimizer; `lean_take` exists because of this).
- Each stage of a program is its own local (`Chain.withLocals`); nested pipes
  are spliced so this holds for them too.
- `tools/same_code.zig` compares instruction shape: the multiset of
  instructions with value and block names erased, phi inputs in any order, and
  `> c` equal to `>= c + 1`. Nothing else is equated; a comparison never
  matches its negation. Say "the same instructions" for a `same_*` fixture,
  not "the same program": wiring is not compared, `behavior.zig` covers
  results. The tool has tests of its own. Do not widen it to make a fixture pass.

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
  `tests/extending.zig` keeps the public operator and source contracts (and
  the guide's example) honest.
- Examples are small, use function aliases at the top (`const map = zrx.map;`),
  and have their exact output asserted in `build.zig`.
- In examples and documentation, write a pipe with one operator per line (end
  the tuple with a trailing comma so `zig fmt` keeps it that way). A pipe with
  a single operator stays on one line. Tests may keep short pipes on one line.
- `zig build test` must pass in Debug and ReleaseFast; `zig build check` adds
  formatting and the cross-target catalog (everything must compile
  freestanding).
