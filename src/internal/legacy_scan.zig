//! Pre-migration scan declaration, retained only for the original regression
//! fixtures. The public operator uses declaration inputs and injected callbacks.
const composition = @import("composition.zig");
const sequences = @import("../data/sequences.zig");

pub fn scan(initial: anytype, comptime reducer: anytype) Scan(reducer) {
    if (@TypeOf(initial) == @TypeOf(undefined))
        @compileError("scan: initial value must not be undefined");
    return .{ .initial = initial };
}

fn Scan(comptime reducer: anytype) type {
    const info = composition.callbackInfo(reducer, "scan: reducer", 2);
    const State = info.param_types[0].?;
    if (@typeInfo(State) == .error_union)
        @compileError("scan: accumulator must not be an outer error union; wrap error data in a struct");
    if (@typeInfo(info.return_type.?) == .error_union)
        @compileError("scan: fallible reducers are not supported");
    if (info.return_type.? != State)
        @compileError("scan: reducer result must exactly match the accumulator type");
    if (@sizeOf(State) == 0)
        @compileError("scan: zero-sized accumulator values are not supported");
    return struct {
        initial: State,
        pub fn Output(comptime Input: type) type {
            _ = @TypeOf(reducer(@as(State, undefined), @as(sequences.Item(Input), undefined)));
            return struct {
                source: Input,
                initial: State,
                pub const sequence_tag = sequences.SequenceTag;
                pub const graph_tag = sequences.GraphTag;
                pub const Item = State;
                pub const declaration_source = Input;
                pub const declaration_kind = .scanned;
                pub const declaration_reducer = reducer;
            };
        }
        pub fn apply(self: @This(), source: anytype) Output(@TypeOf(source)) {
            return .{ .source = source, .initial = self.initial };
        }
    };
}
