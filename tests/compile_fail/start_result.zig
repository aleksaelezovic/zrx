const zrx = @import("zrx");
const pipe = zrx.pipe;
const program = zrx.program;
const range = zrx.range;

// `start` answers like a push, so that a pipe that is done before the first
// item is known to be: a hook that returns nothing would hide that.
const Quiet = struct {
    pub const zrx_operator = {};
    pub const name = "quiet";

    pub fn Out(comptime _: type, comptime In: type) type {
        return In;
    }

    pub fn Stage(comptime Env: type, comptime In: type) type {
        return struct {
            pub fn init(_: *@This(), _: *const Quiet, _: Env) !void {}

            pub fn start(_: *@This(), down: anytype) !void {
                _ = try down.push(@as(In, 0));
            }

            pub fn push(_: *@This(), item: In, down: anytype) !zrx.Flow {
                return down.push(item);
            }
        };
    }
};

test {
    try program(range(u32, 0, 3), pipe(.{ Quiet{}, zrx.drain() })).run(.{});
}
