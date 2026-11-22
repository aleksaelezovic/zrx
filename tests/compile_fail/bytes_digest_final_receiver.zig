const zrx = @import("zrx");
const bytes = zrx.ext.bytes;

// `final` is not a method here: its parameter is not the hasher.
const Seeded = struct {
    sum: u8 = 0,

    pub fn update(hasher: *Seeded, piece: []const u8) void {
        for (piece) |byte| hasher.sum +%= byte;
    }

    pub fn final(seed: u32) u32 {
        return seed;
    }
};
const State = bytes.digest(Seeded{});

fn ignore(_: u32) void {}

test {
    const pieces = [_][]const u8{"abc"};
    zrx.program(zrx.fromSlice(&pieces), .{ zrx.fold(State{}, State.update), zrx.map(State.final), zrx.forEach(ignore) }).run(.{});
}
