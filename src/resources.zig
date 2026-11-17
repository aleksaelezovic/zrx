//! Program bindings. Each acquired value stays alive around the rest of the run.
const di = @import("di.zig");
const lift = @import("pipe.zig").lift;

pub fn resource(comptime acquire: anytype, comptime release: anytype) Resource(acquire, release) {
    return .{};
}

fn Resource(comptime acquire: anytype, comptime release: anytype) type {
    return struct {
        pub const zrx_resource = {};

        pub fn bind(_: @This(), env: anytype, next: anytype) !void {
            const Env = @TypeOf(env);
            const Acquire = di.Bound("resource acquire", acquire, Env, &.{});
            const Value = di.Payload(Acquire.Return);
            if (Value == void) @compileError("resource: acquire must return the value to provide");
            const Release = if (@TypeOf(release) == @TypeOf(null)) void else di.Bound("resource release", release, Env, &.{Value});
            if (Release != void and Release.Return != void)
                @compileError("resource: release must return `void`; a release cannot fail");

            const open: Acquire = .init(env);
            const close: Release = if (Release == void) {} else .init(env);
            const value = try lift(open.call(.{}));
            defer if (Release != void) close.call(.{value});
            return next.call(di.extend(env, value));
        }
    };
}

fn isResource(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "zrx_resource");
}

pub fn run(bindings: anytype, env: anytype, program: anytype) !void {
    return apply(0, bindings, env, program);
}

fn apply(comptime i: usize, bindings: anytype, env: anytype, program: anytype) !void {
    if (i == bindings.len) return program.call(env);
    const binding = bindings[i];
    if (comptime isResource(@TypeOf(binding))) {
        const Next = struct {
            bindings: @TypeOf(bindings),
            program: @TypeOf(program),

            pub fn call(self: @This(), extended: anytype) !void {
                return apply(i + 1, self.bindings, extended, self.program);
            }
        };
        return binding.bind(env, Next{ .bindings = bindings, .program = program });
    }
    return apply(i + 1, bindings, di.extend(env, binding), program);
}
