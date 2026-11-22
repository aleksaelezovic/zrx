const zrx = @import("zrx");
const bytes = zrx.ext.bytes;

// `update` answers with a count, and a reducer has nowhere to put it.
const Counting = struct {
    sum: u8 = 0,

    pub fn update(hasher: *Counting, piece: []const u8) usize {
        for (piece) |byte| hasher.sum +%= byte;
        return piece.len;
    }

    pub fn final(hasher: Counting) u32 {
        return hasher.sum;
    }
};
const State = bytes.digest(Counting{});

fn ignore(_: u32) void {}

test {
    const pieces = [_][]const u8{"abc"};
    zrx.program(zrx.fromSlice(&pieces), .{ zrx.fold(State{}, State.update), zrx.map(State.final), zrx.forEach(ignore) }).run(.{});
}
