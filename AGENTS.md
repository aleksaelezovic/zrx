# Agent instructions

Canonical agent guidance for zrx. Agent-specific instruction files are symlinks
to this file; edit `AGENTS.md`, not copies.

## Scope and workflow

- zrx is a declaration-only functional/reactive Zig library. Programs describe
  inputs, transformations, decisions, resource lifetimes and terminal effects.
  `run(bindings, flows)` is the only public execution boundary.
- Develop in reviewable increments and stop at agreed review points. Recommend
  a concrete next step after each task. Distinguish accepted design decisions
  from proposals; do not preserve conversations as normative requirements.
  During reviews, suggest concise guidance/doc corrections when lasting goals
  or workflow decisions emerge; keep human-facing README content minimal.
- Public pipelines start from declarations, not raw scalar/slice values.
  `fromValue`, `fromSlice`, borrowed adapters and producer/I/O sources stay cold.
  Selected roots must end with terminal effects returning void or E!void.
- The package is `zrx`, not a separate "world" framework. Do not reintroduce
  public eager value executors, `With` variants, or parallel old/new APIs.
  Keep one implementation and test the current API, not a compatibility facade.
- Explicit execution-boundary operators, worker/queue primitives, writable refs,
  multi-parent state, time windows and dynamic subscriptions are future work.
  Do not introduce them as incidental helpers.
- Durability, idempotency and crash recovery require separate designs;
  a repeatable run does not imply exactly-once effects or durable recovery.
- Formatting/linting/canonicalization tools are separate future work.

## Dependencies and resources

- Exact Zig service types are injection keys in a flat heterogeneous binding
  tuple. Directly supplied allocator and Io are mandatory bootstrap bindings,
  available to callbacks and recipes through the same DI mechanism.
- Callback functions are comptime-known, explicitly typed runtime functions.
  The operator defines the ordinary trailing parameters; every preceding
  parameter is an injected service. Generic callbacks, closures and runtime
  callback pointers are unsupported. The trailing data is never an injection
  request, even if its type matches a binding.
- Map/filter/tap/per-item effects have one trailing item; reductions and scan
  have state and item; collection/batch effects have a read-only slice; producers
  have an emitter; resource acquire has configuration; release has the provided value.
- Repeated requests share one binding. Reject missing reachable requirements,
  duplicate provided types and resource dependency cycles at comptime. Tuple
  order is not acquisition order. Unreachable recipes remain cold.
- Distinguish multiple same-implementation services with nominal role types.
  `deriveResource` currently supports a single-field role wrapper. Do not infer
  arbitrary construction, destruction or ownership from a pointer type.
- A borrowed binding is not destroyed by run. A managed recipe explicitly owns
  its acquired value. Acquire successful resources in dependency order and
  release them in reverse order after execution users stop/join. Include
  release-only dependencies in lifetime planning.
- Failed constructors own their partial cleanup. Release returns void and uses
  non-failing, uncancelable cleanup. Fallible finalization is not a release
  shortcut; successful terminal finalization can fail normally.
- No ambient service globals, universal user context, runtime DI registry or
  per-item service lookup. Inject only the requested types. Static validation
  covers declared requirements, not arbitrary hidden global access.
- Values/dependencies are shallow copies. Keep referents and descriptions stable
  through run. Mutable/address-stable services should carry explicit pointers.
  Escaping work must join before borrowed arguments expire.

## Composition and execution

- Prefer standalone functional calls, with zrx function aliases at the top of
  examples/user-facing code. Normal namespace/type/field access is fine.
- Reuse operators and sources of truth. Normalize single/flat nonempty callback
  tuples through one composition rule. Reject empty/nested operator/callback
  tuples. Named helpers express reusable groups.
- Map/each transform stream items as whole values, including arrays/slices.
  Signal map transforms whole current state. Filter is explicit item selection.
  Tap forwards the item after effects; per-item terminal effects return void.
- Finite reductions are deferred left folds from a shallow seed copy per run.
  Reducers return exactly A or E!A; outer error-union seeds are rejected.
  First operation/reducer error discards partial state, emits a pending error,
  and stops without another input probe or automatic rollback.
- `scan(seed, reducer)` is a deferred serial recurrence with a pure typed
  `fn (services..., A, T) A`, exact nonzero-sized A, no outer error-union state
  or fallible reducer. Leading dependencies follow normal injection; purity
  remains the caller's obligation. Each run starts from a shallow seed copy.
  Emit each accumulated value, not seed or an extra final value; empty emits
  none. Stable references share one recurrence. Publish values, not pointers
  into changing state; borrowed referents must stay valid and unchanged for
  older snapshots. Use `hold(seed)` for sampleable current state.
- Stream operation errors skip success-only stages until explicit handling;
  only unhandled terminal outcomes fail run. `recover` takes a narrow error set
  or anyerror and returns exactly the current success type, non-fallibly.
  Map/filter/tap reject error-set/union item arguments; intentional error data
  belongs in records. Cancellation, source and acquisition failures remain
  control flow, never handler input. Signal map error/optional results remain
  current-state data. No automatic rollback or intermediate destruction.
- `retryPipe` is a cold per-item map/each/tap attempt boundary. Each retry uses
  the original shallow item; stop/exhaustion forwards the last operation error
  through the same pending-error model. Function policies return RetryDecision with ordinary error/count
  suffixes and normal injected prefixes; fixed policy zero attempts fails cold.
  Use run-supplied Io for delays and poll zero-delay retries. Cancellation never
  reaches policy/item data; source failures remain fatal, downstream operations
  can recover but are not retried by this boundary. Stateful,
  filtering, branching and terminal operators stay outside attempts. No automatic
  idempotency, rollback, checkpointing or durable recovery is implied.
- Ordinary synchronous stages form typed direct-call regions. Naming an
  exclusive stage by pointer must not introduce a queue/worker. Resolve runtime
  aliasing before processing; do not add per-stage hot-loop interpreters.
- Pointer address and declaration type determine sharing; by-value descriptions
  are independent. Shared stages evaluate once. New runs instantiate fresh state
  and production, not history replay or reset of borrowed state.
- Producer/shared/merge/retention/signal boundaries retain transport as needed.
  Independent graph roots can run concurrently; synchronous stages in one
  region do not promise independent progress or inter-stage prefetch.
- Reuse std.mem.Allocator, std.ArrayList and std.Io. No new scheduler/framework.
  Allocators and application referents must be safe for their selected concurrent
  use. Do not force inlining or claim general zero overhead without evidence.
- Prepare terminal buffers and graph readers/gated workers before acquisition
  and activation. Cold preparation/startup failure calls no user effects.
  Post-activation producer/merge startup failure may follow peer effects.
- First observed failure cancels peers. Select results before shutdown so cleanup
  cancellation cannot replace success/failure. Stop/join users before freeing
  storage or releasing services. Panics do not promise cleanup/unwinding.
- Cancellation is cooperative. Poll traversal/acquisition; callbacks may use
  cancelable Io. Non-cooperative callbacks can prevent joining.

## Operator lifecycle contracts

- `take(n)` succeeds without an extra probe, zero reads none, selected resources
  still acquire. Prefetch may do extra upstream work. Detach only its edge;
  unused chains retire without stopping live siblings. Pending errors pass
  without spending success-item budget; unobserved errors are not probed for.
- `maxItems(n)` consumes but never forwards the first excess success item,
  emits pending TooManyItems, then ends. Exactly n needs end/excess observation.
  Pending upstream errors pass without spending budget. It is not prefix-taking.
- `takeLast(n)` preallocates a shallow n-item ring and publishes only after
  normal end. Zero still consumes; first operation error discards retention,
  forwards that pending error, and ends. Source/cancellation failures stay fatal.
- `collectThen` lends read-only storage only during successful-end callbacks;
  failure suppresses callbacks and frees accumulation. Retention and collection
  storage are separate.
- `batchThen` preallocates a positive-size buffer, calls full batches serially,
  flushes nonempty partial batches only on success, and discards pending items
  on failure. Earlier effects remain. Zero fails before activation.
- Merge uses separate delivery edges, preserves each edge's order, has unspecified
  interleaving and ends after all normal ends. Pending errors remain outcomes;
  source/control failure stops the merge.
- `branch` uses ordered first-match success `when`/final `otherwise` and explicit
  `whenError(ErrorSet, operators)` cases receiving Failure(ErrorSet) records.
  Cases receive persistent substreams and either all produce one common item
  type or all terminate. Success drops/retirement never swallow observed errors.
  Unmatched/retired error routes remain pending; queue admission is not handling.
  Error reports become normal data at callback/terminal acceptance; reporting
  failures are new failures, not recursive routing. Use discard to explicitly
  ignore failures. Handle raw Failure records before lossy/state operators.
  Predicate/case dependencies use normal DI.
- Signals initialize before activation, commit each single-root family together,
  and publish outside cache locks. Observe initial/every replacement with values;
  sampling emits typed event/current tuples without flattening or state consumption.
- Signal families stay run-scoped after observation delivery retires. Final caches
  remain sampleable after normal update end; active update errors fail idle
  samplers. Snapshots copy values, not pointers to cache slots. Join all users
  before freeing caches; no multi-root transaction or feedback safety is implied.
- Line I/O declares paths/addresses, never opens during construction. Run owns
  selected file/socket handles, not process stdio. Release after users join.
  Successful output includes flushing, not fsync; failed cleanup drops buffering.
  Textual endpoint/path conflicts are rejected; path alias canonicalization and
  shared-writer serialization are not promised.
- Line(n) owns bounded bytes inline. LF is framing; CR/encoding remain data.
  General listeners/full-duplex sessions are separate. No human/network waits in defaults.
- HTTP uses a bounded serial listener/request scope and standard body reader.
  Request/response referents expire at completion, not at run end. Exclusive
  routing and per-item effects track completion; unsupported fan-out, retention,
  collection, batching and state dependencies fail before acquisition. Drops
  close without inventing responses. Handlers own response/error policy.

## Layout, tests, and documentation

- Keep src/root.zig thin. Source-root executors compose declarations; operators
  live in src/ops, declaration types in src/data, I/O in src/io, and private
  planning/execution/runtime in src/internal. Related forms share implementations.
- Exactly Zig 0.17.0, pinned by .zigversion and the build. Format with that compiler.
  Run `zig build test`, ReleaseFast tests, and `zig build check` before completion.
  Report the actual compiler, target, commands, results and limitations.
- Public examples, behavior/contract tests and cross fixtures use the current API.
  Private transport tests may inspect join/retirement schedules without exposing
  another declaration surface. Preserve current lifecycle/fault coverage.
  Compile-fail tests must match the intended diagnostic, not just any failure.
- Keep delivery-receipt assertions and forced internal schedules in private
  lifecycle tests. Public behavior tests assert results, errors and lifetimes,
  not private receipt fields. Error acceptance/retirement is first-decision-wins.
- Small examples remain library-built API demonstrations. Real applications
  belong in `examples/apps/` as independent Zig projects using the local zrx
  package. App-only dependencies stay out of the library manifest/build.
  Follow `examples/apps/README.md`; add apps/CI integration only when authorized.
- Maintain one target/case catalog. Export runtime-input fixtures that instantiate
  actual APIs. Foreign object compilation is not foreign execution.
- Cross compilation and runtime-input inspection are not equality/performance
  proofs. Add scoped codegen comparisons only for actual current APIs; do not
  revive a retired executor to manufacture comparison evidence.
- Measurements are opt-in and include correctness checks, compiler/backend/target,
  workload, capacities, warmups/trials and exclusions. Separate measured time,
  allocator bytes, occupancy and structural task/queue estimates. Instrumentation
  must be concurrency-safe when accessed concurrently. No default timing thresholds.
- Keep README minimal and human-facing. Contracts belong beside source APIs;
  docs index them and explain cross-cutting lifecycle. Keep examples executable
  and put fixture/assertion machinery under tests. Label design-only snippets.
- Documentation-only changes get link, symlink-target and whitespace checks,
  not compilation claims.
