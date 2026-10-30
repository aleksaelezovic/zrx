const sequences = @import("../data/sequences.zig");
const kind = @import("../internal/signal_kind.zig");

fn isLiteral(comptime T: type) bool {
    return T == comptime_int or T == comptime_float or T == @TypeOf(null) or T == @TypeOf(.literal);
}

/// Describe replacement-driven state of the input item type T. Initial state
/// coerces normally from a typed runtime value or literal; literal undefined and
/// zero-sized state are rejected. Initial expressions are still ordinary caller
/// code: hold(loadInitial()) does not defer loadInitial.
///
/// Run owns storage/updating/lifetime. Each input replaces the whole state,
/// including equal/error/optional values. Filter updates before hold to reject
/// replacements without affecting its initial value. Use map for pure derived
/// current state, values for observation, withLatestFrom for event sampling.
/// See examples/signals.zig and docs/state.md.
pub fn hold(initial: anytype) Hold(@TypeOf(initial), if (isLiteral(@TypeOf(initial))) initial else {}) {
    return .{ .initial = if (comptime isLiteral(@TypeOf(initial))) {} else initial };
}

fn Hold(comptime Initial: type, comptime literal: anytype) type {
    if (Initial == @TypeOf(undefined)) @compileError("hold: initial value must not be undefined");
    return struct {
        initial: if (isLiteral(Initial)) void else Initial,

        pub fn Output(comptime Input: type) type {
            const T = sequences.Item(Input);
            if (@sizeOf(T) == 0) @compileError("hold: zero-sized state values are not supported");
            _ = @TypeOf(@as(T, if (comptime isLiteral(Initial)) literal else @as(Initial, undefined)));
            return struct {
                source: Input,
                initial: T,
                pub const signal_tag = kind.Tag;
                pub const signal_kind = .root;
                pub const Value = T;
            };
        }

        pub fn apply(self: @This(), source: anytype) Output(@TypeOf(source)) {
            return .{
                .source = source,
                .initial = if (comptime isLiteral(Initial)) literal else self.initial,
            };
        }
    };
}
