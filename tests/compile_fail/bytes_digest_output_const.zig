const zrx = @import("zrx");
const bytes = zrx.ext.bytes;

// A `final` that fills its output cannot be handed it as `const`.
const Summed = struct {
    sum: u8 = 0,

    pub fn update(hasher: *Summed, piece: []const u8) void {
        for (piece) |byte| hasher.sum +%= byte;
    }

    pub fn final(hasher: *Summed, out: *const [4]u8) void {
        @memset(out, hasher.sum);
    }
};
const State = bytes.digest(Summed{});

fn ignore(_: anytype) void {}

test {
    const pieces = [_][]const u8{"abc"};
    zrx.program(zrx.fromSlice(&pieces), .{ zrx.fold(State{}, State.update), zrx.map(State.final), zrx.forEach(ignore) }).run(.{});
}
