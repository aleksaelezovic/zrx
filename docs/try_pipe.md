# Explicit fail-fast composition

`pipe` preserves error unions as values. `tryPipe(value, operators)` checks an
error-union input, then each eager stage result, returning immediately on the
first error without invoking later stages.

Both executors require a nonempty, flat tuple of operators. `tryPipe` always
returns `E!T`: `E` merges input and stage error sets, and `T` is the final success
payload. An entirely infallible pipeline returns `error{}!T`.

See the executable [fail-fast example](../examples/try_pipe.zig).

## Boundaries and grouping

Grouped `map(.{ first, second })` is normalized to consecutive transformations:
failure in `first` skips `second`, just as with separate `map` stages. This policy
does not enter custom operators' internal logic or a lazy `each` sequence.

At each boundary only the outer error union is checked, like ordinary Zig `try`;
an error union nested inside its success payload remains data for the next
callback. Optionals, bare error-set inputs, and errors stored inside sequence
elements are not automatically inspected, unwrapped, or skipped.

Zig does not permit an error union whose payload is a bare error set. `tryPipe`
therefore rejects bare error-set stage results, including intermediates inside
grouped maps. Wrap error data in a struct when it must travel through these
success channels. An initial bare error value may be consumed by a stage that
converts it to a supported payload type.

Use a named helper containing `tryPipe` for a locally fail-fast region inside an
ordinary pipeline, returning its result as data to the outer `pipe`. There is
no operator that changes executor policy halfway through a pipeline.

## Ownership on failure

Failure does not roll back earlier state changes or free intermediate owned
values. Arrange cleanup in a caller-owned scope or a named helper with Zig
`defer` or `errdefer`. Allocating via `collectAlloc` before a later fallible stage
can lose the only reference to that allocation when an error is returned; the
caller must arrange ownership explicitly.

There is no implicit allocation, scheduling, retry, or resource-management
runtime. A successful return does not imply durable persistence.

## Validation

Standalone native tests cover error-set merging, initial and intermediate
failures, grouped/separate maps, custom stateful operators, nested error unions,
null/void/error data, sequence-element errors, and caller-owned cleanup.
Compile-fail tests cover invalid compositions and unsupported payload types.
Exported runtime-input fixtures instantiate the executor for the cross-target
matrix; compilation is not foreign runtime execution or a performance proof.
