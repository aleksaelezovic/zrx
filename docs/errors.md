# Operation errors and explicit handling

[Documentation index](README.md) · [Execution and ownership](execution.md)

An operation failure is an outcome, not an immediate cancellation of every pipe.
Stream `map`/`each`, `filter`, and `tap` skip pending errors without calling their
success callbacks. Type transitions still describe the success path; no missing
success value is fabricated. Sharing, merging, and event sampling preserve these
outcomes. An error reaching a terminal unhandled fails `run` and cancels peers.

There is one error model, including after retry exhaustion:

| Intent | Declaration |
|---|---|
| Replace a matching failure with the current success type | [`recover(handler)`](../src/ops/recover.zig) |
| Send failures to a persistent report/effect lane | [`whenError(ErrorSet, operators)` inside `branch`](../src/ops/branch.zig) |
| Explicitly ignore handled failure records | [`discard()`](../src/ops/effects.zig) |

`recover` has a typed `(services..., ErrorSet) T` callback returning exactly the
current success item type, without an error union. Successes bypass it.
Unmatched errors remain pending for later handlers. Narrow sets select specific
errors; `anyerror` covers all operation errors, without an `All` variant.

`whenError` supplies [`Failure(ErrorSet)`](../src/data/failures.zig) records with
an `err` field, not a borrowed original item or hidden history. Map the record
to a report and use normal terminal sinks. All branch cases either terminate
or produce one common type. Existing `when` and final `otherwise` only select
successes; otherwise is not an implicit catch-all.

Map/filter/tap do not accept bare error-set/error-union item arguments as
implicit handlers. Box intentional error data in application records instead.
Leading injected service parameters are unaffected.

## Run the real program

The [error-routing example](../examples/errors.zig) processes successes into
stdout and errors into stderr using one declared program:

```sh
zig build example-errors
```

Its composition accepts swappable sink declarations; [tests](../tests/errors.zig)
run the same named domain stages with two temporary files. Per-lane order is
preserved; no order between stdout and stderr is promised.

## Handling is not queue admission

An error lane accepts responsibility at a callback or terminal, not when a
report merely enters its queue. If a selected lane retires before acceptance,
the original error remains unhandled. Raw Failure records cannot be silently
filtered, prefixed, suffix-retained, nested-routed or used as signal state/events:
first handle them with a map, effect/reduction, or explicit discard.
Batch/collection terminals accept records into their run-owned storage and
retain normal failure cleanup. Callback inputs/storage contain no delivery lease.

Reporting may itself fail (`E!void` effects or fallible report maps). That is a
new error, not an automatic loop into the same error branch. Handle it farther
down a value-producing lane, or let the terminal return it. Earlier effects are
not rolled back.

## Stateful and execution boundaries

| Boundary | Pending operation error |
|---|---|
| `take` / `maxItems` | Forward without spending success-item budget; excess creates a pending `TooManyItems` and ends the edge |
| `scan` | Forward without changing accumulated state |
| `fold` | Discard partial state, emit the first error, end without another probe |
| `takeLast` | Discard retention, emit the first error, end |
| `collectThen` / `batchThen` | Fail unhandled; discard pending storage, suppress end/partial callbacks |
| `hold` update input | Unhandled state-update boundary; recover before hold |

Cancellation, producer/iterator/I/O source failures, acquisition and infrastructure
failures remain execution control. They never enter recover/whenError/retry
policies. Terminal effects and finalization have no downstream item stage, so
their errors return from run normally.

Optional/source-provided error-union values and signal-map error-union **state**
are still data, not newly thrown operation failures. Use explicit record types
to interpret such data with map. This distinction does not make source failures
recoverable or alter signal-family commit/lifetime rules.
