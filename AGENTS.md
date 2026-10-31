# Agent instructions

This is the canonical agent instruction file for zrx. Agent-specific instruction
files, including `.github/copilot-instructions.md`, are symlinks to this file;
edit `AGENTS.md` rather than maintaining copies.

## Scope and review loop

- zrx is a Zig library for declarative functional pipelines, event-stream graphs,
  and run-owned replacement/derived signal state.
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
  lazy slice sequences with `filter`/`each`, finite `fold`/`tryFold` reduction,
  deferred streaming accumulation with `scan`, synchronous `tap`/`tapWith` effects and
  explicit fail-fast `tryPipe`, plus declarative producer-backed streams and
  grouped `run` execution with automatic reader/result sharing, deferred terminal
  effects and scoped collection callbacks, optional `maxItems` guards, successful
  `take` prefix completion with stream-edge retirement,
  run-owned `takeLast` suffix retention, declarative fan-in with `merge`,
  callback-scoped count batching with `batchThen`/`batchThenWith`, and replacement
  signals with `hold`, `values`, `withLatestFrom`, and single-parent signal `map`.
  High-level bounded line I/O includes stdin/stdout/stderr, path-based file
  input/output, and outgoing receive-only TCP, with run-owned acquire/release
  and terminal finalization. Listeners and full-duplex sessions remain separate.
  Stop for review before adding writable refs, multi-parent state, time windows,
  or further reactive behavior.
- A formatter, linter, or canonicalizing optimizer is separate future work.

## Long-term direction

- Aim to describe whole systems declaratively: externally pushed inputs,
  transformations, decisions, and explicit effects should be visible in named,
  searchable pipeline stages rather than hidden in unrelated control flow.
- Treat multi-pipe programs activated by one `run` as the design target.
  Validate external-I/O abstractions with small terminal, filesystem, and network
  programs; keep domain decisions in named stages, not hidden in adapter loops.
- Writable refs, reducer-backed signal constructors, and dynamic subscriptions
  remain future design topics, not implemented contracts.
- Idempotency and durable workflows are a priority for future design, not
  implemented contracts. A check-then-skip operator alone does not establish
  durable execution; persistence, atomicity, retries, and crash recovery need
  separate designs. Do not promise exactly-once effects.
- Reuse Zig standard-library capabilities and conventions before inventing
  equivalents. In particular use `std.mem.Allocator`, `std.ArrayList`, and
  `std.Io` where appropriate; do not add a universal service context or scheduler.
- Prefer standard readers/writers and existing iterator APIs where they fit.
  Add only the small composition adapters needed by zrx, not parallel stream,
  iterator, or I/O frameworks.
- Prefer high-level I/O declarations taking paths, standard-library addresses,
  and explicit options; run should instantiate and manage their resources.
  Borrowed-handle primitives are secondary interoperability, not required setup
  for the default user-facing API.

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
- Reduction callbacks take typed state and element parameters. `fold` requires
  `fn (A, T) A`; `tryFold` requires `fn (A, T) E!A`. Require an exact state result
  type and reject outer error-union accumulator types. Both are eager left folds
  starting from a shallow copy of the stored seed on each application.
- Eager folds consume finite infallible cursors, not run-backed graphs or
  fallible source cursors. A borrowed standard iterator resumes its shared
  position; do not promise slice-style replay for consuming adapters.
- `tryFold` stops at the first reducer error under either executor, without an
  extra cursor probe, cleanup, or rollback. `tryPipe` only checks the completed
  reduction's outer result; it does not supply per-item short-circuiting.
- `scan(seed, reducer)` is a run-backed serial recurrence over sequence inputs,
  even finite ones. Require one pure typed `fn (A, T) A`, exact nonzero-sized A,
  and no outer error-union accumulator or fallible reducer. Each run starts from
  a shallow seed copy and emits each accumulated value, not seed or an extra
  final value; empty input emits none. Stable references share one recurrence.
  Publish values, never pointers into changing accumulator storage; borrowed
  referents must stay valid and unchanged for older snapshots too. Use existing
  `hold(seed)` for current state. `scanWith` and fallible scan remain future work.
- Follow Zig's normal function argument coercions. Preserve error unions as
  values in `pipe`; explicit `tryPipe` checks pipeline-stage error-union boundaries
  and skips later stages on failure. Grouped/separate whole-value maps must stay
  equivalent under either executor. Null and sequence-element errors remain data.
- Validate statically knowable structural and type contracts at comptime.
  Diagnostics should identify the failing stage and expected contract where
  practical. Do not imply arbitrary runtime behavior can be proven at comptime.
- Make allocation, ownership, lifetimes, side effects, and error propagation
  explicit. Source/graph declarations must not require allocator or Io by
  default, allocate, start work, or own cleanup. `run(allocator, io, flows)` is
  the explicit allocation, activation, cancellation, and cleanup boundary.
- Public `Stream(T)` is a producer declaration, not a live queue owner.
  Producers receive a call-scoped `Emitter(T)` with push and execution-time
  allocator/Io; return closes output. `fromProducerWith` borrows a typed
  single-item capability pointer. Keep capability referents alive through run.
  Queue/reader/tee/share ownership mechanisms remain internal and tested.
- Reference the same stable source/derived declaration by pointer to share its
  execution node within one run. By-value copies are independent descriptions.
  Each run instantiates fresh transport and calls producers again; it does not
  replay history or reset borrowed application state.
- `merge(inputs)` is a resource-free declaration over a nonempty flat tuple of
  same-item-type inputs; use `each` for explicit conversions. Run owns its input
  readers, capacity-one output, and forwarding group. Preserve each input edge's
  order with unspecified interleaving; end only after all inputs end normally.
  Fail fast on input error and preserve the first observed failure. Repeated
  references are distinct delivery edges, not duplicate producer activations.
- Keep `map` a whole-value operation even for arrays and slices. `keepIf` returns
  an optional value; it does not silently skip subsequent pipeline stages.
  `filter` and `each` are explicitly elementwise, borrowed, and lazy. `each`
  transforms elements; it is not an eager effect-only iteration operator.
- Borrowed slice-sequence sources are slices, pointers to arrays, or zrx views;
  reject arrays by value to avoid returning a view into copied temporary storage.
  Iteration is repeatable, re-reads source storage, and re-executes callbacks.
- Stream-backed `each`/`filter`/`maxItems`/`take` describe work for `run`. All public
  terminal `forEach`/`collectThen`/`batchThen` operators and their `With` variants
  are deferred, for finite inputs and streams alike. Pure whole-value composition
  and borrowed cursor mechanics remain separate; direct stream iteration is unsupported.
- `collectThen` callbacks borrow `[]const T` after successful end; run-supplied
  storage is freed after the callback, including on callback failure. Do not call
  them for source error, cancellation, or accumulation failure. Capability-backed
  retention must make an explicitly application-owned copy. The old public
  `collectInto`/`collectAlloc` APIs are retired; eager helpers are test-only.
- `maxItems(n)` validates output count at its position: consume but never forward
  the first excess item, then fail with `TooManyItems`. Exactly n items still
  requires end/excess observation. It is not prefix-taking, retention, batching,
  or a lossy queue policy.
- `take(n)` forwards at most n items, then ends successfully without an extra
  input probe. Zero reads none; normal selected-resource acquisition still
  applies. Finite views stay lazy; consuming iterators resume. Stream completion
  detaches only its edge, retiring unused producer/input chains without blocking
  live siblings. Prefetch can do extra upstream work; observed errors/other live
  dependencies still fail run. Signal caches/updaters remain run-scoped, even
  after their observation delivery retires. Flush/partial batches/suffixes use
  normal successful-end semantics. Do not turn cutoff into a count-limit error.
- `takeLast(n)` preallocates a run-owned n-item ring, consumes the full input,
  and publishes the retained suffix in source order only after successful end.
  Zero still consumes and observes errors; failure/cancellation discards pending
  retention. Items are shallow and overwriting does not infer destructors. The
  ring and `collectThen` storage are separate. Lossy live delivery remains
  future work.
- `batchThen(size, effect)` and `batchThenWith(size, capability, effect)` preallocate
  a positive-size run-owned buffer before activation. Invoke callbacks serially
  for full batches while input is open; flush a nonempty partial batch only on
  successful end. Empty input invokes none. Errors/cancellation discard pending
  items without rolling back earlier effects. Zero returns `InvalidBatchSize`
  before activation. Callbacks borrow read-only slices only during their calls;
  reuse storage afterward and free prepared buffers after consumer tasks join,
  including on preparation/startup failure. Batch-producing streams and timed
  flushing remain separate work.
- `hold(initial)` creates a signal declaration from replacement inputs. Signal
  `map` is deferred and whole-current-value; ordinary maps stay whole-value and
  stream `each` stays elementwise. Use `values(signal)` for terminal observation,
  including initial state and every replacement/equal derived result. No implicit
  equality or coalescing is applied. `withLatestFrom` emits normal typed tuples
  .{ event, currentValue }, with no flattening and no state consumption.
- Run initializes state before activation, computes pure single-parent derived
  candidates outside locks, and commits one root family together. Do not hold
  cache locks during effects or publication. Source errors fail active runs even
  when sampled event inputs are idle; error/optional state remains data under
  `pipe` and `tryPipe`. Completion has a first-result boundary so shutdown
  cancellation cannot turn successful terminal completion into failure.
- Signal dependencies are run-scoped, not per-branch retired. Final caches remain
  sampleable after normal update end until run cleanup. Stop/join updaters and
  all stream/sampling work before freeing caches. Snapshots copy shallow T, not
  pointers to live cache slots; referents must remain stable for older queued
  snapshots too. No setters/getters, feedback safety, global transactions, or
  multi-root atomic sampling are implied.
- Effectful operators must receive runtime capabilities explicitly when needed,
  rather than inventing implicit global services. Producer callbacks may use
  their emitter's run-supplied allocator/Io; domain services remain explicit
  capabilities, not a universal execution context. Unary `tap` can act on state
  in its input. The pure core requires neither Io nor
  implicit error propagation.
- `tryPipe` provides no rollback or automatic cleanup of owned intermediates;
  keep resource ownership in explicit caller/helper scopes.
- Line I/O declares configuration, never open handles. Run acquires selected
  endpoints after preparation/gated worker startup and closes owned resources
  only after work joins. Successful line output includes flushing, not fsync;
  failure/cancellation drops pending buffering without rollback. Process stdio
  handles are not owned. Reject duplicate standard endpoints/textual file
  conflicts; do not claim path canonicalization or shared-writer serialization.
- `Line(n)` stores bounded bytes inline so fan-out/retention/collection cannot
  borrow a reusable read buffer. LF is framing; CR/encoding remain data.
  High-level live-I/O executables are opt-in, never human/network waits in the
  default checks. Test their actual graphs with finite fixtures/loopback peers.

## Implementation and performance

- Keep `src/root.zig` a thin public export list. Put named executors at the
  source root, operator implementations in `src/ops/`, declaration/cursor types
  in `src/data/`, standard I/O glue in `src/io/`, and shared/private machinery
  in `src/internal/`, grouping live execution machinery in
  `src/internal/runtime/`. Do not create operator-named wrappers around an
  unrelated monolith; related forms should share one implementation.
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
- Keep local validation independent of a CI provider. GitHub Actions is a thin
  Linux wrapper around the documented checks; no foreign runtime or emulator is
  required for cross checks. Do not duplicate the target catalog in CI.
- Keep implemented API examples executable and tested. Clearly label design-only
  snippets as illustrative until implementation exists.
- Keep examples focused on entry points, reusable composition, and named stages.
  Put example integration tests/fixtures under `tests/`, importing the same
  composition functions, and retain executable smoke checks for entry points.
- Keep API contracts in source doc comments beside their declarations and
  usage in tested examples. `docs/README.md` indexes them; retain Markdown guides
  for cross-cutting lifecycle/design context, not duplicated API prose or partial
  example copies. Merge/remove nearly empty topic files and superseded proposals
  after preserving accepted decisions. Private cursor/transport fixtures are not
  public API examples: retain their lifecycle coverage when cleaning up retired
  ownership APIs.
- Format Zig code with the pinned compiler's `zig fmt` and run the documented
  checks. Report the compiler version, checks actually run, and any limitations.
- For documentation-only changes, check links, symlink targets, and whitespace;
  do not claim compilation or test coverage.
