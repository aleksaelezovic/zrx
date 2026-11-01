const decl = @import("../data/declarations.zig");
const seq = @import("../data/sequences.zig");
const cb = @import("../internal/callbacks.zig");

/// Replace matching pending operation errors with the current success item type.
/// The callback is fn (services..., ErrorSet) T, never fallible. Successes bypass
/// it; unmatched errors continue to later handlers. Cancellation and source/
/// acquisition failures are control flow, not recoverable operation outcomes.
pub fn recover(comptime handler: anytype) Recover(handler) {
    return .{};
}

fn Recover(comptime handler: anytype) type {
    const Info = cb.Info(handler, 1);
    const E = Info.Params[Info.Params.len - 1];
    if (@typeInfo(E) != .error_set) @compileError("recover: handler input must be an error set");
    return struct {
        pub fn Output(comptime Source: type) type {
            decl.requireSource(Source);
            const T = seq.Item(Source);
            if (Info.Return != T) @compileError("recover: handler must return exactly the success item type, without an error union");
            return struct {
                pub const sequence_tag = seq.SequenceTag;
                pub const graph_tag = seq.GraphTag;
                pub const node_kind = .recover;
                pub const Item = T;
                pub const callback = handler;
                pub const ErrorSet = E;
                pub const Requirements = decl.concat(decl.requirements(Source), &Info.Services);
                source: Source,
            };
        }
        pub fn apply(_: @This(), source: anytype) Output(@TypeOf(source)) {
            return .{ .source = source };
        }
    };
}
