const zrx = @import("zrx");
const bytes = zrx.ext.bytes;

// `digest_length` is a number of bytes, not text.
const Summed = struct {
    sum: u8 = 0,

    pub const digest_length = "4";

    pub fn update(hasher: *Summed, piece: []const u8) void {
        for (piece) |byte| hasher.sum +%= byte;
    }

    pub fn final(hasher: *Summed, out: []u8) void {
        @memset(out, hasher.sum);
    }
};
const State = bytes.digest(Summed{});

fn ignore(_: anytype) void {}

test {
    const pieces = [_][]const u8{"abc"};
    zrx.program(zrx.fromSlice(&pieces), .{ zrx.fold(State{}, State.update), zrx.map(State.final), zrx.forEach(ignore) }).run(.{});
}
