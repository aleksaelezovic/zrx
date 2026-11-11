const std = @import("std");
const zrx = @import("zrx");
const pipe = zrx.pipe;
const program = zrx.program;
const range = zrx.range;

// A stage that reports a failure to the run must be able to return it:
// without `failure`, the run would have no typed error to end with.
const Silent = struct {
    pub const zrx_operator = {};
    pub const name = "silent";

    pub fn Out(comptime _: type, comptime In: type) type {
        return In;
    }

    pub fn Stage(comptime Env: type, comptime In: type) type {
        return struct {
            io: std.Io,
            supervision: zrx.operator.Supervision,

            pub const zrx_boundary = {};

            pub fn init(self: *@This(), _: *const Silent, env: Env) !void {
                self.* = .{ .io = zrx.di.get(env, std.Io), .supervision = zrx.di.get(env, zrx.operator.Supervision) };
            }

            pub fn push(self: *@This(), item: In, down: anytype) !zrx.Flow {
                self.supervision.fail(self.io, self);
                return down.push(item);
            }
        };
    }
};

test {
    try program(range(u32, 0, 3), pipe(.{ Silent{}, zrx.drain() })).run(.{std.testing.io});
}
