const std = @import("std");
const zrx = @import("zrx");
const program = zrx.program;
const range = zrx.range;
const fromSlice = zrx.fromSlice;
const map = zrx.map;
const field = zrx.field;
const drain = zrx.drain;
const collections = zrx.ext.collections;

const Order = struct { id: u32, cents: u32, heat: f32, name: []const u8 };
const orders = [_]Order{.{ .id = 1, .cents = 250, .heat = 0.5, .name = "a" }};

fn ignore(_: anyerror) void {}

/// Runs with a rescue, so that the one thing wrong is what the case is about.
fn run(runnable: anytype) void {
    runnable.run(.{zrx.rescue(ignore)});
}

test {
    run(program(fromSlice(&orders), .{ collections.distinct(0, field(.id)), drain() }));
}
