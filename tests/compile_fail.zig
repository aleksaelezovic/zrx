//! Misuse must fail to compile, with a message that says what is wrong and
//! what to do instead. Each entry names a file in `compile_fail/` and the
//! compile error it must produce (the build matches it as the end of a line).
pub const cases = .{
    .{ "after_terminal", "pipe: `map` at position 1 comes after the terminal operator `subscribe`; nothing flows past a terminal operator" },
    .{ "comptime_dependency", "zrx: dependency 0 has type `comptime_int`; a dependency is a runtime value keyed by its type, so give it a named type" },
    .{ "dependencies_not_tuple", "zrx: dependencies must be a tuple such as `.{ io, logger }`, got `u32`" },
    .{ "duplicate_dependency", "zrx: dependency type `duplicate_dependency.Scale` is provided twice; wrap one in a distinct struct type to tell them apart" },
    .{ "empty_pipe", "pipe: a pipe needs at least one operator" },
    .{ "filter_result", "filter: predicate must return `bool` or `E!bool`, got `u32`" },
    .{ "flatten_scalar", "flatten: items must be arrays or slices, got `u32`" },
    .{ "handler_arity", "map: handler `fn () u32` must end with 1 data parameter(s); dependencies come before them" },
    .{ "item_type", "map: handler `fn (u64) u64` takes `u64` but receives `u32` here" },
    .{ "map_void", "map: handler returns no value; use tap(...) for an effect that keeps the item, or subscribe(...) to end the pipe" },
    .{ "missing_dependency", "map: handler `fn (missing_dependency.Scale, u32) u32` asks for dependency `missing_dependency.Scale`, which is not provided here; provided: (nothing). Pass it to `run(.{ ... })` or add `provide(...)` upstream." },
    .{ "not_handler", "map: expected a handler (a comptime-known function), got `comptime_int`" },
    .{ "not_operator", "pipe: element 1 is not an operator (got `fn (u32) u32`); a pipe holds operators such as map(...), filter(...) or another pipe" },
    .{ "program_not_pipe", "program: expected `pipe(.{ ... })`, got `ops.sink.Subscribe((function 'ignore'))`" },
    .{ "program_not_source", "program: the first argument must be a source such as fromSlice(...), got `*const [2]u32`" },
    .{ "scan_reducer", "scan: reducer must return `u64` or `E!u64`, got `u32`" },
    .{ "unterminated", "program: the pipe must terminate, but it still emits `u32`; end it with subscribe(...), drain() or another terminal operator" },
    .{ "untyped_dependency", "map: handler `fn (anytype, u32) u32` has an untyped dependency parameter; only trailing data parameters may be `anytype`" },
};
