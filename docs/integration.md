# Declaration-runtime integration handoff

Status: track 5 implementation and measurement work is frozen for integration
review. No commit, push or landing onto a shared branch was performed here.
This is a handoff checklist, not a second API specification.

## Source and transfer

- Source thread: [5 - Measurement and developer tooling](delta://thread/ksQQ1WGCFVMmQfKeOD6sXwmq2JLOAAtK4pIBxBDX6SG4hCRLX7nFizx94PwY).
- Destination: [original project thread](delta://thread/ksQQ1WGCFVMmQfKeOD6sXwmq2JLOAAZKdJIBxBDX6SG4hCRLX7nFizx94PwY).
- Git base remains `39ac0c2998e1a65a18a8f7692909f5276e28ff64`; the complete
  implementation is worktree changes, including new/untracked source files.
  A tracked-only `git diff` is **not** a complete handoff.
- Pull this related thread's whole worktree from the destination thread. Do not
  cherry-pick only benchmarks, overwrite the destination checkout, or discard
  destination edits to make the import appear clean.
- Only track 2 was previously imported here. No parent/other sibling changes
  were automatically pulled. The parent's separately integrated scan change
  (`fa15652`) is not part of this source snapshot.
- Worktree transfer does not copy conversation history; this document, current
  guides, [migration record](history/execution_migration.md) and measurement
  records preserve the relevant context.

The user approved consolidation/transfer for integration. That is not approval
to commit, push or merge to `main`. If the transfer conflicts, reconcile in the
destination, preserving both accepted behaviors, then rerun validation there.

## Intentional breaking changes

Current public contracts are in [execution.md](execution.md), source APIs and the
[current examples](README.md#executable-examples):

- One package, `zrx`; one execution boundary, `run(bindings, flows)`. Inputs and
  pipelines are cold declarations; selected roots must end with `void`/`E!void`
  terminal effects. Intermediate declarations can still produce values.
- No public eager value executors, `With` variants, `tryPipe` or `tryFold`.
  The user explicitly accepted those removals.
- Callbacks are comptime-known typed functions. Every leading parameter is an
  exact-type injected service; the operator's ordinary suffix is always data.
  Flat nonempty callback/operator tuples share one composition rule.
- A flat binding tuple supplies borrowed values or explicit managed recipes.
  Allocator/Io are required direct bootstrap values and ordinary injectable
  services. Missing reachable services, duplicates and cycles fail at comptime.
- Recipe dependencies, including release-only dependencies, determine acquisition
  order. Successful services release in reverse order after users stop/join.
  Failed acquire owns its partial cleanup. Release is void/non-failing/
  uncancelable; borrowed bindings are not destroyed.
- Nominal single-field roles plus `deriveResource` distinguish services such as
  two database instances. There is no arbitrary pointer-ownership inference.
- Exclusive synchronous regions lower to typed loops, including named stages.
  A pre-execution address/type alias scan preserves actual sharing; no per-stage
  hot-loop interpreter. Producer/shared/merge/retention/state boundaries retain
  transport/lifetime machinery.
- Stream callback outer errors fail run; signal-map error/optional results stay
  current-state data. No rollback, panic unwinding or durable recovery promise.

“World” survives only in private identifiers/test names/diagnostic prefixes.
There is no public world package. Avoid a cosmetic mass rename while integrating.

## Review map

| Area | Main files and evidence |
|---|---|
| Public surface/composition | `src/root.zig`, `src/compose.zig`, `src/data/declarations.zig`, `src/ops/effects.zig` |
| Typed callbacks and services | `src/internal/callbacks.zig`, `src/internal/world/`, `tests/world.zig`, `tests/compile_fail/world_*.zig` |
| Execution/lowering | `src/run.zig`, `src/internal/execution/`, `src/internal/graph_run.zig`, `tests/declarative_graphs.zig` |
| Retained coordinator integration | `src/io/lines.zig`, private signal-cell binding in `src/internal/runtime/signals.zig`, shared terminal consumer adaptation |
| Lifecycle preservation | `tests/lifecycle_hardening.zig`, `tests/join_retirement.zig`, imported branching/take/I/O regressions |
| Current programs | `examples/resources.zig`, `examples/streams.zig`, `examples/signals.zig`, `examples/io_file.zig` |
| Private regression evidence | `src/legacy_test_api.zig`, `src/runtime_test_api.zig`, `tests/legacy_examples/`; not a compatibility promise |
| Measurement tools | `benchmarks/`, `src/benchmark_api.zig`, `tests/measurement.zig`, `tests/phase_observation.zig`, `tests/phase_erasure.zig` |
| Build/catalog | `build.zig`, package paths in `build.zig.zon`, current public object fixtures in the existing `tests/codegen/catalog.zig` |

The original strict kernel comparisons/normalization were not weakened. The
catalog remains the single cross-target/case source. New current-API cross
fixtures instantiate APIs but do not establish imperative body equality.

## Sibling reconciliation order and risks

1. **Bring in this coherent foundation first.** Review the new run/callback/
   resource contracts, canonical guidance and archived/current separation.
2. **Preserve/adapt the parent's scan work.** Check public export, operator/
   declaration metadata, callback dependency inference, signal initialization,
   error-as-state rules, native tests, cross fixtures and docs. Passing this
   source's checks does not validate the combined scan implementation.
3. **Adapt tracks 1 and 3 to that integrated foundation.** Read their final
   accepted decisions and actual source; do not treat early design snippets
   using eager executors, `With` callbacks or the old run signature as current.
   Port behavior/tests rather than resurrecting the old public surface.
4. **Reconcile shared files deliberately:** `AGENTS.md`, root/docs indexes,
   `build.zig`, public exports, execution/state/I/O guides and cross fixtures are
   likely overlap points. Keep canonical instruction symlinks intact.
5. **Validate the combined revision before more performance changes.** Old
   timings retain their exact source baselines, not the merged revision's label.

`docs/proposals/` was removed **from this track**: implemented material now lives
in current guides or `docs/history/`/`docs/measurements/`, and superseded lowering
sketches were deleted. Do not delete genuinely pending sibling designs merely
because their directory has the same old name. Promote accepted/implemented
material and remove superseded text during its own integration review.

Track 2 was merged cleanly at captured causal version
`c51a1e93-38c8-4690-90de-59239000df07.753188`. Its full source transcript was read;
it reproduced no runtime bug and contributed the audit plus four regressions.
Later deterministic join/retirement and public lifecycle schedules strengthen
that evidence. No need to pull track 2 separately or infer that an audit finding
required this redesign.

## Validation and limitations

Source host/toolchain: exactly Zig **0.17.0**, macOS ARM64,
`aarch64-macos.27.0.1...27.0.1-none`. Native benchmarks/inspection use LLVM
ReleaseFast, CPU `apple_a14`; Debug and ReleaseFast behavior suites are separate.
Final source validation:

```sh
zig version
zig fmt --check build.zig build.zig.zon src tests examples benchmarks
zig build declarative-test
zig build lifecycle-test
zig build measurement-test
zig build test
zig build test -Doptimize=ReleaseFast
zig build check
zig build example
zig build io-examples
```

Benchmark drivers smoke-ran previously, with every work/hash check passing.
No new timing dataset was collected during consolidation. Final consolidation
also ran actual `copy-lines` with finite LF-terminated files and exact `cmp`;
repeat that workflow after integration. Documentation link/anchor, instruction
symlink-target and whitespace checks cover the moved records too.

This validation is **source-snapshot evidence**, not an assertion that a future
worktree import is conflict-free or that the combined sibling state passes.
Foreign object compilation is not foreign runtime execution. No race detector,
exhaustive scheduler exploration, total RSS/occupied-payload measurement or
universal zero-cost proof. Non-cooperative callbacks can prevent joining.

## Resume later

The [performance roadmap](performance.md) is the single next-investigation plan:
integrated reference → existing capacity sweep → active-cost attribution → one
evidenced mechanism → semantic, codegen, resource and elapsed validation.
The [measurement index](measurements/README.md) retains raw results, snapshots,
compiler configuration and exclusions. No further performance implementation,
worker/boundary primitive or broad profiling framework is part of this handoff.

## Original-thread reconciliation

The original thread imported the whole frozen worktree at causal version
`42ecebbe-dc7e-42a4-bc28-8e8e67520480.985229`, onto parent Git base
`fa15652a561e0165387b8340775f2bc01cb8abdb`. This includes new/untracked files,
not only the tracked diff. Track 1 and track 3 were not imported. No commit,
push or shared-branch landing was performed.

The transfer reported conflicts in `AGENTS.md`, `README.md`, `docs/README.md`,
`docs/execution.md` and `src/root.zig`. Only the public root contained textual
conflict markers. The canonical guidance/root README retained the parent text
despite the conflict report; they were deliberately reconciled using the exact
frozen source documents, plus the accepted scan contract. The documentation
index, execution guide and public exports now describe one public model.

The parent's implemented scan behavior is preserved on the new foundation:

- [`scan`](../src/ops/scan.zig) accepts declaration inputs, infers injected
  leading dependencies and treats state/item as ordinary trailing data.
  Its reducer remains pure, exact-state and infallible; purity is not statically
  proven. Every run starts from a shallow seed copy and emits updates only.
- Exclusive recurrences use a typed cursor; actual shared references use normal
  publication and edge retirement. Held state retains its run-scoped lifecycle.
  No public eager executor or `With` form was restored.
- The [monitor](../examples/scan.zig) and its external integration test use
  `run(bindings, flows)` and distinct nominal writer roles.
- [Current public scan tests](../tests/declarative_scan.zig) cover fresh runs,
  empty/singleton input, injected suffix separation, managed lifetime,
  exclusive named lowering, shared prefixes, held state, error-valued data,
  source failure, no-extra-probe/resuming iterators, zero prefixes and snapshots.
  Seven current-API compile-fail fixtures and
  [runtime-input cross fixtures](../tests/cross/declarative_scan.zig) complement them.
- The original 20 scan tests, 15 invalid-contract fixtures and cross fixture
  remain private regression evidence through `src/legacy_test_api.zig`, not a
  second public API. Their original transport recurrence is retained.

Historical performance records are unchanged. Four opt-in drivers smoke-ran
at N=8/C=1, one warmup and one trial, with correctness checks passing; these
smokes are not a new performance baseline. An initial zero-warmup invocation
was rejected with `ExpectedPositiveOptions`; rerunning with one warmup passed.

Combined destination validation passed with exactly Zig **0.17.0**, native
macOS ARM64:

```sh
zig fmt --check build.zig build.zig.zon src tests examples benchmarks
zig build declarative-test
zig build lifecycle-test
zig build measurement-test
zig build test
zig build test -Doptimize=ReleaseFast
zig build check
zig build example
zig build io-examples
zig build example-scan
```

The installed `copy-lines` also copied a finite two-line LF fixture with exact
`cmp` equality. Local Markdown links/anchors, instruction symlinks and whitespace
were checked. Cross objects include the current scan/hold/sampling fixture on
all six catalog targets; they were not executed abroad. No race detector or
exhaustive interleaving proof was run, and the historical measurements are not
relabeled as evidence for this combined revision.

Next review: approve the combined declaration/resource model and migrated scan
before porting either sibling feature or beginning the performance roadmap.
