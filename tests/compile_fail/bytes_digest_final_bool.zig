const zrx = @import("zrx");
const bytes = zrx.ext.bytes;

// A `bool` is no digest: `final` returns an unsigned integer or fills an array.
const Flag = struct {
    sum: u8 = 0,

    pub fn update(hasher: *Flag, piece: []const u8) void {
        for (piece) |byte| hasher.sum +%= byte;
    }

    pub fn final(hasher: Flag) bool {
        return hasher.sum != 0;
    }
};
const State = bytes.digest(Flag{});

fn ignore(_: bool) void {}

test {
    const pieces = [_][]const u8{"abc"};
    zrx.program(zrx.fromSlice(&pieces), .{ zrx.fold(State{}, State.update), zrx.map(State.final), zrx.forEach(ignore) }).run(.{});
}
