const composition = @import("../internal/composition.zig");

/// Invoke a typed unary effect once and forward its input. A void callback
/// yields T; an E!void callback yields E!T. No implicit scheduling or cleanup.
/// Normal coercions determine the forwarded T; constructing the operator does
/// not call it. Effects act on a whole value, never consume a view implicitly.
/// Use a transformation for non-void payloads, forEach for per-element effects.
///
/// pipe keeps E!T as data; tryPipe checks it. Optional/element errors remain data.
/// Bare error-set input cannot be forwarded by a fallible effect (wrap it in a
/// struct). No retry, rollback, flush, durability, or exactly-once guarantee:
/// each pipeline call invokes reached effects again. See examples/effects.zig.
pub fn tap(comptime effect: anytype) Effect(effect, false) {
    return .{ .capability = {} };
}

// Shared specialization for the unary/capability forms.
pub fn Effect(comptime effect: anytype, comptime with_capability: bool) type {
    const name = if (with_capability) "tapWith" else "tap";
    const info = composition.callbackInfo(effect, name ++ ": effect", if (with_capability) 2 else 1);
    const Capability = if (with_capability) info.param_types[0].? else void;
    const Input = info.param_types[if (with_capability) 1 else 0].?;
    const Return = info.return_type.?;
    const Result = block: {
        if (Return == void) break :block Input;
        if (@typeInfo(Return) == .error_union and composition.Payload(Return) == void) {
            if (@typeInfo(Input) == .error_set) {
                @compileError(name ++ ": fallible effects cannot forward bare error-set inputs; wrap error data in a struct");
            }
            break :block @typeInfo(Return).error_union.error_set!Input;
        }
        @compileError(name ++ ": effect must return void or an error union with void payload");
    };
    return struct {
        capability: Capability,

        pub fn Output(comptime _: type) type {
            return Result;
        }

        pub fn apply(self: @This(), value: Input) Result {
            const result = if (with_capability) effect(self.capability, value) else effect(value);
            if (Return != void) try result;
            return value;
        }
    };
}
