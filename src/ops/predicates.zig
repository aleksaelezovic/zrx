//! Static boolean composition, not closures or a runtime predicate interpreter.
const cb = @import("../internal/callbacks.zig");
const decl = @import("../data/declarations.zig");
const composition = @import("../internal/composition.zig");
const Tag = @import("../internal/predicate.zig").Tag;

/// Left-to-right short-circuit conjunction. Accepts a typed predicate or flat
/// nonempty tuple; nest all/any explicitly rather than nesting callback tuples.
/// Each predicate receives the same item and its own normally injected prefix.
/// A fallible predicate makes the composition fallible; first error stops it.
pub fn all(comptime predicates: anytype) Compound(.all, cb.functions(predicates, 1)) {
    return .{};
}

/// Left-to-right short-circuit disjunction. Skipped predicates are not invoked.
/// Requirements of every declared predicate remain statically reachable even
/// when a particular item short-circuits. Return is bool or anyerror!bool.
pub fn any(comptime predicates: anytype) Compound(.any, cb.functions(predicates, 1)) {
    return .{};
}

const Mode = enum { all, any };
fn Compound(comptime mode: Mode, comptime predicates: anytype) type {
    const First = cb.Info(predicates[0], 1);
    const Input = First.Params[First.Params.len - 1];
    const fallible = block: {
        var result = false;
        for (predicates) |predicate| {
            const Meta = cb.Info(predicate, 1);
            cb.validate(predicate, &.{Input});
            if (composition.Payload(Meta.Return) != bool)
                @compileError("predicate composition: callbacks must return bool or E!bool");
            result = result or @typeInfo(Meta.Return) == .error_union;
        }
        break :block result;
    };
    return struct {
        pub const predicate_tag = Tag;
        pub const Services = decl.concat(&.{}, decl.services(predicates, 1, 0));
        pub const Params = decl.concat(&Services, &.{Input});
        pub const Return = if (fallible) anyerror!bool else bool;

        pub fn evaluate(env: anytype, item: Input) Return {
            inline for (predicates) |predicate| {
                const result = cb.invoke(predicate, env, .{item});
                const passed = if (@typeInfo(@TypeOf(result)) == .error_union) try result else result;
                if (mode == .all and !passed) return false;
                if (mode == .any and passed) return true;
            }
            return mode == .all;
        }
    };
}
