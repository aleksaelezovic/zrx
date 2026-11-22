const zrx = @import("zrx");
const bytes = zrx.ext.bytes;

// The digests of `std.hash` are unsigned; a signed number is refused.
const Signed = struct {
    sum: u8 = 0,

    pub fn update(hasher: *Signed, piece: []const u8) void {
        for (piece) |byte| hasher.sum +%= byte;
    }

    pub fn final(hasher: Signed) i32 {
        return hasher.sum;
    }
};
const State = bytes.digest(Signed{});

fn ignore(_: i32) void {}

test {
    const pieces = [_][]const u8{"abc"};
    zrx.program(zrx.fromSlice(&pieces), .{ zrx.fold(State{}, State.update), zrx.map(State.final), zrx.forEach(ignore) }).run(.{});
}
