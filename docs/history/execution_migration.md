# Execution-model migration record

Status: historical implementation record of the breaking public API migration.
The package is **zrx**, not a second framework or public compatibility mode.
Current contracts live in [the execution guide](../execution.md) and source;
integration status and sibling reconciliation are in [the handoff](../integration.md).

## Accepted and implemented

- One cold declaration model. `pipe` connects declarations; only `run` executes.
  Typed `fromValue`/`fromSlice`, producers, adapters, streams, signals and I/O
  supply inputs. Selected roots terminate in effects returning void/E!void.
- `run(bindings, flows)` accepts a flat heterogeneous tuple of service values or
  resource recipes. Allocator and Io are mandatory directly supplied bindings.
  Exact service types are keys; nominal roles distinguish multiple instances.
- Callback suffixes are ordinary operator data; every leading parameter is an
  injected service. This replaces both explicit capability binding and the
  prototype dependency-struct convention. There are no public With variants.
- Resource recipes explicitly acquire and release provided values. Dependencies
  determine acquisition order, independent of tuple order. Release-only
  requirements are lifetime edges too. Missing keys, duplicates and cycles fail
  compilation; unreachable recipes remain cold.
- A recipe can provide a service instead of a borrowed value. Supplying both is
  a duplicate, not an override. `deriveResource` delegates a single-field nominal
  role to its configured private recipe; two databases do not share a global
  raw-pointer binding accidentally.
- Synchronous stages compose into typed loops. An allocation-free bounded alias
  scan identifies actual sharing. Exclusive named ancestors fuse, as do ordinary
  by-value chains. Shared computations retain once-per-item evaluation. Region
  selection occurs before processing, not by per-stage hot-loop dispatch.

See [execution contracts](../execution.md) and the tested
[two-resource program](../../examples/resources.zig) rather than duplicating API
snippets here. The public API lives in [root.zig](../../src/root.zig).

## Implementation and evidence

- [Callback metadata/invocation](../../src/internal/callbacks.zig) builds typed
  argument tuples and known direct calls; it does not perform runtime DI lookup.
- [Declarations](../../src/data/declarations.zig) retain callback/service metadata.
  [Recipes](../../src/internal/world/resources.zig) delegate explicit lifecycles.
  [Service planning](../../src/internal/world/dependencies.zig) computes the
  reachable dependency order at comptime and stores typed values per run.
  Only reachable bindings/value slots are retained; unused large recipe outputs
  do not reserve run-owned storage. Non-batch terminals store no batch buffer.
- [Run](../../src/run.zig) prepares buffers before acquisition for direct finite
  execution. Graph execution uses the audited [coordinator](../../src/internal/graph_run.zig),
  with a resource activation hook after gated worker startup.
- [Region binding](../../src/internal/execution/bind.zig) resolves runtime pointer
  identity, and [cursors](../../src/internal/execution/cursors.zig) process
  synchronous regions directly. Producer/shared/merge/retention/state boundaries
  retain transport, preparation allocations and tasks; this is not whole-runtime
  zero cost.
- [Public resource tests](../../tests/world.zig) cover recipes, role identities,
  borrowing, rerun, type transitions, failures, cancellation and no-allocation/
  no-concurrent-task finite execution, including named exclusive stages.
- [Public graph tests](../../tests/declarative_graphs.zig) cover minimal concurrent
  slot limits, named-chain fusion, shared prefix retirement, signals/sampling,
  merge/reduction, actual file I/O, allocation failures, activation failure and
  joining blocked users before service release.
- [Runtime-input loop](../../tests/world_loop.zig) permits scoped manual LLVM
  inspection. The shared [catalog](../../tests/codegen/catalog.zig) retains the
  original strict kernel comparisons and adds object-only current public API
  coverage. Kernel equality is not public executor/graph performance evidence.

On native ARM64 LLVM ReleaseFast, both the current finite fixture and a direct
equivalent with matching cancellation checkpoints had no stack allocas or
separate direct callback calls in their scoped bodies. Io cancellation calls
remain. The functions were not asserted to have identical IR, and no universal
zero-cost or foreign runtime claim follows.

```sh
zig version
zig build declarative-test
zig build example
zig build test
zig build test -Doptimize=ReleaseFast
zig build check
```

The old eager surface is retained only through `src/legacy_test_api.zig` for
internal regression/codegen fixtures. Archived executable programs are under
`tests/legacy_examples/`, not user-facing examples. No second supported public
framework, public compatibility mode or world package remains.
The [suite classification](../../tests/README.md) makes the facade wiring explicit.

## Error and ownership boundaries

Borrowed bindings/referents remain caller-owned. Managed service values release
after all users stop/join. Failed acquire cleans its own partial construction;
earlier successful services release in reverse order. Release is void,
non-failing and uncancelable; no panic unwinding or rollback is promised.

Stream callback outer errors fail run; signal-map errors/optionals remain state.
First-result selection prevents cleanup cancellation from replacing a result.
Restart can repeat external effects and is not durable recovery. Static
requirements do not prove arbitrary hidden global access, referent lifetime,
callback purity or termination.

## Preserved track 2 context

Source [Runtime and lifecycle](delta://thread/ksQQ1WGCFVMmQfKeOD6sXwmq2JLOAAtKpJIBxBDX6SG4hCRLX7nFizx94PwY)
was merged cleanly at captured version
`c51a1e93-38c8-4690-90de-59239000df07.753188`. Its persisted transcript was read
in full and had no further user decisions beyond the focused audit assignment.

The [audit](runtime_lifecycle.md) describes baseline
`39ac0c2998e1a65a18a8f7692909f5276e28ff64`. It reproduced no bug and supplied
four regressions: contended producer-result joins/cached errors, diamond-prefix
retirement with a draining sibling, cancellation during partial acquisition,
and joining blocked users before owned-file release. Those regressions remain.
The redesign was requested by the user, not justified by an audit bug finding.

Deterministic await-versus-retirement/post-activation-startup fault injection is
partially addressed by the [subsequent hardening schedules](runtime_lifecycle.md#subsequent-declaration-runtime-hardening):
both join orders and completed-prefix/state-failure scenarios are forced through
test-local Io shims. Faults at every startup point and exhaustive interleaving
coverage remain follow-ups. Only track 2 was pulled; no parent/other-track changes were
automatically imported. Original measurements retain their original baseline.

## Separate follow-up designs

Explicit execution boundaries, worker/queue primitives, managed allocator/Io
bootstrap, arbitrary nested resource derivation, fallible resource finalizers,
precisely inferred run error sets, multi-parent state, and formatter/linter/
canonicalization tooling are not implemented by this migration. Comptime
specialization can increase generated-code/compile-time costs; measure those
before adding further planner complexity or making universal zero-cost claims.
