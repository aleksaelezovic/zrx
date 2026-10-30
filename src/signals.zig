const sequences = @import("sequences.zig");
const kind = @import("signal_kind.zig");

fn isLiteral(comptime T: type) bool {
    return T == comptime_int or T == comptime_float or T == @TypeOf(null) or T == @TypeOf(.literal);
}

/// Describe replacement-driven state. Run supplies its storage and lifetime.
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

pub fn Mapped(comptime Source: type, comptime functions: anytype) type {
    const U = block: {
        var Current = kind.Value(Source);
        for (functions) |transform| {
            Current = @TypeOf(transform(@as(Current, undefined)));
            // Every boundary must also be valid as a separate signal map.
            if (@sizeOf(Current) == 0)
                @compileError("map: signal transforms must return nonzero-sized values; use values and terminal effects");
        }
        break :block Current;
    };
    return struct {
        source: Source,
        pub const signal_tag = kind.Tag;
        pub const signal_kind = .mapped;
        pub const signal_functions = functions;
        pub const Value = U;
    };
}

/// Observe initial state and every committed replacement, without coalescing.
pub fn values(signal: anytype) Values(@TypeOf(signal)) {
    return .{ .signal = signal };
}

fn Values(comptime Signal: type) type {
    const T = kind.Value(Signal);
    return struct {
        signal: Signal,
        pub const signal_values_tag = kind.ValuesTag;
        pub const graph_tag = sequences.GraphTag;
        pub const sequence_tag = sequences.SequenceTag;
        pub const Item = T;
    };
}

/// Pair each event with a current snapshot: .{ event, value }. No flattening.
pub fn withLatestFrom(signal: anytype) Sample(@TypeOf(signal)) {
    return .{ .signal = signal };
}

fn Sample(comptime Signal: type) type {
    const T = kind.Value(Signal);
    return struct {
        signal: Signal,
        pub fn Output(comptime Input: type) type {
            const Pair = @Tuple(&.{ sequences.Item(Input), T });
            return struct {
                source: Input,
                signal: Signal,
                pub const signal_sample_tag = kind.SampleTag;
                pub const graph_tag = sequences.GraphTag;
                pub const sequence_tag = sequences.SequenceTag;
                pub const Item = Pair;
            };
        }
        pub fn apply(self: @This(), source: anytype) Output(@TypeOf(source)) {
            return .{ .source = source, .signal = self.signal };
        }
    };
}
