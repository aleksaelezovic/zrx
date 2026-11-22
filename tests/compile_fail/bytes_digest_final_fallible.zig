const zrx = @import("zrx");
const bytes = zrx.ext.bytes;

// A `final` that fills an array returns nothing: this one can fail.
const Fallible = struct {
    sum: u8 = 0,

    pub fn update(hasher: *Fallible, piece: []const u8) void {
        for (piece) |byte| hasher.sum +%= byte;
    }

    pub fn final(hasher: *Fallible, out: *[1]u8) error{Empty}!void {
        if (hasher.sum == 0) return error.Empty;
        out[0] = hasher.sum;
    }
};
const State = bytes.digest(Fallible{});

fn ignore(_: [1]u8) void {}

test {
    const pieces = [_][]const u8{"abc"};
    zrx.program(zrx.fromSlice(&pieces), .{ zrx.fold(State{}, State.update), zrx.map(State.final), zrx.forEach(ignore) }).run(.{});
}
