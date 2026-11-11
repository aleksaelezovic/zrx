//! A handler combinator this app needs and zrx does not have yet.
const zrx = @import("zrx");
const di = zrx.di;

/// `handler`, with a failure turned into a value: when it returns an error,
/// the result is `fallback(deps..., err)` instead. Both forward their
/// dependencies, like the combinators in zrx.
pub fn orElse(comptime handler: anytype, comptime fallback: anytype) type {
    return struct {
        pub const zrx_handler = {};

        pub fn requires(comptime arity: usize) []const type {
            return di.merge(di.requires("orElse", handler, arity), di.requires("orElse", fallback, 1));
        }

        pub fn call(env: anytype, args: anytype) di.Payload(di.Result("orElse", handler, di.types(@TypeOf(args)))) {
            return di.invoke(handler, env, args) catch |err| di.invoke(fallback, env, .{err});
        }
    };
}
