# Synchronous effects

`tap(effect)` and `tapWith(capability, effect)` invoke synchronous effects and
forward values. `pipe` preserves errors as values; `tryPipe` explicitly opts
into fail-fast execution. There is no reactive behavior or scheduling.

## Effect contracts

Callbacks are comptime-known functions with explicitly typed runtime parameters.
`tap` takes a unary callback. `tapWith` takes a callback whose first parameter is
an explicit capability `C`, followed by value `T`. The capability may be a
caller-owned state pointer, `std.Io`, or a standard writer; it need not be a
pointer. zrx does not introduce an I/O wrapper or universal context.

Both forms share the [existing operator protocol](sequences.md#runtime-capabilities-and-custom-operators).

| Form and effect signature | Stage output |
|---|---|
| `tap`: `fn (T) void` | `T` |
| `tap`: `fn (T) E!void` | `E!T` |
| `tapWith`: `fn (C, T) void` | `T` |
| `tapWith`: `fn (C, T) E!void` | `E!T` |

Other return payloads, generic callbacks, and function pointers are rejected at
comptime. Effects that compute a new value belong in a transformation, not in
`tap` with a silently discarded result.

Normal Zig argument coercions apply. The forwarded value is the same coerced
`T` supplied to the effect. For example, a callback accepting `u32` can accept
an input `u8` or an integer literal, and the forwarded type is `u32`.

See the executable [effects example](../examples/effects.zig), which uses
`std.Io.Writer.fixed` directly, without any zrx writer abstraction.

## Choosing error flow

`pipe` never unwraps errors automatically. A fallible effect yields an error-union
value that can be inspected by a later stage. A callback expecting plain `T`
cannot consume `E!T` without an explicit recovery step.

`tryPipe` instead checks outer error unions and skips later stages on failure.
See [fail-fast composition](try_pipe.md) for its return types, grouping,
error-boundary, and ownership contracts. Null and sequence-element errors remain
data under either executor.

Zig does not permit an error union whose payload is a bare error set. Therefore
fallible tap callbacks cannot forward a bare error-set input. Wrap error data in
a struct when it must travel through that success channel.

## Execution and ownership

- Invoke the callback once per reached stage per pipeline call, in pipeline order.
  Constructing the operator does not invoke it. This is not durable exactly-once
  execution: calling the pipeline again invokes the effect again.
- Both tap forms act on the whole value. Tapping a lazy view does not consume it
  or run per-element effects. There is no `tapEach` or tuple-of-effects form.
- The capability is stored by value; referenced resources remain caller-owned
  and must outlive use. No implicit allocation, close, free, flush, or scheduling.
- Failure does not roll back earlier effects or partial changes made by the
  callback. Success means the callback returned successfully, not that a
  transaction committed or data became durable.

Neither executor automatically frees owned intermediates on failure; see
[ownership on failure](try_pipe.md#ownership-on-failure). The effects example
avoids this issue by using caller-owned storage.

## Validation scope

Native tests cover ordering, error flow, grouped/separate forms, coercions,
capabilities, and ownership boundaries. Compile-fail tests cover invalid
signatures and transitions. Cross fixtures instantiate effects and standard
writers for the target matrix.

The [codegen catalog](../tests/codegen/catalog.zig) includes strict comparison
cases for both tap forms. The fallible `tryPipe` fixture is behavior/cross-only:
its current optimized output differs from the imperative baseline. No general
zero-overhead guarantee is implied.

These synchronous tap operators do not add reactive scheduling or cancellation.
Stream/signal execution uses the separate [`run` boundary](pipes.md) and terminal
effects. Retries, idempotency, and reactive reducers remain separate designs.
Finite synchronous reduction is covered by [`fold` and `tryFold`](reduction.md).
