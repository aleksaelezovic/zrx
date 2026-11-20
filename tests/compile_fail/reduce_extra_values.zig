const std = @import("std");
const zrx = @import("zrx");
const program = zrx.program;
const range = zrx.range;

fn bump(state: [2]u32, value: u32) [2]u32 {
    return .{ state[0] + value, state[1] + 1 };
}

test {
    const seed: [2]u32 = .{ 0, 0 };
    program(range(u32, 0, 3), .{ zrx.fold(seed, zrx.reduce(seed, bump)), zrx.drain() }).run(.{});
}
